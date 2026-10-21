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
use crate::secrets;

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
    /// 推送、收件箱用的语言（1.6）：`zh-CN` 或 `en`。
    pub locale: String,
    pub created_at_ms: i64,
}

impl From<d::User> for User {
    fn from(u: d::User) -> Self {
        Self {
            id: u.id.to_string(),
            phone: u.phone,
            display_name: u.display_name,
            status: u.status.to_string(),
            locale: u.locale.to_string(),
            created_at_ms: ms(u.created_at),
        }
    }
}

/// 登录着的一台设备（设置里的“登录设备”）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct DeviceInfo {
    pub id: String,
    /// ios、android、macos……
    pub platform: String,
    pub name: String,
    pub push_channel: Option<String>,
    /// 是不是正在用的这台。
    pub current: bool,
    /// 电脑连着设备中继（14.1）；手机总是 false。
    pub online: bool,
    pub created_at_ms: i64,
    pub last_seen_at_ms: i64,
}

impl From<api::DeviceView> for DeviceInfo {
    fn from(v: api::DeviceView) -> Self {
        let d = v.device;
        Self {
            id: d.id.to_string(),
            platform: d.platform.as_str().into(),
            name: d.name,
            push_channel: d.push_channel.map(|c| c.as_str().into()),
            current: v.current,
            online: v.online,
            created_at_ms: ms(d.created_at),
            last_seen_at_ms: ms(d.last_seen_at),
        }
    }
}

/// 手机和电脑之间的一条消息（14.1）：配对应答、审批请求和决定、能力令牌、吊销。内容和签名的格式见 docs/pairing.md。
#[derive(Debug, Clone, uniffi::Record)]
pub struct DeviceMessage {
    pub id: String,
    pub from_device_id: String,
    pub to_device_id: String,
    /// pair_response、pair_confirm、approval_request、approval_decision、capability、revoke……
    pub kind: String,
    /// 消息内容（JSON）。
    pub body_json: String,
    pub created_at_ms: i64,
    pub expires_at_ms: i64,
}

impl From<d::DeviceMessage> for DeviceMessage {
    fn from(m: d::DeviceMessage) -> Self {
        Self {
            id: m.id.to_string(),
            from_device_id: m.from_device.to_string(),
            to_device_id: m.to_device.to_string(),
            kind: m.kind.as_str().into(),
            body_json: m.body.to_string(),
            created_at_ms: ms(m.created_at),
            expires_at_ms: ms(m.expires_at),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct LoginResult {
    pub user: User,
    pub new_user: bool,
}

/// 全部停止的结果（4.6）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct StopAllResult {
    pub runs_cancelled: u64,
    pub grants_revoked: u64,
    pub plans_paused: u64,
}

impl From<api::Stopped> for StopAllResult {
    fn from(s: api::Stopped) -> Self {
        Self {
            runs_cancelled: s.runs_cancelled,
            grants_revoked: s.grants_revoked,
            plans_paused: s.plans_paused,
        }
    }
}

/// 下线其他设备的结果（4.6）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct SignOutOthersResult {
    pub devices_signed_out: u64,
    /// 顺带全部停止时有。
    pub stopped: Option<StopAllResult>,
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
    /// 可以用的版本，当前版本在前：实例的版本不是第一个时可以提示升级。
    pub versions: Vec<String>,
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
            versions: a.versions,
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
    /// 降级链：主 key 失效、欠费、被限流或连不上时按顺序换用，最多 3 个。
    pub fallbacks: Vec<RouteFallback>,
}

/// 降级链里的一项：备用的 key 和它那边的上游模型。
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RouteFallback {
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

/// 计划的策略（4.4、4.7、7.11）。
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PlanPolicy {
    /// 预授权的工具种类（ACP 的 tool kind：read、edit、search、execute……），用到时不用审批。
    pub preauthorized_tools: Vec<String>,
    pub approval_timeout_secs: u64,
    /// 审批（和等电脑、等 key）超时以后：skip（拒绝这一步，接着干）、pause_plan（暂停计划）、fail（这次失败）。
    pub on_approval_timeout: String,
    /// 每次运行的上限：token 数、时长、步数。
    pub max_tokens: Option<u64>,
    pub max_duration_secs: u64,
    pub max_steps: Option<u32>,
    /// 整个计划每天最多用多少 token。
    pub daily_token_limit: Option<u64>,
    /// 等电脑上线、等补上 key 最多等多久。
    pub wait_timeout_secs: u64,
}

impl From<d::PlanPolicy> for PlanPolicy {
    fn from(p: d::PlanPolicy) -> Self {
        Self {
            preauthorized_tools: p.preauthorized_tools,
            approval_timeout_secs: p.approval_timeout_secs,
            on_approval_timeout: p.on_approval_timeout.as_str().into(),
            max_tokens: p.budget.max_tokens,
            max_duration_secs: p.budget.max_duration_secs,
            max_steps: p.budget.max_steps,
            daily_token_limit: p.daily_token_limit,
            wait_timeout_secs: p.wait_timeout_secs,
        }
    }
}

impl TryFrom<PlanPolicy> for d::PlanPolicy {
    type Error = ClientError;
    fn try_from(p: PlanPolicy) -> Result<Self> {
        Ok(Self {
            preauthorized_tools: p.preauthorized_tools,
            approval_timeout_secs: p.approval_timeout_secs,
            on_approval_timeout: from_enum_str(&p.on_approval_timeout, "approval timeout action")?,
            budget: d::RunBudget {
                max_tokens: p.max_tokens,
                max_duration_secs: p.max_duration_secs,
                max_steps: p.max_steps,
            },
            daily_token_limit: p.daily_token_limit,
            wait_timeout_secs: p.wait_timeout_secs,
        })
    }
}

/// 改计划：给了才改。`steps` 整体替换，给空的就变回单个 agent 的计划。
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct PlanChange {
    #[uniffi(default = None)]
    pub title: Option<String>,
    #[uniffi(default = None)]
    pub goal: Option<String>,
    #[uniffi(default = None)]
    pub policy: Option<PlanPolicy>,
    /// once（错过的只补一次）、all（全补）、skip（不补）。
    #[uniffi(default = None)]
    pub catch_up: Option<String>,
    #[uniffi(default = None)]
    pub steps: Option<Vec<PlanStep>>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Plan {
    pub id: String,
    pub instance_id: String,
    pub title: String,
    pub goal: String,
    pub paused: bool,
    /// user / agent
    pub created_by: String,
    /// agent 新建或修改过、等用户确认（用 `confirm_plan`，带上 `revision`）。
    pub awaiting_confirmation: bool,
    /// 计划的版本，确认时原样带回：确认之前又被改过，确认会失败（要重新看一遍）。
    pub revision: u32,
    /// 策略（预授权工具、审批超时、预算），JSON。和 `policy` 一样，留着给老版本的 App 用。
    pub policy_json: String,
    pub policy: PlanPolicy,
    /// 错过的触发怎么补：once、all、skip。
    pub catch_up: String,
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
            awaiting_confirmation: p.awaiting_confirmation,
            revision: p.revision,
            policy_json: serde_json::to_string(&p.policy).unwrap_or_default(),
            policy: p.policy.into(),
            catch_up: p.catch_up.as_str().into(),
            created_at_ms: ms(p.created_at),
            triggers: Vec::new(),
            steps: Vec::new(),
        }
    }
}

impl From<api::PlanView> for Plan {
    fn from(v: api::PlanView) -> Self {
        Self {
            triggers: v.triggers.into_iter().map(trigger_record).collect(),
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
    /// 不给就用默认的策略。
    #[uniffi(default = None)]
    pub policy: Option<PlanPolicy>,
    /// once（默认）、all、skip。
    #[uniffi(default = None)]
    pub catch_up: Option<String>,
}

fn trigger_record(t: d::Trigger) -> Trigger {
    Trigger {
        id: t.id.to_string(),
        schedule: t.spec.into(),
        enabled: t.enabled,
        next_fire_at_ms: ms_opt(t.next_fire_at),
        last_fire_at_ms: ms_opt(t.last_fire_at),
    }
}

/// 团队里的一个实例（8.1）。
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TeamMember {
    pub instance_id: String,
    /// lead（负责人，一个团队一个）或 member。
    pub role: String,
    /// 显示顺序。
    pub position: u32,
}

impl From<d::TeamMember> for TeamMember {
    fn from(m: d::TeamMember) -> Self {
        Self {
            instance_id: m.instance_id.to_string(),
            role: m.role.as_str().into(),
            position: m.position,
        }
    }
}

impl TryFrom<TeamMember> for d::TeamMember {
    type Error = ClientError;
    fn try_from(m: TeamMember) -> Result<Self> {
        Ok(Self {
            instance_id: parse(&m.instance_id, "instance")?,
            role: from_enum_str(&m.role, "team role")?,
            position: m.position,
        })
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Team {
    pub id: String,
    pub name: String,
    pub members: Vec<TeamMember>,
    pub created_at_ms: i64,
}

impl From<d::Team> for Team {
    fn from(t: d::Team) -> Self {
        Self {
            id: t.id.to_string(),
            name: t.name,
            members: t.members.into_iter().map(Into::into).collect(),
            created_at_ms: ms(t.created_at),
        }
    }
}

/// 团队模板里的一个成员：领养时用这个 agent 新领养一个实例。
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TemplateMember {
    pub agent_id: String,
    /// 接入方式（同一个 agent 的几种，比如 claude 的 acp、cli）；不给用默认的。
    pub harness: Option<String>,
    pub name: String,
    /// lead 或 member。
    pub role: String,
}

impl From<d::TemplateMember> for TemplateMember {
    fn from(m: d::TemplateMember) -> Self {
        Self {
            agent_id: m.agent_id,
            harness: m.harness,
            name: m.name,
            role: m.role.as_str().into(),
        }
    }
}

impl TryFrom<TemplateMember> for d::TemplateMember {
    type Error = ClientError;
    fn try_from(m: TemplateMember) -> Result<Self> {
        Ok(Self {
            agent_id: m.agent_id,
            harness: m.harness,
            name: m.name,
            role: from_enum_str(&m.role, "team role")?,
        })
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TeamTemplate {
    pub id: String,
    pub name: String,
    pub members: Vec<TemplateMember>,
    pub created_at_ms: i64,
}

impl From<d::TeamTemplate> for TeamTemplate {
    fn from(t: d::TeamTemplate) -> Self {
        Self {
            id: t.id.to_string(),
            name: t.name,
            members: t.spec.members.into_iter().map(Into::into).collect(),
            created_at_ms: ms(t.created_at),
        }
    }
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
    /// 正文是 agent 生成的：显示时要带“AI 生成”标识（16.3）。
    pub ai_generated: bool,
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
            ai_generated: i.ai_generated,
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
    /// 内容是 agent 生成的（消息、思考、计划）：显示时要带“AI 生成”标识（16.3）。
    pub ai_generated: bool,
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
            ai_generated: proto::labels::is_ai_generated_event(&e.kind),
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

/// 预置的模型厂商（9.12）。不在列表里的接口用 vendor = "custom" 加自定义地址。
#[derive(Debug, Clone, uniffi::Record)]
pub struct VendorInfo {
    pub id: String,
    pub name: String,
    /// `anthropic`、`chat`、`responses` 中的若干个：Claude 走 anthropic，Codex 只会 responses，其余走 chat。
    pub protocols: Vec<String>,
    /// 推荐的上游模型，以厂商控制台为准。
    pub models: Vec<String>,
    pub notes: String,
}

impl From<api::VendorInfo> for VendorInfo {
    fn from(v: api::VendorInfo) -> Self {
        Self {
            id: v.id,
            name: v.name,
            protocols: v.protocols,
            models: v.models,
            notes: v.notes,
        }
    }
}

/// IM 群机器人（10.5）。token 和签名密钥服务端从不返回，`hint` 是 token 后 4 位。
#[derive(Debug, Clone, uniffi::Record)]
pub struct ImChannel {
    pub id: String,
    /// feishu、lark、wecom、dingtalk。
    pub vendor: String,
    pub label: String,
    pub hint: String,
    pub has_secret: bool,
    /// run_finished、run_failed、approval 中的若干个。
    pub events: Vec<String>,
    pub enabled: bool,
    pub last_sent_at_ms: Option<i64>,
    pub last_error: Option<String>,
    pub created_at_ms: i64,
}

impl From<d::ImChannel> for ImChannel {
    fn from(c: d::ImChannel) -> Self {
        Self {
            id: c.id.to_string(),
            vendor: c.vendor.as_str().into(),
            label: c.label,
            hint: c.hint,
            has_secret: c.has_secret,
            events: c.events.iter().map(|e| e.as_str().to_owned()).collect(),
            enabled: c.enabled,
            last_sent_at_ms: c.last_sent_at.map(ms),
            last_error: c.last_error,
            created_at_ms: ms(c.created_at),
        }
    }
}

#[derive(Clone, uniffi::Record)]
pub struct NewImChannel {
    pub webhook_url: String,
    pub secret: Option<String>,
    pub label: String,
    /// 不给就是全部事件。
    pub events: Option<Vec<String>>,
}

impl std::fmt::Debug for NewImChannel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NewImChannel")
            .field("label", &self.label)
            .finish_non_exhaustive()
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

/// 用量的一组汇总：`key` 按分组是日期、实例 id、`厂商/模型` 或 key 的 id。
#[derive(Debug, Clone, uniffi::Record)]
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

impl From<api::UsageBucket> for UsageBucket {
    fn from(b: api::UsageBucket) -> Self {
        Self {
            key: b.key,
            requests: b.requests,
            input_tokens: b.input_tokens,
            cache_read_tokens: b.cache_read_tokens,
            cache_write_tokens: b.cache_write_tokens,
            output_tokens: b.output_tokens,
            charged_tokens: b.charged_tokens,
            estimated_requests: b.estimated_requests,
            failed_requests: b.failed_requests,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct UsageSummary {
    pub buckets: Vec<UsageBucket>,
    pub total: UsageBucket,
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

// ---------- 密码保险箱（9.11）和输入里的密码拦截（11.6） ----------

/// 保险箱条目。没有密码；账号只在 `vault_item` 的详情里有。
#[derive(Debug, Clone, uniffi::Record)]
pub struct VaultItem {
    pub id: String,
    /// 引用名（`github`），消息里写成 `[vault:github]`。
    pub name: String,
    pub purpose: String,
    pub has_username: bool,
    /// 能用它的实例；空表示全部。
    pub instance_ids: Vec<String>,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    pub last_used_at_ms: Option<i64>,
}

impl From<d::VaultItem> for VaultItem {
    fn from(v: d::VaultItem) -> Self {
        Self {
            id: v.id.to_string(),
            name: v.name,
            purpose: v.purpose,
            has_username: v.has_username,
            instance_ids: v.instance_ids.iter().map(ToString::to_string).collect(),
            created_at_ms: ms(v.created_at),
            updated_at_ms: ms(v.updated_at),
            last_used_at_ms: ms_opt(v.last_used_at),
        }
    }
}

/// 条目详情：多一个账号。
#[derive(Debug, Clone, uniffi::Record)]
pub struct VaultItemDetail {
    pub item: VaultItem,
    pub username: String,
}

#[derive(Clone, uniffi::Record)]
pub struct NewVaultItem {
    pub name: String,
    pub purpose: String,
    pub username: String,
    pub password: String,
    /// 空表示所有实例都能用。
    pub instance_ids: Vec<String>,
}

impl std::fmt::Debug for NewVaultItem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NewVaultItem")
            .field("name", &self.name)
            .field("purpose", &self.purpose)
            .finish_non_exhaustive()
    }
}

impl NewVaultItem {
    fn into_api(self) -> Result<api::NewVaultItem> {
        Ok(api::NewVaultItem {
            name: self.name,
            purpose: self.purpose,
            username: self.username,
            password: self.password,
            instance_ids: self
                .instance_ids
                .iter()
                .map(|i| parse(i, "instance"))
                .collect::<Result<_>>()?,
        })
    }
}

/// 修改条目：只改给了的字段。
#[derive(Clone, uniffi::Record)]
pub struct VaultItemUpdate {
    pub purpose: Option<String>,
    pub username: Option<String>,
    pub password: Option<String>,
    pub instance_ids: Option<Vec<String>>,
}

impl std::fmt::Debug for VaultItemUpdate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VaultItemUpdate")
            .field("purpose", &self.purpose)
            .field("password_changed", &self.password.is_some())
            .finish_non_exhaustive()
    }
}

/// agent 请用户填的表单（App 收到 `vault.requested` 事件、推送后展示）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct VaultRequest {
    pub id: String,
    pub instance_id: String,
    pub run_id: Option<String>,
    pub name: String,
    /// agent 写的用途，显示时带“AI 生成”标识。
    pub purpose: String,
    /// 要填的字段：`username`、`password`。
    pub fields: Vec<String>,
    /// pending / fulfilled / declined / expired
    pub status: String,
    pub item_id: Option<String>,
    pub created_at_ms: i64,
    pub expires_at_ms: i64,
    pub resolved_at_ms: Option<i64>,
}

impl From<d::VaultRequest> for VaultRequest {
    fn from(r: d::VaultRequest) -> Self {
        Self {
            id: r.id.to_string(),
            instance_id: r.instance_id.to_string(),
            run_id: r.run_id.map(|i| i.to_string()),
            name: r.name,
            purpose: r.purpose,
            fields: r.fields,
            status: r.status.to_string(),
            item_id: r.item_id.map(|i| i.to_string()),
            created_at_ms: ms(r.created_at),
            expires_at_ms: ms(r.expires_at),
            resolved_at_ms: ms_opt(r.resolved_at),
        }
    }
}

/// 消息里一处像密码、key 的内容（11.6）。位置是 UTF-16 下标（Swift 的 NSRange、Kotlin 的 String 下标）。
#[derive(Clone, uniffi::Record)]
pub struct DetectedSecret {
    /// private_key / url_password / api_key / token / labeled / high_entropy
    pub kind: String,
    pub start: u32,
    pub end: u32,
    /// 原文里的那段，预填进表单的密码栏。
    pub value: String,
    /// 建议的条目名，预填进表单（已经符合命名规则）。
    pub suggested_name: String,
    /// 认出来的厂商或服务（anthropic、github……）；模型厂商的 key 可以提示“添加为模型 key”。
    pub service: String,
    /// 能存进保险箱。私钥这种多行的不能，只提示别发。
    pub storable: bool,
}

impl std::fmt::Debug for DetectedSecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DetectedSecret")
            .field("kind", &self.kind)
            .field("start", &self.start)
            .field("end", &self.end)
            .field("suggested_name", &self.suggested_name)
            .finish_non_exhaustive()
    }
}

/// 把消息里的值换成引用时用：`value` 换成 `[vault:name]`。
#[derive(Clone, uniffi::Record)]
pub struct SecretReference {
    pub value: String,
    pub name: String,
}

impl std::fmt::Debug for SecretReference {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SecretReference")
            .field("name", &self.name)
            .finish_non_exhaustive()
    }
}

/// 从消息里存进保险箱的结果：条目和换成引用后的消息（直接放回输入框）。
#[derive(Debug, Clone, uniffi::Record)]
pub struct SavedSecret {
    pub item: VaultItem,
    pub message: String,
}

fn utf16_at(text: &str, byte: usize) -> u32 {
    u32::try_from(text[..byte].encode_utf16().count()).unwrap_or(u32::MAX)
}

/// 发送前检查消息（11.6），不联网。有命中时 App 拦下，提示“对话里不收明文密码”，
/// 弹表单（值和建议名已预填）存进保险箱，再把消息里的值换成引用。
#[uniffi::export]
pub fn detect_secrets(text: String) -> Vec<DetectedSecret> {
    secrets::detect(&text)
        .into_iter()
        .map(|f| DetectedSecret {
            kind: f.kind.as_str().into(),
            start: utf16_at(&text, f.start),
            end: utf16_at(&text, f.end),
            value: f.value,
            suggested_name: f.suggested_name,
            service: f.service,
            storable: f.storable,
        })
        .collect()
}

/// 把消息里的值都换成 `[vault:名字]`（所有出现的地方）。
#[uniffi::export]
pub fn redact_message(text: String, references: Vec<SecretReference>) -> String {
    let pairs: Vec<(String, String)> = references.into_iter().map(|r| (r.value, r.name)).collect();
    secrets::redact(&text, &pairs)
}

/// 建议名已经被占用时，换一个不重复的（`github` → `github_2`）。`taken` 是现有条目的名字。
#[uniffi::export]
pub fn unique_vault_name(base: String, taken: Vec<String>) -> String {
    secrets::unique_name(&secrets::sanitize_name(&base, "secret"), &taken)
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

    /// 推送、收件箱用的语言（1.6）。传 App 界面当前的语言（`zh-CN`、`en`，系统的语言标签也行），
    /// 用户在 App 里换语言时调一次。
    pub async fn set_locale(&self, locale: String) -> Result<User> {
        self.run(|c| async move { Ok(c.api.set_locale(&locale).await?.into()) })
            .await
    }

    /// 改昵称；传 `None` 清掉。
    pub async fn update_profile(&self, display_name: Option<String>) -> Result<User> {
        self.run(|c| async move { Ok(c.api.update_profile(display_name.as_deref()).await?.into()) })
            .await
    }

    /// 登录着的设备，最近活跃的在前。
    pub async fn devices(&self) -> Result<Vec<DeviceInfo>> {
        self.run(
            |c| async move { Ok(c.api.devices().await?.into_iter().map(Into::into).collect()) },
        )
        .await
    }

    /// 吊销一台设备：它的登录会话立即失效（吊销当前这台等于退出登录）。
    pub async fn revoke_device(&self, device_id: String) -> Result<()> {
        let id: d::DeviceId = parse(&device_id, "device")?;
        self.run(|c| async move { c.api.revoke_device(id).await })
            .await
    }

    /// 发给自己的另一台设备（手机发给电脑：配对应答、审批决定、能力令牌、吊销）。`body_json` 是消息内容的 JSON。
    /// 电脑不在线时排队，连上设备中继后投递。
    pub async fn send_device_message(
        &self,
        to_device_id: String,
        kind: String,
        body_json: String,
    ) -> Result<DeviceMessage> {
        let to: d::DeviceId = parse(&to_device_id, "device")?;
        let kind: d::DeviceMessageKind = from_enum_str(&kind, "device message kind")?;
        let body: serde_json::Value =
            serde_json::from_str(&body_json).map_err(|e| ClientError::InvalidArgument {
                message: format!("body_json is not JSON: {e}"),
            })?;
        self.run(|c| async move { Ok(c.api.send_device_message(to, kind, &body).await?.into()) })
            .await
    }

    /// 别的设备发给这台、还没收下的消息（电脑发来的配对确认、审批请求），按发出的顺序。
    pub async fn device_messages(&self) -> Result<Vec<DeviceMessage>> {
        self.run(|c| async move {
            Ok(c.api
                .device_messages()
                .await?
                .into_iter()
                .map(Into::into)
                .collect())
        })
        .await
    }

    /// 收下了这些消息（验过签、处理完），之后不再返回。返回确认的条数。
    pub async fn ack_device_messages(&self, ids: Vec<String>) -> Result<u64> {
        let ids: Vec<d::DeviceMessageId> = ids
            .iter()
            .map(|i| parse(i, "device message"))
            .collect::<Result<_>>()?;
        self.run(|c| async move { c.api.ack_device_messages(&ids).await })
            .await
    }

    /// 给自己的手机号发验证码：`purpose` 是 `delete_account`（注销）或 `change_phone`。
    pub async fn send_self_code(&self, purpose: String) -> Result<()> {
        self.run(|c| async move { c.api.send_self_code(&purpose).await })
            .await
    }

    /// 注销账号（16.4）：用 `send_self_code("delete_account")` 发来的验证码确认。内容全部删除、不能恢复；
    /// 成功后本地的登录状态和缓存一起清掉。
    pub async fn delete_account(&self, code: String) -> Result<()> {
        self.run(|c| async move { c.delete_account(&code).await })
            .await
    }

    /// 推送令牌变了（重装、系统重置）时更新。
    pub async fn set_push_token(&self, channel: String, token: String) -> Result<()> {
        let channel: d::PushChannelKind = from_enum_str(&channel, "push channel")?;
        self.run(|c| async move { c.api.set_push(channel, &token).await })
            .await
    }

    /// 全部停止（4.6）：取消所有运行、吊销全部运行授权、暂停全部计划。
    /// 之后在实例上发起运行、恢复计划时自动重新授权。
    pub async fn stop_all(&self) -> Result<StopAllResult> {
        self.run(|c| async move { Ok(c.api.stop_all().await?.into()) })
            .await
    }

    /// 下线其他设备（4.6），只留当前这台。`stop_agents` 时顺带全部停止（怀疑账号被盗时）。
    pub async fn sign_out_other_devices(&self, stop_agents: bool) -> Result<SignOutOthersResult> {
        self.run(|c| async move {
            let r = c.api.sign_out_other_devices(stop_agents).await?;
            Ok(SignOutOthersResult {
                devices_signed_out: r.devices_signed_out,
                stopped: r.stopped.map(Into::into),
            })
        })
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

    pub async fn instance(&self, instance_id: String) -> Result<Instance> {
        let id: d::InstanceId = parse(&instance_id, "instance")?;
        self.run(|c| async move { Ok(c.api.instance(id).await?.into()) })
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

    /// 升级（不给版本）或回滚到旧版本：下次唤醒时生效，工作区保留。
    pub async fn set_instance_version(
        &self,
        instance_id: String,
        version: Option<String>,
    ) -> Result<Instance> {
        let id: d::InstanceId = parse(&instance_id, "instance")?;
        self.run(|c| async move {
            Ok(c.api
                .set_instance_version(id, version.as_deref())
                .await?
                .into())
        })
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
                    fallbacks: r
                        .fallbacks
                        .into_iter()
                        .map(|f| RouteFallback {
                            credential_id: f.credential_id.to_string(),
                            upstream_model: f.upstream_model,
                        })
                        .collect(),
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
                    fallbacks: r
                        .fallbacks
                        .into_iter()
                        .map(|f| {
                            Ok(d::RouteFallback {
                                credential_id: parse(&f.credential_id, "credential")?,
                                upstream_model: f.upstream_model,
                            })
                        })
                        .collect::<Result<Vec<_>>>()?,
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

    /// 更早的一页运行：`before_run_id` 之前的（列表往下翻）。
    pub async fn older_runs(
        &self,
        instance_id: String,
        before_run_id: String,
        limit: u32,
    ) -> Result<Vec<Run>> {
        let id: d::InstanceId = parse(&instance_id, "instance")?;
        let before: d::RunId = parse(&before_run_id, "run")?;
        self.run(|c| async move {
            Ok(c.older_runs(id, before, limit)
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

    /// 实例的产出物，新的在前（最多 `limit` 个，上限 500）。
    pub async fn instance_artifacts(
        &self,
        instance_id: String,
        limit: u32,
    ) -> Result<Vec<Artifact>> {
        let id: d::InstanceId = parse(&instance_id, "instance")?;
        self.run(|c| async move {
            Ok(c.api
                .instance_artifacts(id, limit)
                .await?
                .into_iter()
                .map(Into::into)
                .collect())
        })
        .await
    }

    pub async fn delete_artifact(&self, artifact_id: String) -> Result<()> {
        let id: d::ArtifactId = parse(&artifact_id, "artifact")?;
        self.run(|c| async move { c.api.delete_artifact(id).await })
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
            policy: plan.policy.map(TryInto::try_into).transpose()?,
            catch_up: plan
                .catch_up
                .map(|c| from_enum_str(&c, "catch up"))
                .transpose()?,
        };
        self.run(|c| async move { Ok(c.api.create_plan(&new).await?.into()) })
            .await
    }

    /// 改计划：标题、目标、策略、补跑方式、流水线步骤，给了才改。返回改完的计划（带触发器和步骤）。
    pub async fn update_plan(&self, plan_id: String, change: PlanChange) -> Result<Plan> {
        let id: d::PlanId = parse(&plan_id, "plan")?;
        let change = api::PlanChange {
            title: change.title,
            goal: change.goal,
            policy: change.policy.map(TryInto::try_into).transpose()?,
            catch_up: change
                .catch_up
                .map(|c| from_enum_str(&c, "catch up"))
                .transpose()?,
            steps: change
                .steps
                .map(|s| {
                    s.into_iter()
                        .map(TryInto::try_into)
                        .collect::<Result<Vec<_>>>()
                })
                .transpose()?,
        };
        self.run(|c| async move { Ok(c.api.update_plan(id, &change).await?.into()) })
            .await
    }

    /// 给计划加一个触发器（一个计划最多 10 个）。
    pub async fn add_trigger(&self, plan_id: String, schedule: Schedule) -> Result<Trigger> {
        let id: d::PlanId = parse(&plan_id, "plan")?;
        let spec: d::ScheduleSpec = schedule.try_into()?;
        self.run(|c| async move { Ok(trigger_record(c.api.add_trigger(id, &spec).await?)) })
            .await
    }

    pub async fn delete_trigger(&self, trigger_id: String) -> Result<()> {
        let id: d::TriggerId = parse(&trigger_id, "trigger")?;
        self.run(|c| async move { c.api.delete_trigger(id).await })
            .await
    }

    /// 暂停或恢复用户自己的计划。等确认的计划要用 `confirm_plan`。
    pub async fn set_plan_paused(&self, plan_id: String, paused: bool) -> Result<Plan> {
        let id: d::PlanId = parse(&plan_id, "plan")?;
        self.run(|c| async move { Ok(c.api.set_plan_paused(id, paused).await?.into()) })
            .await
    }

    /// 确认 agent 新建或修改的计划。`revision` 是界面上展示的那个版本：之后又被改过会返回冲突错误，
    /// 重新拉取计划给用户看了再确认。
    pub async fn confirm_plan(&self, plan_id: String, revision: u32) -> Result<Plan> {
        let id: d::PlanId = parse(&plan_id, "plan")?;
        self.run(|c| async move { Ok(c.api.confirm_plan(id, revision).await?.into()) })
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

    /// 一条通知（从推送点进来时用）。
    pub async fn inbox_item(&self, item_id: String) -> Result<InboxItem> {
        let id: d::InboxItemId = parse(&item_id, "inbox item")?;
        self.run(|c| async move { Ok(c.inbox_item(id).await?.into()) })
            .await
    }

    /// 标回未读（要联网）。返回未读数。
    pub async fn mark_inbox_unread(&self, item_id: String) -> Result<i64> {
        let id: d::InboxItemId = parse(&item_id, "inbox item")?;
        self.run(|c| async move { c.mark_inbox_unread(id).await })
            .await
    }

    pub async fn delete_inbox_item(&self, item_id: String) -> Result<()> {
        let id: d::InboxItemId = parse(&item_id, "inbox item")?;
        self.run(|c| async move { c.delete_inbox_item(id).await })
            .await
    }

    // ---------- 团队和团队模板（8.1） ----------

    pub async fn teams(&self) -> Result<Vec<Team>> {
        self.run(|c| async move { Ok(c.api.teams().await?.into_iter().map(Into::into).collect()) })
            .await
    }

    /// 把几个实例编成团队：一个负责人（role = lead），其余是成员。
    pub async fn create_team(&self, name: String, members: Vec<TeamMember>) -> Result<Team> {
        let members: Vec<d::TeamMember> = members
            .into_iter()
            .map(TryInto::try_into)
            .collect::<Result<_>>()?;
        self.run(|c| async move { Ok(c.api.create_team(&name, &members).await?.into()) })
            .await
    }

    pub async fn team(&self, team_id: String) -> Result<Team> {
        let id: d::TeamId = parse(&team_id, "team")?;
        self.run(|c| async move { Ok(c.api.team(id).await?.into()) })
            .await
    }

    /// 改名、换成员（整体替换）；给了才改。
    pub async fn update_team(
        &self,
        team_id: String,
        name: Option<String>,
        members: Option<Vec<TeamMember>>,
    ) -> Result<Team> {
        let id: d::TeamId = parse(&team_id, "team")?;
        let members: Option<Vec<d::TeamMember>> = members
            .map(|m| m.into_iter().map(TryInto::try_into).collect::<Result<_>>())
            .transpose()?;
        self.run(|c| async move {
            Ok(c.api
                .update_team(id, name.as_deref(), members.as_deref())
                .await?
                .into())
        })
        .await
    }

    /// 删团队（实例不删）。
    pub async fn delete_team(&self, team_id: String) -> Result<()> {
        let id: d::TeamId = parse(&team_id, "team")?;
        self.run(|c| async move { c.api.delete_team(id).await })
            .await
    }

    pub async fn team_templates(&self) -> Result<Vec<TeamTemplate>> {
        self.run(|c| async move {
            Ok(c.api
                .team_templates()
                .await?
                .into_iter()
                .map(Into::into)
                .collect())
        })
        .await
    }

    /// 新建团队模板，直接给成员。
    pub async fn create_team_template(
        &self,
        name: String,
        members: Vec<TemplateMember>,
    ) -> Result<TeamTemplate> {
        let spec = d::TeamTemplateSpec {
            members: members
                .into_iter()
                .map(TryInto::try_into)
                .collect::<Result<_>>()?,
        };
        self.run(|c| async move {
            Ok(c.api
                .create_team_template(&name, Some(&spec), None)
                .await?
                .into())
        })
        .await
    }

    /// 从现有团队生成模板（每个成员记下它的 agent、接入方式、名字、角色）。
    pub async fn create_team_template_from_team(
        &self,
        name: String,
        team_id: String,
    ) -> Result<TeamTemplate> {
        let id: d::TeamId = parse(&team_id, "team")?;
        self.run(|c| async move {
            Ok(c.api
                .create_team_template(&name, None, Some(id))
                .await?
                .into())
        })
        .await
    }

    pub async fn delete_team_template(&self, template_id: String) -> Result<()> {
        let id: d::TeamTemplateId = parse(&template_id, "template")?;
        self.run(|c| async move { c.api.delete_team_template(id).await })
            .await
    }

    /// 一键领养一整个团队：每个成员领养一个新实例，再编成团队。`name` 不给就用模板的名字。
    pub async fn adopt_team_template(
        &self,
        template_id: String,
        name: Option<String>,
    ) -> Result<Team> {
        let id: d::TeamTemplateId = parse(&template_id, "template")?;
        self.run(
            |c| async move { Ok(c.api.adopt_team_template(id, name.as_deref()).await?.into()) },
        )
        .await
    }

    // ---------- 用量 ----------

    /// 用量汇总。`group`：day / instance / model / credential；时间是 Unix 毫秒，不给就是最近 30 天；
    /// `tz` 是按天分组的时区（IANA 名称，默认 Asia/Shanghai）。
    pub async fn usage(
        &self,
        group: String,
        from_ms: Option<i64>,
        to_ms: Option<i64>,
        tz: Option<String>,
    ) -> Result<UsageSummary> {
        let rfc = |ms: Option<i64>| -> Result<Option<String>> {
            ms.map(|m| {
                Utc.timestamp_millis_opt(m)
                    .single()
                    .map(|t| t.to_rfc3339())
                    .ok_or_else(|| ClientError::InvalidArgument {
                        message: format!("bad time {m}"),
                    })
            })
            .transpose()
        };
        let (from, to) = (rfc(from_ms)?, rfc(to_ms)?);
        self.run(|c| async move {
            let s = c
                .api
                .usage(&group, from.as_deref(), to.as_deref(), tz.as_deref())
                .await?;
            Ok(UsageSummary {
                buckets: s.buckets.into_iter().map(Into::into).collect(),
                total: s.total.into(),
            })
        })
        .await
    }

    // ---------- 模型 key ----------

    /// 预置的模型厂商（添加 key 时选）。
    pub async fn vendors(&self) -> Result<Vec<VendorInfo>> {
        self.run(
            |c| async move { Ok(c.api.vendors().await?.into_iter().map(Into::into).collect()) },
        )
        .await
    }

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

    /// 改备注、停用或重新启用一把 key；给了才改。
    pub async fn update_credential(
        &self,
        credential_id: String,
        label: Option<String>,
        disabled: Option<bool>,
    ) -> Result<Credential> {
        let id: d::CredentialId = parse(&credential_id, "credential")?;
        self.run(|c| async move {
            Ok(c.api
                .update_credential(id, label.as_deref(), disabled)
                .await?
                .into())
        })
        .await
    }

    /// 换 key（同一个厂商、同一条记录：模型路由不用改）。等 key 的运行会接着跑。
    pub async fn replace_credential_secret(
        &self,
        credential_id: String,
        api_key: String,
    ) -> Result<Credential> {
        let id: d::CredentialId = parse(&credential_id, "credential")?;
        self.run(|c| async move { Ok(c.api.replace_credential_secret(id, &api_key).await?.into()) })
            .await
    }

    pub async fn delete_credential(&self, credential_id: String) -> Result<()> {
        let id: d::CredentialId = parse(&credential_id, "credential")?;
        self.run(|c| async move { c.api.delete_credential(id).await })
            .await
    }

    // ---------- IM 渠道（10.5） ----------

    pub async fn im_channels(&self) -> Result<Vec<ImChannel>> {
        self.run(|c| async move {
            Ok(c.api
                .im_channels()
                .await?
                .into_iter()
                .map(Into::into)
                .collect())
        })
        .await
    }

    pub async fn add_im_channel(&self, channel: NewImChannel) -> Result<ImChannel> {
        let new = api::NewImChannel {
            webhook_url: channel.webhook_url,
            secret: channel.secret,
            label: channel.label,
            events: channel.events,
        };
        self.run(|c| async move { Ok(c.api.add_im_channel(&new).await?.into()) })
            .await
    }

    pub async fn update_im_channel(
        &self,
        channel_id: String,
        label: Option<String>,
        events: Option<Vec<String>>,
        enabled: Option<bool>,
    ) -> Result<ImChannel> {
        let id: d::ImChannelId = parse(&channel_id, "im channel")?;
        self.run(|c| async move {
            Ok(c.api
                .update_im_channel(id, label.as_deref(), events.as_deref(), enabled)
                .await?
                .into())
        })
        .await
    }

    pub async fn replace_im_webhook(
        &self,
        channel_id: String,
        webhook_url: String,
        secret: Option<String>,
    ) -> Result<ImChannel> {
        let id: d::ImChannelId = parse(&channel_id, "im channel")?;
        self.run(|c| async move {
            Ok(c.api
                .replace_im_webhook(id, &webhook_url, secret.as_deref())
                .await?
                .into())
        })
        .await
    }

    pub async fn test_im_channel(&self, channel_id: String) -> Result<()> {
        let id: d::ImChannelId = parse(&channel_id, "im channel")?;
        self.run(|c| async move { c.api.test_im_channel(id).await })
            .await
    }

    pub async fn delete_im_channel(&self, channel_id: String) -> Result<()> {
        let id: d::ImChannelId = parse(&channel_id, "im channel")?;
        self.run(|c| async move { c.api.delete_im_channel(id).await })
            .await
    }

    // ---------- 密码保险箱（9.11）和输入里的密码拦截（11.6） ----------

    /// 发一条消息（起一次运行）。消息里有像密码、key 的内容时不发，返回 `ContainsSecrets`
    /// （先用 `detect_secrets` 检查就不会走到这里）；用户确认要发时带 `allow_secrets`。
    pub async fn send_message(
        &self,
        instance_id: String,
        text: String,
        allow_secrets: bool,
    ) -> Result<Run> {
        let id: d::InstanceId = parse(&instance_id, "instance")?;
        self.run(|c| async move { Ok(c.send_message(id, &text, allow_secrets).await?.into()) })
            .await
    }

    /// 把消息里拦下的值存进保险箱，返回条目和换成引用后的消息。`value` 是消息里原来的那段，
    /// `item.password` 是表单里确认过的值。重名时返回 conflict，消息不动（可用 `unique_vault_name` 换名）。
    pub async fn save_secret_from_message(
        &self,
        message: String,
        value: String,
        item: NewVaultItem,
    ) -> Result<SavedSecret> {
        let item = item.into_api()?;
        self.run(|c| async move {
            let (saved, message) = c.save_secret_from_message(&message, &value, &item).await?;
            Ok(SavedSecret {
                item: saved.into(),
                message,
            })
        })
        .await
    }

    pub async fn vault_items(&self) -> Result<Vec<VaultItem>> {
        self.run(|c| async move {
            Ok(c.api
                .vault_items()
                .await?
                .into_iter()
                .map(Into::into)
                .collect())
        })
        .await
    }

    pub async fn vault_item(&self, item_id: String) -> Result<VaultItemDetail> {
        let id: d::VaultItemId = parse(&item_id, "vault item")?;
        self.run(|c| async move {
            let v = c.api.vault_item(id).await?;
            Ok(VaultItemDetail {
                item: v.item.into(),
                username: v.username,
            })
        })
        .await
    }

    pub async fn create_vault_item(&self, item: NewVaultItem) -> Result<VaultItem> {
        let item = item.into_api()?;
        self.run(|c| async move { Ok(c.api.create_vault_item(&item).await?.into()) })
            .await
    }

    pub async fn update_vault_item(
        &self,
        item_id: String,
        change: VaultItemUpdate,
    ) -> Result<VaultItem> {
        let id: d::VaultItemId = parse(&item_id, "vault item")?;
        let change = api::VaultItemUpdate {
            purpose: change.purpose,
            username: change.username,
            password: change.password,
            instance_ids: change
                .instance_ids
                .map(|ids| {
                    ids.iter()
                        .map(|i| parse(i, "instance"))
                        .collect::<Result<Vec<_>>>()
                })
                .transpose()?,
        };
        self.run(|c| async move { Ok(c.api.update_vault_item(id, &change).await?.into()) })
            .await
    }

    pub async fn delete_vault_item(&self, item_id: String) -> Result<()> {
        let id: d::VaultItemId = parse(&item_id, "vault item")?;
        self.run(|c| async move { c.api.delete_vault_item(id).await })
            .await
    }

    /// agent 请用户填的表单。默认只要还在等的，`all` 时带上处理过的。
    pub async fn vault_requests(&self, all: bool) -> Result<Vec<VaultRequest>> {
        self.run(|c| async move {
            Ok(c.api
                .vault_requests(all)
                .await?
                .into_iter()
                .map(Into::into)
                .collect())
        })
        .await
    }

    /// 填好 agent 要的账号密码。`purpose` 不给就用 agent 写的。
    pub async fn fulfill_vault_request(
        &self,
        request_id: String,
        username: String,
        password: String,
        purpose: Option<String>,
    ) -> Result<VaultRequest> {
        let id: d::VaultRequestId = parse(&request_id, "vault request")?;
        self.run(|c| async move {
            Ok(c.api
                .fulfill_vault_request(id, &username, &password, purpose.as_deref())
                .await?
                .into())
        })
        .await
    }

    pub async fn decline_vault_request(&self, request_id: String) -> Result<VaultRequest> {
        let id: d::VaultRequestId = parse(&request_id, "vault request")?;
        self.run(|c| async move { Ok(c.api.decline_vault_request(id).await?.into()) })
            .await
    }
}
