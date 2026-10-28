//! 接口客户端（WBS 11.2）：带版本头、统一错误模型；访问令牌过期时自动用刷新令牌换新的再重试一次，
//! 并发的请求只刷新一次。刷新令牌失效（被吊销、被重复使用）就清掉会话，返回 [`ClientError::SignedOut`]。
//!
//! 会话（含刷新令牌）交给原生端的 [`SessionStore`] 保存（Keychain / Keystore），这里只在内存里留一份。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, RwLock};
use std::time::Duration;

use proto::api::{API_VERSION, ErrorCode, VERSION_HEADER};
use proto::domain::{
    Approval, ApprovalId, Artifact, ArtifactId, CatchUp, ContentReport, Credential, CredentialId,
    Device, DeviceId, DeviceMessage, DeviceMessageId, DeviceMessageKind, DevicePlatform, ImChannel,
    ImChannelId, InboxItem, InboxItemId, Instance, InstanceEvent, InstanceId, ModelRoute, Plan,
    PlanId, PlanPolicy, PlanStep, PushChannelKind, ReportReason, Run, RunId, ScheduleSpec, Team,
    TeamId, TeamMember, TeamTemplate, TeamTemplateId, TeamTemplateSpec, Trigger, TriggerId, User,
    VaultItem, VaultItemId, VaultRequest, VaultRequestId,
};
use reqwest::Method;
use reqwest::header::HeaderValue;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::error::{ClientError, Result};

/// 登录后的会话。刷新令牌等同于密码，原生端要放进系统的安全存储。
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct Session {
    pub user_id: String,
    pub device_id: String,
    pub access_token: String,
    pub refresh_token: String,
}

impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Session")
            .field("user_id", &self.user_id)
            .field("device_id", &self.device_id)
            .finish_non_exhaustive()
    }
}

/// 原生端实现：把会话存进 Keychain / Keystore。`save(None)` 表示退出登录或会话失效，要删掉。
#[uniffi::export(foreign)]
pub trait SessionStore: Send + Sync {
    fn load(&self) -> Option<Session>;
    fn save(&self, session: Option<Session>);
}

/// 只放内存（测试、命令行工具）。
#[derive(Default)]
pub struct MemorySessionStore(RwLock<Option<Session>>);

impl SessionStore for MemorySessionStore {
    fn load(&self) -> Option<Session> {
        self.0.read().unwrap_or_else(|e| e.into_inner()).clone()
    }
    fn save(&self, session: Option<Session>) {
        *self.0.write().unwrap_or_else(|e| e.into_inner()) = session;
    }
}

#[derive(Debug, Clone)]
pub struct ApiConfig {
    /// 比如 `https://api.thinktin.cn`。
    pub base_url: String,
    pub platform: DevicePlatform,
    pub device_name: String,
    pub timeout: Duration,
    /// 设备的语言偏好，`Accept-Language` 的写法（`zh-Hans-CN, en-US;q=0.9`）。每个请求都带上；服务端在新用户
    /// 注册时按它定推送和收件箱的语言。
    pub accept_language: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct LoginResult {
    pub user: User,
    pub new_user: bool,
}

/// 设备列表里的一台设备。
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct DeviceView {
    #[serde(flatten)]
    pub device: Device,
    /// 是不是正在用的这台。
    #[serde(default)]
    pub current: bool,
    /// 电脑连着设备中继（14.1）；手机总是 false。
    #[serde(default)]
    pub online: bool,
}

/// 可以领养的 agent。
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct AgentInfo {
    pub id: String,
    pub name: String,
    pub version: String,
    #[serde(default)]
    pub license: Option<String>,
    #[serde(default)]
    pub sites: Vec<String>,
    pub harnesses: Vec<String>,
    pub default_harness: String,
    /// 可以用的版本，当前版本在前。
    #[serde(default)]
    pub versions: Vec<String>,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub upstream: String,
    #[serde(default)]
    pub license_note: Option<String>,
    #[serde(default)]
    pub protocols: Vec<String>,
    #[serde(default)]
    pub active_protocol: Option<String>,
}

/// 跨实例列运行的条件（11.8）。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RunFilter {
    pub plan: Option<PlanId>,
    pub active: bool,
    pub roots: bool,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct PlanView {
    #[serde(flatten)]
    pub plan: Plan,
    #[serde(default)]
    pub triggers: Vec<Trigger>,
    #[serde(default)]
    pub steps: Vec<PlanStep>,
    #[serde(default)]
    pub next_fire_at: Option<chrono::DateTime<chrono::Utc>>,
    #[serde(default)]
    pub invalid_triggers: u32,
}

#[derive(Debug, Clone, Serialize)]
pub struct NewPlan {
    pub instance_id: InstanceId,
    pub title: String,
    pub goal: String,
    /// 不给就用服务端的默认（不预授权工具、审批 24 小时超时暂停计划……）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub policy: Option<PlanPolicy>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub catch_up: Option<CatchUp>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub triggers: Vec<ScheduleSpec>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<PlanStep>,
}

/// 改计划：给了才改。`steps` 整体替换，给空的就变回单个 agent 的计划。
#[derive(Debug, Clone, Default, Serialize)]
pub struct PlanChange {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub goal: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub policy: Option<PlanPolicy>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub catch_up: Option<CatchUp>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub steps: Option<Vec<PlanStep>>,
}

/// 改实例：给了才改（名字、用途说明、“允许其他 agent 查我、问我”）。
#[derive(Debug, Clone, Default, Serialize)]
pub struct InstanceChange {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub purpose: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub peer_access: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct InboxPage {
    pub items: Vec<InboxItem>,
    pub unread: i64,
}

/// 用量的一组汇总（9.10）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct UsageBucket {
    pub key: String,
    pub requests: u64,
    pub input_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub output_tokens: u64,
    pub charged_tokens: u64,
    pub estimated_requests: u64,
    pub failed_requests: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct UsageSummary {
    pub buckets: Vec<UsageBucket>,
    pub total: UsageBucket,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct EventsPage {
    pub events: Vec<InstanceEvent>,
    pub oldest_seq: Option<u64>,
    pub latest_seq: Option<u64>,
}

/// 全部停止的结果（4.6）。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
pub struct Stopped {
    pub runs_cancelled: u64,
    pub grants_revoked: u64,
    pub plans_paused: u64,
}

/// 下线其他设备的结果（4.6）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct SignedOutOthers {
    pub devices_signed_out: u64,
    /// 顺带全部停止时有。
    #[serde(default)]
    pub stopped: Option<Stopped>,
}

/// 预置的模型厂商（9.12）。不在列表里的接口用 `custom` 加自定义地址。
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct VendorInfo {
    pub id: String,
    pub name: String,
    /// `anthropic`、`chat`、`responses` 中的若干个：Claude 走 anthropic，Codex 只会 responses，其余走 chat。
    pub protocols: Vec<String>,
    /// 推荐的上游模型，以厂商控制台为准。
    #[serde(default)]
    pub models: Vec<String>,
    #[serde(default)]
    pub notes: String,
    /// 订阅类 key 的前缀（11.9）：这家的 key 以它们开头的服务端不收。
    #[serde(default)]
    pub subscription_key_prefixes: Vec<String>,
    /// 这家套餐专用地址的前缀（11.9）：自定义端点填了任何一家的这些地址服务端不收。
    #[serde(default)]
    pub plan_only_bases: Vec<String>,
}

#[derive(Clone, Default, Serialize)]
pub struct NewCredential {
    pub vendor: String,
    pub label: String,
    pub api_key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub anthropic_base: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub openai_base: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub responses_base: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub daily_token_limit: Option<u64>,
}

impl std::fmt::Debug for NewCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NewCredential")
            .field("vendor", &self.vendor)
            .field("label", &self.label)
            .finish_non_exhaustive()
    }
}

/// 绑定 IM 群机器人（10.5）：粘贴的 webhook 地址、加签的密钥（飞书、钉钉可选，企业微信没有）。
/// `events` 不给就是全部（run_finished、run_failed、approval）。
#[derive(Clone, Default, Serialize)]
pub struct NewImChannel {
    pub webhook_url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secret: Option<String>,
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub events: Option<Vec<String>>,
}

impl std::fmt::Debug for NewImChannel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NewImChannel")
            .field("label", &self.label)
            .field("events", &self.events)
            .finish_non_exhaustive()
    }
}

/// 新建保险箱条目（9.11、11.6）。`instance_ids` 空表示所有实例都能用。
#[derive(Clone, Default, Serialize)]
pub struct NewVaultItem {
    pub name: String,
    pub purpose: String,
    pub username: String,
    pub password: String,
    pub instance_ids: Vec<InstanceId>,
}

impl std::fmt::Debug for NewVaultItem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NewVaultItem")
            .field("name", &self.name)
            .field("purpose", &self.purpose)
            .field("instance_ids", &self.instance_ids)
            .finish_non_exhaustive()
    }
}

/// 修改保险箱条目：只改给了的字段。
#[derive(Clone, Default, Serialize)]
pub struct VaultItemUpdate {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub purpose: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub password: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub instance_ids: Option<Vec<InstanceId>>,
}

impl std::fmt::Debug for VaultItemUpdate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VaultItemUpdate")
            .field("purpose", &self.purpose)
            .field("password_changed", &self.password.is_some())
            .field("instance_ids", &self.instance_ids)
            .finish_non_exhaustive()
    }
}

/// 条目详情：多一个账号。密码永远不返回。
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct VaultItemDetail {
    #[serde(flatten)]
    pub item: VaultItem,
    #[serde(default)]
    pub username: String,
}

#[derive(Deserialize)]
struct Tokens {
    access_token: String,
    refresh_token: String,
}

#[derive(Deserialize)]
struct LoginResp {
    user: User,
    new_user: bool,
    device_id: String,
    #[serde(flatten)]
    tokens: Tokens,
}

pub struct Api {
    base: String,
    cfg: ApiConfig,
    http: reqwest::Client,
    store: Arc<dyn SessionStore>,
    session: RwLock<Option<Session>>,
    refreshing: tokio::sync::Mutex<()>,
    /// 会话没了（退出、被吊销、刷新失败）时调用：清掉上一个人的本地缓存。
    on_signed_out: RwLock<Option<SignedOutHook>>,
    /// 事件流的 TLS 配置（系统证书校验，和接口请求一样）。
    ws_tls: Arc<rustls::ClientConfig>,
    accept_language: RwLock<Option<HeaderValue>>,
    /// 服务端说这个版本太老了（426）：之后的事件流不再连，界面提示升级。一直有效（升级就是重装）。
    upgrade_required: AtomicBool,
}

/// `Accept-Language` 最长多少字节。
pub const MAX_ACCEPT_LANGUAGE: usize = 256;

/// 服务端的错误体。`code` 先按字符串收：服务端以后加了这个版本不认识的码（比如 11.9 的 `instance_limit`），照样当
/// 接口错误交给 App（按状态码给通用提示），而不是当成解析失败。
#[derive(Deserialize)]
struct WireError {
    code: String,
    #[serde(default)]
    message: String,
    #[serde(default)]
    retry_after_secs: Option<u64>,
}

impl WireError {
    fn known(&self) -> Option<ErrorCode> {
        serde_json::from_value(Value::String(self.code.clone())).ok()
    }

    fn into_api(self, status: u16) -> ClientError {
        ClientError::Api {
            status,
            code: self.code,
            detail: self.message,
            retry_after_secs: self.retry_after_secs,
        }
    }
}

/// 检查 `Accept-Language`：去掉首尾空白，空的当没有；最长 [`MAX_ACCEPT_LANGUAGE`] 字节，不能有换行之类的字符。
fn accept_language_header(v: Option<&str>) -> Result<Option<HeaderValue>> {
    let Some(v) = v.map(str::trim).filter(|v| !v.is_empty()) else {
        return Ok(None);
    };
    if v.len() > MAX_ACCEPT_LANGUAGE {
        return Err(ClientError::InvalidArgument {
            detail: "accept_language is longer than 256 bytes".into(),
        });
    }
    HeaderValue::from_str(v)
        .map(Some)
        .map_err(|_| ClientError::InvalidArgument {
            detail: "accept_language has characters a header cannot carry".into(),
        })
}

type SignedOutHook = Arc<dyn Fn() + Send + Sync>;

/// 刷新请求本身的结果。
enum Refreshed {
    Ok,
    SignedOut,
}

impl Api {
    pub fn new(cfg: ApiConfig, store: Arc<dyn SessionStore>) -> Result<Self> {
        crate::install_crypto();
        if cfg.base_url.starts_with("https://") && !crate::tls::platform_ready() {
            return Err(ClientError::Internal {
                detail: "call cn.thinktin.core.TlsInit.initialize(context) before creating \
                          ThinktinClient (https on Android)"
                    .into(),
            });
        }
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(cfg.timeout)
            .build()
            .map_err(ClientError::network)?;
        let ws_tls = crate::tls::ws_client_config().map_err(ClientError::network)?;
        let accept_language = accept_language_header(cfg.accept_language.as_deref())?;
        let session = store.load();
        Ok(Self {
            base: cfg.base_url.trim_end_matches('/').to_owned(),
            cfg,
            http,
            store,
            session: RwLock::new(session),
            refreshing: tokio::sync::Mutex::new(()),
            on_signed_out: RwLock::new(None),
            ws_tls,
            accept_language: RwLock::new(accept_language),
            upgrade_required: AtomicBool::new(false),
        })
    }

    pub fn base_url(&self) -> &str {
        &self.base
    }

    pub(crate) fn ws_tls(&self) -> Arc<rustls::ClientConfig> {
        self.ws_tls.clone()
    }

    /// 换设备语言（App 里切换了语言）。之后的请求带新的 `Accept-Language`；`None` 不带。
    pub fn set_accept_language(&self, v: Option<&str>) -> Result<()> {
        let h = accept_language_header(v)?;
        *self
            .accept_language
            .write()
            .unwrap_or_else(|e| e.into_inner()) = h;
        Ok(())
    }

    pub(crate) fn accept_language(&self) -> Option<HeaderValue> {
        self.accept_language
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// 服务端说过这个版本太老了（任何请求、事件流的握手收到 426）。
    pub fn upgrade_required(&self) -> bool {
        self.upgrade_required.load(Ordering::Relaxed)
    }

    pub(crate) fn mark_upgrade_required(&self) {
        self.upgrade_required.store(true, Ordering::Relaxed);
    }

    /// 所有请求的公共部分：版本头、语言。
    fn request(&self, method: Method, url: String) -> reqwest::RequestBuilder {
        let req = self
            .http
            .request(method, url)
            .header(VERSION_HEADER, API_VERSION.to_string());
        match self.accept_language() {
            Some(lang) => req.header(reqwest::header::ACCEPT_LANGUAGE, lang),
            None => req,
        }
    }

    pub fn session(&self) -> Option<Session> {
        self.session
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    fn access_token(&self) -> Option<String> {
        self.session().map(|s| s.access_token)
    }

    fn set_session(&self, s: Option<Session>) {
        let signed_out = s.is_none();
        *self.session.write().unwrap_or_else(|e| e.into_inner()) = s.clone();
        self.store.save(s);
        if signed_out {
            let hook = self
                .on_signed_out
                .read()
                .unwrap_or_else(|e| e.into_inner())
                .clone();
            if let Some(hook) = hook {
                hook();
            }
        }
    }

    /// 会话没了的时候要做的事（不管是哪个接口、事件流发现的）。
    pub fn on_signed_out(&self, hook: impl Fn() + Send + Sync + 'static) {
        *self
            .on_signed_out
            .write()
            .unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(hook));
    }

    /// 当前的访问令牌（事件流连 WebSocket 用）。没有登录时返回 [`ClientError::SignedOut`]。
    pub fn bearer(&self) -> Result<String> {
        self.access_token().ok_or(ClientError::SignedOut)
    }

    /// 发请求，解析错误体。`auth` 时带访问令牌，遇到令牌过期刷新后重试一次。
    async fn send(
        &self,
        method: Method,
        path: &str,
        body: Option<&Value>,
        auth: bool,
    ) -> Result<reqwest::Response> {
        for attempt in 0..2 {
            let token = if auth { Some(self.bearer()?) } else { None };
            let mut req = self.request(method.clone(), format!("{}{path}", self.base));
            if let Some(t) = &token {
                req = req.bearer_auth(t);
            }
            if let Some(b) = body {
                req = req.json(b);
            }
            let resp = req.send().await.map_err(ClientError::network)?;
            let status = resp.status().as_u16();
            if (200..300).contains(&status) {
                return Ok(resp);
            }
            let err = match resp.json::<WireError>().await {
                Ok(e) => e,
                Err(_) if status == 426 => {
                    self.mark_upgrade_required();
                    return Err(ClientError::UpgradeRequired);
                }
                Err(e) => return Err(ClientError::decode(format!("status {status}: {e}"))),
            };
            match err.known() {
                Some(ErrorCode::UpgradeRequired) => {
                    self.mark_upgrade_required();
                    return Err(ClientError::UpgradeRequired);
                }
                Some(ErrorCode::AccountFrozen) => return Err(ClientError::AccountFrozen),
                Some(ErrorCode::Unauthenticated) if attempt == 0 && token.is_some() => {
                    // 令牌过期：刷新后重试。别人已经刷新过就直接重试。
                    match self.refresh_from(token.as_deref()).await? {
                        Refreshed::Ok => continue,
                        Refreshed::SignedOut => return Err(ClientError::SignedOut),
                    }
                }
                Some(ErrorCode::Unauthenticated | ErrorCode::SessionRevoked) if auth => {
                    self.set_session(None);
                    return Err(ClientError::SignedOut);
                }
                _ => return Err(err.into_api(status)),
            }
        }
        Err(ClientError::SignedOut)
    }

    /// 用刷新令牌换新令牌。`stale` 是失败请求用的访问令牌：当前令牌已经不是它，说明别的请求刚刷新过。
    async fn refresh_from(&self, stale: Option<&str>) -> Result<Refreshed> {
        let _guard = self.refreshing.lock().await;
        let Some(current) = self.session() else {
            return Ok(Refreshed::SignedOut);
        };
        if stale.is_some_and(|s| s != current.access_token) {
            return Ok(Refreshed::Ok);
        }
        let resp = self
            .request(Method::POST, format!("{}/v1/auth/refresh", self.base))
            .json(&json!({ "refresh_token": current.refresh_token }))
            .send()
            .await
            .map_err(ClientError::network)?;
        let status = resp.status().as_u16();
        // 426 不一定带错误体。
        if status == 426 {
            self.mark_upgrade_required();
            return Err(ClientError::UpgradeRequired);
        }
        if status == 200 {
            let t: Tokens = resp.json().await.map_err(ClientError::decode)?;
            self.set_session(Some(Session {
                access_token: t.access_token,
                refresh_token: t.refresh_token,
                ..current
            }));
            return Ok(Refreshed::Ok);
        }
        let Ok(err) = resp.json::<WireError>().await else {
            return Err(ClientError::decode(format!("refresh: status {status}")));
        };
        match err.known() {
            Some(ErrorCode::Unauthenticated | ErrorCode::SessionRevoked) => {
                self.set_session(None);
                Ok(Refreshed::SignedOut)
            }
            Some(ErrorCode::UpgradeRequired) => Err(ClientError::UpgradeRequired),
            // 冻结不清会话：解冻后用同一个刷新令牌接着用。
            Some(ErrorCode::AccountFrozen) => Err(ClientError::AccountFrozen),
            _ => Err(err.into_api(status)),
        }
    }

    /// 强制刷新一次访问令牌（事件流被服务端以“令牌过期”关闭时用）。
    pub async fn refresh(&self) -> Result<()> {
        let stale = self.access_token();
        match self.refresh_from(stale.as_deref()).await? {
            Refreshed::Ok => Ok(()),
            Refreshed::SignedOut => Err(ClientError::SignedOut),
        }
    }

    async fn json<T: DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        body: Option<&Value>,
    ) -> Result<T> {
        let resp = self.send(method, path, body, true).await?;
        resp.json().await.map_err(ClientError::decode)
    }

    async fn empty(&self, method: Method, path: &str, body: Option<&Value>) -> Result<()> {
        self.send(method, path, body, true).await?;
        Ok(())
    }

    // ---------- 账号（4.1、4.2） ----------

    pub async fn send_code(&self, phone: &str) -> Result<()> {
        self.send(
            Method::POST,
            "/v1/auth/code",
            Some(&json!({ "phone": phone })),
            false,
        )
        .await?;
        Ok(())
    }

    pub async fn login(
        &self,
        phone: &str,
        code: &str,
        push: Option<(PushChannelKind, String)>,
    ) -> Result<LoginResult> {
        let mut device = json!({
            "platform": self.cfg.platform,
            "name": self.cfg.device_name,
        });
        if let Some((channel, token)) = push {
            device["push_channel"] = json!(channel);
            device["push_token"] = json!(token);
        }
        let resp = self
            .send(
                Method::POST,
                "/v1/auth/login",
                Some(&json!({ "phone": phone, "code": code, "device": device })),
                false,
            )
            .await?;
        let l: LoginResp = resp.json().await.map_err(ClientError::decode)?;
        self.set_session(Some(Session {
            user_id: l.user.id.to_string(),
            device_id: l.device_id,
            access_token: l.tokens.access_token,
            refresh_token: l.tokens.refresh_token,
        }));
        Ok(LoginResult {
            user: l.user,
            new_user: l.new_user,
        })
    }

    /// 退出登录（只下线本设备）。服务端调用失败也清掉本地会话。
    pub async fn logout(&self) -> Result<()> {
        let result = match self.access_token() {
            Some(_) => self.empty(Method::POST, "/v1/auth/logout", None).await,
            None => Ok(()),
        };
        self.set_session(None);
        match result {
            Err(ClientError::SignedOut) => Ok(()),
            r => r,
        }
    }

    pub async fn me(&self) -> Result<User> {
        self.json(Method::GET, "/v1/me", None).await
    }

    /// 推送、收件箱用的语言（1.6）。
    pub async fn set_locale(&self, locale: &str) -> Result<User> {
        self.json(Method::PATCH, "/v1/me", Some(&json!({ "locale": locale })))
            .await
    }

    /// 改昵称；`None` 清掉。
    pub async fn update_profile(&self, display_name: Option<&str>) -> Result<User> {
        self.json(
            Method::PATCH,
            "/v1/me",
            Some(&json!({ "display_name": display_name })),
        )
        .await
    }

    /// 给自己的手机号发验证码，做敏感操作前确认：`delete_account`（注销）或 `change_phone`。
    pub async fn send_self_code(&self, purpose: &str) -> Result<()> {
        self.empty(
            Method::POST,
            "/v1/me/code",
            Some(&json!({ "purpose": purpose })),
        )
        .await
    }

    /// 注销账号（16.4）：用 [`Self::send_self_code`]（`delete_account`）发来的验证码确认。成功后本地会话一起清掉。
    pub async fn delete_account(&self, code: &str) -> Result<()> {
        self.empty(
            Method::POST,
            "/v1/me/delete",
            Some(&json!({ "code": code })),
        )
        .await?;
        self.set_session(None);
        Ok(())
    }

    /// 吊销一台设备（丢了的手机、不用的电脑）：它的登录会话立即失效。吊销的是这台自己：本地的登录状态（和缓存）
    /// 马上清掉，不用等下一个请求被拒。
    pub async fn revoke_device(&self, id: DeviceId) -> Result<()> {
        let mine = self
            .session()
            .and_then(|s| s.device_id.parse::<DeviceId>().ok())
            .is_some_and(|d| d == id);
        self.empty(Method::DELETE, &format!("/v1/devices/{id}"), None)
            .await?;
        if mine {
            self.set_session(None);
        }
        Ok(())
    }

    pub async fn set_push(&self, channel: PushChannelKind, token: &str) -> Result<()> {
        self.empty(
            Method::PUT,
            "/v1/devices/current/push",
            Some(&json!({ "channel": channel, "token": token })),
        )
        .await
    }

    /// 这台设备的推送开启令牌（10.6，ActivityKit 的 `pushToStartTokenUpdates`）：`Some` 登记（用户打开了
    /// “计划运行时显示实时活动”），`None` 清掉。
    pub async fn set_live_activity_start_token(&self, token: Option<&str>) -> Result<()> {
        let path = "/v1/devices/current/live-activity-start";
        match token {
            Some(token) => {
                self.empty(Method::PUT, path, Some(&json!({ "token": token })))
                    .await
            }
            None => self.empty(Method::DELETE, path, None).await,
        }
    }

    /// 全部停止（4.6）：取消所有运行、吊销全部运行授权、暂停全部计划。
    pub async fn stop_all(&self) -> Result<Stopped> {
        self.json(Method::POST, "/v1/me/stop-all", Some(&json!({})))
            .await
    }

    /// 下线其他设备（4.6），只留当前这台。`stop_agents` 时顺带全部停止。
    pub async fn sign_out_other_devices(&self, stop_agents: bool) -> Result<SignedOutOthers> {
        self.json(
            Method::POST,
            "/v1/devices/sign-out-others",
            Some(&json!({ "stop_agents": stop_agents })),
        )
        .await
    }

    /// 登录着的设备，最近活跃的在前；电脑带在线状态（连着设备中继，14.1）。
    pub async fn devices(&self) -> Result<Vec<DeviceView>> {
        #[derive(Deserialize)]
        struct R {
            devices: Vec<DeviceView>,
        }
        Ok(self
            .json::<R>(Method::GET, "/v1/devices", None)
            .await?
            .devices)
    }

    // ---------- 手机和电脑之间的消息（14.1，内容和签名见 pairing） ----------

    /// 发给自己的另一台设备（手机发给电脑：配对应答、审批决定、能力令牌、吊销）。
    /// 电脑不在线时排队，连上设备中继后投递。
    pub async fn send_device_message(
        &self,
        to: DeviceId,
        kind: DeviceMessageKind,
        body: &Value,
    ) -> Result<DeviceMessage> {
        self.json(
            Method::POST,
            &format!("/v1/devices/{to}/messages"),
            Some(&json!({ "kind": kind, "body": body })),
        )
        .await
    }

    /// 别的设备发给这台、还没收的消息（电脑发来的配对确认、审批请求），按发出的顺序。
    pub async fn device_messages(&self) -> Result<Vec<DeviceMessage>> {
        #[derive(Deserialize)]
        struct R {
            messages: Vec<DeviceMessage>,
        }
        Ok(self
            .json::<R>(Method::GET, "/v1/devices/current/messages", None)
            .await?
            .messages)
    }

    /// 收下了这些消息（验过签、处理完），之后不再返回。返回确认的条数。
    pub async fn ack_device_messages(&self, ids: &[DeviceMessageId]) -> Result<u64> {
        #[derive(Deserialize)]
        struct R {
            acknowledged: u64,
        }
        Ok(self
            .json::<R>(
                Method::POST,
                "/v1/devices/current/messages/ack",
                Some(&json!({ "ids": ids })),
            )
            .await?
            .acknowledged)
    }

    // ---------- agent 与实例 ----------

    pub async fn agents(&self) -> Result<Vec<AgentInfo>> {
        #[derive(Deserialize)]
        struct R {
            agents: Vec<AgentInfo>,
        }
        Ok(self
            .json::<R>(Method::GET, "/v1/agents", None)
            .await?
            .agents)
    }

    pub async fn instances(&self) -> Result<Vec<Instance>> {
        #[derive(Deserialize)]
        struct R {
            instances: Vec<Instance>,
        }
        Ok(self
            .json::<R>(Method::GET, "/v1/instances", None)
            .await?
            .instances)
    }

    pub async fn instance(&self, id: InstanceId) -> Result<Instance> {
        self.json(Method::GET, &format!("/v1/instances/{id}"), None)
            .await
    }

    pub async fn adopt(
        &self,
        agent_id: &str,
        name: &str,
        harness: Option<&str>,
    ) -> Result<Instance> {
        self.json(
            Method::POST,
            "/v1/instances",
            Some(&json!({ "agent_id": agent_id, "name": name, "harness": harness })),
        )
        .await
    }

    pub async fn rename_instance(&self, id: InstanceId, name: &str) -> Result<Instance> {
        self.json(
            Method::PATCH,
            &format!("/v1/instances/{id}"),
            Some(&json!({ "name": name })),
        )
        .await
    }

    /// 改实例的名字、用途说明、交流开关（8.9），给了才改。
    pub async fn update_instance(
        &self,
        id: InstanceId,
        change: &InstanceChange,
    ) -> Result<Instance> {
        let body = serde_json::to_value(change).map_err(ClientError::decode)?;
        self.json(Method::PATCH, &format!("/v1/instances/{id}"), Some(&body))
            .await
    }

    /// 换模板版本（不给就是升级到当前版本）：下次唤醒时重建沙箱，工作区保留。
    pub async fn set_instance_version(
        &self,
        id: InstanceId,
        version: Option<&str>,
    ) -> Result<Instance> {
        self.json(
            Method::POST,
            &format!("/v1/instances/{id}/version"),
            Some(&json!({ "version": version })),
        )
        .await
    }

    /// 实例的模型别名 → 哪把 key、哪个上游模型。
    pub async fn model_routes(&self, id: InstanceId) -> Result<Vec<ModelRoute>> {
        #[derive(Deserialize)]
        struct R {
            routes: Vec<ModelRoute>,
        }
        Ok(self
            .json::<R>(Method::GET, &format!("/v1/instances/{id}/routes"), None)
            .await?
            .routes)
    }

    /// 整体替换实例的模型别名。
    pub async fn set_model_routes(&self, id: InstanceId, routes: &[ModelRoute]) -> Result<()> {
        self.send(
            Method::PUT,
            &format!("/v1/instances/{id}/routes"),
            Some(&json!({ "routes": routes })),
            true,
        )
        .await?;
        Ok(())
    }

    pub async fn delete_instance(&self, id: InstanceId) -> Result<()> {
        self.empty(Method::DELETE, &format!("/v1/instances/{id}"), None)
            .await
    }

    // ---------- 运行 ----------

    pub async fn create_run(&self, instance: InstanceId, prompt: &str) -> Result<Run> {
        self.json(
            Method::POST,
            &format!("/v1/instances/{instance}/runs"),
            Some(&json!({ "prompt": prompt })),
        )
        .await
    }

    pub async fn runs(
        &self,
        instance: InstanceId,
        before: Option<RunId>,
        limit: u32,
    ) -> Result<Vec<Run>> {
        #[derive(Deserialize)]
        struct R {
            runs: Vec<Run>,
        }
        let mut path = format!("/v1/instances/{instance}/runs?limit={limit}");
        if let Some(b) = before {
            path.push_str(&format!("&before={b}"));
        }
        Ok(self.json::<R>(Method::GET, &path, None).await?.runs)
    }

    /// 跨实例的运行（11.8），新的在前。
    pub async fn all_runs(
        &self,
        f: &RunFilter,
        before: Option<RunId>,
        limit: u32,
    ) -> Result<Vec<Run>> {
        #[derive(Deserialize)]
        struct R {
            runs: Vec<Run>,
        }
        let mut path = format!("/v1/runs?limit={limit}");
        if let Some(p) = f.plan {
            path.push_str(&format!("&plan_id={p}"));
        }
        if f.active {
            path.push_str("&active=true");
        }
        if f.roots {
            path.push_str("&roots=true");
        }
        if let Some(b) = before {
            path.push_str(&format!("&before={b}"));
        }
        Ok(self.json::<R>(Method::GET, &path, None).await?.runs)
    }

    pub async fn run(&self, id: RunId) -> Result<Run> {
        self.json(Method::GET, &format!("/v1/runs/{id}"), None)
            .await
    }

    /// 取消一个运行；`tree` 时停掉整棵运行树（流水线）。
    pub async fn cancel_run(&self, id: RunId, tree: bool) -> Result<Run> {
        self.json(
            Method::POST,
            &format!("/v1/runs/{id}/cancel?tree={tree}"),
            None,
        )
        .await
    }

    /// 这个运行在这台设备上开了实时活动（10.6），或者远程开启的那个拿到了令牌：登记它的推送令牌
    /// （ActivityKit 的 `pushTokenUpdates`）。令牌变了再调一次；App 启动、回到前台时把每个开着的实时活动现在的令牌
    /// 再报一次（没变的什么都不做，连着失败放弃了的从头来）。
    pub async fn register_live_activity(&self, id: RunId, token: &str) -> Result<()> {
        self.empty(
            Method::PUT,
            &format!("/v1/runs/{id}/live-activity"),
            Some(&json!({ "token": token })),
        )
        .await
    }

    /// 这个运行的实时活动关掉了（用户划掉了、App 自己结束了）：后台不再推送。
    pub async fn end_live_activity(&self, id: RunId) -> Result<()> {
        self.empty(
            Method::DELETE,
            &format!("/v1/runs/{id}/live-activity"),
            None,
        )
        .await
    }

    pub async fn run_tree(&self, id: RunId) -> Result<Vec<Run>> {
        #[derive(Deserialize)]
        struct R {
            runs: Vec<Run>,
        }
        Ok(self
            .json::<R>(Method::GET, &format!("/v1/runs/{id}/tree"), None)
            .await?
            .runs)
    }

    // ---------- 审批 ----------

    pub async fn approvals(&self) -> Result<Vec<Approval>> {
        #[derive(Deserialize)]
        struct R {
            approvals: Vec<Approval>,
        }
        Ok(self
            .json::<R>(Method::GET, "/v1/approvals", None)
            .await?
            .approvals)
    }

    /// 一条审批（什么状态都行）。
    pub async fn approval(&self, id: ApprovalId) -> Result<Approval> {
        self.json(Method::GET, &format!("/v1/approvals/{id}"), None)
            .await
    }

    pub async fn decide_approval(&self, id: ApprovalId, option_id: &str) -> Result<Approval> {
        self.json(
            Method::POST,
            &format!("/v1/approvals/{id}/decide"),
            Some(&json!({ "option_id": option_id })),
        )
        .await
    }

    // ---------- 计划 ----------

    /// 计划列表，带着每个计划的触发器、步骤、下次运行时间（老的服务端只有计划本身，其余为空）。
    pub async fn plans(&self, instance: Option<InstanceId>) -> Result<Vec<PlanView>> {
        #[derive(Deserialize)]
        struct R {
            plans: Vec<PlanView>,
        }
        let path = match instance {
            Some(i) => format!("/v1/plans?instance_id={i}"),
            None => "/v1/plans".into(),
        };
        Ok(self.json::<R>(Method::GET, &path, None).await?.plans)
    }

    pub async fn plan(&self, id: PlanId) -> Result<PlanView> {
        self.json(Method::GET, &format!("/v1/plans/{id}"), None)
            .await
    }

    pub async fn create_plan(&self, plan: &NewPlan) -> Result<PlanView> {
        let body = serde_json::to_value(plan).map_err(ClientError::decode)?;
        self.json(Method::POST, "/v1/plans", Some(&body)).await
    }

    pub async fn update_plan(&self, id: PlanId, change: &PlanChange) -> Result<PlanView> {
        let body = serde_json::to_value(change).map_err(ClientError::decode)?;
        self.json(Method::PATCH, &format!("/v1/plans/{id}"), Some(&body))
            .await
    }

    /// 给计划加一个触发器（一个计划最多 10 个）。
    pub async fn add_trigger(&self, plan: PlanId, spec: &ScheduleSpec) -> Result<Trigger> {
        self.json(
            Method::POST,
            &format!("/v1/plans/{plan}/triggers"),
            Some(&json!({ "spec": spec })),
        )
        .await
    }

    pub async fn delete_trigger(&self, id: TriggerId) -> Result<()> {
        self.empty(Method::DELETE, &format!("/v1/triggers/{id}"), None)
            .await
    }

    /// 暂停或恢复用户自己的计划（等确认的计划用 `confirm_plan`）。
    pub async fn set_plan_paused(&self, id: PlanId, paused: bool) -> Result<PlanView> {
        let action = if paused { "pause" } else { "resume" };
        self.json(Method::POST, &format!("/v1/plans/{id}/{action}"), None)
            .await
    }

    /// 确认 agent 新建或修改的计划，`revision` 是用户看到的版本。
    pub async fn confirm_plan(&self, id: PlanId, revision: u32) -> Result<PlanView> {
        self.json(
            Method::POST,
            &format!("/v1/plans/{id}/confirm"),
            Some(&serde_json::json!({ "revision": revision })),
        )
        .await
    }

    pub async fn delete_plan(&self, id: PlanId) -> Result<()> {
        self.empty(Method::DELETE, &format!("/v1/plans/{id}"), None)
            .await
    }

    // ---------- 收件箱（10.4） ----------

    pub async fn inbox(
        &self,
        before: Option<InboxItemId>,
        limit: u32,
        unread_only: bool,
    ) -> Result<InboxPage> {
        let mut path = format!("/v1/inbox?limit={limit}&unread={unread_only}");
        if let Some(b) = before {
            path.push_str(&format!("&before={b}"));
        }
        self.json(Method::GET, &path, None).await
    }

    pub async fn inbox_item(&self, id: InboxItemId) -> Result<InboxItem> {
        self.json(Method::GET, &format!("/v1/inbox/{id}"), None)
            .await
    }

    pub async fn mark_inbox_unread(&self, id: InboxItemId) -> Result<()> {
        self.empty(Method::POST, &format!("/v1/inbox/{id}/unread"), None)
            .await
    }

    pub async fn delete_inbox_item(&self, id: InboxItemId) -> Result<()> {
        self.empty(Method::DELETE, &format!("/v1/inbox/{id}"), None)
            .await
    }

    /// 标已读：给 `ids` 只标这些；否则标到 `up_to`（含）为止。返回剩余未读数。
    pub async fn mark_inbox_read(
        &self,
        ids: Option<&[InboxItemId]>,
        up_to: Option<InboxItemId>,
    ) -> Result<i64> {
        #[derive(Deserialize)]
        struct R {
            unread: i64,
        }
        let body = match ids {
            Some(ids) => json!({ "ids": ids }),
            None => json!({ "up_to": up_to }),
        };
        Ok(self
            .json::<R>(Method::POST, "/v1/inbox/read", Some(&body))
            .await?
            .unread)
    }

    // ---------- 事件（补发） ----------

    pub async fn events_page(
        &self,
        instance: InstanceId,
        after: u64,
        limit: u32,
    ) -> Result<EventsPage> {
        self.json(
            Method::GET,
            &format!("/v1/instances/{instance}/events?after={after}&limit={limit}"),
            None,
        )
        .await
    }

    // ---------- 模型 key ----------

    /// 预置的模型厂商（添加 key 时选）。
    pub async fn vendors(&self) -> Result<Vec<VendorInfo>> {
        #[derive(Deserialize)]
        struct R {
            vendors: Vec<VendorInfo>,
        }
        Ok(self
            .json::<R>(Method::GET, "/v1/vendors", None)
            .await?
            .vendors)
    }

    pub async fn credentials(&self) -> Result<Vec<Credential>> {
        #[derive(Deserialize)]
        struct R {
            credentials: Vec<Credential>,
        }
        Ok(self
            .json::<R>(Method::GET, "/v1/credentials", None)
            .await?
            .credentials)
    }

    pub async fn add_credential(&self, c: &NewCredential) -> Result<Credential> {
        let body = serde_json::to_value(c).map_err(ClientError::decode)?;
        self.json(Method::POST, "/v1/credentials", Some(&body))
            .await
    }

    /// 改备注、停用或重新启用一把 key；给了才改。
    pub async fn update_credential(
        &self,
        id: CredentialId,
        label: Option<&str>,
        disabled: Option<bool>,
    ) -> Result<Credential> {
        let mut body = serde_json::Map::new();
        if let Some(l) = label {
            body.insert("label".into(), json!(l));
        }
        if let Some(d) = disabled {
            body.insert("disabled".into(), json!(d));
        }
        self.json(
            Method::PATCH,
            &format!("/v1/credentials/{id}"),
            Some(&Value::Object(body)),
        )
        .await
    }

    /// 改每日 token 上限（11.9）：`None` 取消上限。
    pub async fn set_credential_daily_limit(
        &self,
        id: CredentialId,
        limit: Option<u64>,
    ) -> Result<Credential> {
        self.json(
            Method::PATCH,
            &format!("/v1/credentials/{id}"),
            Some(&json!({ "daily_token_limit": limit })),
        )
        .await
    }

    /// 换 key（同一个厂商、同一条记录：模型路由不用改）。
    pub async fn replace_credential_secret(
        &self,
        id: CredentialId,
        api_key: &str,
    ) -> Result<Credential> {
        self.json(
            Method::PUT,
            &format!("/v1/credentials/{id}/secret"),
            Some(&json!({ "api_key": api_key })),
        )
        .await
    }

    pub async fn delete_credential(&self, id: CredentialId) -> Result<()> {
        self.empty(Method::DELETE, &format!("/v1/credentials/{id}"), None)
            .await
    }

    // ---------- IM 渠道（10.5） ----------

    pub async fn im_channels(&self) -> Result<Vec<ImChannel>> {
        #[derive(Deserialize)]
        struct R {
            channels: Vec<ImChannel>,
        }
        Ok(self
            .json::<R>(Method::GET, "/v1/im-channels", None)
            .await?
            .channels)
    }

    pub async fn add_im_channel(&self, c: &NewImChannel) -> Result<ImChannel> {
        let body = serde_json::to_value(c).map_err(ClientError::decode)?;
        self.json(Method::POST, "/v1/im-channels", Some(&body))
            .await
    }

    /// 改名字、订阅的事件、开关；不给的不改。
    pub async fn update_im_channel(
        &self,
        id: ImChannelId,
        label: Option<&str>,
        events: Option<&[String]>,
        enabled: Option<bool>,
    ) -> Result<ImChannel> {
        let mut body = serde_json::Map::new();
        if let Some(l) = label {
            body.insert("label".into(), json!(l));
        }
        if let Some(e) = events {
            body.insert("events".into(), json!(e));
        }
        if let Some(e) = enabled {
            body.insert("enabled".into(), json!(e));
        }
        self.json(
            Method::PATCH,
            &format!("/v1/im-channels/{id}"),
            Some(&Value::Object(body)),
        )
        .await
    }

    /// 换 webhook 地址或加签密钥（要是同一家的）。机器人失效被后台停用的渠道会重新打开，用户自己关掉的还是关着。
    pub async fn replace_im_webhook(
        &self,
        id: ImChannelId,
        webhook_url: &str,
        secret: Option<&str>,
    ) -> Result<ImChannel> {
        let body = json!({ "webhook_url": webhook_url, "secret": secret });
        self.json(
            Method::PUT,
            &format!("/v1/im-channels/{id}/webhook"),
            Some(&body),
        )
        .await
    }

    /// 发一条测试消息（异步发，结果看渠道的 `last_sent_at` / `last_error`）。
    pub async fn test_im_channel(&self, id: ImChannelId) -> Result<()> {
        self.empty(Method::POST, &format!("/v1/im-channels/{id}/test"), None)
            .await
    }

    pub async fn delete_im_channel(&self, id: ImChannelId) -> Result<()> {
        self.empty(Method::DELETE, &format!("/v1/im-channels/{id}"), None)
            .await
    }

    // ---------- 内容举报（5.5） ----------

    /// 举报 agent 的输出：整个运行（它的回复），或者其中一条事件、一个产出物。同一条内容再举报一次返回那一条
    /// 待处理的举报。
    pub async fn report_content(
        &self,
        run: RunId,
        event_seq: Option<u64>,
        artifact: Option<ArtifactId>,
        reason: ReportReason,
        note: Option<&str>,
    ) -> Result<ContentReport> {
        self.json(
            Method::POST,
            "/v1/reports",
            Some(&json!({
                "run_id": run,
                "event_seq": event_seq,
                "artifact_id": artifact,
                "reason": reason,
                "note": note,
            })),
        )
        .await
    }

    /// 自己的举报和处理结果，新的在前。
    pub async fn reports(&self) -> Result<Vec<ContentReport>> {
        #[derive(Deserialize)]
        struct R {
            reports: Vec<ContentReport>,
        }
        Ok(self
            .json::<R>(Method::GET, "/v1/reports", None)
            .await?
            .reports)
    }

    // ---------- 团队和团队模板（8.1） ----------

    pub async fn teams(&self) -> Result<Vec<Team>> {
        #[derive(Deserialize)]
        struct R {
            teams: Vec<Team>,
        }
        Ok(self.json::<R>(Method::GET, "/v1/teams", None).await?.teams)
    }

    /// 把几个实例编成团队（一个负责人 lead，其余是成员）。
    pub async fn create_team(&self, name: &str, members: &[TeamMember]) -> Result<Team> {
        self.json(
            Method::POST,
            "/v1/teams",
            Some(&json!({ "name": name, "members": members })),
        )
        .await
    }

    pub async fn team(&self, id: TeamId) -> Result<Team> {
        self.json(Method::GET, &format!("/v1/teams/{id}"), None)
            .await
    }

    /// 改名、换成员（整体替换）；给了才改。
    pub async fn update_team(
        &self,
        id: TeamId,
        name: Option<&str>,
        members: Option<&[TeamMember]>,
    ) -> Result<Team> {
        let mut body = serde_json::Map::new();
        if let Some(n) = name {
            body.insert("name".into(), json!(n));
        }
        if let Some(m) = members {
            body.insert("members".into(), json!(m));
        }
        self.json(
            Method::PATCH,
            &format!("/v1/teams/{id}"),
            Some(&Value::Object(body)),
        )
        .await
    }

    /// 删团队（实例不删）。
    pub async fn delete_team(&self, id: TeamId) -> Result<()> {
        self.empty(Method::DELETE, &format!("/v1/teams/{id}"), None)
            .await
    }

    pub async fn team_templates(&self) -> Result<Vec<TeamTemplate>> {
        #[derive(Deserialize)]
        struct R {
            templates: Vec<TeamTemplate>,
        }
        Ok(self
            .json::<R>(Method::GET, "/v1/team-templates", None)
            .await?
            .templates)
    }

    /// 新建团队模板：直接给成员（agent、接入方式、名字、角色），或者从现有团队生成（给 `team`）。
    pub async fn create_team_template(
        &self,
        name: &str,
        spec: Option<&TeamTemplateSpec>,
        team: Option<TeamId>,
    ) -> Result<TeamTemplate> {
        self.json(
            Method::POST,
            "/v1/team-templates",
            Some(&json!({ "name": name, "spec": spec, "team_id": team })),
        )
        .await
    }

    pub async fn delete_team_template(&self, id: TeamTemplateId) -> Result<()> {
        self.empty(Method::DELETE, &format!("/v1/team-templates/{id}"), None)
            .await
    }

    /// 按模板领养一整个团队：每个成员领养一个新实例，再编成团队。`name` 不给就用模板的名字。
    pub async fn adopt_team_template(
        &self,
        id: TeamTemplateId,
        name: Option<&str>,
    ) -> Result<Team> {
        self.json(
            Method::POST,
            &format!("/v1/team-templates/{id}/adopt"),
            Some(&json!({ "name": name })),
        )
        .await
    }

    // ---------- 用量 ----------

    /// 用量汇总。`group`：day / instance / model / credential；时间是 RFC 3339，不给就是最近 30 天。
    pub async fn usage(
        &self,
        group: &str,
        from: Option<&str>,
        to: Option<&str>,
        tz: Option<&str>,
    ) -> Result<UsageSummary> {
        let query = {
            let mut q = url::form_urlencoded::Serializer::new(String::new());
            q.append_pair("group", group);
            for (k, v) in [("from", from), ("to", to), ("tz", tz)] {
                if let Some(v) = v {
                    q.append_pair(k, v);
                }
            }
            q.finish()
        };
        self.json(Method::GET, &format!("/v1/usage?{query}"), None)
            .await
    }

    // ---------- 密码保险箱（9.11、11.6） ----------

    /// 条目列表（没有账号和密码）。
    pub async fn vault_items(&self) -> Result<Vec<VaultItem>> {
        #[derive(Deserialize)]
        struct R {
            items: Vec<VaultItem>,
        }
        Ok(self.json::<R>(Method::GET, "/v1/vault", None).await?.items)
    }

    /// 详情，带账号。
    pub async fn vault_item(&self, id: VaultItemId) -> Result<VaultItemDetail> {
        self.json(Method::GET, &format!("/v1/vault/{id}"), None)
            .await
    }

    /// 新建。同名返回 409（`conflict`）。
    pub async fn create_vault_item(&self, item: &NewVaultItem) -> Result<VaultItem> {
        let body = serde_json::to_value(item).map_err(ClientError::decode)?;
        self.json(Method::POST, "/v1/vault", Some(&body)).await
    }

    pub async fn update_vault_item(
        &self,
        id: VaultItemId,
        change: &VaultItemUpdate,
    ) -> Result<VaultItem> {
        let body = serde_json::to_value(change).map_err(ClientError::decode)?;
        self.json(Method::PATCH, &format!("/v1/vault/{id}"), Some(&body))
            .await
    }

    pub async fn delete_vault_item(&self, id: VaultItemId) -> Result<()> {
        self.empty(Method::DELETE, &format!("/v1/vault/{id}"), None)
            .await
    }

    /// agent 请用户填的表单。默认只要还在等的，`all` 时带上处理过的。
    pub async fn vault_requests(&self, all: bool) -> Result<Vec<VaultRequest>> {
        #[derive(Deserialize)]
        struct R {
            requests: Vec<VaultRequest>,
        }
        let path = if all {
            "/v1/vault/requests?all=true"
        } else {
            "/v1/vault/requests"
        };
        Ok(self.json::<R>(Method::GET, path, None).await?.requests)
    }

    /// 填好 agent 要的账号密码：存进保险箱，agent 只拿到名字。
    pub async fn fulfill_vault_request(
        &self,
        id: VaultRequestId,
        username: &str,
        password: &str,
        purpose: Option<&str>,
    ) -> Result<VaultRequest> {
        let mut body = json!({ "username": username, "password": password });
        if let Some(p) = purpose {
            body["purpose"] = json!(p);
        }
        self.json(
            Method::POST,
            &format!("/v1/vault/requests/{id}/fulfill"),
            Some(&body),
        )
        .await
    }

    pub async fn decline_vault_request(&self, id: VaultRequestId) -> Result<VaultRequest> {
        self.json(
            Method::POST,
            &format!("/v1/vault/requests/{id}/decline"),
            None,
        )
        .await
    }

    // ---------- 产出物 ----------

    pub async fn run_artifacts(&self, run: RunId) -> Result<Vec<Artifact>> {
        #[derive(Deserialize)]
        struct R {
            artifacts: Vec<Artifact>,
        }
        Ok(self
            .json::<R>(Method::GET, &format!("/v1/runs/{run}/artifacts"), None)
            .await?
            .artifacts)
    }

    /// 实例的产出物，新的在前（最多 `limit` 个）。
    pub async fn instance_artifacts(
        &self,
        instance: InstanceId,
        limit: u32,
    ) -> Result<Vec<Artifact>> {
        #[derive(Deserialize)]
        struct R {
            artifacts: Vec<Artifact>,
        }
        Ok(self
            .json::<R>(
                Method::GET,
                &format!("/v1/instances/{instance}/artifacts?limit={limit}"),
                None,
            )
            .await?
            .artifacts)
    }

    pub async fn delete_artifact(&self, id: ArtifactId) -> Result<()> {
        self.empty(Method::DELETE, &format!("/v1/artifacts/{id}"), None)
            .await
    }

    pub async fn artifact_content(&self, id: ArtifactId) -> Result<Vec<u8>> {
        let resp = self
            .send(
                Method::GET,
                &format!("/v1/artifacts/{id}/content"),
                None,
                true,
            )
            .await?;
        Ok(resp.bytes().await.map_err(ClientError::network)?.to_vec())
    }
}
