//! 海外 Android 推送（WBS 10.2）：Firebase Cloud Messaging 的 HTTP v1 接口。
//!
//! - 鉴权：用服务账号（Google Cloud 的 JSON 密钥）签一个 RS256 的 JWT，到 OAuth 令牌端点换访问令牌，
//!   缓存到快过期前 5 分钟；
//! - 消息：系统通知（标题、正文）加 data（客户端用的 id，键以 `tt_` 开头、值都是字符串）；审批和失败用高优先级，
//!   审批走单独的通知渠道；同一个 collapse_id 的通知互相替换（collapse_key、tag）；
//! - 结果：`UNREGISTERED`（App 卸载、令牌过期）、`SENDER_ID_MISMATCH`（令牌属于别的项目）、令牌格式不对视为令牌失效；
//!   限流、服务不可用按 `Retry-After` 退避；访问令牌失效（401）换一个再试一次；鉴权、权限这类配置问题重试
//!   （修好之前别把通知丢掉）；其余是请求本身的问题，不重试。

use std::fmt;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use aws_lc_rs::rand::SystemRandom;
use aws_lc_rs::signature::{RSA_PKCS1_SHA256, RsaKeyPair};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use crate::{PushChannel, PushKind, PushMessage, PushOutcome};

pub const ENDPOINT: &str = "https://fcm.googleapis.com";
pub const SCOPE: &str = "https://www.googleapis.com/auth/firebase.messaging";
const TOKEN_URI: &str = "https://oauth2.googleapis.com/token";
const MAX_TITLE_CHARS: usize = 100;
const MAX_BODY_CHARS: usize = 400;
/// FCM 最多保留 4 周。
const MAX_TTL_SECS: u64 = 28 * 24 * 3600;
/// 访问令牌在过期前这么久换新的。
const TOKEN_MARGIN: Duration = Duration::from_secs(300);

#[derive(Debug, thiserror::Error)]
pub enum FcmError {
    #[error("http client: {0}")]
    Http(#[from] reqwest::Error),
    #[error("service account: {0}")]
    Account(String),
    #[error("oauth token: {0}")]
    Token(String),
}

/// 服务账号的 JSON 密钥里用到的字段。
#[derive(Clone, Deserialize)]
pub struct ServiceAccount {
    pub project_id: String,
    pub private_key_id: String,
    /// PEM（PKCS#8）。
    pub private_key: String,
    pub client_email: String,
    #[serde(default = "default_token_uri")]
    pub token_uri: String,
}

fn default_token_uri() -> String {
    TOKEN_URI.into()
}

impl fmt::Debug for ServiceAccount {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ServiceAccount")
            .field("project_id", &self.project_id)
            .field("client_email", &self.client_email)
            .field("private_key", &"***")
            .finish_non_exhaustive()
    }
}

pub struct FcmConfig {
    /// [`ENDPOINT`]（测试时可以是本地地址）。
    pub endpoint: String,
    pub account: ServiceAccount,
    /// App 里通知渠道（Android NotificationChannel）的 id：审批一个、其余一个。
    pub approval_channel: String,
    pub default_channel: String,
}

pub struct FcmClient {
    endpoint: String,
    project_id: String,
    client_email: String,
    private_key_id: String,
    token_uri: String,
    key: RsaKeyPair,
    approval_channel: String,
    default_channel: String,
    http: reqwest::Client,
    token: Mutex<Option<(Zeroizing<String>, Instant)>>,
}

impl fmt::Debug for FcmClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FcmClient")
            .field("project_id", &self.project_id)
            .field("client_email", &self.client_email)
            .finish_non_exhaustive()
    }
}

/// PEM 里的 DER。
fn pem_der(pem: &str) -> Option<Zeroizing<Vec<u8>>> {
    let body: String = pem
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with("-----"))
        .collect();
    STANDARD.decode(body).ok().map(Zeroizing::new)
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[derive(Deserialize)]
struct TokenReply {
    access_token: String,
    #[serde(default)]
    expires_in: u64,
}

impl FcmClient {
    pub fn new(config: FcmConfig) -> Result<Self, FcmError> {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .build()?;
        Self::with_http(config, http)
    }

    pub fn with_http(config: FcmConfig, http: reqwest::Client) -> Result<Self, FcmError> {
        let a = config.account;
        if a.project_id.is_empty() || a.client_email.is_empty() {
            return Err(FcmError::Account(
                "project_id and client_email are required".into(),
            ));
        }
        let der = pem_der(&a.private_key)
            .ok_or_else(|| FcmError::Account("private_key is not PEM".into()))?;
        let key = RsaKeyPair::from_pkcs8(&der)
            .map_err(|e| FcmError::Account(format!("private_key: {e}")))?;
        Ok(Self {
            endpoint: config.endpoint.trim_end_matches('/').to_owned(),
            project_id: a.project_id,
            client_email: a.client_email,
            private_key_id: a.private_key_id,
            token_uri: a.token_uri,
            key,
            approval_channel: config.approval_channel,
            default_channel: config.default_channel,
            http,
            token: Mutex::new(None),
        })
    }

    /// 换访问令牌用的 JWT（RS256），有效 1 小时。
    fn jwt(&self, iat: u64) -> Result<String, FcmError> {
        let quote = |s: &str| serde_json::to_string(s).unwrap_or_default();
        let header = format!(
            r#"{{"alg":"RS256","typ":"JWT","kid":{}}}"#,
            quote(&self.private_key_id)
        );
        let claims = format!(
            r#"{{"iss":{},"scope":{},"aud":{},"iat":{iat},"exp":{}}}"#,
            quote(&self.client_email),
            quote(SCOPE),
            quote(&self.token_uri),
            iat + 3600
        );
        let input = format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(header),
            URL_SAFE_NO_PAD.encode(claims)
        );
        let mut sig = vec![0u8; self.key.public_modulus_len()];
        self.key
            .sign(
                &RSA_PKCS1_SHA256,
                &SystemRandom::new(),
                input.as_bytes(),
                &mut sig,
            )
            .map_err(|_| FcmError::Account("signing failed".into()))?;
        Ok(format!("{input}.{}", URL_SAFE_NO_PAD.encode(sig)))
    }

    /// 缓存的访问令牌；快过期了就换一个。
    async fn access_token(&self) -> Result<Zeroizing<String>, FcmError> {
        let cached = {
            let guard = self.token.lock().unwrap();
            guard
                .as_ref()
                .filter(|(_, until)| Instant::now() < *until)
                .map(|(token, _)| token.clone())
        };
        if let Some(token) = cached {
            return Ok(token);
        }
        let assertion = self.jwt(now_secs())?;
        // JWT 只含 base64url 字符和点，不用编码。
        let resp = self
            .http
            .post(&self.token_uri)
            .header("content-type", "application/x-www-form-urlencoded")
            .body(format!(
                "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion={assertion}"
            ))
            .send()
            .await?;
        let status = resp.status();
        if !status.is_success() {
            let body: Value = resp.json().await.unwrap_or(Value::Null);
            return Err(FcmError::Token(format!(
                "{status}: {} {}",
                body["error"].as_str().unwrap_or_default(),
                body["error_description"].as_str().unwrap_or_default()
            )));
        }
        let reply: TokenReply = resp.json().await?;
        let token = Zeroizing::new(reply.access_token);
        let lifetime = Duration::from_secs(reply.expires_in.max(60));
        let until = Instant::now() + lifetime.saturating_sub(TOKEN_MARGIN);
        *self.token.lock().unwrap() = Some((token.clone(), until));
        Ok(token)
    }

    /// 请求体。
    pub fn payload(&self, device_token: &str, message: &PushMessage) -> Value {
        let title: String = message.title.chars().take(MAX_TITLE_CHARS).collect();
        let body: String = message
            .display_body()
            .chars()
            .take(MAX_BODY_CHARS)
            .collect();
        let mut data = Map::new();
        data.insert("tt_kind".into(), json!(message.kind.as_str()));
        let t = &message.target;
        for (k, v) in [
            ("tt_instance", &t.instance_id),
            ("tt_run", &t.run_id),
            ("tt_approval", &t.approval_id),
            ("tt_plan", &t.plan_id),
            ("tt_inbox", &t.inbox_id),
            ("tt_vault_request", &t.vault_request_id),
            ("tt_subtype", &message.subtype),
        ] {
            if let Some(v) = v {
                data.insert(k.into(), json!(v));
            }
        }
        let urgent = message.kind.waits_for_user() || message.kind == PushKind::RunFailed;
        let channel = if message.kind.waits_for_user() {
            &self.approval_channel
        } else {
            &self.default_channel
        };
        let ttl = message
            .ttl
            .unwrap_or(crate::DEFAULT_TTL)
            .as_secs()
            // 剩下的有效期原样给（排队、重试过的审批提醒不能比审批活得久）；0 是在线就送、不在线就算了。
            .min(MAX_TTL_SECS);
        // 不带角标数：Android 的 `notification_count` 是“这一条通知代表几件事”，桌面把通知栏里每一条的加起来，
        // 填未读总数会越加越多。Android 的角标由桌面按通知栏里的通知自己算。
        let mut notification = json!({ "channel_id": channel });
        let mut android = json!({
            "priority": if urgent { "HIGH" } else { "NORMAL" },
            "ttl": format!("{ttl}s"),
        });
        if let Some(id) = &message.collapse_id {
            notification["tag"] = json!(id);
            android["collapse_key"] = json!(id);
        }
        android["notification"] = notification;
        json!({
            "message": {
                "token": device_token,
                "notification": { "title": title, "body": body },
                "data": data,
                "android": android,
            }
        })
    }

    fn forget_token(&self) {
        *self.token.lock().unwrap() = None;
    }
}

/// FCM 的注册令牌：字母、数字和 `:_-`，几十到几百个字符。
fn valid_token(token: &str) -> bool {
    (20..=4096).contains(&token.len())
        && token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b':' | b'_' | b'-'))
}

/// 错误里的 FCM 错误码（`details` 里的 `errorCode`）、gRPC 状态和说明。
fn error_parts(body: &Value) -> (String, String, String) {
    let e = &body["error"];
    let code = e["details"]
        .as_array()
        .into_iter()
        .flatten()
        .find_map(|d| d["errorCode"].as_str())
        .unwrap_or_default()
        .to_owned();
    let status = e["status"].as_str().unwrap_or_default().to_owned();
    let message = e["message"]
        .as_str()
        .unwrap_or_default()
        .chars()
        .take(200)
        .collect();
    (code, status, message)
}

#[async_trait]
impl PushChannel for FcmClient {
    fn name(&self) -> &'static str {
        "fcm"
    }

    async fn send(&self, device_token: &str, message: &PushMessage) -> PushOutcome {
        if !valid_token(device_token) {
            return PushOutcome::InvalidToken {
                reason: "malformed registration token".into(),
            };
        }
        let payload = self.payload(device_token, message);
        let url = format!(
            "{}/v1/projects/{}/messages:send",
            self.endpoint, self.project_id
        );
        let mut refreshed = false;
        loop {
            let token = match self.access_token().await {
                Ok(t) => t,
                Err(e) => {
                    return PushOutcome::Retry {
                        after: None,
                        reason: e.to_string(),
                    };
                }
            };
            let resp = match self
                .http
                .post(&url)
                .bearer_auth(token.as_str())
                .json(&payload)
                .send()
                .await
            {
                Ok(r) => r,
                Err(e) => {
                    return PushOutcome::Retry {
                        after: None,
                        reason: format!("network: {e}"),
                    };
                }
            };
            let status = resp.status().as_u16();
            let after = resp
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.trim().parse().ok())
                .map(Duration::from_secs);
            let body: Value = resp.json().await.unwrap_or(Value::Null);
            if status == 200 {
                return PushOutcome::Delivered {
                    id: body["name"].as_str().map(str::to_owned),
                };
            }
            // 访问令牌被撤销或者过期得比预计早：换一个再试一次。
            if status == 401 && !refreshed {
                self.forget_token();
                refreshed = true;
                continue;
            }
            let (code, grpc, msg) = error_parts(&body);
            let reason = format!("status {status}, {code} {grpc}: {msg}");
            let token_problem = msg.to_ascii_lowercase().contains("registration token");
            return match (status, code.as_str()) {
                (_, "UNREGISTERED" | "SENDER_ID_MISMATCH") => PushOutcome::InvalidToken { reason },
                (400, "INVALID_ARGUMENT" | "") if token_problem => {
                    PushOutcome::InvalidToken { reason }
                }
                (429, _) | (_, "QUOTA_EXCEEDED") => PushOutcome::Retry { after, reason },
                (500..=599, _) | (_, "UNAVAILABLE" | "INTERNAL") => {
                    PushOutcome::Retry { after, reason }
                }
                // 鉴权、权限（服务账号、APNs 证书这类）是配置问题：修好之前别把通知丢掉。
                (401 | 403, _) | (_, "THIRD_PARTY_AUTH_ERROR") => PushOutcome::Retry {
                    after: None,
                    reason,
                },
                _ => PushOutcome::Rejected { reason },
            };
        }
    }
}

#[cfg(test)]
mod tests;
