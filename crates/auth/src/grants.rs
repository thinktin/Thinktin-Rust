//! 运行授权（WBS 4.3）和用它换沙箱令牌（4.4）。
//!
//! 运行授权只在平台内部，从不下发到客户端或沙箱。编排服务每次唤醒沙箱时用它换出一个短期沙箱令牌，
//! 这是唯一进沙箱的凭证；换令牌就算一次活动，顶层授权快到期时自动续期。

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use chrono::Utc;
use proto::domain::{GrantId, GrantScope, InstanceId, InstanceState, PlanId, RunGrant, UserStatus};
use store::Db;

use crate::sandbox_token::{SandboxTokenIssuer, TokenRequest};
use crate::service::{AuthError, Principal, Result};

#[derive(Debug, Clone)]
pub struct GrantConfig {
    /// 新授权的有效期（默认 90 天）。
    pub ttl: Duration,
    /// 剩余有效期不足这么久时，有活动就顺延回 `ttl`。
    pub renew_below: Duration,
    /// 沙箱令牌的有效期上限（不会超过授权本身的剩余有效期）。
    pub sandbox_token_ttl: Duration,
}

impl Default for GrantConfig {
    fn default() -> Self {
        Self {
            ttl: Duration::from_secs(90 * 24 * 3600),
            renew_below: Duration::from_secs(30 * 24 * 3600),
            sandbox_token_ttl: Duration::from_secs(24 * 3600),
        }
    }
}

pub struct GrantService {
    db: Db,
    cfg: GrantConfig,
    issuer: SandboxTokenIssuer,
}

/// 换出的沙箱令牌，连同它绑定的沙箱。
pub struct SandboxCredential {
    pub token: String,
    pub sandbox_id: String,
    pub expires_in: Duration,
}

impl std::fmt::Debug for SandboxCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SandboxCredential")
            .field("sandbox_id", &self.sandbox_id)
            .field("expires_in", &self.expires_in)
            .finish_non_exhaustive()
    }
}

impl GrantService {
    pub fn new(db: Db, cfg: GrantConfig, issuer: SandboxTokenIssuer) -> Self {
        Self { db, cfg, issuer }
    }

    /// 用户签发（领养实例、创建计划时由接口层调用）。
    pub async fn issue(
        &self,
        who: &Principal,
        instance: InstanceId,
        plan: Option<PlanId>,
        scope: &GrantScope,
    ) -> Result<RunGrant> {
        let mut t = self.db.tenant(who.user).await?;
        let grant = t
            .create_run_grant(instance, plan, scope, self.cfg.ttl)
            .await?;
        t.audit(
            &who.actor(),
            "grant.issue",
            Some(&grant.id.to_string()),
            &serde_json::json!({ "instance": instance.to_string() }),
        )
        .await?;
        t.commit().await?;
        Ok(grant)
    }

    /// 用户吊销（连同子授权）。
    pub async fn revoke(&self, who: &Principal, grant: GrantId, reason: &str) -> Result<u64> {
        let mut t = self.db.tenant(who.user).await?;
        let n = t.revoke_run_grant(grant, reason).await?;
        if n == 0 {
            return Err(AuthError::NotFound);
        }
        t.audit(
            &who.actor(),
            "grant.revoke",
            Some(&grant.to_string()),
            &serde_json::json!({ "reason": reason, "count": n }),
        )
        .await?;
        t.commit().await?;
        Ok(n)
    }

    /// 编排服务唤醒沙箱后换令牌：授权有效、账号可用、授权属于这个实例、实例当前绑定着沙箱。
    /// 令牌绑定实例当前的沙箱 id 和网络身份，换了沙箱旧令牌就失效。
    pub async fn sandbox_token(
        &self,
        grant: GrantId,
        instance: InstanceId,
    ) -> Result<SandboxCredential> {
        let mut w = self.db.worker().await?;
        let rt = w.instance_runtime(instance).await?;
        let Some((user, g)) = w
            .touch_run_grant(grant, self.cfg.renew_below, self.cfg.ttl)
            .await?
        else {
            return Err(AuthError::Invalid(format!(
                "grant {grant} is revoked or expired"
            )));
        };
        if g.instance_id != instance || user != rt.user_id {
            return Err(AuthError::Invalid(
                "grant does not belong to this instance".into(),
            ));
        }
        if w.user(user).await?.status != UserStatus::Active {
            return Err(AuthError::AccountFrozen);
        }
        if matches!(rt.state, InstanceState::Deleted | InstanceState::Archived) {
            return Err(AuthError::Invalid(format!("instance is {}", rt.state)));
        }
        let Some(sandbox_id) = rt.sandbox_id.clone() else {
            return Err(AuthError::Invalid("instance has no sandbox".into()));
        };
        w.commit().await?;
        let remaining = (g.expires_at - Utc::now()).to_std().unwrap_or_default();
        let expires_in = self.cfg.sandbox_token_ttl.min(remaining);
        if expires_in.as_secs() == 0 {
            return Err(AuthError::Invalid(format!(
                "grant {grant} is about to expire"
            )));
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or_default();
        let token = self.issuer.issue(
            TokenRequest {
                ep: rt.token_epoch,
                iid: instance.to_string(),
                uid: user.to_string(),
                grant: grant.to_string(),
                sbx: sandbox_id.clone(),
                net: rt.sandbox_address.map(|a| a.to_string()),
            },
            expires_in.as_secs(),
            now,
        )?;
        Ok(SandboxCredential {
            token,
            sandbox_id,
            expires_in,
        })
    }
}
