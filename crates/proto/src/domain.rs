//! 领域类型（WBS 3.1）：服务端、客户端核心共用。字符串取值和数据库里的一致。

use std::fmt;
use std::str::FromStr;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

macro_rules! id_type {
    ($($(#[$doc:meta])* $name:ident),* $(,)?) => {$(
        $(#[$doc])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(pub Uuid);

        impl $name {
            /// 新的 UUIDv7（按时间有序，索引友好）。
            pub fn new() -> Self {
                Self(Uuid::now_v7())
            }
        }

        impl Default for $name {
            fn default() -> Self {
                Self::new()
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(f)
            }
        }

        impl FromStr for $name {
            type Err = uuid::Error;
            fn from_str(s: &str) -> Result<Self, Self::Err> {
                Uuid::parse_str(s).map(Self)
            }
        }

        impl From<Uuid> for $name {
            fn from(u: Uuid) -> Self {
                Self(u)
            }
        }
    )*};
}

id_type!(
    UserId,
    DeviceId,
    SessionId,
    CredentialId,
    InstanceId,
    GrantId,
    PlanId,
    TriggerId,
    RunId,
    ApprovalId,
    InboxItemId,
    TeamId,
    TeamTemplateId,
    ArtifactId,
);

/// 字符串枚举的公共实现：和数据库里的取值一一对应。
macro_rules! str_enum {
    ($(#[$doc:meta])* $name:ident { $($(#[$vdoc:meta])* $variant:ident = $s:literal),* $(,)? }) => {
        $(#[$doc])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
        pub enum $name {
            $($(#[$vdoc])* #[serde(rename = $s)] $variant),*
        }

        impl $name {
            pub const ALL: &'static [$name] = &[$($name::$variant),*];

            pub fn as_str(self) -> &'static str {
                match self { $($name::$variant => $s),* }
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(self.as_str())
            }
        }

        impl FromStr for $name {
            type Err = UnknownValue;
            fn from_str(s: &str) -> Result<Self, Self::Err> {
                match s {
                    $($s => Ok($name::$variant),)*
                    other => Err(UnknownValue { kind: stringify!($name), value: other.to_owned() }),
                }
            }
        }
    };
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("unknown {kind} value {value:?}")]
pub struct UnknownValue {
    pub kind: &'static str,
    pub value: String,
}

str_enum!(
    /// 账号状态。冻结会暂停所有运行授权（4.6）。
    UserStatus { Active = "active", Frozen = "frozen", Deleted = "deleted" }
);

str_enum!(
    DevicePlatform { Ios = "ios", Android = "android", Macos = "macos" }
);

str_enum!(
    /// 推送通道（8.3）。
    PushChannelKind {
        Apns = "apns", Fcm = "fcm", Hms = "hms", Honor = "honor", Mi = "mi", Oppo = "oppo", Vivo = "vivo",
        /// 统一推送服务（个推、极光之类）。
        Unipush = "unipush",
    }
);

str_enum!(
    /// 实例（沙箱）的状态（4.10）。
    InstanceState {
        Provisioning = "provisioning",
        Running = "running",
        /// 内存快照，唤醒快。
        Paused = "paused",
        /// 只留工作区卷，唤醒要从模板重建。
        Archived = "archived",
        Deleted = "deleted",
    }
);

str_enum!(
    /// 运行由什么发起。
    RunSource { User = "user", Plan = "plan", Pipeline = "pipeline", Delegate = "delegate" }
);

str_enum!(
    /// 运行的状态机（4.3）。
    RunState {
        Queued = "queued",
        /// 拿到执行租约，正在唤醒沙箱、等 agent 就绪。
        Starting = "starting",
        Running = "running",
        WaitingApproval = "waiting_approval",
        WaitingDevice = "waiting_device",
        WaitingQuota = "waiting_quota",
        /// 父运行等子运行（4.11）。
        WaitingChildren = "waiting_children",
        /// 崩溃或超时后的重试等待。
        Backoff = "backoff",
        Succeeded = "succeeded",
        Failed = "failed",
        Cancelled = "cancelled",
    }
);

impl RunState {
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Succeeded | Self::Failed | Self::Cancelled)
    }

    pub fn is_waiting(self) -> bool {
        matches!(
            self,
            Self::WaitingApproval
                | Self::WaitingDevice
                | Self::WaitingQuota
                | Self::WaitingChildren
        )
    }

    /// 占着实例：同一实例同时只能有一个这样的运行（等待、退避中的运行，agent 的会话停在这一轮中间）。
    pub fn holds_instance(self) -> bool {
        !self.is_terminal() && self != Self::Queued
    }

    /// 状态迁移是否合法。任何未结束的运行都能被取消。
    pub fn can_transition(self, to: RunState) -> bool {
        use RunState::*;
        if self.is_terminal() {
            return false;
        }
        if to == Cancelled {
            return true;
        }
        match self {
            // 流水线运行不执行 agent：排队后直接等子运行。
            Queued => matches!(to, Starting | WaitingChildren),
            Starting => matches!(to, Running | Backoff | Failed),
            Running => matches!(
                to,
                WaitingApproval
                    | WaitingDevice
                    | WaitingQuota
                    | WaitingChildren
                    | Backoff
                    | Succeeded
                    | Failed
            ),
            // 等的事情发生：沙箱还醒着就直接回到运行中，已暂停就先唤醒（启动中）。超时按策略失败。
            WaitingApproval | WaitingDevice | WaitingQuota => {
                matches!(to, Running | Starting | Failed)
            }
            // 子运行都结束：委派的父运行回到运行中，流水线运行直接结束。
            WaitingChildren => matches!(to, Running | Starting | Succeeded | Failed),
            Backoff => matches!(to, Starting | Failed),
            Succeeded | Failed | Cancelled => false,
        }
    }
}

str_enum!(
    /// 运行的种类：agent 在实例的沙箱里执行一轮；pipeline 是流水线的根，只协调子运行（8.3）。
    RunKind { Agent = "agent", Pipeline = "pipeline" }
);

str_enum!(
    TeamRole {
        /// 负责人：委派时由它分工（8.7）。
        Lead = "lead",
        Member = "member",
    }
);

str_enum!(
    /// 错过的触发怎么补（4.4）。
    CatchUp { Once = "once", All = "all", Skip = "skip" }
);

#[allow(clippy::derivable_impls)] // 枚举由宏生成，没法在变体上标 #[default]
impl Default for CatchUp {
    fn default() -> Self {
        Self::Once
    }
}

/// 定时触发方式（7.1）。事件触发（新消息、webhook）另行定义。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ScheduleSpec {
    /// 五段 cron（分钟粒度），按 `tz`（IANA 名称）的本地时间解释。
    Cron { expr: String, tz: String },
    /// iCalendar 的 DTSTART + RRULE，DTSTART 必须带 TZID。
    Rrule { rule: String },
    /// 一次性定时。
    Once { at: DateTime<Utc> },
}

str_enum!(
    /// 审批超时后怎么办（4.7）。
    ApprovalTimeoutAction {
        /// 拒绝这一步，让 agent 继续。
        Skip = "skip",
        /// 暂停整个计划。
        PausePlan = "pause_plan",
        /// 这次运行失败。
        Fail = "fail",
    }
);

str_enum!(
    ApprovalState {
        Pending = "pending",
        Approved = "approved",
        Rejected = "rejected",
        Expired = "expired",
        Cancelled = "cancelled",
    }
);

/// 运行的预算护栏（4.7、7.7）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct RunBudget {
    pub max_tokens: Option<u64>,
    pub max_duration_secs: u64,
    pub max_steps: Option<u32>,
}

impl Default for RunBudget {
    fn default() -> Self {
        Self {
            max_tokens: None,
            max_duration_secs: 6 * 3600,
            max_steps: None,
        }
    }
}

/// 计划的执行策略。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlanPolicy {
    /// 预授权的工具种类（ACP 的 tool kind，比如 read、edit、search）。
    pub preauthorized_tools: Vec<String>,
    pub approval_timeout_secs: u64,
    pub on_approval_timeout: ApprovalTimeoutAction,
    pub budget: RunBudget,
    /// 每天最多消耗的 token 数（整个计划）。
    pub daily_token_limit: Option<u64>,
}

impl Default for PlanPolicy {
    fn default() -> Self {
        Self {
            preauthorized_tools: Vec::new(),
            approval_timeout_secs: 24 * 3600,
            on_approval_timeout: ApprovalTimeoutAction::PausePlan,
            budget: RunBudget::default(),
            daily_token_limit: None,
        }
    }
}

/// 运行授权的范围（4.6）。子运行只能收窄，不能放大（8.6）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct GrantScope {
    /// 可用的模型别名；为空表示实例配置的全部别名。
    pub aliases: Vec<String>,
    /// 可用的平台工具；为空表示不给平台工具。
    pub platform_tools: Vec<String>,
    /// token 上限。
    pub max_tokens: Option<u64>,
}

impl GrantScope {
    /// `child` 是否没有超出 `self`。
    pub fn contains(&self, child: &GrantScope) -> bool {
        let aliases_ok = self.aliases.is_empty()
            || (!child.aliases.is_empty()
                && child.aliases.iter().all(|a| self.aliases.contains(a)));
        let tools_ok = child
            .platform_tools
            .iter()
            .all(|t| self.platform_tools.contains(t));
        let tokens_ok = match (self.max_tokens, child.max_tokens) {
            (None, _) => true,
            (Some(_), None) => false,
            (Some(p), Some(c)) => c <= p,
        };
        aliases_ok && tools_ok && tokens_ok
    }
}

/// 实例的模型网关限额（WBS 9.5），和 llm-gw 的 `Limits` 同构。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct InstanceLimits {
    pub requests_per_minute: u32,
    pub max_concurrent: u32,
}

impl Default for InstanceLimits {
    fn default() -> Self {
        Self {
            requests_per_minute: 120,
            max_concurrent: 8,
        }
    }
}

str_enum!(
    /// 计划由谁建的：agent 通过平台工具建的计划要用户确认后才生效（7.8）。
    PlanAuthor { User = "user", Agent = "agent" }
);

// ---------- 对外展示的对象（接入网关返回、客户端核心缓存） ----------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct User {
    pub id: UserId,
    /// E.164。
    pub phone: String,
    pub display_name: Option<String>,
    pub status: UserStatus,
    pub created_at: DateTime<Utc>,
}

/// 登录过的一台设备。退出登录、远程下线后 `revoked_at` 有值。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Device {
    pub id: DeviceId,
    pub platform: DevicePlatform,
    pub name: String,
    pub push_channel: Option<PushChannelKind>,
    pub created_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
    pub revoked_at: Option<DateTime<Utc>>,
}

/// 运行授权（4.6）：实例代表用户干活的权限，和登录会话无关。只在平台内部使用，不下发到客户端或沙箱。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunGrant {
    pub id: GrantId,
    pub instance_id: InstanceId,
    pub plan_id: Option<PlanId>,
    /// 从哪个授权收窄出来的（子运行）。
    pub parent_id: Option<GrantId>,
    pub scope: GrantScope,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub last_used_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
    pub revoke_reason: Option<String>,
}

impl RunGrant {
    pub fn is_active(&self, now: DateTime<Utc>) -> bool {
        self.revoked_at.is_none() && self.expires_at > now
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Instance {
    pub id: InstanceId,
    pub agent_id: String,
    pub agent_version: String,
    pub harness: String,
    pub name: String,
    pub state: InstanceState,
    pub created_at: DateTime<Utc>,
    pub last_active_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelRoute {
    pub alias: String,
    pub credential_id: CredentialId,
    pub upstream_model: String,
}

/// 用户保存的 key：永远只返回后 4 位。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Credential {
    pub id: CredentialId,
    pub vendor: String,
    pub label: String,
    pub last4: String,
    pub daily_token_limit: Option<u64>,
    pub disabled: bool,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Plan {
    pub id: PlanId,
    pub instance_id: InstanceId,
    pub title: String,
    pub goal: String,
    pub policy: PlanPolicy,
    pub catch_up: CatchUp,
    pub paused: bool,
    pub created_by: PlanAuthor,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Trigger {
    pub id: TriggerId,
    pub plan_id: PlanId,
    pub spec: ScheduleSpec,
    pub enabled: bool,
    pub next_fire_at: Option<DateTime<Utc>>,
    pub last_fire_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Run {
    pub id: RunId,
    pub kind: RunKind,
    pub instance_id: InstanceId,
    pub plan_id: Option<PlanId>,
    pub parent_run_id: Option<RunId>,
    pub root_run_id: RunId,
    /// 流水线子运行对应的步骤。
    pub step_key: Option<String>,
    pub source: RunSource,
    pub prompt: String,
    pub state: RunState,
    pub state_reason: Option<String>,
    pub attempt: u32,
    pub tokens_used: u64,
    pub summary: Option<String>,
    pub error: Option<String>,
    pub created_at: DateTime<Utc>,
    pub started_at: Option<DateTime<Utc>>,
    pub finished_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Approval {
    pub id: ApprovalId,
    pub run_id: RunId,
    pub instance_id: InstanceId,
    pub title: Option<String>,
    pub options: Value,
    pub tool_call: Value,
    pub state: ApprovalState,
    pub expires_at: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
}

/// 团队（8.1）：同一用户的几个实例。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Team {
    pub id: TeamId,
    pub name: String,
    pub members: Vec<TeamMember>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamMember {
    pub instance_id: InstanceId,
    pub role: TeamRole,
    pub position: u32,
}

/// 团队模板：一键领养一整个团队。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TeamTemplate {
    pub id: TeamTemplateId,
    pub name: String,
    pub spec: TeamTemplateSpec,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TeamTemplateSpec {
    pub members: Vec<TemplateMember>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TemplateMember {
    pub agent_id: String,
    #[serde(default)]
    pub harness: Option<String>,
    pub name: String,
    #[serde(default = "member_role")]
    pub role: TeamRole,
}

fn member_role() -> TeamRole {
    TeamRole::Member
}

/// 流水线的一步（8.3）：交给哪个实例、做什么、依赖哪些步骤的产出。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanStep {
    pub key: String,
    pub instance_id: InstanceId,
    pub prompt: String,
    #[serde(default)]
    pub depends_on: Vec<String>,
}

/// 校验流水线步骤：键唯一、依赖都存在、没有环。返回按依赖排好的顺序（拓扑序）。
pub fn order_steps(steps: &[PlanStep]) -> Result<Vec<&PlanStep>, String> {
    use std::collections::{HashMap, HashSet};
    let mut by_key: HashMap<&str, &PlanStep> = HashMap::new();
    for s in steps {
        if by_key.insert(s.key.as_str(), s).is_some() {
            return Err(format!("duplicate step {:?}", s.key));
        }
    }
    for s in steps {
        for d in &s.depends_on {
            if !by_key.contains_key(d.as_str()) {
                return Err(format!("step {:?} depends on unknown step {d:?}", s.key));
            }
            if d == &s.key {
                return Err(format!("step {:?} depends on itself", s.key));
            }
        }
    }
    // Kahn 算法；同一层按声明顺序，结果稳定。
    let mut done: HashSet<&str> = HashSet::new();
    let mut order = Vec::with_capacity(steps.len());
    while order.len() < steps.len() {
        let ready: Vec<&PlanStep> = steps
            .iter()
            .filter(|s| !done.contains(s.key.as_str()))
            .filter(|s| s.depends_on.iter().all(|d| done.contains(d.as_str())))
            .collect();
        if ready.is_empty() {
            return Err("steps have a dependency cycle".into());
        }
        for s in ready {
            done.insert(s.key.as_str());
            order.push(s);
        }
    }
    Ok(order)
}

/// 产出物（8.4）：运行发布的文件，内容加密存在对象存储里。名字在一棵运行树里唯一，同名再发布是新版本。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Artifact {
    pub id: ArtifactId,
    pub instance_id: InstanceId,
    pub run_id: RunId,
    pub root_run_id: RunId,
    pub name: String,
    pub version: u32,
    pub content_type: String,
    pub size: u64,
    /// 内容的 SHA-256（十六进制）。
    pub sha256: String,
    pub created_at: DateTime<Utc>,
}

/// 实例事件流里的一条（4.8）：按 `seq` 单调递增，客户端带上最后收到的序号续传。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InstanceEvent {
    pub instance_id: InstanceId,
    pub seq: u64,
    pub run_id: Option<RunId>,
    pub kind: String,
    pub payload: Value,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InboxItem {
    pub id: InboxItemId,
    pub instance_id: Option<InstanceId>,
    pub run_id: Option<RunId>,
    pub plan_id: Option<PlanId>,
    pub approval_id: Option<ApprovalId>,
    pub kind: String,
    pub title: String,
    pub body: String,
    pub read: bool,
    pub created_at: DateTime<Utc>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_time_ordered_and_roundtrip() {
        let a = RunId::new();
        let b = RunId::new();
        assert!(a < b);
        assert_eq!(a.to_string().parse::<RunId>().unwrap(), a);
        assert_eq!(serde_json::to_string(&a).unwrap(), format!("\"{a}\""));
    }

    #[test]
    fn enums_match_database_strings() {
        for s in RunState::ALL {
            assert_eq!(s.as_str().parse::<RunState>().unwrap(), *s);
            assert_eq!(
                serde_json::to_value(s).unwrap(),
                Value::String(s.as_str().into())
            );
        }
        assert!("bogus".parse::<RunState>().is_err());
        assert_eq!(
            serde_json::to_string(&ApprovalTimeoutAction::PausePlan).unwrap(),
            "\"pause_plan\""
        );
    }

    #[test]
    fn run_state_machine() {
        use RunState::*;
        // 架构方案 4.3 的主路径。
        for (a, b) in [
            (Queued, Starting),
            (Starting, Running),
            (Running, WaitingApproval),
            (WaitingApproval, Running),
            (Running, WaitingDevice),
            (WaitingDevice, Starting),
            (Running, WaitingQuota),
            (Running, WaitingChildren),
            (Running, Backoff),
            (Backoff, Starting),
            (Backoff, Failed),
            (Running, Succeeded),
            (WaitingApproval, Failed),
            (Queued, WaitingChildren),
            (WaitingChildren, Succeeded),
        ] {
            assert!(a.can_transition(b), "{a} -> {b}");
        }
        for (a, b) in [
            (Queued, Running),
            (Queued, Succeeded),
            (Succeeded, Running),
            (Failed, Queued),
            (Cancelled, Cancelled),
            (Backoff, Running),
            (Starting, Succeeded),
        ] {
            assert!(!a.can_transition(b), "{a} -> {b} must be rejected");
        }
        for s in RunState::ALL.iter().filter(|s| !s.is_terminal()) {
            assert!(s.can_transition(Cancelled), "{s} can be cancelled");
        }
        assert!(Backoff.holds_instance() && WaitingApproval.holds_instance());
        assert!(!Queued.holds_instance() && !Succeeded.holds_instance());
    }

    #[test]
    fn grant_scopes_only_narrow() {
        let parent = GrantScope {
            aliases: vec!["main".into(), "fast".into()],
            platform_tools: vec!["schedule_list".into()],
            max_tokens: Some(1000),
        };
        let narrower = GrantScope {
            aliases: vec!["fast".into()],
            platform_tools: vec![],
            max_tokens: Some(500),
        };
        assert!(parent.contains(&narrower));
        let wider = GrantScope {
            max_tokens: None,
            ..narrower.clone()
        };
        assert!(
            !parent.contains(&wider),
            "dropping the token cap widens the scope"
        );
        let all_aliases = GrantScope {
            aliases: vec![],
            ..narrower.clone()
        };
        assert!(
            !parent.contains(&all_aliases),
            "an empty alias list means all aliases"
        );
        let extra_tool = GrantScope {
            platform_tools: vec!["delegate".into()],
            ..narrower
        };
        assert!(!parent.contains(&extra_tool));
        assert!(GrantScope::default().contains(&GrantScope::default()));
    }

    #[test]
    fn step_ordering() {
        let step = |k: &str, deps: &[&str]| PlanStep {
            key: k.into(),
            instance_id: InstanceId::new(),
            prompt: "p".into(),
            depends_on: deps.iter().map(|d| d.to_string()).collect(),
        };
        let steps = vec![
            step("report", &["research", "data"]),
            step("research", &[]),
            step("data", &[]),
            step("push", &["report"]),
        ];
        let order: Vec<_> = order_steps(&steps)
            .unwrap()
            .into_iter()
            .map(|s| s.key.as_str())
            .collect();
        assert_eq!(order, ["research", "data", "report", "push"]);
        assert!(order_steps(&[step("a", &["b"]), step("b", &["a"])]).is_err());
        assert!(order_steps(&[step("a", &["zzz"])]).is_err());
        assert!(order_steps(&[step("a", &[]), step("a", &[])]).is_err());
        assert!(order_steps(&[step("a", &["a"])]).is_err());
    }

    #[test]
    fn schedule_spec_json() {
        let s: ScheduleSpec =
            serde_json::from_str(r#"{"kind":"cron","expr":"0 8 * * *","tz":"Asia/Shanghai"}"#)
                .unwrap();
        assert_eq!(
            s,
            ScheduleSpec::Cron {
                expr: "0 8 * * *".into(),
                tz: "Asia/Shanghai".into()
            }
        );
        let p: PlanPolicy = serde_json::from_str("{}").unwrap();
        assert_eq!(p.approval_timeout_secs, 86_400);
        assert_eq!(p.on_approval_timeout, ApprovalTimeoutAction::PausePlan);
    }
}
