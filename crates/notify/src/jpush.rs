//! 国内 Android 推送（WBS 10.3）：先经极光推送（JPush REST API v3）覆盖华为、荣耀、小米、OPPO、vivo
//! 等厂商通道，App 里集成极光 SDK 和各厂商插件，设备上报的推送令牌是极光的 registration_id。
//!
//! - 鉴权：`Authorization: Basic base64(appKey:masterSecret)`；
//! - 我们的通知都是用户自己的任务结果、审批、计划确认，按“系统消息”（`classification = 1`）发，
//!   不是运营消息；各厂商的消息分类（华为 category、小米 / OPPO 的 channel_id、vivo 的 category）
//!   要先在厂商后台申请，申请下来后在配置里填（[`VendorOptions`]），没填就不传；
//! - 1011（没有满足条件的推送目标：registration_id 不属于这个应用或设备 255 天没活跃）视为令牌失效；
//!   429 / 2002 限频按 `X-Rate-Limit-Reset` 退避，1000、1030、5xx 重试，1012（厂商配额用完）过一阵再试；
//!   其余是请求本身的问题，不重试。

use std::time::Duration;

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use crate::{PushChannel, PushKind, PushMessage, PushOutcome};

pub const ENDPOINT: &str = "https://api.jpush.cn";
/// 标题、摘要的长度上限（字符）：厂商通道对标题、正文长度有限制，超出会被截断或拒绝。
const MAX_TITLE_CHARS: usize = 40;
const MAX_BODY_CHARS: usize = 200;
/// 普通账号离线保留最长 3 天。
const MAX_TTL_SECS: u64 = 3 * 24 * 3600;
/// 厂商配额用完（1012）后多久再试。
const QUOTA_RETRY: Duration = Duration::from_secs(3600);

#[derive(Debug, thiserror::Error)]
pub enum JpushError {
    #[error("http client: {0}")]
    Http(#[from] reqwest::Error),
}

/// 各厂商通道的消息分类参数（在厂商后台申请下来以后再填）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct VendorOptions {
    /// 华为自分类的 category（比如 `WORK`）。
    pub huawei_category: Option<String>,
    /// 小米通知类别（channel_id）。
    pub xiaomi_channel_id: Option<String>,
    /// OPPO 私信通道的 channel_id。
    pub oppo_channel_id: Option<String>,
    /// OPPO 消息分类 category（比如 `TODO`）。
    pub oppo_category: Option<String>,
    /// vivo 消息二级分类 category（比如 `TODO`）。
    pub vivo_category: Option<String>,
}

pub struct JpushConfig {
    /// [`ENDPOINT`]（测试时可以是本地地址）。
    pub endpoint: String,
    pub app_key: String,
    pub master_secret: Zeroizing<String>,
    pub vendors: VendorOptions,
    /// App 里通知渠道（Android NotificationChannel）的 id：审批一个、其余一个。
    pub approval_channel: String,
    pub default_channel: String,
}

pub struct JpushClient {
    endpoint: String,
    auth: Zeroizing<String>,
    vendors: VendorOptions,
    approval_channel: String,
    default_channel: String,
    http: reqwest::Client,
}

impl JpushClient {
    pub fn new(config: JpushConfig) -> Result<Self, JpushError> {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .build()?;
        Ok(Self::with_http(config, http))
    }

    pub fn with_http(config: JpushConfig, http: reqwest::Client) -> Self {
        let credential = Zeroizing::new(format!("{}:{}", config.app_key, *config.master_secret));
        let auth = Zeroizing::new(format!("Basic {}", STANDARD.encode(credential.as_bytes())));
        Self {
            endpoint: config.endpoint.trim_end_matches('/').to_owned(),
            auth,
            vendors: config.vendors,
            approval_channel: config.approval_channel,
            default_channel: config.default_channel,
            http,
        }
    }

    /// 请求体。客户端自定义数据放在 extras 里，键都以 `tt_` 开头、值都是字符串（厂商通道只认字符串）。
    pub fn payload(&self, registration_id: &str, message: &PushMessage) -> Value {
        let title: String = message.title.chars().take(MAX_TITLE_CHARS).collect();
        let body: String = message
            .display_body()
            .chars()
            .take(MAX_BODY_CHARS)
            .collect();
        let mut extras = Map::new();
        extras.insert("tt_kind".into(), json!(message.kind.as_str()));
        let t = &message.target;
        for (k, v) in [
            ("tt_instance", &t.instance_id),
            ("tt_run", &t.run_id),
            ("tt_approval", &t.approval_id),
            ("tt_plan", &t.plan_id),
            ("tt_inbox", &t.inbox_id),
        ] {
            if let Some(v) = v {
                extras.insert(k.into(), json!(v));
            }
        }
        let urgent = message.kind.is_approval() || message.kind == PushKind::RunFailed;
        let channel = if message.kind.is_approval() {
            &self.approval_channel
        } else {
            &self.default_channel
        };
        let mut android = json!({
            "alert": body,
            "title": title,
            "channel_id": channel,
            "priority": if urgent { 1 } else { 0 },
            "extras": extras,
        });
        if message.kind.is_approval() {
            android["category"] = json!("reminder");
        }
        let v = &self.vendors;
        let mut vendors = Map::new();
        let mut put = |vendor: &str, key: &str, value: &Option<String>| {
            if let Some(value) = value {
                vendors
                    .entry(vendor.to_owned())
                    .or_insert_with(|| json!({}))
                    .as_object_mut()
                    .map(|o| o.insert(key.to_owned(), json!(value)));
            }
        };
        put("huawei", "category", &v.huawei_category);
        put("xiaomi", "channel_id", &v.xiaomi_channel_id);
        put("oppo", "channel_id", &v.oppo_channel_id);
        put("oppo", "category", &v.oppo_category);
        put("vivo", "category", &v.vivo_category);
        // 华为、荣耀：服务与通讯类消息是 NORMAL（LOW 是资讯营销类）。
        for vendor in ["huawei", "honor"] {
            vendors
                .entry(vendor.to_owned())
                .or_insert_with(|| json!({}))
                .as_object_mut()
                .map(|o| o.insert("importance".into(), json!("NORMAL")));
        }
        let ttl = message
            .ttl
            .unwrap_or(crate::DEFAULT_TTL)
            .as_secs()
            .clamp(60, MAX_TTL_SECS);
        let options = json!({
            "time_to_live": ttl,
            "classification": 1,
            "third_party_channel": vendors,
        });
        json!({
            "platform": "android",
            "audience": { "registration_id": [registration_id] },
            "notification": { "android": android },
            "options": options,
        })
    }
}

/// registration_id 是字母数字串。
fn valid_registration_id(id: &str) -> bool {
    (8..=64).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric())
}

#[derive(Deserialize)]
struct ErrorBody {
    error: ErrorDetail,
}

#[derive(Deserialize)]
struct ErrorDetail {
    code: i64,
    #[serde(default)]
    message: String,
}

#[async_trait]
impl PushChannel for JpushClient {
    fn name(&self) -> &'static str {
        "jpush"
    }

    async fn send(&self, device_token: &str, message: &PushMessage) -> PushOutcome {
        if !valid_registration_id(device_token) {
            return PushOutcome::InvalidToken {
                reason: "malformed registration id".into(),
            };
        }
        let resp = match self
            .http
            .post(format!("{}/v3/push", self.endpoint))
            .header("authorization", self.auth.as_str())
            .json(&self.payload(device_token, message))
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
        let reset = resp
            .headers()
            .get("x-rate-limit-reset")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.trim().parse().ok())
            .map(Duration::from_secs);
        let body: Value = resp.json().await.unwrap_or(Value::Null);
        if status == 200 {
            let id = body["msg_id"]
                .as_str()
                .map(str::to_owned)
                .or_else(|| body["msg_id"].as_i64().map(|i| i.to_string()));
            return PushOutcome::Delivered { id };
        }
        let (code, msg) = match serde_json::from_value::<ErrorBody>(body) {
            Ok(e) => (e.error.code, e.error.message),
            Err(_) => (0, String::new()),
        };
        let reason = format!("status {status}, code {code}: {msg}");
        match (status, code) {
            (_, 1011) => PushOutcome::InvalidToken { reason },
            (429, _) | (_, 2002) => PushOutcome::Retry {
                after: reset,
                reason,
            },
            (_, 1012) => PushOutcome::Retry {
                after: Some(QUOTA_RETRY),
                reason,
            },
            (500..=599, _) | (_, 1000 | 1030) => PushOutcome::Retry {
                after: None,
                reason,
            },
            // 鉴权、IP 白名单、应用被限制：配置问题，修好之前别把通知丢掉。
            (_, 1004 | 2003 | 2004) => PushOutcome::Retry {
                after: None,
                reason,
            },
            _ => PushOutcome::Rejected { reason },
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use axum::extract::State;
    use axum::http::{HeaderMap, StatusCode};
    use axum::response::IntoResponse;

    use super::*;
    use crate::PushTarget;

    #[derive(Default)]
    struct Fake {
        seen: Mutex<Vec<(HeaderMap, Value)>>,
    }

    async fn handler(
        State(fake): State<Arc<Fake>>,
        headers: HeaderMap,
        axum::Json(v): axum::Json<Value>,
    ) -> axum::response::Response {
        let rid = v["audience"]["registration_id"][0]
            .as_str()
            .unwrap()
            .to_owned();
        fake.seen.lock().unwrap().push((headers, v));
        let err = |status: StatusCode, code: i64| {
            (
                status,
                [("x-rate-limit-reset", "17")],
                axum::Json(json!({ "error": { "code": code, "message": "nope" } })),
            )
                .into_response()
        };
        match &rid[..4] {
            "gone" => err(StatusCode::BAD_REQUEST, 1011),
            "busy" => err(StatusCode::TOO_MANY_REQUESTS, 2002),
            "auth" => err(StatusCode::UNAUTHORIZED, 1004),
            "full" => err(StatusCode::BAD_REQUEST, 1012),
            "bad0" => err(StatusCode::BAD_REQUEST, 1005),
            "down" => (StatusCode::BAD_GATEWAY, "oops").into_response(),
            _ => {
                axum::Json(json!({ "sendno": "0", "msg_id": "18100287008546343" })).into_response()
            }
        }
    }

    async fn setup(vendors: VendorOptions) -> (JpushClient, Arc<Fake>) {
        let fake = Arc::new(Fake::default());
        let app = axum::Router::new()
            .route("/v3/push", axum::routing::post(handler))
            .with_state(fake.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let client = JpushClient::new(JpushConfig {
            endpoint: format!("http://{addr}/"),
            app_key: "appkey123".into(),
            master_secret: Zeroizing::new("secret456".into()),
            vendors,
            approval_channel: "tt_approval".into(),
            default_channel: "tt_results".into(),
        })
        .unwrap();
        (client, fake)
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
                inbox_id: Some("inbox-3".into()),
            },
            ttl: Some(Duration::from_secs(3600)),
            ai_generated: false,
            locale: Default::default(),
        }
    }

    #[tokio::test]
    async fn sends_a_system_notification_with_ids_only() {
        let (client, fake) = setup(VendorOptions {
            huawei_category: Some("WORK".into()),
            oppo_channel_id: Some("tt_private".into()),
            ..VendorOptions::default()
        })
        .await;
        let out = client
            .send("1a0018970a8b7c6d5e4", &message(PushKind::Approval))
            .await;
        assert_eq!(
            out,
            PushOutcome::Delivered {
                id: Some("18100287008546343".into())
            }
        );
        let (headers, v) = fake.seen.lock().unwrap().pop().unwrap();
        assert_eq!(
            headers["authorization"],
            format!("Basic {}", STANDARD.encode("appkey123:secret456"))
        );
        assert_eq!(v["platform"], "android");
        assert_eq!(v["audience"]["registration_id"][0], "1a0018970a8b7c6d5e4");
        let a = &v["notification"]["android"];
        assert_eq!(a["title"], "调研助手");
        assert_eq!(a["channel_id"], "tt_approval");
        assert_eq!(a["priority"], 1);
        assert_eq!(a["extras"]["tt_kind"], "approval");
        assert_eq!(a["extras"]["tt_approval"], "appr-9");
        assert_eq!(a["extras"]["tt_inbox"], "inbox-3");
        assert!(a["extras"].get("tt_plan").is_none());
        let o = &v["options"];
        assert_eq!(o["classification"], 1);
        assert_eq!(o["time_to_live"], 3600);
        assert_eq!(o["third_party_channel"]["huawei"]["category"], "WORK");
        assert_eq!(o["third_party_channel"]["huawei"]["importance"], "NORMAL");
        assert_eq!(o["third_party_channel"]["oppo"]["channel_id"], "tt_private");
        assert!(o["third_party_channel"].get("vivo").is_none());

        // 普通结果：默认渠道、普通优先级、没配的厂商参数不带。
        let (client, fake) = setup(VendorOptions::default()).await;
        let mut m = message(PushKind::RunFinished);
        m.ttl = None;
        m.body = "长".repeat(500);
        client.send("1a0018970a8b7c6d5e4", &m).await;
        let (_, v) = fake.seen.lock().unwrap().pop().unwrap();
        let a = &v["notification"]["android"];
        assert_eq!(a["channel_id"], "tt_results");
        assert_eq!(a["priority"], 0);
        assert_eq!(a["alert"].as_str().unwrap().chars().count(), 200);
        assert_eq!(v["options"]["time_to_live"], 86400);
        // agent 写的正文带显式标识。
        m.ai_generated = true;
        m.body = "今天晴".into();
        let p = client.payload("1a0018970a8b7c6d5e4", &m);
        assert_eq!(p["notification"]["android"]["alert"], "【AI 生成】今天晴");
        // 英文用户（1.6）：标识也是英文。
        m.locale = proto::domain::Locale::En;
        m.body = "Sunny today".into();
        let p = client.payload("1a0018970a8b7c6d5e4", &m);
        assert_eq!(
            p["notification"]["android"]["alert"],
            "[AI-generated] Sunny today"
        );
        assert_eq!(
            v["options"]["third_party_channel"],
            json!({ "huawei": { "importance": "NORMAL" }, "honor": { "importance": "NORMAL" } })
        );
    }

    #[tokio::test]
    async fn maps_errors_to_outcomes() {
        let (client, fake) = setup(VendorOptions::default()).await;
        let m = message(PushKind::RunFinished);
        assert!(matches!(
            client.send("gone00000000", &m).await,
            PushOutcome::InvalidToken { .. }
        ));
        assert_eq!(
            client.send("busy00000000", &m).await,
            PushOutcome::Retry {
                after: Some(Duration::from_secs(17)),
                reason: "status 429, code 2002: nope".into()
            }
        );
        assert!(matches!(
            client.send("auth00000000", &m).await,
            PushOutcome::Retry { after: None, .. }
        ));
        assert!(matches!(
            client.send("full00000000", &m).await,
            PushOutcome::Retry { after: Some(d), .. } if d == QUOTA_RETRY
        ));
        assert!(matches!(
            client.send("down00000000", &m).await,
            PushOutcome::Retry { .. }
        ));
        assert!(matches!(
            client.send("bad000000000", &m).await,
            PushOutcome::Rejected { .. }
        ));
        let before = fake.seen.lock().unwrap().len();
        assert!(matches!(
            client.send("not a token!", &m).await,
            PushOutcome::InvalidToken { .. }
        ));
        assert_eq!(
            fake.seen.lock().unwrap().len(),
            before,
            "malformed ids are not sent"
        );
    }
}
