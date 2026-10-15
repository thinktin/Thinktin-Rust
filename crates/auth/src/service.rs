//! 账号与设备会话的业务流程（WBS 4.1、4.2）：发验证码、登录、刷新、核对访问令牌、退出登录、
//! 远程下线、注销账号。
//!
//! 刷新令牌每次刷新都轮换。拿已经被换掉的旧令牌来刷新，说明令牌可能被盗（攻击者和本人各拿着一份），
//! 整个会话吊销，两边都得重新登录；只有刚轮换完很短时间内（App 并发刷新）的旧令牌例外。

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use chrono::Utc;
use proto::api::ErrorCode;
use proto::domain::{
    DeviceId, DevicePlatform, PushChannelKind, SessionId, User, UserId, UserStatus,
};
use serde_json::json;
use store::Db;
use zeroize::Zeroizing;

use crate::access_token::{ACCESS_TTL_SECS, AccessTokenIssuer, AccessTokenVerifier};
use crate::secrets::{
    CODE_MAX_ATTEMPTS, CODE_TTL_SECS, RefreshToken, code_hash, generate_code, normalize_phone,
    verify_code,
};
use crate::signed::TokenError;
use crate::sms::{CodePurpose, SmsSender};

#[derive(Debug, Clone)]
pub struct AuthConfig {
    pub code_ttl: Duration,
    /// 同一手机号两次发码的最短间隔。
    pub code_resend_interval: Duration,
    /// 同一手机号 24 小时内最多发几次。
    pub code_daily_limit: i64,
    /// 刷新令牌的滑动有效期：这么久没刷新就要重新登录。
    pub refresh_ttl: Duration,
    /// 轮换后这么久之内拿旧令牌刷新算并发刷新，不算被盗。
    pub refresh_reuse_grace: Duration,
}

impl Default for AuthConfig {
    fn default() -> Self {
        Self {
            code_ttl: Duration::from_secs(CODE_TTL_SECS),
            code_resend_interval: Duration::from_secs(60),
            code_daily_limit: 10,
            refresh_ttl: Duration::from_secs(30 * 24 * 3600),
            refresh_reuse_grace: Duration::from_secs(30),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("invalid phone number")]
    InvalidPhone,
    #[error("too many codes requested, retry after {retry_after_secs}s")]
    TooManyCodes { retry_after_secs: u64 },
    /// 验证码错误、过期或没发过（不区分，防止探测）。
    #[error("invalid or expired code")]
    InvalidCode,
    #[error("account is frozen")]
    AccountFrozen,
    /// 访问令牌无效或过期：客户端刷新后重试。
    #[error("not authenticated")]
    Unauthenticated,
    /// 会话被吊销或过期：客户端回到登录页。
    #[error("session revoked")]
    SessionRevoked,
    #[error("not found")]
    NotFound,
    #[error("invalid: {0}")]
    Invalid(String),
    #[error("sms: {0}")]
    Sms(#[from] crate::sms::SmsError),
    #[error("token: {0}")]
    Token(#[from] TokenError),
    #[error(transparent)]
    Store(store::Error),
}

impl From<store::Error> for AuthError {
    fn from(e: store::Error) -> Self {
        match e {
            store::Error::NotFound => AuthError::NotFound,
            store::Error::Invalid(m) => AuthError::Invalid(m),
            other => AuthError::Store(other),
        }
    }
}

impl AuthError {
    /// 对客户端的错误码。
    pub fn code(&self) -> ErrorCode {
        match self {
            Self::InvalidPhone | Self::InvalidCode | Self::Invalid(_) => ErrorCode::Invalid,
            Self::TooManyCodes { .. } => ErrorCode::RateLimited,
            Self::AccountFrozen => ErrorCode::Forbidden,
            Self::Unauthenticated => ErrorCode::Unauthenticated,
            Self::SessionRevoked => ErrorCode::SessionRevoked,
            Self::NotFound => ErrorCode::NotFound,
            Self::Sms(_) => ErrorCode::Unavailable,
            Self::Token(_) | Self::Store(_) => ErrorCode::Internal,
        }
    }
}

pub type Result<T, E = AuthError> = std::result::Result<T, E>;

/// 登录时客户端报上来的设备信息。
#[derive(Debug, Clone)]
pub struct NewDevice {
    pub platform: DevicePlatform,
    pub name: String,
    pub push: Option<(PushChannelKind, String)>,
}

/// 交给客户端的一对令牌。
pub struct Tokens {
    pub access_token: String,
    pub access_expires_in: u64,
    pub refresh_token: Zeroizing<String>,
}

impl std::fmt::Debug for Tokens {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Tokens")
            .field("access_expires_in", &self.access_expires_in)
            .finish_non_exhaustive()
    }
}

#[derive(Debug)]
pub struct Login {
    pub user: User,
    pub new_user: bool,
    pub device_id: DeviceId,
    pub session_id: SessionId,
    pub tokens: Tokens,
}

/// 通过核对的请求方。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Principal {
    pub user: UserId,
    pub device: DeviceId,
    pub session: SessionId,
}

impl Principal {
    /// 审计日志里的操作者。
    pub fn actor(&self) -> String {
        format!("user:{}", self.device)
    }
}

pub struct AuthService {
    db: Db,
    cfg: AuthConfig,
    pepper: Zeroizing<Vec<u8>>,
    issuer: AccessTokenIssuer,
    verifier: AccessTokenVerifier,
    sms: Arc<dyn SmsSender>,
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}

impl AuthService {
    /// `pepper`：验证码 HMAC 的服务端密钥（至少 32 字节）。`verifier` 要包含 `issuer` 的公钥
    /// （轮换签名密钥时再加上旧公钥）。
    pub fn new(
        db: Db,
        cfg: AuthConfig,
        pepper: Zeroizing<Vec<u8>>,
        issuer: AccessTokenIssuer,
        verifier: AccessTokenVerifier,
        sms: Arc<dyn SmsSender>,
    ) -> Result<Self> {
        if pepper.len() < 32 {
            return Err(AuthError::Invalid(
                "code pepper must be at least 32 bytes".into(),
            ));
        }
        Ok(Self {
            db,
            cfg,
            pepper,
            issuer,
            verifier,
            sms,
        })
    }

    /// 给手机号发验证码。同一手机号限频；不论号码是否注册都一样处理（不泄露账号是否存在）。
    pub async fn send_code(&self, phone: &str, purpose: CodePurpose) -> Result<()> {
        let phone = normalize_phone(phone).map_err(|_| AuthError::InvalidPhone)?;
        let mut w = self.db.worker().await?;
        w.lock_phone(&phone).await?;
        let (last, sent_today) = w.login_code_stats(&phone).await?;
        if let Some(last) = last {
            let since = (Utc::now() - last).to_std().unwrap_or_default();
            if since < self.cfg.code_resend_interval {
                return Err(AuthError::TooManyCodes {
                    retry_after_secs: (self.cfg.code_resend_interval - since).as_secs().max(1),
                });
            }
        }
        if sent_today >= self.cfg.code_daily_limit {
            return Err(AuthError::TooManyCodes {
                retry_after_secs: 3600,
            });
        }
        let code = generate_code()?;
        let hash = code_hash(&self.pepper, purpose.as_str(), &phone, &code);
        w.insert_login_code(&phone, purpose.as_str(), &hash, self.cfg.code_ttl)
            .await?;
        w.commit().await?;
        // 提交后再发：发送失败时库里多一个没人知道的码，无害；先发后提交则可能发出一个无效的码。
        self.sms.send_code(&phone, &code, purpose).await?;
        Ok(())
    }

    /// 给已登录用户自己的手机号发码（注销账号、换手机号前的确认）。
    pub async fn send_code_to_self(&self, who: &Principal, purpose: CodePurpose) -> Result<()> {
        if purpose == CodePurpose::Login {
            return Err(AuthError::Invalid(
                "login codes are requested by phone number".into(),
            ));
        }
        let mut t = self.db.tenant(who.user).await?;
        let me = t.me().await?;
        t.rollback().await?;
        self.send_code(&me.phone, purpose).await
    }

    /// 校验并用掉验证码。失败计入尝试次数（单独提交，不随调用方的事务回滚）。
    async fn check_code(&self, phone: &str, purpose: CodePurpose, code: &str) -> Result<()> {
        let mut w = self.db.worker().await?;
        w.lock_phone(phone).await?;
        let Some(stored) = w.active_login_code(phone, purpose.as_str()).await? else {
            return Err(AuthError::InvalidCode);
        };
        if !verify_code(
            &self.pepper,
            purpose.as_str(),
            phone,
            code,
            &stored.code_hash,
        ) {
            w.fail_login_code(stored.id, CODE_MAX_ATTEMPTS).await?;
            w.commit().await?;
            return Err(AuthError::InvalidCode);
        }
        w.consume_login_code(stored.id).await?;
        w.commit().await?;
        Ok(())
    }

    /// 验证码登录。手机号没注册过就新建账号。每次登录建一台新设备和一个新会话。
    pub async fn login(&self, phone: &str, code: &str, device: &NewDevice) -> Result<Login> {
        let phone = normalize_phone(phone).map_err(|_| AuthError::InvalidPhone)?;
        self.check_code(&phone, CodePurpose::Login, code).await?;
        let mut w = self.db.worker().await?;
        let (user, new_user) = w.upsert_user_by_phone(&phone).await?;
        if user.status == UserStatus::Frozen {
            return Err(AuthError::AccountFrozen);
        }
        let push = device.push.as_ref().map(|(c, t)| (*c, t.as_str()));
        let device_id = w
            .create_device(user.id, device.platform, &device.name, push)
            .await?;
        let session_id = SessionId::new();
        let refresh = RefreshToken::generate(&session_id.to_string())?;
        w.create_session(
            session_id,
            user.id,
            device_id,
            &refresh.hash(),
            self.cfg.refresh_ttl,
        )
        .await?;
        w.audit(
            Some(user.id),
            &format!("user:{device_id}"),
            "auth.login",
            Some(&session_id.to_string()),
            &json!({ "new_user": new_user, "platform": device.platform.as_str() }),
        )
        .await?;
        w.commit().await?;
        let tokens = self.tokens(user.id, device_id, session_id, refresh)?;
        Ok(Login {
            user,
            new_user,
            device_id,
            session_id,
            tokens,
        })
    }

    fn tokens(
        &self,
        user: UserId,
        device: DeviceId,
        session: SessionId,
        refresh: RefreshToken,
    ) -> Result<Tokens> {
        let access_token = self.issuer.issue(
            &user.to_string(),
            &device.to_string(),
            &session.to_string(),
            unix_now(),
        )?;
        Ok(Tokens {
            access_token,
            access_expires_in: ACCESS_TTL_SECS,
            refresh_token: refresh.encode(),
        })
    }

    /// 用刷新令牌换一对新令牌（刷新令牌同时轮换）。
    pub async fn refresh(&self, refresh_token: &str) -> Result<Tokens> {
        let presented =
            RefreshToken::parse(refresh_token).map_err(|_| AuthError::Unauthenticated)?;
        let sid: SessionId = presented
            .session_id
            .parse()
            .map_err(|_| AuthError::Unauthenticated)?;
        let mut w = self.db.worker().await?;
        let Some(s) = w.session_for_refresh(sid).await? else {
            return Err(AuthError::Unauthenticated);
        };
        if s.revoked || s.expired || s.user_status == UserStatus::Deleted {
            return Err(AuthError::SessionRevoked);
        }
        if s.user_status == UserStatus::Frozen {
            return Err(AuthError::AccountFrozen);
        }
        let current = presented.matches(&s.refresh_hash);
        let previous = s
            .prev_refresh_hash
            .as_deref()
            .is_some_and(|h| presented.matches(h));
        if !current {
            if previous && s.since_rotation <= self.cfg.refresh_reuse_grace {
                // App 同时发了两个刷新请求，另一个刚轮换完：照常轮换，两边拿到的令牌都能用到下次刷新。
            } else if previous || w.refresh_hash_retired(sid, &presented.hash()).await? {
                // 出示的是这个会话以前用过的令牌（不只是上一个）：令牌被盗，整个会话吊销。
                w.revoke_session(sid, "refresh_token_reuse").await?;
                w.audit(
                    Some(s.user_id),
                    "system",
                    "auth.refresh_reuse",
                    Some(&sid.to_string()),
                    &json!({ "device": s.device_id.to_string() }),
                )
                .await?;
                w.commit().await?;
                tracing::warn!(session = %sid, "refresh token reuse detected, session revoked");
                return Err(AuthError::SessionRevoked);
            } else {
                return Err(AuthError::Unauthenticated);
            }
        }
        let next = RefreshToken::generate(&sid.to_string())?;
        w.rotate_session(sid, &next.hash(), self.cfg.refresh_ttl)
            .await?;
        w.commit().await?;
        self.tokens(s.user_id, s.device_id, sid, next)
    }

    /// 核对访问令牌：验签、有效期，再查会话没被吊销、账号可用。
    pub async fn authenticate(&self, access_token: &str) -> Result<Principal> {
        let claims = self
            .verifier
            .verify(access_token, unix_now())
            .map_err(|_| AuthError::Unauthenticated)?;
        fn parse<T: std::str::FromStr>(s: &str) -> Result<T> {
            s.parse().map_err(|_| AuthError::Unauthenticated)
        }
        let principal = Principal {
            user: parse(&claims.uid)?,
            device: parse(&claims.did)?,
            session: parse(&claims.sid)?,
        };
        let mut w = self.db.worker().await?;
        let state = w.session_state(principal.session).await?;
        w.rollback().await?;
        let Some(state) = state else {
            return Err(AuthError::Unauthenticated);
        };
        if state.user_id != principal.user || state.device_id != principal.device {
            return Err(AuthError::Unauthenticated);
        }
        match state.user_status {
            UserStatus::Frozen => return Err(AuthError::AccountFrozen),
            UserStatus::Deleted => return Err(AuthError::SessionRevoked),
            UserStatus::Active => {}
        }
        if !state.live {
            return Err(AuthError::SessionRevoked);
        }
        Ok(principal)
    }

    /// 退出登录：只吊销这台设备（会话、推送令牌）。agent 的运行授权不受影响，计划照常执行。
    pub async fn logout(&self, who: &Principal) -> Result<()> {
        self.revoke_device(who, who.device).await
    }

    /// 远程下线自己的某台设备。
    pub async fn revoke_device(&self, who: &Principal, device: DeviceId) -> Result<()> {
        let mut t = self.db.tenant(who.user).await?;
        let reason = if device == who.device {
            "logout"
        } else {
            "remote_logout"
        };
        t.revoke_device(device, reason).await?;
        t.audit(
            &who.actor(),
            &format!("auth.{reason}"),
            Some(&device.to_string()),
            &json!({}),
        )
        .await?;
        t.commit().await?;
        Ok(())
    }

    /// 注销账号：需要发到本人手机的 `delete_account` 验证码。吊销一切、销毁密钥，见
    /// [`store::Tx::erase_account`]。
    pub async fn delete_account(&self, who: &Principal, code: &str) -> Result<()> {
        let mut t = self.db.tenant(who.user).await?;
        let me = t.me().await?;
        t.rollback().await?;
        self.check_code(&me.phone, CodePurpose::DeleteAccount, code)
            .await?;
        let mut w = self.db.worker().await?;
        w.erase_account(who.user).await?;
        w.audit(
            Some(who.user),
            &who.actor(),
            "auth.delete_account",
            None,
            &json!({}),
        )
        .await?;
        w.commit().await?;
        Ok(())
    }

    /// 风控冻结或解冻：冻结后不能登录、刷新，所有运行授权暂停（换不出沙箱令牌），解冻后恢复。
    pub async fn set_frozen(&self, user: UserId, frozen: bool, reason: &str) -> Result<()> {
        let mut w = self.db.worker().await?;
        let status = if frozen {
            UserStatus::Frozen
        } else {
            UserStatus::Active
        };
        w.set_user_status(user, status).await?;
        w.audit(
            Some(user),
            "system",
            if frozen {
                "auth.freeze"
            } else {
                "auth.unfreeze"
            },
            None,
            &json!({ "reason": reason }),
        )
        .await?;
        w.commit().await?;
        Ok(())
    }
}
