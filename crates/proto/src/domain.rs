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
    VaultItemId,
    VaultRequestId,
    DeviceCallId,
    DeviceMessageId,
    ImChannelId,
    ReportId,
    BoardPostId,
    PlanHookId,
    EgressRequestId,
    ProjectId,
    ProjectInviteId,
);

// 团队就是只有创建者一个用户的项目（8.13，docs/projects.md 第 3 节）：id 一样。
impl From<TeamId> for ProjectId {
    fn from(t: TeamId) -> Self {
        Self(t.0)
    }
}

impl From<ProjectId> for TeamId {
    fn from(p: ProjectId) -> Self {
        Self(p.0)
    }
}

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
    /// 登录设备的平台。macOS 和 Windows 是电脑（连设备中继、给 agent 当“我的电脑”用，第 7 节），其余是手机。
    DevicePlatform { Ios = "ios", Android = "android", Macos = "macos", Windows = "windows" }
);

impl DevicePlatform {
    /// 是不是电脑：连设备中继，agent 的 `computer_*` 工具在它上面执行（14.1、14.2）。
    pub fn is_computer(self) -> bool {
        matches!(self, Self::Macos | Self::Windows)
    }
}

str_enum!(
    /// 推送通道（8.3）。
    PushChannelKind {
        Apns = "apns",
        /// 开发证书签名的包（Xcode 直装）拿到的是 APNs 沙盒环境的令牌，要发到沙盒环境（10.7）。
        ApnsSandbox = "apns_sandbox",
        Fcm = "fcm", Hms = "hms", Honor = "honor", Mi = "mi", Oppo = "oppo", Vivo = "vivo",
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
    /// 用户的语言（1.6）：服务端生成的推送、收件箱文案按它输出。App 界面的语言由客户端自己管。
    Locale { ZhCn = "zh-CN", En = "en" }
);

/// 默认中文：加语言偏好之前的用户、认不出系统语言的新用户都按中文。
impl Default for Locale {
    fn default() -> Self {
        Self::ZhCn
    }
}

impl Locale {
    /// 从系统的语言标签（`zh-Hans-CN`、`en_US`、`zh` 之类）认出支持的语言；认不出返回 None。
    pub fn from_tag(tag: &str) -> Option<Self> {
        let tag = tag.trim().to_ascii_lowercase();
        match tag.split(['-', '_']).next().unwrap_or_default() {
            "zh" => Some(Self::ZhCn),
            "en" => Some(Self::En),
            _ => None,
        }
    }

    /// HTTP `Accept-Language`（`en-US,en;q=0.9,zh-CN;q=0.8`）里最想要的、支持的语言：
    /// 按 q 值从高到低（相同的按出现顺序），q=0 的不要。
    pub fn from_accept_language(header: &str) -> Option<Self> {
        let mut tags: Vec<(f32, &str)> = header
            .split(',')
            .take(20)
            .filter_map(|part| {
                let mut fields = part.split(';');
                let tag = fields.next()?.trim();
                let q = fields
                    .find_map(|f| f.trim().strip_prefix("q="))
                    .map_or(Some(1.0), |q| q.trim().parse::<f32>().ok())?;
                Some((q, tag))
            })
            .collect();
        tags.sort_by(|a, b| b.0.total_cmp(&a.0));
        tags.into_iter()
            .filter(|(q, _)| *q > 0.0)
            .find_map(|(_, tag)| Self::from_tag(tag))
    }
}

str_enum!(
    /// 运行由什么发起。`Ask` 是别的 agent 问的问题（8.11），在被问的实例上跑。
    RunSource {
        User = "user",
        Plan = "plan",
        Pipeline = "pipeline",
        Delegate = "delegate",
        Ask = "ask",
    }
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
    /// 审批超时，以及等电脑、等 key 超时（7.11）之后怎么办。等 key 没法“跳过”，按失败处理。
    pub on_approval_timeout: ApprovalTimeoutAction,
    pub budget: RunBudget,
    /// 每天最多消耗的 token 数（整个计划）。
    pub daily_token_limit: Option<u64>,
    /// 等电脑上线、等补上 key 最多等多久（7.11）。
    pub wait_timeout_secs: u64,
    /// 运行成功时通知用户（推送、收件箱）。事件触发的计划（7.1）常常关掉：没事的时候别打扰；失败、等审批、
    /// 等 key 这些要用户处理的照样通知。老数据没有这一项，按打开算。
    pub notify_success: bool,
}

impl Default for PlanPolicy {
    fn default() -> Self {
        Self {
            preauthorized_tools: Vec::new(),
            approval_timeout_secs: 24 * 3600,
            on_approval_timeout: ApprovalTimeoutAction::PausePlan,
            budget: RunBudget::default(),
            daily_token_limit: None,
            wait_timeout_secs: 24 * 3600,
            notify_success: true,
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
    /// 推送、收件箱用的语言（1.6）。
    #[serde(default)]
    pub locale: Locale,
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
    /// 用途说明（8.9）：用户写的，别的 agent 用 `agents_list` 看得到。老的服务端没有，按空的算。
    #[serde(default)]
    pub purpose: String,
    /// “允许其他 agent 查我、问我”（8.9），默认打开。老的服务端没有，按打开算。
    #[serde(default = "default_true")]
    pub peer_access: bool,
    /// 能上哪些网站（2.7）。默认是 `dev`：搜索和开发网站直接能用，别的网站第一次访问时问用户。以后加了这个版本不认识的
    /// 档位，按只连模型显示（不让整个实例列表解析失败）。
    #[serde(default, deserialize_with = "lenient_egress_mode")]
    pub egress_mode: EgressMode,
    /// 用户选了“一直允许”的网站（[`crate::egress::normalize_host`] 整理过的写法）。
    #[serde(default)]
    pub egress_hosts: Vec<String>,
}

str_enum!(
    /// 项目的状态（8.13，docs/projects.md 第 4 节）。
    ProjectStatus {
        Active = "active",
        /// 归档：只读，不再派任务。
        Archived = "archived",
        /// 删除：马上读不到，后台清理（8.15）。
        Deleted = "deleted",
    }
);

str_enum!(
    /// 用户在项目里的身份（8.14）。
    ProjectRole {
        /// 建项目的人：邀请、移出别人，改项目名字和目标。
        Creator = "creator",
        Member = "member",
    }
);

str_enum!(
    /// 邀请是怎么发的（8.14）。
    ProjectInviteKind {
        /// 按手机号邀请：只在 App 里收到，不发短信。
        Phone = "phone",
        /// 邀请链接：谁拿到都能用，用一次就失效。
        Link = "link",
    }
);

str_enum!(
    /// 邀请的状态（8.14）。
    ProjectInviteStatus {
        Pending = "pending",
        Accepted = "accepted",
        Declined = "declined",
        /// 创建者撤回了。
        Revoked = "revoked",
        Expired = "expired",
    }
);

/// 一个项目最多这么多人（8.14，含创建者）。
pub const MAX_PROJECT_USERS: u64 = 10;
/// 一个项目里最多这么多个 agent（所有人的加在一起）。
pub const MAX_PROJECT_AGENTS: u64 = 30;
/// 一个项目同时最多这么多个待处理的邀请。
pub const MAX_PENDING_PROJECT_INVITES: u64 = 20;
/// 邀请链接 72 小时内有效，用一次就失效。
pub const PROJECT_INVITE_LINK_TTL_SECS: u64 = 72 * 3600;
/// 按手机号的邀请 7 天内有效。
pub const PROJECT_INVITE_PHONE_TTL_SECS: u64 = 7 * 24 * 3600;
/// 每个用户最多屏蔽这么多人。
pub const MAX_BLOCKS: u64 = 1000;
/// 项目目标最长这么多字。
pub const MAX_PROJECT_GOAL_CHARS: usize = 4000;
/// 项目预算（token 数）最大能设这么多。
pub const MAX_TOKEN_LIMIT: u64 = 1_000_000_000_000;
/// App 里邀请链接的前缀，后面是邀请令牌。
pub const PROJECT_INVITE_LINK_PREFIX: &str = "thinktin://join/";
/// 加入项目、加 agent 时用户同意的说明是第几版（[`ProjectInvitePreview`] 里列的那些）；说明改了加一。
pub const PROJECT_CONSENT_VERSION: u32 = 1;

str_enum!(
    /// 实例能上哪些网站（2.7，受控出网通道，见 docs/egress.md）。内网、元数据地址、服务机自己哪一档都连不了。用户
    /// 2026-11-04 定：App 里不放档位开关，大家都是 `dev`；别的档位留着给以后的管理策略。
    EgressMode {
        /// 只连模型，也不问用户。
        Model = "model",
        /// 默认：搜索（[`crate::egress::SEARCH_HOSTS`]）、开发网站（[`crate::egress::DEV_HOSTS`]）和用户一直允许的网站直接
        /// 能用，别的网站问用户（访问一次 / 一直允许 / 拒绝）。
        Dev = "dev",
        /// 只有用户一直允许的网站直接能用，别的问用户。
        Custom = "custom",
        /// 全部公网，不问。
        All = "all",
    }
);

/// 认不出的档位按只连模型。
fn lenient_egress_mode<'de, D: serde::Deserializer<'de>>(d: D) -> Result<EgressMode, D::Error> {
    let raw = String::deserialize(d)?;
    Ok(raw.parse().unwrap_or(EgressMode::Model))
}

// 枚举由 `str_enum!` 生成，派生不了 Default。
#[allow(clippy::derivable_impls)]
impl Default for EgressMode {
    fn default() -> Self {
        EgressMode::Dev
    }
}

impl EgressMode {
    /// 这一档直接放行 `host` 吗（已经按 [`crate::egress::normalize_host`] 整理过）。不直接放行的，[`EgressMode::asks`] 的
    /// 档位问用户。
    pub fn allows(self, host: &str, extra: &[String]) -> bool {
        match self {
            EgressMode::Model => false,
            EgressMode::Dev => {
                crate::egress::SEARCH_HOSTS.contains(&host)
                    || crate::egress::DEV_HOSTS.contains(&host)
                    || extra.iter().any(|h| h == host)
            }
            EgressMode::Custom => extra.iter().any(|h| h == host),
            EgressMode::All => true,
        }
    }

    /// 不直接放行的网站要不要问用户。
    pub fn asks(self) -> bool {
        matches!(self, EgressMode::Dev | EgressMode::Custom)
    }
}

str_enum!(
    /// 用户对“agent 想访问某个网站”的回答（2.7）。
    EgressDecision {
        /// 只在当前这次任务里能访问。
        Once = "once",
        /// 这个 agent 以后都能直接访问（记进实例的 `egress_hosts`）。
        Always = "always",
        /// 这次任务里不再问。
        Deny = "deny",
    }
);

/// agent 想访问、要问用户的一个网站（2.7）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EgressRequest {
    pub id: EgressRequestId,
    pub instance_id: InstanceId,
    pub host: String,
    /// 问的时候实例在做的任务（“访问一次”“拒绝”只对它有效）。
    pub run_id: Option<RunId>,
    /// pending（等用户）、once、always、denied、expired（太久没人处理）。是字符串：以后加了新状态老版本照样解析。
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub decided_at: Option<DateTime<Utc>>,
}

/// 用途说明最长这么多字（8.9）。
pub const MAX_INSTANCE_PURPOSE_CHARS: usize = 200;

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelRoute {
    pub alias: String,
    pub credential_id: CredentialId,
    pub upstream_model: String,
    /// 降级链（9.9）：主 key 失效、欠费或被限流时按顺序换用，最多 [`MAX_ROUTE_FALLBACKS`] 个。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fallbacks: Vec<RouteFallback>,
}

/// 降级链里的一项：备用的 key 和它那边的上游模型。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RouteFallback {
    pub credential_id: CredentialId,
    pub upstream_model: String,
}

/// 每个别名最多几个备用项。
pub const MAX_ROUTE_FALLBACKS: usize = 3;

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
    /// 这把 key 能用哪些协议（anthropic、chat、responses）：预置厂商按厂商算，自定义端点按配了哪几个地址算。
    /// 选 key 时按 agent 的 `active_protocol` 过滤。
    #[serde(default)]
    pub protocols: Vec<String>,
}

/// 保险箱条目（9.11）：账号和密码按用户 DEK 加密，接口从不返回密码。
/// agent 只知道名字，用沙箱里的 `thinktin-vault` 按名字把值注入命令。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VaultItem {
    pub id: VaultItemId,
    /// 引用名，见 [`valid_vault_name`]，比如 `github`。
    pub name: String,
    /// 用途，给用户和 agent 看。
    pub purpose: String,
    /// 存没存账号（账号和密码一起加密，详情接口才返回账号）。
    pub has_username: bool,
    /// 能用它的实例；空表示全部实例。
    pub instance_ids: Vec<InstanceId>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub last_used_at: Option<DateTime<Utc>>,
}

str_enum!(
    /// IM 渠道（10.5）：群机器人所在的平台。飞书和 Lark（飞书的海外版）域名不同、账号不通，分开记。
    ImVendor {
        Feishu = "feishu",
        Lark = "lark",
        Wecom = "wecom",
        Dingtalk = "dingtalk",
    }
);

str_enum!(
    /// 发到 IM 群里的事件（10.5）：和系统推送的重要事件一致。
    ImEvent {
        RunFinished = "run_finished",
        RunFailed = "run_failed",
        Approval = "approval",
    }
);

/// 用户绑定的 IM 群机器人（10.5）。webhook 地址里的 token 和签名密钥按用户 DEK 加密，接口从不返回，
/// 只给 `hint`（token 后 4 位）让用户认出是哪个群。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ImChannel {
    pub id: ImChannelId,
    pub vendor: ImVendor,
    pub label: String,
    pub hint: String,
    /// 有没有存签名密钥（飞书、钉钉的“加签”）。
    pub has_secret: bool,
    pub events: Vec<ImEvent>,
    pub enabled: bool,
    pub last_sent_at: Option<DateTime<Utc>>,
    /// 最近一次发送失败的原因（签名不对、关键词不匹配、机器人被删……），发成功后清空。
    pub last_error: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

str_enum!(
    /// 用户举报 agent 输出的原因（5.5）。
    ReportReason {
        /// 危害人身安全、教唆违法犯罪。
        Harmful = "harmful",
        /// 违法违规的内容。
        Illegal = "illegal",
        /// 色情低俗。
        Sexual = "sexual",
        /// 歧视、仇恨、侮辱。
        Hateful = "hateful",
        /// 泄露个人信息、侵犯隐私。
        Privacy = "privacy",
        /// 虚假信息。
        Misinformation = "misinformation",
        /// 侵犯知识产权。
        Infringement = "infringement",
        Other = "other",
    }
);

str_enum!(
    /// 举报的处理状态：待处理、已处理。
    ReportState { Open = "open", Closed = "closed" }
);

/// 用户的一条举报（5.5）。被举报的那一条内容在提交时复制下来（运营看的是它，事件过了保留期也还在），
/// 接口只返回举报本身，不回显复制的内容。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ContentReport {
    pub id: ReportId,
    pub run_id: RunId,
    pub instance_id: InstanceId,
    /// 举报的是运行里的哪一条事件（实例事件流的序号）；没有就是整个运行（它的回复）。
    pub event_seq: Option<u64>,
    pub artifact_id: Option<ArtifactId>,
    pub reason: ReportReason,
    pub note: Option<String>,
    pub state: ReportState,
    /// 处理结果（运营写的，也发给举报的人）。
    pub resolution: Option<String>,
    pub created_at: DateTime<Utc>,
    pub handled_at: Option<DateTime<Utc>>,
}

/// 保险箱条目里的字段：账号、密码。
pub const VAULT_FIELDS: [&str; 2] = ["username", "password"];

/// 保险箱条目名：小写字母或数字开头，只含小写字母、数字、`_`、`-`，最长 64 个字符（和数据库约束一致）。
/// 不能有 `.`：引用字段时写成 `github.username`。
pub fn valid_vault_name(name: &str) -> bool {
    let b = name.as_bytes();
    !b.is_empty()
        && b.len() <= 64
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_' || *c == b'-')
}

str_enum!(
    /// agent 请用户填账号密码的请求（9.11）。过了期限还没处理的读出来是 `expired`。
    VaultRequestStatus {
        Pending = "pending",
        Fulfilled = "fulfilled",
        Declined = "declined",
        Expired = "expired",
    }
);

/// agent 请用户把账号密码存进保险箱（9.11）：App 据此弹表单，用户填的值只进保险箱，
/// agent 只拿到名字。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VaultRequest {
    pub id: VaultRequestId,
    pub instance_id: InstanceId,
    pub run_id: Option<RunId>,
    pub name: String,
    /// agent 写的用途（显示时带“AI 生成”标识）。
    pub purpose: String,
    /// 要填的字段，见 [`VAULT_FIELDS`]。
    pub fields: Vec<String>,
    pub status: VaultRequestStatus,
    pub item_id: Option<VaultItemId>,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub resolved_at: Option<DateTime<Utc>>,
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
    /// 每次 agent 改动加一；确认时要带上用户看到的版本（防止确认之前被悄悄改掉）。
    #[serde(default)]
    pub revision: u32,
    /// agent 新建或修改过、等用户确认。确认前不会运行，也不能直接恢复。
    #[serde(default)]
    pub awaiting_confirmation: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Trigger {
    pub id: TriggerId,
    pub plan_id: PlanId,
    pub spec: ScheduleSpec,
    pub enabled: bool,
    pub next_fire_at: Option<DateTime<Utc>>,
    pub last_fire_at: Option<DateTime<Utc>>,
    /// 后台为什么停用了它（[`TRIGGER_INVALID_RULE`]）。用户自己停不了触发器，没被停用时没有。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disabled_reason: Option<String>,
}

/// 计划的 webhook（7.1 事件触发）：外面的服务往它的地址 POST，平台按这个计划起一次运行。令牌只在建、换的
/// 时候返回一次，这里没有。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanHook {
    pub id: PlanHookId,
    pub plan_id: PlanId,
    pub enabled: bool,
    /// 用户同意把收到的内容交给 agent 和模型厂商的时间。
    pub consented_at: DateTime<Utc>,
    pub last_event_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

/// 触发器的规则解析不了了（比如时区没了）：后台停用它，用户删掉重新加。
pub const TRIGGER_INVALID_RULE: &str = "invalid_rule";

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
    /// 等的是什么（[`wait_code`]），只在 `waiting_quota`、`waiting_device` 时有；`waiting_children` 时只等
    /// 队友回答的是 [`wait_code::ANSWER`]。是字符串不是枚举：以后加了新值，老的客户端照样解析得了。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wait_code: Option<String>,
    /// 项目运行（8.15）：在哪个项目里；私人运行没有。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<ProjectId>,
}

/// 运行在等什么（11.8）：App 据此决定显示“去换 key”还是“稍后自动重试”。
pub mod wait_code {
    /// key 无效或没有权限：要用户换 key。
    pub const INVALID: &str = "invalid";
    /// 欠费、额度用完：要用户充值或换 key（每小时也自己再试一次）。
    pub const NO_BALANCE: &str = "no_balance";
    /// 没有能用的 key（都停用了、当天预算用完、解不开）：要用户处理（每小时也自己再试一次）。
    pub const UNAVAILABLE: &str = "unavailable";
    /// 被限流：几分钟后自己继续，不用处理。
    pub const RATE_LIMITED: &str = "rate_limited";
    /// 模型服务繁忙或连不上：几分钟后自己继续，不用处理。
    pub const OVERLOADED: &str = "overloaded";
    /// 等用户的电脑上线。
    pub const DEVICE_OFFLINE: &str = "device_offline";
    /// 等待子任务时（`waiting_children`）：等的只是队友的回答（8.11），没有委派的子任务。
    pub const ANSWER: &str = "answer";
    pub const ALL: [&str; 7] = [
        INVALID,
        NO_BALANCE,
        UNAVAILABLE,
        RATE_LIMITED,
        OVERLOADED,
        DEVICE_OFFLINE,
        ANSWER,
    ];
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
    /// shim 给的请求 id（和 `agent.permission_requested` 事件里的一样）。shim 每次尝试都从 perm-1 重新编号，
    /// 所以要和 `attempt` 一起才对得上。
    #[serde(default)]
    pub request_id: String,
    /// 第几次尝试（和 `run.state` 事件的 `attempt` 一样）；0 是不知道（老数据）。
    #[serde(default)]
    pub attempt: u32,
    #[serde(default)]
    pub decided_option: Option<String>,
    #[serde(default)]
    pub decided_at: Option<DateTime<Utc>>,
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

/// 项目里的一个人（8.14）：只有用户 id 和昵称，不带手机号。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectPerson {
    pub user_id: UserId,
    #[serde(default)]
    pub display_name: Option<String>,
}

/// 项目列表里的一项（8.14）：我是成员的项目。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProjectSummary {
    pub id: ProjectId,
    pub name: String,
    pub goal: String,
    pub status: ProjectStatus,
    /// 我在项目里的身份。
    pub role: ProjectRole,
    /// 有没有别人加入过（加入过就一直是共享项目）。
    pub shared: bool,
    pub creator: ProjectPerson,
    pub member_count: u32,
    pub agent_count: u32,
    /// 其中我的 agent 有几个。
    pub my_agent_count: u32,
    pub created_at: DateTime<Utc>,
    /// 我是什么时候加入的。
    pub joined_at: DateTime<Utc>,
}

/// 项目的一个成员（只有成员看得到）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectMemberView {
    pub user_id: UserId,
    #[serde(default)]
    pub display_name: Option<String>,
    pub role: ProjectRole,
    pub joined_at: DateTime<Utc>,
    /// 他在项目里有几个 agent。
    pub agent_count: u32,
    pub is_me: bool,
}

/// 项目里的一个 agent：谁的、哪个实例。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectAgentView {
    pub instance_id: InstanceId,
    /// agent 的主人。
    pub owner_id: UserId,
    pub agent_id: String,
    pub name: String,
    pub is_lead: bool,
    pub position: u32,
    pub added_at: DateTime<Utc>,
    /// 是我的 agent。
    pub mine: bool,
}

/// 我在这个项目里的预算（每个人管自己的 agent 花多少；没有是不限）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectBudget {
    #[serde(default)]
    pub daily_token_limit: Option<u64>,
    #[serde(default)]
    pub total_token_limit: Option<u64>,
}

/// 项目的上限：最多几个人、几个 agent。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectLimits {
    pub max_users: u32,
    pub max_agents: u32,
}

impl Default for ProjectLimits {
    fn default() -> Self {
        Self {
            max_users: MAX_PROJECT_USERS as u32,
            max_agents: MAX_PROJECT_AGENTS as u32,
        }
    }
}

/// 项目详情（只有成员看得到）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProjectDetail {
    #[serde(flatten)]
    pub summary: ProjectSummary,
    /// 创建者在前。
    pub members: Vec<ProjectMemberView>,
    pub agents: Vec<ProjectAgentView>,
    pub my_budget: ProjectBudget,
    pub limits: ProjectLimits,
}

/// 一个邀请（创建者看的）。按手机号的只给打码的手机号。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectInvite {
    pub id: ProjectInviteId,
    pub project_id: ProjectId,
    pub kind: ProjectInviteKind,
    pub status: ProjectInviteStatus,
    #[serde(default)]
    pub phone_masked: Option<String>,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    /// 接受、拒绝、撤回、过期的时间。
    #[serde(default)]
    pub settled_at: Option<DateTime<Utc>>,
    /// 谁接受的。
    #[serde(default)]
    pub accepted_by: Option<ProjectPerson>,
}

/// 邀请预览里的项目（还不是成员时看到的）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectBrief {
    pub id: ProjectId,
    pub name: String,
    pub goal: String,
}

/// 邀请预览里的成员：只有昵称，不带用户 id（还不是成员）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectMemberBrief {
    #[serde(default)]
    pub display_name: Option<String>,
    pub role: ProjectRole,
    pub agent_count: u32,
}

/// 加入前看到的邀请（8.14）：项目是什么、有谁，加入后哪些东西项目里的人看得到、哪些还是自己的。
/// `shared_with_project` 和 `kept_private` 是固定的键（App 自己翻译），见 [`project_consent`]。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectInvitePreview {
    pub invite_id: ProjectInviteId,
    pub kind: ProjectInviteKind,
    pub expires_at: DateTime<Utc>,
    pub project: ProjectBrief,
    /// 发邀请的创建者：屏蔽要用他的 id。
    pub creator: ProjectPerson,
    pub members: Vec<ProjectMemberBrief>,
    pub users: u32,
    pub agents: u32,
    pub limits: ProjectLimits,
    pub shared_with_project: Vec<String>,
    pub kept_private: Vec<String>,
}

/// 加入项目时的说明（[`PROJECT_CONSENT_VERSION`] 这一版）：App 按键显示。
pub mod project_consent {
    /// 项目里的人都看得到的。
    pub const SHARED_WITH_PROJECT: [&str; 5] = [
        "project_goal_and_tasks",
        "project_board",
        "project_artifacts",
        "your_agents_project_runs",
        "sent_to_all_agents_vendors",
    ];
    /// 还是只有自己看得到的。
    pub const KEPT_PRIVATE: [&str; 8] = [
        "private_runs",
        "private_board",
        "private_artifacts",
        "vault",
        "computer",
        "model_keys",
        "costs",
        "approvals",
    ];
}

str_enum!(
    /// 项目里的内容是谁的（8.15）：成员、已退出的成员、已注销的用户（后两种不给用户 id 和昵称）。
    ProjectAuthorStatus {
        Member = "member",
        Left = "left",
        Erased = "erased",
    }
);

/// 项目里一条内容（运行、产出物）的主人（8.15）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectAuthor {
    #[serde(default)]
    pub user_id: Option<UserId>,
    #[serde(default)]
    pub display_name: Option<String>,
    pub status: ProjectAuthorStatus,
}

str_enum!(
    /// 成员看到的运行状态（8.15）：比 [`RunState`] 粗，看不出主人那边在等什么（等 key、等审批、等电脑都是“等主人处理”）。
    ProjectRunState {
        Queued = "queued",
        Running = "running",
        WaitingOwner = "waiting_owner",
        WaitingChildren = "waiting_children",
        Succeeded = "succeeded",
        Failed = "failed",
        Cancelled = "cancelled",
    }
);

/// 成员看到的项目运行（8.15）：任务、粗略的状态、结果摘要；不带失败原因、花费、尝试次数、计划、授权这些主人私人的东西。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProjectRun {
    pub id: RunId,
    pub project_id: ProjectId,
    pub instance_id: InstanceId,
    pub owner: ProjectAuthor,
    /// 是我的 agent 的运行。
    pub mine: bool,
    pub kind: RunKind,
    pub source: RunSource,
    #[serde(default)]
    pub parent_run_id: Option<RunId>,
    pub root_run_id: RunId,
    #[serde(default)]
    pub step_key: Option<String>,
    pub prompt: String,
    pub state: ProjectRunState,
    #[serde(default)]
    pub summary: Option<String>,
    pub created_at: DateTime<Utc>,
    #[serde(default)]
    pub started_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub finished_at: Option<DateTime<Utc>>,
}

/// 成员看到的一条运行事件（8.15）：只有 [`PROJECT_RUN_EVENT_KINDS`] 这几种，每种只留白名单里的字段（库里的函数挑好）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProjectRunEvent {
    pub run_id: RunId,
    pub kind: String,
    pub data: Value,
    pub created_at: DateTime<Utc>,
}

/// 一个运行最近的那些事件（最多 500 条，旧的在前）；`truncated`：更早的没给。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProjectRunEvents {
    pub events: Vec<ProjectRunEvent>,
    pub truncated: bool,
}

/// 成员看到的项目产出物（8.15）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectArtifact {
    pub id: ArtifactId,
    pub project_id: ProjectId,
    pub instance_id: InstanceId,
    pub run_id: RunId,
    pub root_run_id: RunId,
    pub author: ProjectAuthor,
    pub mine: bool,
    pub name: String,
    pub version: u32,
    pub content_type: String,
    pub size: u64,
    pub sha256: String,
    pub created_at: DateTime<Utc>,
}

/// 成员看得到的事件种类（8.15）；别的种类（思考、用量、审批、工具调用的原始参数和结果……）一律不给。和迁移 0054 里的
/// 白名单一样（测试核对）。
pub const PROJECT_RUN_EVENT_KINDS: [&str; 10] = [
    "agent.tool_call",
    "agent.tool_call_update",
    "agent.message",
    "agent.plan",
    "agent.turn_started",
    "agent.turn_ended",
    "run.state",
    "run.log_truncated",
    "artifact.published",
    "pipeline.step_started",
];

/// 我屏蔽的人（8.14）：他发的项目邀请不再给我看。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlockedUser {
    pub user_id: UserId,
    #[serde(default)]
    pub display_name: Option<String>,
    pub created_at: DateTime<Utc>,
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

/// 提醒是哪一种（10.7）：推送的 `tt.subtype`（Android 是 `tt_subtype`）和收件箱条目的 `subtype`，App 据此跳转、
/// 刷新。是字符串不是枚举：以后加了新值，老的客户端照样解析得了（不认识的按 `kind` 显示）。运行在等什么的提醒
/// （`run_failed`，运行进入等待状态时）用 [`wait_code`] 的值。
pub mod notice_subtype {
    /// 账号被冻结了。
    pub const ACCOUNT_FROZEN: &str = "account_frozen";
    /// 账号解冻了：App 收到后重查账号状态、重新订阅事件流。
    pub const ACCOUNT_RESTORED: &str = "account_restored";
    /// 用户点了“全部停止”。
    pub const STOPPED_ALL: &str = "stopped_all";
    /// 审批超时、按策略跳过了这一步。
    pub const APPROVAL_SKIPPED: &str = "approval_skipped";
    /// 计划的触发规则失效、被停用了（带 `plan_id`）。
    pub const TRIGGER_DISABLED: &str = "trigger_disabled";
    /// IM 群机器人失效、渠道被停用了。
    pub const IM_CHANNEL_DISABLED: &str = "im_channel_disabled";
    /// 用户的内容举报处理完了。
    pub const REPORT_HANDLED: &str = "report_handled";
    /// 平台搜索要运营者处理（docs/search.md）：额度快用完、用完了，搜索接口欠费或 key 不对。只发给 `[search] alert_phone`
    /// 的账号。
    pub const SEARCH_ALERT: &str = "search_alert";
    /// 有人邀请我加入项目（带 `project_id` 和 `project_invite_id`）。
    pub const PROJECT_INVITE: &str = "project_invite";
    /// 有人加入了我在的项目。
    pub const PROJECT_JOINED: &str = "project_joined";
    /// 有人退出了我在的项目。
    pub const PROJECT_LEFT: &str = "project_left";
    /// 我被移出了项目。
    pub const PROJECT_REMOVED: &str = "project_removed";
    /// 有人撤下了自己在项目里的 agent。
    pub const PROJECT_AGENT_LEFT: &str = "project_agent_left";
    /// 我的 agent 被创建者移出了项目。
    pub const PROJECT_AGENT_REMOVED: &str = "project_agent_removed";
    /// 我在的项目被创建者删了（8.15）。
    pub const PROJECT_DELETED: &str = "project_deleted";
    /// 项目回执：只关于成员关系本身、退出以后照样留在收件人收件箱里的（8.15 的租户策略、守卫、后台清理按子类型认）。
    pub const PROJECT_RECEIPTS: [&str; 7] = [
        PROJECT_INVITE,
        PROJECT_JOINED,
        PROJECT_LEFT,
        PROJECT_REMOVED,
        PROJECT_AGENT_LEFT,
        PROJECT_AGENT_REMOVED,
        PROJECT_DELETED,
    ];
}

/// 共享看板的一条（8.10）：用户的 agent（或用户自己）写的进展、决定、待别人处理的事。写了不改，只能归档、删除。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BoardPost {
    pub id: BoardPostId,
    /// 哪个实例写的；没有是用户自己写的。实例删了 id 还在、`author_name` 没有：用 `ai_generated` 区分用户和
    /// 删了的 agent。
    pub author_instance_id: Option<InstanceId>,
    /// 写它的实例的名字（实例删了就没有）。
    pub author_name: Option<String>,
    /// 哪次运行写的。
    pub run_id: Option<RunId>,
    pub body: String,
    pub tags: Vec<String>,
    /// agent 写的（App 里按 AI 生成内容标注）；用户自己写的是 false。
    pub ai_generated: bool,
    pub created_at: DateTime<Utc>,
    pub archived_at: Option<DateTime<Utc>>,
}

/// 看板一条最长这么多字（8.10）。
pub const MAX_BOARD_BODY_CHARS: usize = 2000;
/// 看板一条最多这么多个标签。
pub const MAX_BOARD_TAGS: usize = 8;
/// 每个用户的看板上没归档的最多这么多条，满了最早的自动归档。
pub const MAX_BOARD_LIVE_POSTS: u64 = 200;

/// 看板标签的格式：字母（含中文）、数字、`-`、`_`，1–32 个字。比较前转成小写。
pub fn valid_board_tag(tag: &str) -> bool {
    (1..=32).contains(&tag.chars().count())
        && tag
            .chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
}

/// 提醒子类型的格式（和库里的 CHECK 一样）：小写字母开头，字母和下划线，最长 32。
pub fn valid_subtype(s: &str) -> bool {
    let b = s.as_bytes();
    (1..=32).contains(&b.len())
        && b[0].is_ascii_lowercase()
        && b.iter().all(|c| c.is_ascii_lowercase() || *c == b'_')
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
    /// 正文是 agent 生成的：显示时要带“AI 生成”标识。
    #[serde(default)]
    pub ai_generated: bool,
    pub read: bool,
    pub created_at: DateTime<Utc>,
    /// 是哪一种提醒（[`notice_subtype`]）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtype: Option<String>,
    /// 保险箱请求（`kind` 是 `vault_request` 时）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vault_request_id: Option<VaultRequestId>,
    /// agent 想访问的网站（`kind` 是 `egress_request` 时，2.7）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub egress_request_id: Option<EgressRequestId>,
    /// 项目回执（8.14：邀请、加入、退出）对应的项目；打开时项目没了接口回 404。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<ProjectId>,
    /// 项目邀请（`subtype` 是 `project_invite` 时）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_invite_id: Option<ProjectInviteId>,
}

str_enum!(
    /// 手机和电脑之间经平台转发的消息（14.1；内容和签名见 docs/pairing.md）。
    /// 平台只转发：内容由两端用安全芯片里的私钥签名，平台改不了也冒充不了。
    DeviceMessageKind {
        /// 手机 → 电脑：扫码后的配对应答。
        PairResponse = "pair_response",
        /// 电脑 → 手机：确认配对。
        PairConfirm = "pair_confirm",
        /// 电脑 → 手机：高危操作，请手机签名批准。
        ApprovalRequest = "approval_request",
        /// 手机 → 电脑：签了名的批准或拒绝。
        ApprovalDecision = "approval_decision",
        /// 手机 → 电脑：普通操作的能力令牌。
        Capability = "capability",
        /// 手机 → 电脑：吊销能力令牌。
        Revocation = "revocation",
    }
);

impl DeviceMessageKind {
    /// 这种消息由电脑发给手机（否则由手机发给电脑）。
    pub fn from_computer(self) -> bool {
        matches!(self, Self::PairConfirm | Self::ApprovalRequest)
    }
}

/// 手机和电脑之间转发的一条消息。收件方不在线时排队，上线后投递，过期没送到的丢掉。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeviceMessage {
    pub id: DeviceMessageId,
    pub from_device: DeviceId,
    pub to_device: DeviceId,
    pub kind: DeviceMessageKind,
    pub body: Value,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

str_enum!(
    /// 平台发给电脑的工具调用（14.1）走到哪一步了。
    DeviceCallState {
        /// 等电脑连上中继来取。
        Pending = "pending",
        /// 中继已经转给电脑，等结果。
        Sent = "sent",
        /// 电脑回了结果（工具本身可能报错，见结果里的 `is_error`）。
        Done = "done",
        /// 没能完成：转出去以后电脑断线了。
        Failed = "failed",
        /// 平台不等了。
        Expired = "expired",
    }
);

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
    fn locales_from_system_tags() {
        for (tag, want) in [
            ("zh-Hans-CN", Some(Locale::ZhCn)),
            ("zh_TW", Some(Locale::ZhCn)),
            ("ZH", Some(Locale::ZhCn)),
            ("en-US", Some(Locale::En)),
            ("en", Some(Locale::En)),
            ("ja-JP", None),
            ("", None),
        ] {
            assert_eq!(Locale::from_tag(tag), want, "{tag}");
        }
        assert_eq!(Locale::default(), Locale::ZhCn);
        assert_eq!("en".parse::<Locale>().unwrap(), Locale::En);
        for (header, want) in [
            ("en-US,en;q=0.9,zh-CN;q=0.8", Some(Locale::En)),
            ("zh-Hans-CN;q=0.5, en;q=0.7", Some(Locale::En)),
            ("ja-JP, zh-TW;q=0.9", Some(Locale::ZhCn)),
            ("en;q=0, zh", Some(Locale::ZhCn)),
            ("ja, ko;q=0.8", None),
            ("en;q=abc", None),
            ("", None),
        ] {
            assert_eq!(Locale::from_accept_language(header), want, "{header}");
        }
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

    #[test]
    fn vault_names() {
        for ok in ["github", "work-mail", "db_2", "9to5"] {
            assert!(valid_vault_name(ok), "{ok}");
        }
        let long = "a".repeat(65);
        for bad in [
            "",
            "GitHub",
            "git.hub",
            "-x",
            "_x",
            "邮箱",
            "a b",
            long.as_str(),
        ] {
            assert!(!valid_vault_name(bad), "{bad}");
        }
    }

    /// 老服务端、缓存里的运行没有 `wait_code`，新服务端可能给出不认识的值：都解析得了。
    #[test]
    fn runs_parse_with_or_without_a_wait_code() {
        let base = serde_json::json!({
            "id": RunId::new(), "kind": "agent", "instance_id": InstanceId::new(), "plan_id": null,
            "parent_run_id": null, "root_run_id": RunId::new(), "step_key": null, "source": "user",
            "prompt": "p", "state": "waiting_quota", "state_reason": null, "attempt": 1, "tokens_used": 0,
            "summary": null, "error": null, "created_at": "2026-10-22T00:00:00Z", "started_at": null,
            "finished_at": null
        });
        let old: Run = serde_json::from_value(base.clone()).unwrap();
        assert_eq!(old.wait_code, None);
        assert!(
            serde_json::to_value(&old)
                .unwrap()
                .get("wait_code")
                .is_none()
        );
        let mut newer = base;
        newer["wait_code"] = serde_json::json!("future_thing");
        let r: Run = serde_json::from_value(newer).unwrap();
        assert_eq!(r.wait_code.as_deref(), Some("future_thing"));
    }

    /// 老服务端、缓存里的实例没有用途说明和交流开关（8.9）：开关按打开算。
    #[test]
    fn instances_parse_without_purpose_or_peer_access() {
        let old = serde_json::json!({
            "id": InstanceId::new(), "agent_id": "claude", "agent_version": "1", "harness": "acp",
            "name": "c", "state": "running", "created_at": "2026-10-28T00:00:00Z",
            "last_active_at": "2026-10-28T00:00:00Z"
        });
        let i: Instance = serde_json::from_value(old).unwrap();
        assert_eq!(i.purpose, "");
        assert!(i.peer_access);
    }
}

/// 手机号打码：留国家码和前几位、后四位，比如 `+86138****8000`（运维命令、项目邀请里给别人看的号码）。
pub fn mask_phone(phone: &str) -> String {
    let chars: Vec<char> = phone.chars().collect();
    let n = chars.len();
    if n <= 6 {
        return "*".repeat(n);
    }
    let (head, tail) = if n > 10 { (6, 4) } else { (n - 6, 2) };
    let shown_head: String = chars[..head].iter().collect();
    let shown_tail: String = chars[n - tail..].iter().collect();
    format!("{shown_head}{}{shown_tail}", "*".repeat(n - head - tail))
}

#[cfg(test)]
mod project_tests {
    use super::*;

    #[test]
    fn project_subtypes_and_consent_keys_are_valid() {
        for s in [
            notice_subtype::PROJECT_INVITE,
            notice_subtype::PROJECT_JOINED,
            notice_subtype::PROJECT_LEFT,
            notice_subtype::PROJECT_REMOVED,
            notice_subtype::PROJECT_AGENT_LEFT,
            notice_subtype::PROJECT_AGENT_REMOVED,
        ] {
            assert!(valid_subtype(s), "{s}");
        }
        let all: Vec<_> = project_consent::SHARED_WITH_PROJECT
            .iter()
            .chain(&project_consent::KEPT_PRIVATE)
            .collect();
        let mut dedup = all.clone();
        dedup.sort();
        dedup.dedup();
        assert_eq!(dedup.len(), all.len(), "keys are distinct");
        for r in ProjectRole::ALL {
            assert_eq!(r.as_str().parse::<ProjectRole>().unwrap(), *r);
        }
        for k in ProjectInviteStatus::ALL {
            assert_eq!(k.as_str().parse::<ProjectInviteStatus>().unwrap(), *k);
        }
        assert_eq!(MAX_TOKEN_LIMIT as i64 as u64, MAX_TOKEN_LIMIT);
        for s in notice_subtype::PROJECT_RECEIPTS {
            assert!(valid_subtype(s), "{s}");
        }
        assert!(notice_subtype::PROJECT_RECEIPTS.contains(&notice_subtype::PROJECT_DELETED));
        for k in PROJECT_RUN_EVENT_KINDS {
            assert!(k.contains('.'), "{k}");
        }
        for s in ProjectRunState::ALL {
            assert_eq!(s.as_str().parse::<ProjectRunState>().unwrap(), *s);
        }
    }

    #[test]
    fn runs_carry_their_project_only_when_there_is_one() {
        let v = serde_json::json!({
            "id": RunId::new(), "kind": "agent", "instance_id": InstanceId::new(),
            "plan_id": null, "parent_run_id": null, "root_run_id": RunId::new(), "step_key": null,
            "source": "user", "prompt": "p", "state": "queued", "state_reason": null, "attempt": 0,
            "tokens_used": 0, "summary": null, "error": null, "created_at": chrono::Utc::now(),
            "started_at": null, "finished_at": null
        });
        let run: Run = serde_json::from_value(v).unwrap();
        assert_eq!(run.project_id, None);
        assert!(
            serde_json::to_value(&run)
                .unwrap()
                .get("project_id")
                .is_none()
        );
        let p = ProjectId::new();
        let run = Run {
            project_id: Some(p),
            ..run
        };
        assert_eq!(
            serde_json::to_value(&run).unwrap()["project_id"],
            p.to_string()
        );
    }

    #[test]
    fn project_detail_flattens_the_summary() {
        let me = UserId::new();
        let now = chrono::Utc::now();
        let d = ProjectDetail {
            summary: ProjectSummary {
                id: ProjectId::new(),
                name: "p".into(),
                goal: "g".into(),
                status: ProjectStatus::Active,
                role: ProjectRole::Creator,
                shared: false,
                creator: ProjectPerson {
                    user_id: me,
                    display_name: None,
                },
                member_count: 1,
                agent_count: 0,
                my_agent_count: 0,
                created_at: now,
                joined_at: now,
            },
            members: vec![],
            agents: vec![],
            my_budget: ProjectBudget::default(),
            limits: ProjectLimits::default(),
        };
        let v = serde_json::to_value(&d).unwrap();
        assert_eq!(v["role"], "creator");
        assert_eq!(v["limits"]["max_users"], 10);
        assert!(v.get("summary").is_none());
        assert_eq!(serde_json::from_value::<ProjectDetail>(v).unwrap(), d);
    }
}

#[cfg(test)]
mod mask_tests {
    use super::mask_phone;

    #[test]
    fn phones_are_masked() {
        assert_eq!(mask_phone("+8613800138000"), "+86138****8000");
        assert_eq!(mask_phone("+14155550123"), "+14155**0123");
        assert_eq!(mask_phone("+4930123"), "+4****23");
        assert_eq!(mask_phone("deleted"), "d****ed");
        assert_eq!(mask_phone("+123"), "****");
    }
}
