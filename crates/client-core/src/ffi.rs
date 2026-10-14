//! 给原生端（Swift / Kotlin）的接口。类型和服务端的 `proto` 一一对应，只是换成绑定好用的形式：
//! id 是字符串、时间是 Unix 毫秒、结构不固定的部分（事件载荷、工具调用、计划策略）是 JSON 字符串。
//!
//! 所有网络操作都在 client-core 自己的 tokio 运行时上执行，原生端的 async 调用只是等结果，
//! 不依赖调用方的线程模型。

use std::str::FromStr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, TimeZone, Utc};
use proto::domain as d;

use crate::api::{self, Api, ApiConfig, SessionStore};
use crate::cache::Cache;
use crate::client::Client;
use crate::error::{ClientError, Result};
use crate::events::{EventSink, StreamConfig, StreamHandle, StreamStatus};

fn ms(t: DateTime<Utc>) -> i64 {
    t.timestamp_millis()
}

fn ms_opt(t: Option<DateTime<Utc>>) -> Option<i64> {
    t.map(ms)
}

fn parse<T: FromStr>(raw: &str, what: &str) -> Result<T> {
    raw.parse().map_err(|_| ClientError::InvalidArgument {
        message: format!("bad {what} id {raw:?}"),
    })
}

fn parse_opt<T: FromStr>(raw: &Option<String>, what: &str) -> Result<Option<T>> {
    raw.as_deref().map(|r| parse(r, what)).transpose()
}

fn from_enum_str<T: serde::de::DeserializeOwned>(raw: &str, what: &str) -> Result<T> {
    serde_json::from_value(serde_json::Value::String(raw.to_owned())).map_err(|_| {
        ClientError::InvalidArgument {
            message: format!("unknown {what} {raw:?}"),
        }
    })
}

// ---------- 记录类型 ----------

#[derive(Debug, Clone, uniffi::Record)]
pub struct ClientConfig {
    /// 比如 `https://api.thinktin.cn`。
    pub base_url: String,
    /// 缓存数据库文件（App 的私有目录）；为空不缓存。
    pub cache_path: Option<String>,
    /// ios / android / macos
    pub platform: String,
    /// 设备名（“张三的 iPhone”），显示在设备管理里。
    pub device_name: String,
    pub timeout_secs: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct User {
    pub id: String,
    pub phone: String,
    pub display_name: Option<String>,
    pub status: String,
    pub created_at_ms: i64,
}

impl From<d::User> for User {
    fn from(u: d::User) -> Self {
        Self {
            id: u.id.to_string(),
            phone: u.phone,
            display_name: u.display_name,
            status: u.status.to_string(),
            created_at_ms: ms(u.created_at),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LoginResult {
    pub user: User,
    pub new_user: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AgentInfo {
    pub id: String,
    pub name: String,
    pub version: String,
    pub license: Option<String>,
    pub sites: Vec<String>,
    pub harnesses: Vec<String>,
    pub default_harness: String,
}

impl From<api::AgentInfo> for AgentInfo {
    fn from(a: api::AgentInfo) -> Self {
        Self {
            id: a.id,
            name: a.name,
            version: a.version,
            license: a.license,
            sites: a.sites,
            harnesses: a.harnesses,
            default_harness: a.default_harness,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Instance {
    pub id: String,
    pub agent_id: String,
    pub agent_version: String,
    pub harness: String,
    pub name: String,
    pub state: String,
    pub created_at_ms: i64,
    pub last_active_at_ms: i64,
}

impl From<d::Instance> for Instance {
    fn from(i: d::Instance) -> Self {
        Self {
            id: i.id.to_string(),
            agent_id: i.agent_id,
            agent_version: i.agent_version,
            harness: i.harness,
            name: i.name,
            state: i.state.to_string(),
            created_at_ms: ms(i.created_at),
            last_active_at_ms: ms(i.last_active_at),
        }
    }
}

/// 模型别名：agent 用别名调模型，平台按它找到用户的哪把 key、哪个上游模型。
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ModelRoute {
    pub alias: String,
    pub credential_id: String,
    pub upstream_model: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Run {
    pub id: String,
    /// agent / pipeline
    pub kind: String,
    pub instance_id: String,
    pub plan_id: Option<String>,
    pub parent_run_id: Option<String>,
    pub root_run_id: String,
    pub step_key: Option<String>,
    pub source: String,
    pub prompt: String,
    pub state: String,
    pub state_reason: Option<String>,
    pub attempt: u32,
    pub tokens_used: u64,
    pub summary: Option<String>,
    pub error: Option<String>,
    pub created_at_ms: i64,
    pub started_at_ms: Option<i64>,
    pub finished_at_ms: Option<i64>,
}

impl From<d::Run> for Run {
    fn from(r: d::Run) -> Self {
        Self {
            id: r.id.to_string(),
            kind: r.kind.to_string(),
            instance_id: r.instance_id.to_string(),
            plan_id: r.plan_id.map(|p| p.to_string()),
            parent_run_id: r.parent_run_id.map(|p| p.to_string()),
            root_run_id: r.root_run_id.to_string(),
            step_key: r.step_key,
            source: r.source.to_string(),
            prompt: r.prompt,
            state: r.state.to_string(),
            state_reason: r.state_reason,
            attempt: r.attempt,
            tokens_used: r.tokens_used,
            summary: r.summary,
            error: r.error,
            created_at_ms: ms(r.created_at),
            started_at_ms: ms_opt(r.started_at),
            finished_at_ms: ms_opt(r.finished_at),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ApprovalOption {
    pub option_id: String,
    pub name: String,
    /// allow_once / allow_always / reject_once / reject_always
    pub kind: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Approval {
    pub id: String,
    pub run_id: String,
    pub instance_id: String,
    pub title: Option<String>,
    pub options: Vec<ApprovalOption>,
    /// agent 要执行的工具调用（JSON），给用户看细节。
    pub tool_call_json: String,
    pub state: String,
    pub expires_at_ms: i64,
    pub created_at_ms: i64,
}

impl From<d::Approval> for Approval {
    fn from(a: d::Approval) -> Self {
        let field = |o: &serde_json::Value, k: &str| {
            o.get(k)
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        let options = a
            .options
            .as_array()
            .map(|opts| {
                opts.iter()
                    .map(|o| ApprovalOption {
                        option_id: field(o, "option_id"),
                        name: field(o, "name"),
                        kind: field(o, "kind"),
                    })
                    .collect()
            })
            .unwrap_or_default();
        Self {
            id: a.id.to_string(),
            run_id: a.run_id.to_string(),
            instance_id: a.instance_id.to_string(),
            title: a.title,
            options,
            tool_call_json: a.tool_call.to_string(),
            state: a.state.to_string(),
            expires_at_ms: ms(a.expires_at),
            created_at_ms: ms(a.created_at),
        }
    }
}

/// 触发规则。
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum Schedule {
    /// 五段 cron，按 `tz`（IANA 名称，比如 Asia/Shanghai）的本地时间。
    Cron {
        expr: String,
        tz: String,
    },
    /// iCalendar 的 DTSTART;TZID=...+RRULE。
    Rrule {
        rule: String,
    },
    Once {
        at_ms: i64,
    },
}

impl From<d::ScheduleSpec> for Schedule {
    fn from(s: d::ScheduleSpec) -> Self {
        match s {
            d::ScheduleSpec::Cron { expr, tz } => Self::Cron { expr, tz },
            d::ScheduleSpec::Rrule { rule } => Self::Rrule { rule },
            d::ScheduleSpec::Once { at } => Self::Once { at_ms: ms(at) },
        }
    }
}

impl TryFrom<Schedule> for d::ScheduleSpec {
    type Error = ClientError;
    fn try_from(s: Schedule) -> Result<Self> {
        Ok(match s {
            Schedule::Cron { expr, tz } => Self::Cron { expr, tz },
            Schedule::Rrule { rule } => Self::Rrule { rule },
            Schedule::Once { at_ms } => Self::Once {
                at: Utc.timestamp_millis_opt(at_ms).single().ok_or_else(|| {
                    ClientError::InvalidArgument {
                        message: format!("bad time {at_ms}"),
                    }
                })?,
            },
        })
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Trigger {
    pub id: String,
    pub schedule: Schedule,
    pub enabled: bool,
    pub next_fire_at_ms: Option<i64>,
    pub last_fire_at_ms: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PlanStep {
    pub key: String,
    pub instance_id: String,
    pub prompt: String,
    pub depends_on: Vec<String>,
}

impl From<d::PlanStep> for PlanStep {
    fn from(s: d::PlanStep) -> Self {
        Self {
            key: s.key,
            instance_id: s.instance_id.to_string(),
            prompt: s.prompt,
            depends_on: s.depends_on,
        }
    }
}

impl TryFrom<PlanStep> for d::PlanStep {
    type Error = ClientError;
    fn try_from(s: PlanStep) -> Result<Self> {
        Ok(Self {
            key: s.key,
            instance_id: parse(&s.instance_id, "instance")?,
            prompt: s.prompt,
            depends_on: s.depends_on,
        })
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Plan {
    pub id: String,
    pub instance_id: String,
    pub title: String,
    pub goal: String,
    pub paused: bool,
    /// user / agent（agent 建的计划要用户恢复才生效）
    pub created_by: String,
    /// 策略（预授权工具、审批超时、预算），JSON。
    pub policy_json: String,
    pub created_at_ms: i64,
    /// 列表接口里为空，详情里有。
    pub triggers: Vec<Trigger>,
    pub steps: Vec<PlanStep>,
}

impl From<d::Plan> for Plan {
    fn from(p: d::Plan) -> Self {
        Self {
            id: p.id.to_string(),
            instance_id: p.instance_id.to_string(),
            title: p.title,
            goal: p.goal,
            paused: p.paused,
            created_by: p.created_by.to_string(),
            policy_json: serde_json::to_string(&p.policy).unwrap_or_default(),
            created_at_ms: ms(p.created_at),
            triggers: Vec::new(),
            steps: Vec::new(),
        }
    }
}

impl From<api::PlanView> for Plan {
    fn from(v: api::PlanView) -> Self {
        Self {
            triggers: v
                .triggers
                .into_iter()
                .map(|t| Trigger {
                    id: t.id.to_string(),
                    schedule: t.spec.into(),
                    enabled: t.enabled,
                    next_fire_at_ms: ms_opt(t.next_fire_at),
                    last_fire_at_ms: ms_opt(t.last_fire_at),
                })
                .collect(),
            steps: v.steps.into_iter().map(Into::into).collect(),
            ..v.plan.into()
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NewPlan {
    pub instance_id: String,
    pub title: String,
    pub goal: String,
    pub triggers: Vec<Schedule>,
    /// 给了就是流水线：按依赖顺序在各个实例上执行。
    pub steps: Vec<PlanStep>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct InboxItem {
    pub id: String,
    pub instance_id: Option<String>,
    pub run_id: Option<String>,
    pub plan_id: Option<String>,
    pub approval_id: Option<String>,
    /// run_finished / run_failed / approval / info
    pub kind: String,
    pub title: String,
    pub body: String,
    pub read: bool,
    pub created_at_ms: i64,
}

impl From<d::InboxItem> for InboxItem {
    fn from(i: d::InboxItem) -> Self {
        Self {
            id: i.id.to_string(),
            instance_id: i.instance_id.map(|x| x.to_string()),
            run_id: i.run_id.map(|x| x.to_string()),
            plan_id: i.plan_id.map(|x| x.to_string()),
            approval_id: i.approval_id.map(|x| x.to_string()),
            kind: i.kind,
            title: i.title,
            body: i.body,
            read: i.read,
            created_at_ms: ms(i.created_at),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct InboxPage {
    pub items: Vec<InboxItem>,
    pub unread: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct InstanceEvent {
    pub instance_id: String,
    pub seq: u64,
    pub run_id: Option<String>,
    /// agent.message、agent.tool_call、run.state……
    pub kind: String,
    pub payload_json: String,
    pub created_at_ms: i64,
}

impl From<&d::InstanceEvent> for InstanceEvent {
    fn from(e: &d::InstanceEvent) -> Self {
        Self {
            instance_id: e.instance_id.to_string(),
            seq: e.seq,
            run_id: e.run_id.map(|r| r.to_string()),
            kind: e.kind.clone(),
            payload_json: e.payload.to_string(),
            created_at_ms: ms(e.created_at),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Credential {
    pub id: String,
    pub vendor: String,
    pub label: String,
    pub last4: String,
    pub daily_token_limit: Option<u64>,
    pub disabled: bool,
    pub created_at_ms: i64,
}

impl From<d::Credential> for Credential {
    fn from(c: d::Credential) -> Self {
        Self {
            id: c.id.to_string(),
            vendor: c.vendor,
            label: c.label,
            last4: c.last4,
            daily_token_limit: c.daily_token_limit,
            disabled: c.disabled,
            created_at_ms: ms(c.created_at),
        }
    }
}

#[derive(Clone, uniffi::Record)]
pub struct NewCredential {
    pub vendor: String,
    pub label: String,
    pub api_key: String,
    pub anthropic_base: Option<String>,
    pub openai_base: Option<String>,
    pub responses_base: Option<String>,
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

#[derive(Debug, Clone, uniffi::Record)]
pub struct Artifact {
    pub id: String,
    pub instance_id: String,
    pub run_id: String,
    pub name: String,
    pub version: u32,
    pub content_type: String,
    pub size: u64,
    pub sha256: String,
    pub created_at_ms: i64,
}

impl From<d::Artifact> for Artifact {
    fn from(a: d::Artifact) -> Self {
        Self {
            id: a.id.to_string(),
            instance_id: a.instance_id.to_string(),
            run_id: a.run_id.to_string(),
            name: a.name,
            version: a.version,
            content_type: a.content_type,
            size: a.size,
            sha256: a.sha256,
            created_at_ms: ms(a.created_at),
        }
    }
}

// ---------- 事件流 ----------

/// 原生端实现：收事件、状态变化。回调在 client-core 的后台线程上，界面更新要切回主线程。
#[uniffi::export(foreign)]
pub trait EventListener: Send + Sync {
    fn on_event(&self, event: InstanceEvent);
    /// 续传位置已经过了保留期：本地的旧事件作废，整体重新加载后接着收。
    fn on_reset(&self, oldest_seq: u64, latest_seq: Option<u64>);
    fn on_status(&self, status: StreamStatus);
}

struct Bridge(Arc<dyn EventListener>);

impl EventSink for Bridge {
    fn on_event(&self, event: &d::InstanceEvent) {
        self.0.on_event(event.into());
    }
    fn on_reset(&self, oldest_seq: u64, latest_seq: Option<u64>) {
        self.0.on_reset(oldest_seq, latest_seq);
    }
    fn on_status(&self, status: StreamStatus) {
        self.0.on_status(status);
    }
}

/// 一个实例的事件订阅。`stop()` 或释放对象就停止。
#[derive(uniffi::Object)]
pub struct EventSubscription {
    handle: Mutex<Option<StreamHandle>>,
}

#[uniffi::export]
impl EventSubscription {
    pub fn stop(&self) {
        if let Some(h) = self.handle.lock().unwrap_or_else(|e| e.into_inner()).take() {
            h.stop();
        }
    }
}

// ---------- 客户端 ----------

/// 自带的 tokio 运行时；释放时不等后台任务（不能在异步上下文里阻塞）。
struct Runtime(Option<tokio::runtime::Runtime>);

impl Drop for Runtime {
    fn drop(&mut self) {
        if let Some(rt) = self.0.take() {
            rt.shutdown_background();
        }
    }
}

#[derive(uniffi::Object)]
pub struct ThinktinClient {
    rt: Runtime,
    inner: Arc<Client>,
}

impl ThinktinClient {
    fn handle(&self) -> &tokio::runtime::Handle {
        self.rt
            .0
            .as_ref()
            .expect("runtime lives as long as the client")
            .handle()
    }

    /// 在自己的运行时上跑，等结果。
    async fn run<T, F, Fut>(&self, f: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce(Arc<Client>) -> Fut,
        Fut: Future<Output = Result<T>> + Send + 'static,
    {
        let fut = f(self.inner.clone());
        self.handle()
            .spawn(fut)
            .await
            .map_err(|e| ClientError::Internal {
                message: e.to_string(),
            })?
    }
}

#[uniffi::export]
impl ThinktinClient {
    /// 会话从 `sessions` 里恢复（已经登录过就不用再登录）。
    #[uniffi::constructor]
    pub fn new(config: ClientConfig, sessions: Arc<dyn SessionStore>) -> Result<Arc<Self>> {
        let platform: d::DevicePlatform = from_enum_str(&config.platform, "platform")?;
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("thinktin-core")
            .enable_all()
            .build()
            .map_err(|e| ClientError::Internal {
                message: e.to_string(),
            })?;
        let api = Api::new(
            ApiConfig {
                base_url: config.base_url,
                platform,
                device_name: config.device_name,
                timeout: Duration::from_secs(u64::from(config.timeout_secs.max(5))),
            },
            sessions,
        )?;
        let cache = config.cache_path.map(Cache::open).transpose()?;
        Ok(Arc::new(Self {
            rt: Runtime(Some(rt)),
            inner: Arc::new(Client::new(api, cache)?),
        }))
    }

    /// 已经登录（有会话）。
    pub fn signed_in(&self) -> bool {
        self.inner.api.session().is_some()
    }

    // ---------- 账号 ----------

    pub async fn send_code(&self, phone: String) -> Result<()> {
        self.run(|c| async move { c.api.send_code(&phone).await })
            .await
    }

    /// `push_channel` 是 apns / unipush / fcm……，和 `push_token` 一起给，或都不给。
    pub async fn login(
        &self,
        phone: String,
        code: String,
        push_channel: Option<String>,
        push_token: Option<String>,
    ) -> Result<LoginResult> {
        let push = match (push_channel, push_token) {
            (Some(ch), Some(tok)) => Some((from_enum_str(&ch, "push channel")?, tok)),
            (None, None) => None,
            _ => {
                return Err(ClientError::InvalidArgument {
                    message: "push_channel and push_token go together".into(),
                });
            }
        };
        self.run(|c| async move {
            let r = c.login(&phone, &code, push).await?;
            Ok(LoginResult {
                user: r.user.into(),
                new_user: r.new_user,
            })
        })
        .await
    }

    pub async fn logout(&self) -> Result<()> {
        self.run(|c| async move { c.logout().await }).await
    }

    pub async fn me(&self) -> Result<User> {
        self.run(|c| async move { Ok(c.me().await?.into()) }).await
    }

    /// 推送令牌变了（重装、系统重置）时更新。
    pub async fn set_push_token(&self, channel: String, token: String) -> Result<()> {
        let channel: d::PushChannelKind = from_enum_str(&channel, "push channel")?;
        self.run(|c| async move { c.api.set_push(channel, &token).await })
            .await
    }

    // ---------- agent 与实例 ----------

    pub async fn agents(&self) -> Result<Vec<AgentInfo>> {
        self.run(|c| async move { Ok(c.api.agents().await?.into_iter().map(Into::into).collect()) })
            .await
    }

    /// 拉实例列表（同时更新缓存）。
    pub async fn instances(&self) -> Result<Vec<Instance>> {
        self.run(|c| async move { Ok(c.instances().await?.into_iter().map(Into::into).collect()) })
            .await
    }

    /// 缓存里的实例列表（离线、启动时先显示）。
    pub fn cached_instances(&self) -> Result<Vec<Instance>> {
        Ok(self
            .inner
            .cached_instances()?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn adopt(
        &self,
        agent_id: String,
        name: String,
        harness: Option<String>,
    ) -> Result<Instance> {
        self.run(|c| async move {
            Ok(c.api
                .adopt(&agent_id, &name, harness.as_deref())
                .await?
                .into())
        })
        .await
    }

    pub async fn rename_instance(&self, instance_id: String, name: String) -> Result<Instance> {
        let id: d::InstanceId = parse(&instance_id, "instance")?;
        self.run(|c| async move { Ok(c.api.rename_instance(id, &name).await?.into()) })
            .await
    }

    pub async fn model_routes(&self, instance_id: String) -> Result<Vec<ModelRoute>> {
        let id: d::InstanceId = parse(&instance_id, "instance")?;
        self.run(|c| async move {
            Ok(c.api
                .model_routes(id)
                .await?
                .into_iter()
                .map(|r| ModelRoute {
                    alias: r.alias,
                    credential_id: r.credential_id.to_string(),
                    upstream_model: r.upstream_model,
                })
                .collect())
        })
        .await
    }

    /// 整体替换实例的模型别名（叫 main 的是默认模型）。
    pub async fn set_model_routes(
        &self,
        instance_id: String,
        routes: Vec<ModelRoute>,
    ) -> Result<()> {
        let id: d::InstanceId = parse(&instance_id, "instance")?;
        let routes = routes
            .into_iter()
            .map(|r| {
                Ok(d::ModelRoute {
                    alias: r.alias,
                    credential_id: parse(&r.credential_id, "credential")?,
                    upstream_model: r.upstream_model,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        self.run(|c| async move { c.api.set_model_routes(id, &routes).await })
            .await
    }

    pub async fn delete_instance(&self, instance_id: String) -> Result<()> {
        let id: d::InstanceId = parse(&instance_id, "instance")?;
        self.run(|c| async move { c.api.delete_instance(id).await })
            .await
    }

    // ---------- 运行 ----------

    pub async fn create_run(&self, instance_id: String, prompt: String) -> Result<Run> {
        let id: d::InstanceId = parse(&instance_id, "instance")?;
        self.run(|c| async move { Ok(c.api.create_run(id, &prompt).await?.into()) })
            .await
    }

    pub async fn runs(&self, instance_id: String, limit: u32) -> Result<Vec<Run>> {
        let id: d::InstanceId = parse(&instance_id, "instance")?;
        self.run(|c| async move {
            Ok(c.runs(id, limit)
                .await?
                .into_iter()
                .map(Into::into)
                .collect())
        })
        .await
    }

    pub fn cached_runs(&self, instance_id: String, limit: u32) -> Result<Vec<Run>> {
        let id: d::InstanceId = parse(&instance_id, "instance")?;
        Ok(self
            .inner
            .cached_runs(id, limit)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub async fn get_run(&self, run_id: String) -> Result<Run> {
        let id: d::RunId = parse(&run_id, "run")?;
        self.run(|c| async move { Ok(c.api.run(id).await?.into()) })
            .await
    }

    /// 取消；`whole_tree` 时停掉整棵运行树（流水线）。
    pub async fn cancel_run(&self, run_id: String, whole_tree: bool) -> Result<Run> {
        let id: d::RunId = parse(&run_id, "run")?;
        self.run(|c| async move { Ok(c.api.cancel_run(id, whole_tree).await?.into()) })
            .await
    }

    pub async fn run_tree(&self, run_id: String) -> Result<Vec<Run>> {
        let id: d::RunId = parse(&run_id, "run")?;
        self.run(|c| async move {
            Ok(c.api
                .run_tree(id)
                .await?
                .into_iter()
                .map(Into::into)
                .collect())
        })
        .await
    }

    pub async fn run_artifacts(&self, run_id: String) -> Result<Vec<Artifact>> {
        let id: d::RunId = parse(&run_id, "run")?;
        self.run(|c| async move {
            Ok(c.api
                .run_artifacts(id)
                .await?
                .into_iter()
                .map(Into::into)
                .collect())
        })
        .await
    }

    pub async fn artifact_content(&self, artifact_id: String) -> Result<Vec<u8>> {
        let id: d::ArtifactId = parse(&artifact_id, "artifact")?;
        self.run(|c| async move { c.api.artifact_content(id).await })
            .await
    }

    // ---------- 事件流 ----------

    /// 开始收实例的事件：先补发缓存续传位置之后的，再实时推送。
    pub fn subscribe(
        &self,
        instance_id: String,
        listener: Arc<dyn EventListener>,
    ) -> Result<Arc<EventSubscription>> {
        let id: d::InstanceId = parse(&instance_id, "instance")?;
        let handle = self.inner.subscribe(
            self.handle(),
            id,
            Arc::new(Bridge(listener)),
            StreamConfig::default(),
        );
        Ok(Arc::new(EventSubscription {
            handle: Mutex::new(Some(handle)),
        }))
    }

    /// 缓存里 `after_seq` 之后的事件（打开页面时先显示）。
    pub fn cached_events(
        &self,
        instance_id: String,
        after_seq: u64,
        limit: u32,
    ) -> Result<Vec<InstanceEvent>> {
        let id: d::InstanceId = parse(&instance_id, "instance")?;
        Ok(self
            .inner
            .cached_events(id, after_seq, limit)?
            .iter()
            .map(Into::into)
            .collect())
    }

    // ---------- 审批 ----------

    pub async fn approvals(&self) -> Result<Vec<Approval>> {
        self.run(|c| async move {
            Ok(c.api
                .approvals()
                .await?
                .into_iter()
                .map(Into::into)
                .collect())
        })
        .await
    }

    /// 选一个选项。注意：批准前原生端要先做生物识别确认。
    pub async fn decide_approval(
        &self,
        approval_id: String,
        option_id: String,
    ) -> Result<Approval> {
        let id: d::ApprovalId = parse(&approval_id, "approval")?;
        self.run(|c| async move { Ok(c.api.decide_approval(id, &option_id).await?.into()) })
            .await
    }

    // ---------- 计划 ----------

    pub async fn plans(&self, instance_id: Option<String>) -> Result<Vec<Plan>> {
        let id: Option<d::InstanceId> = parse_opt(&instance_id, "instance")?;
        self.run(
            |c| async move { Ok(c.api.plans(id).await?.into_iter().map(Into::into).collect()) },
        )
        .await
    }

    pub async fn get_plan(&self, plan_id: String) -> Result<Plan> {
        let id: d::PlanId = parse(&plan_id, "plan")?;
        self.run(|c| async move { Ok(c.api.plan(id).await?.into()) })
            .await
    }

    pub async fn create_plan(&self, plan: NewPlan) -> Result<Plan> {
        let new = api::NewPlan {
            instance_id: parse(&plan.instance_id, "instance")?,
            title: plan.title,
            goal: plan.goal,
            triggers: plan
                .triggers
                .into_iter()
                .map(TryInto::try_into)
                .collect::<Result<_>>()?,
            steps: plan
                .steps
                .into_iter()
                .map(TryInto::try_into)
                .collect::<Result<_>>()?,
        };
        self.run(|c| async move { Ok(c.api.create_plan(&new).await?.into()) })
            .await
    }

    /// 暂停或恢复。agent 建的计划要用户在这里恢复才会按时运行。
    pub async fn set_plan_paused(&self, plan_id: String, paused: bool) -> Result<Plan> {
        let id: d::PlanId = parse(&plan_id, "plan")?;
        self.run(|c| async move { Ok(c.api.set_plan_paused(id, paused).await?.into()) })
            .await
    }

    pub async fn delete_plan(&self, plan_id: String) -> Result<()> {
        let id: d::PlanId = parse(&plan_id, "plan")?;
        self.run(|c| async move { c.api.delete_plan(id).await })
            .await
    }

    // ---------- 收件箱 ----------

    /// 同步收件箱：补发离线已读，拉最新一页，合并进缓存。
    pub async fn sync_inbox(&self, limit: u32) -> Result<InboxPage> {
        self.run(|c| async move {
            let p = c.sync_inbox(limit).await?;
            Ok(InboxPage {
                items: p.items.into_iter().map(Into::into).collect(),
                unread: p.unread,
            })
        })
        .await
    }

    pub async fn older_inbox(&self, before_id: String, limit: u32) -> Result<Vec<InboxItem>> {
        let before: d::InboxItemId = parse(&before_id, "inbox item")?;
        self.run(|c| async move {
            Ok(c.older_inbox(before, limit)
                .await?
                .into_iter()
                .map(Into::into)
                .collect())
        })
        .await
    }

    pub fn cached_inbox(&self, before_id: Option<String>, limit: u32) -> Result<Vec<InboxItem>> {
        let before: Option<d::InboxItemId> = parse_opt(&before_id, "inbox item")?;
        Ok(self
            .inner
            .cached_inbox(before, limit)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn cached_unread(&self) -> Result<i64> {
        self.inner.cached_unread()
    }

    /// 标已读（没网也立即生效，联网后补发）。`ids` 为空表示全部已读，到 `up_to_id` 为止。返回未读数。
    pub async fn mark_inbox_read(&self, ids: Vec<String>, up_to_id: Option<String>) -> Result<i64> {
        let ids: Vec<d::InboxItemId> = ids
            .iter()
            .map(|i| parse(i, "inbox item"))
            .collect::<Result<_>>()?;
        let up_to: Option<d::InboxItemId> = parse_opt(&up_to_id, "inbox item")?;
        self.run(|c| async move { c.mark_inbox_read(&ids, up_to).await })
            .await
    }

    // ---------- 模型 key ----------

    pub async fn credentials(&self) -> Result<Vec<Credential>> {
        self.run(|c| async move {
            Ok(c.api
                .credentials()
                .await?
                .into_iter()
                .map(Into::into)
                .collect())
        })
        .await
    }

    pub async fn add_credential(&self, credential: NewCredential) -> Result<Credential> {
        let new = api::NewCredential {
            vendor: credential.vendor,
            label: credential.label,
            api_key: credential.api_key,
            anthropic_base: credential.anthropic_base,
            openai_base: credential.openai_base,
            responses_base: credential.responses_base,
            daily_token_limit: credential.daily_token_limit,
        };
        self.run(|c| async move { Ok(c.api.add_credential(&new).await?.into()) })
            .await
    }

    pub async fn delete_credential(&self, credential_id: String) -> Result<()> {
        let id: d::CredentialId = parse(&credential_id, "credential")?;
        self.run(|c| async move { c.api.delete_credential(id).await })
            .await
    }
}
