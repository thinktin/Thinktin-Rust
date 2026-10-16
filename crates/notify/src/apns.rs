//! APNs（iOS、macOS 推送，WBS 10.1）：HTTP/2 + ES256 签名的提供方令牌（.p8 密钥）。
//!
//! - 提供方令牌（JWT）缓存 40 分钟再换（苹果要求 20 到 60 分钟之间换，太频繁会被拒）；
//! - 410、`BadDeviceToken`、`DeviceTokenNotForTopic` 表示设备令牌失效，调用方应删掉它；
//! - 403 的令牌错误会清掉缓存的 JWT，下次重签；429 和 5xx 退避重试。

use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use p256::pkcs8::DecodePrivateKey;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::{PushChannel, PushKind, PushMessage, PushOutcome};

pub const PRODUCTION: &str = "https://api.push.apple.com";
pub const SANDBOX: &str = "https://api.sandbox.push.apple.com";
/// 苹果对普通推送载荷的上限。
pub const MAX_PAYLOAD: usize = 4096;
/// 摘要最多这么多个字符，留足载荷余量。
const MAX_BODY_CHARS: usize = 400;
const TOKEN_REFRESH_SECS: u64 = 40 * 60;

#[derive(Debug, thiserror::Error)]
pub enum ApnsError {
    #[error("invalid APNs signing key: {0}")]
    Key(String),
    #[error("http client: {0}")]
    Http(#[from] reqwest::Error),
}

pub struct ApnsConfig {
    /// [`PRODUCTION`] 或 [`SANDBOX`]（测试时也可以是本地地址）。
    pub endpoint: String,
    /// App 的 bundle id。
    pub topic: String,
    pub team_id: String,
    pub key_id: String,
    /// .p8 文件内容（PKCS#8 PEM）。
    pub key_pem: Zeroizing<String>,
}

pub struct ApnsClient {
    endpoint: String,
    topic: String,
    team_id: String,
    key_id: String,
    key: SigningKey,
    http: reqwest::Client,
    token: Mutex<Option<(String, u64)>>,
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl ApnsClient {
    /// APNs 只支持 HTTP/2。
    pub fn new(config: ApnsConfig) -> Result<Self, ApnsError> {
        let http = reqwest::Client::builder()
            .http2_prior_knowledge()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .build()?;
        Self::with_http(config, http)
    }

    /// 自带 HTTP 客户端（测试用 HTTP/1 的本地服务）。
    pub fn with_http(config: ApnsConfig, http: reqwest::Client) -> Result<Self, ApnsError> {
        let key = SigningKey::from_pkcs8_pem(&config.key_pem)
            .map_err(|e| ApnsError::Key(e.to_string()))?;
        Ok(Self {
            endpoint: config.endpoint.trim_end_matches('/').to_owned(),
            topic: config.topic,
            team_id: config.team_id,
            key_id: config.key_id,
            key,
            http,
            token: Mutex::new(None),
        })
    }

    /// 提供方令牌：`{"alg":"ES256","kid":...}.{"iss":team,"iat":...}`，签名是 64 字节的 r‖s。
    fn provider_token(&self, now: u64) -> String {
        let mut cached = self.token.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((token, iat)) = cached.as_ref()
            && now.saturating_sub(*iat) < TOKEN_REFRESH_SECS
        {
            return token.clone();
        }
        let header =
            URL_SAFE_NO_PAD.encode(json!({"alg": "ES256", "kid": self.key_id}).to_string());
        let claims = URL_SAFE_NO_PAD.encode(json!({"iss": self.team_id, "iat": now}).to_string());
        let signing_input = format!("{header}.{claims}");
        let sig: Signature = self.key.sign(signing_input.as_bytes());
        let token = format!("{signing_input}.{}", URL_SAFE_NO_PAD.encode(sig.to_bytes()));
        *cached = Some((token.clone(), now));
        token
    }

    fn forget_token(&self) {
        *self.token.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    /// 推送载荷。客户端自定义数据放在 `tt` 下，只有 id。
    pub fn payload(message: &PushMessage) -> Value {
        let body: String = message
            .display_body()
            .chars()
            .take(MAX_BODY_CHARS)
            .collect();
        let mut aps = json!({
            "alert": {"title": message.title, "body": body},
            "sound": "default",
            "category": message.kind.category(),
        });
        if let Some(thread) = &message.thread_id {
            aps["thread-id"] = json!(thread);
        }
        if message.kind.is_approval() {
            aps["interruption-level"] = json!("time-sensitive");
        }
        let mut tt = json!({"kind": message.kind});
        let t = &message.target;
        for (k, v) in [
            ("instance", &t.instance_id),
            ("run", &t.run_id),
            ("approval", &t.approval_id),
            ("plan", &t.plan_id),
            ("inbox", &t.inbox_id),
        ] {
            if let Some(v) = v {
                tt[k] = json!(v);
            }
        }
        json!({"aps": aps, "tt": tt})
    }
}

/// 设备令牌是十六进制串（目前 64 个字符，苹果说以后可能变长）。
fn valid_device_token(token: &str) -> bool {
    (32..=200).contains(&token.len()) && token.bytes().all(|b| b.is_ascii_hexdigit())
}

#[async_trait]
impl PushChannel for ApnsClient {
    fn name(&self) -> &'static str {
        "apns"
    }

    async fn send(&self, device_token: &str, message: &PushMessage) -> PushOutcome {
        if !valid_device_token(device_token) {
            return PushOutcome::InvalidToken {
                reason: "malformed device token".into(),
            };
        }
        let body = Self::payload(message).to_string();
        if body.len() > MAX_PAYLOAD {
            return PushOutcome::Rejected {
                reason: format!("payload is {} bytes", body.len()),
            };
        }
        let now = now_secs();
        let priority = if message.kind == PushKind::Info {
            "5"
        } else {
            "10"
        };
        let mut req = self
            .http
            .post(format!("{}/3/device/{device_token}", self.endpoint))
            .header(
                "authorization",
                format!("bearer {}", self.provider_token(now)),
            )
            .header("apns-topic", &self.topic)
            .header("apns-push-type", "alert")
            .header("apns-priority", priority)
            .header(
                "apns-expiration",
                message.ttl.map_or(0, |ttl| now + ttl.as_secs()).to_string(),
            )
            .header("content-type", "application/json")
            .body(body);
        if let Some(c) = &message.collapse_id {
            req = req.header("apns-collapse-id", c.chars().take(64).collect::<String>());
        }
        let resp = match req.send().await {
            Ok(r) => r,
            Err(e) => {
                return PushOutcome::Retry {
                    after: None,
                    reason: format!("network: {e}"),
                };
            }
        };
        let status = resp.status().as_u16();
        let apns_id = resp
            .headers()
            .get("apns-id")
            .and_then(|v| v.to_str().ok())
            .map(str::to_owned);
        let retry_after = resp
            .headers()
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse().ok())
            .map(Duration::from_secs);
        if status == 200 {
            return PushOutcome::Delivered { id: apns_id };
        }
        let reason = resp
            .json::<Value>()
            .await
            .ok()
            .and_then(|v| v["reason"].as_str().map(str::to_owned))
            .unwrap_or_else(|| format!("status {status}"));
        match (status, reason.as_str()) {
            (410, _) | (400, "BadDeviceToken" | "DeviceTokenNotForTopic") => {
                PushOutcome::InvalidToken { reason }
            }
            (403, "ExpiredProviderToken" | "InvalidProviderToken") => {
                self.forget_token();
                PushOutcome::Retry {
                    after: None,
                    reason,
                }
            }
            (429, _) | (500..=599, _) => PushOutcome::Retry {
                after: retry_after,
                reason,
            },
            _ => PushOutcome::Rejected { reason },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::PushTarget;
    use axum::extract::{Path, State};
    use axum::http::{HeaderMap, StatusCode};
    use axum::response::IntoResponse;
    use p256::ecdsa::VerifyingKey;
    use p256::ecdsa::signature::Verifier;
    use p256::pkcs8::{EncodePrivateKey, LineEnding};
    use std::sync::Arc;

    #[derive(Default)]
    struct Fake {
        seen: Mutex<Vec<(String, HeaderMap, Value)>>,
        fail_auth_once: Mutex<bool>,
    }

    async fn handler(
        State(fake): State<Arc<Fake>>,
        Path(token): Path<String>,
        headers: HeaderMap,
        body: String,
    ) -> axum::response::Response {
        let v: Value = serde_json::from_str(&body).unwrap();
        fake.seen.lock().unwrap().push((token.clone(), headers, v));
        if std::mem::take(&mut *fake.fail_auth_once.lock().unwrap()) {
            return (
                StatusCode::FORBIDDEN,
                axum::Json(json!({"reason": "ExpiredProviderToken"})),
            )
                .into_response();
        }
        match token.as_str() {
            t if t.starts_with("dead") => (
                StatusCode::GONE,
                axum::Json(json!({"reason": "Unregistered", "timestamp": 1})),
            )
                .into_response(),
            t if t.starts_with("feed") => (
                StatusCode::TOO_MANY_REQUESTS,
                [("retry-after", "7")],
                axum::Json(json!({"reason": "TooManyRequests"})),
            )
                .into_response(),
            _ => (StatusCode::OK, [("apns-id", "abc-123")]).into_response(),
        }
    }

    async fn setup() -> (ApnsClient, Arc<Fake>, VerifyingKey) {
        let fake = Arc::new(Fake::default());
        let app = axum::Router::new()
            .route("/3/device/{token}", axum::routing::post(handler))
            .with_state(fake.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let key = SigningKey::from_slice(&[7u8; 32]).unwrap();
        let pem = key.to_pkcs8_pem(LineEnding::LF).unwrap();
        let client = ApnsClient::with_http(
            ApnsConfig {
                endpoint: format!("http://{addr}"),
                topic: "com.thinktin.app".into(),
                team_id: "TEAM123456".into(),
                key_id: "KEY1234567".into(),
                key_pem: Zeroizing::new(pem.to_string()),
            },
            reqwest::Client::builder().no_proxy().build().unwrap(),
        )
        .unwrap();
        (client, fake, VerifyingKey::from(&key))
    }

    fn message(kind: PushKind) -> PushMessage {
        PushMessage {
            kind,
            title: "调研助手".into(),
            body: "需要你批准：执行 `rm -rf build`".into(),
            thread_id: Some("run-1".into()),
            collapse_id: Some("approval-9".into()),
            target: PushTarget {
                instance_id: Some("inst-1".into()),
                run_id: Some("run-1".into()),
                approval_id: Some("appr-9".into()),
                plan_id: None,
                inbox_id: None,
            },
            ttl: Some(Duration::from_secs(3600)),
            ai_generated: false,
            locale: Default::default(),
        }
    }

    const TOKEN: &str = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";

    #[tokio::test]
    async fn sends_signed_request_with_payload() {
        let (client, fake, vk) = setup().await;
        let out = client.send(TOKEN, &message(PushKind::Approval)).await;
        assert_eq!(
            out,
            PushOutcome::Delivered {
                id: Some("abc-123".into())
            }
        );
        let seen = fake.seen.lock().unwrap();
        let (token, headers, body) = &seen[0];
        assert_eq!(token, TOKEN);
        assert_eq!(headers["apns-topic"], "com.thinktin.app");
        assert_eq!(headers["apns-push-type"], "alert");
        assert_eq!(headers["apns-priority"], "10");
        assert_eq!(headers["apns-collapse-id"], "approval-9");
        assert_ne!(headers["apns-expiration"], "0");
        assert_eq!(body["aps"]["category"], "APPROVAL");
        assert_eq!(body["aps"]["interruption-level"], "time-sensitive");
        assert_eq!(body["aps"]["thread-id"], "run-1");
        assert_eq!(
            body["tt"],
            json!({"kind": "approval", "instance": "inst-1", "run": "run-1", "approval": "appr-9"})
        );
        // JWT 用 ES256 签名，验得过。
        let jwt = headers["authorization"]
            .to_str()
            .unwrap()
            .strip_prefix("bearer ")
            .unwrap();
        let (input, sig) = jwt.rsplit_once('.').unwrap();
        let sig = Signature::from_slice(&URL_SAFE_NO_PAD.decode(sig).unwrap()).unwrap();
        vk.verify(input.as_bytes(), &sig).unwrap();
        let header: Value = serde_json::from_slice(
            &URL_SAFE_NO_PAD
                .decode(input.split('.').next().unwrap())
                .unwrap(),
        )
        .unwrap();
        assert_eq!(header, json!({"alg": "ES256", "kid": "KEY1234567"}));
    }

    #[tokio::test]
    async fn outcomes_and_token_refresh() {
        let (client, fake, _) = setup().await;
        let msg = message(PushKind::RunFinished);
        let dead = format!("dead{}", &TOKEN[4..]);
        assert!(matches!(
            client.send(&dead, &msg).await,
            PushOutcome::InvalidToken { .. }
        ));
        let busy = format!("feed{}", &TOKEN[4..]);
        assert_eq!(
            client.send(&busy, &msg).await,
            PushOutcome::Retry {
                after: Some(Duration::from_secs(7)),
                reason: "TooManyRequests".into()
            }
        );
        assert!(matches!(
            client.send("not-hex", &msg).await,
            PushOutcome::InvalidToken { .. }
        ));

        // 同一个 JWT 复用；令牌过期被拒后重签。
        client.send(TOKEN, &msg).await;
        *fake.fail_auth_once.lock().unwrap() = true;
        assert!(matches!(
            client.send(TOKEN, &msg).await,
            PushOutcome::Retry { .. }
        ));
        assert!(
            client.token.lock().unwrap().is_none(),
            "the rejected provider token is dropped"
        );
        assert_eq!(
            client.send(TOKEN, &msg).await,
            PushOutcome::Delivered {
                id: Some("abc-123".into())
            }
        );
        let seen = fake.seen.lock().unwrap();
        let auths: Vec<_> = seen
            .iter()
            .map(|(_, h, _)| h["authorization"].clone())
            .collect();
        assert_eq!(auths[0], auths[1], "provider token is cached");
    }

    #[tokio::test]
    async fn long_bodies_are_truncated_and_oversize_rejected() {
        let (client, _, _) = setup().await;
        let mut msg = message(PushKind::Info);
        msg.body = "长".repeat(5000);
        let p = ApnsClient::payload(&msg);
        assert_eq!(
            p["aps"]["alert"]["body"].as_str().unwrap().chars().count(),
            MAX_BODY_CHARS
        );
        assert!(p.get("interruption-level").is_none());
        msg.title = "x".repeat(MAX_PAYLOAD);
        assert!(matches!(
            client.send(TOKEN, &msg).await,
            PushOutcome::Rejected { .. }
        ));
    }
}
