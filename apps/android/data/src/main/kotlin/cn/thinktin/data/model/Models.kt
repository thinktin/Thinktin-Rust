package cn.thinktin.data.model

import kotlinx.serialization.json.JsonObject

/*
 * App 侧模型：和 cn.thinktin.core（UniFFI 生成）的数据类一一对应，但
 * - 状态字段换成枚举（未知值 → Unknown）；
 * - 无符号整数换成 Int / Long（界面直接用）；
 * - 时间统一是 Unix 毫秒（Long）；
 * - JSON 字符串解析成 JsonObject（失败则空对象）。
 * 映射见 cn.thinktin.data.core.Mappers。
 */

data class User(
    val id: String,
    val phone: String,
    val displayName: String?,
    val status: String,
    /** zh-CN / en */
    val locale: String,
    val createdAtMs: Long,
)

data class LoginResult(val user: User, val newUser: Boolean)

data class AgentInfo(
    val id: String,
    val name: String,
    val version: String,
    val license: String?,
    val sites: List<String>,
    val harnesses: List<String>,
    val defaultHarness: String,
    /** 可用版本，当前版本在前。 */
    val versions: List<String>,
    /** 一句话介绍（按设备语言给；老的服务端为空）。 */
    val description: String = "",
    /** 上游仓库（https）；没有时为空。 */
    val upstream: String = "",
    /** 许可说明（专有许可证必有），按设备语言给。 */
    val licenseNote: String? = null,
    /** 能说的协议，按优先级：anthropic、chat、responses（和 [VendorInfo.protocols]、[Credential.protocols] 同一套名字）。 */
    val protocols: List<String> = emptyList(),
    /** 运行时实际用的协议：实例配的每把 key 的 [Credential.protocols] 都要包含它，选 key 时按它过滤。 */
    val activeProtocol: String? = null,
)

data class Instance(
    val id: String,
    val agentId: String,
    val agentVersion: String,
    val harness: String,
    val name: String,
    val state: InstanceState,
    val createdAtMs: Long,
    val lastActiveAtMs: Long,
)

data class RouteFallback(val credentialId: String, val upstreamModel: String)

data class ModelRoute(
    val alias: String,
    val credentialId: String,
    val upstreamModel: String,
    val fallbacks: List<RouteFallback>,
)

data class Run(
    val id: String,
    val kind: RunKind,
    val instanceId: String,
    val planId: String?,
    val parentRunId: String?,
    val rootRunId: String,
    val stepKey: String?,
    val source: RunSource,
    /** 用户的提问（不在事件流里）。 */
    val prompt: String,
    val state: RunState,
    val stateReason: String?,
    val attempt: Int,
    val tokensUsed: Long,
    val summary: String?,
    val error: String?,
    val createdAtMs: Long,
    val startedAtMs: Long?,
    val finishedAtMs: Long?,
    /** 等的是什么（只在 waiting_quota / waiting_device 时有）：界面按码显示原因和操作。 */
    val waitCode: WaitCode? = null,
) {
    /** 耗时（毫秒）；还没开始时为 null，没结束时算到 [nowMs]。 */
    fun durationMs(nowMs: Long): Long? {
        val start = startedAtMs ?: return null
        return ((finishedAtMs ?: nowMs) - start).coerceAtLeast(0)
    }
}

data class Artifact(
    val id: String,
    val instanceId: String,
    val runId: String,
    val name: String,
    val version: Int,
    val contentType: String,
    val size: Long,
    val sha256: String,
    val createdAtMs: Long,
)

/**
 * 实例事件（第 8.2 节）。[kind] 保留原始字符串（未知的 kind 显示成系统行），
 * [payload] 是 payload_json 解析后的对象，解析失败为空对象。
 */
data class InstanceEvent(
    val instanceId: String,
    val seq: Long,
    val runId: String?,
    val kind: String,
    val payload: JsonObject,
    val aiGenerated: Boolean,
    val createdAtMs: Long,
)

/** 第 8.2 节表里的事件类型。 */
object EventKinds {
    const val AGENT_MESSAGE = "agent.message"
    const val AGENT_THOUGHT = "agent.thought"
    const val AGENT_TOOL_CALL = "agent.tool_call"
    const val AGENT_TOOL_CALL_UPDATE = "agent.tool_call_update"
    const val AGENT_PLAN = "agent.plan"
    const val AGENT_USAGE = "agent.usage"
    const val AGENT_PERMISSION_REQUESTED = "agent.permission_requested"
    const val AGENT_PERMISSION_RESOLVED = "agent.permission_resolved"
    const val AGENT_PLATFORM_TOOL_CALL = "agent.platform_tool_call"
    const val AGENT_VAULT_REVEAL = "agent.vault_reveal"
    const val AGENT_TURN_STARTED = "agent.turn_started"
    const val AGENT_TURN_ENDED = "agent.turn_ended"
    const val AGENT_READY = "agent.ready"
    const val AGENT_SESSION_LOST = "agent.session_lost"
    const val AGENT_EXITED = "agent.exited"
    const val AGENT_UPDATE = "agent.update"
    const val AGENT_ERROR = "agent.error"
    const val RUN_STATE = "run.state"
    const val RUN_LOG_TRUNCATED = "run.log_truncated"
    const val PIPELINE_STEP_STARTED = "pipeline.step_started"
    const val DELEGATE_STARTED = "delegate.started"
    const val ARTIFACT_PUBLISHED = "artifact.published"
    const val APPROVAL_DECIDED = "approval.decided"
    const val PLAN_NEEDS_CONFIRMATION = "plan.needs_confirmation"
    const val PLAN_CANCELLED = "plan.cancelled"
    const val VAULT_REQUESTED = "vault.requested"
    const val VAULT_FULFILLED = "vault.fulfilled"
    const val VAULT_DECLINED = "vault.declined"
    const val VAULT_USED = "vault.used"

    /** 全部已知的 kind（Mock 数据和测试用来确认覆盖）。 */
    val ALL: List<String> = listOf(
        AGENT_MESSAGE, AGENT_THOUGHT, AGENT_TOOL_CALL, AGENT_TOOL_CALL_UPDATE, AGENT_PLAN, AGENT_USAGE,
        AGENT_PERMISSION_REQUESTED, AGENT_PERMISSION_RESOLVED, AGENT_PLATFORM_TOOL_CALL, AGENT_VAULT_REVEAL,
        AGENT_TURN_STARTED, AGENT_TURN_ENDED, AGENT_READY, AGENT_SESSION_LOST, AGENT_EXITED, AGENT_UPDATE,
        AGENT_ERROR, RUN_STATE, RUN_LOG_TRUNCATED, PIPELINE_STEP_STARTED, DELEGATE_STARTED,
        ARTIFACT_PUBLISHED, APPROVAL_DECIDED, PLAN_NEEDS_CONFIRMATION, PLAN_CANCELLED,
        VAULT_REQUESTED, VAULT_FULFILLED, VAULT_DECLINED, VAULT_USED,
    )
}

/** 事件流的连接状态（client-core 的 StreamStatus）。 */
sealed interface StreamState {
    data object Connecting : StreamState
    data object Live : StreamState
    data class Reconnecting(val retryInMs: Long) : StreamState
    data object SignedOut : StreamState
    data object NotFound : StreamState
    data object AccountFrozen : StreamState

    /** 握手被拒（426）：App 版本太老，不再重连；界面进升级页（[cn.thinktin.data.service.ThinktinService.upgradeState]）。 */
    data object UpgradeRequired : StreamState

    /** 调用方停的，或后台任务意外退出。 */
    data object Stopped : StreamState
}

/** 终止状态：之后不会再有事件，events() 的流在发出它之后结束。 */
val StreamState.isTerminal: Boolean
    get() = when (this) {
        StreamState.NotFound, StreamState.SignedOut, StreamState.AccountFrozen, StreamState.UpgradeRequired,
        StreamState.Stopped,
        -> true
        StreamState.Connecting, StreamState.Live, is StreamState.Reconnecting -> false
    }

/** ThinktinService.events() 吐出的东西：事件、续传重置、连接状态。 */
sealed interface EventStreamItem {
    data class Event(val event: InstanceEvent) : EventStreamItem

    /** 续传位置过了保留期：本地旧事件作废，整体重新加载。 */
    data class Reset(val oldestSeq: Long, val latestSeq: Long?) : EventStreamItem
    data class Status(val state: StreamState) : EventStreamItem
}

data class ApprovalOption(val optionId: String, val name: String, val kind: OptionKind)

data class Approval(
    val id: String,
    val runId: String,
    val instanceId: String,
    val title: String?,
    val options: List<ApprovalOption>,
    /** agent 要执行的工具调用（原始 JSON）。 */
    val toolCallJson: String,
    val toolCall: JsonObject,
    val state: ApprovalState,
    val expiresAtMs: Long,
    val createdAtMs: Long,
    /**
     * shim 给的请求 id（和 `agent.permission_requested` 事件里的一样）。shim 每次尝试从 perm-1 重新编号，
     * 所以要用 [key]（`runId`、`attempt`、`requestId` 三个一起）认同一条审批。老数据为空串。
     */
    val requestId: String = "",
    /** 第几次尝试（和 `run.state` 事件的 `attempt` 一样）；0 是不知道（老数据）。 */
    val attempt: Int = 0,
    /** 选了哪个选项（`optionId`）；没处理、过期了的为 null。 */
    val decidedOption: String? = null,
    val decidedAtMs: Long? = null,
) {
    /** 认审批的关联键（docs/agent-integration.md 第 6 节）。 */
    val key: ApprovalKey get() = ApprovalKey(runId = runId, attempt = attempt, requestId = requestId)
}

/** 审批的关联键：`runId`、`attempt`、`requestId` 三个对上才是同一条审批。 */
data class ApprovalKey(val runId: String, val attempt: Int, val requestId: String)

sealed interface Schedule {
    /** 五段 cron，按 [tz]（IANA 名称）的本地时间。 */
    data class Cron(val expr: String, val tz: String) : Schedule

    /** iCalendar 的 DTSTART;TZID=...+RRULE。 */
    data class Rrule(val rule: String) : Schedule
    data class Once(val atMs: Long) : Schedule
}

data class Trigger(
    val id: String,
    val schedule: Schedule,
    val enabled: Boolean,
    val nextFireAtMs: Long?,
    val lastFireAtMs: Long?,
    /** 后台停用它的原因（规则失效）；没被停用时为 null。 */
    val disabledReason: TriggerDisabledReason? = null,
)

data class PlanStep(
    val key: String,
    val instanceId: String,
    val prompt: String,
    val dependsOn: List<String>,
)

data class Plan(
    val id: String,
    val instanceId: String,
    val title: String,
    val goal: String,
    val paused: Boolean,
    /** user / agent */
    val createdBy: String,
    val awaitingConfirmation: Boolean,
    val revision: Int,
    /** 策略的原始 JSON（client-core 为老版本 App 保留）；界面用 [policy]。 */
    val policyJson: String,
    val policy: PlanPolicy,
    /** 错过的触发怎么补。 */
    val catchUp: CatchUp,
    val createdAtMs: Long,
    /** 列表（plans）和详情（getPlan）里都有。 */
    val triggers: List<Trigger>,
    val steps: List<PlanStep>,
    /**
     * 下一次按时运行的名义时间（服务端算好的，实际可能因削峰晚几分钟）：在用的触发器里最早的；
     * 暂停了、等确认、没有会再触发的规则时为 null。
     */
    val nextFireAtMs: Long? = null,
    /** 规则失效、被后台停用的触发器个数：详情页提示“规则已失效”，给“修改规则”的入口。 */
    val invalidTriggers: Int = 0,
)

/**
 * 计划的策略（4.4、4.7、7.11）。默认值和服务端的默认策略一样：`PlanPolicy()` 就是默认策略。
 * 时长都是秒；null 表示不限。
 */
data class PlanPolicy(
    /** 预授权的工具种类（ACP 的 tool kind：read、edit、search、execute……），用到时不用审批。 */
    val preauthorizedTools: List<String> = emptyList(),
    val approvalTimeoutSecs: Long = DEFAULT_APPROVAL_TIMEOUT_SECS,
    /** 审批（和等电脑、等 key）超时以后怎么办。 */
    val onApprovalTimeout: ApprovalTimeoutAction = ApprovalTimeoutAction.PausePlan,
    /** 每次运行的上限：token 数、时长、步数。 */
    val maxTokens: Long? = null,
    val maxDurationSecs: Long = DEFAULT_MAX_DURATION_SECS,
    val maxSteps: Int? = null,
    /** 整个计划每天最多用多少 token。 */
    val dailyTokenLimit: Long? = null,
    /** 等电脑上线、等补上 key 最多等多久。 */
    val waitTimeoutSecs: Long = DEFAULT_WAIT_TIMEOUT_SECS,
) {
    companion object {
        const val DEFAULT_APPROVAL_TIMEOUT_SECS: Long = 86_400
        const val DEFAULT_MAX_DURATION_SECS: Long = 21_600
        const val DEFAULT_WAIT_TIMEOUT_SECS: Long = 86_400
    }
}

data class NewPlan(
    val instanceId: String,
    val title: String,
    val goal: String,
    val triggers: List<Schedule>,
    /** 给了就是流水线：按依赖顺序在各个实例上执行。 */
    val steps: List<PlanStep> = emptyList(),
    /** null 用默认策略。 */
    val policy: PlanPolicy? = null,
    /** null 用默认（[CatchUp.Once]）。 */
    val catchUp: CatchUp? = null,
)

/** 修改计划：给了才改（null 表示不改）。[steps] 整体替换，给空列表就变回单个 agent 的计划。 */
data class PlanChange(
    val title: String? = null,
    val goal: String? = null,
    val policy: PlanPolicy? = null,
    val catchUp: CatchUp? = null,
    val steps: List<PlanStep>? = null,
)

data class InboxItem(
    val id: String,
    val instanceId: String?,
    val runId: String?,
    val planId: String?,
    val approvalId: String?,
    val kind: InboxKind,
    val title: String,
    val body: String,
    val aiGenerated: Boolean,
    val read: Boolean,
    val createdAtMs: Long,
    /**
     * 是哪一种提醒（10.7）：account_frozen、account_restored、stopped_all、approval_skipped、trigger_disabled、
     * im_channel_disabled、report_handled；运行进入等待时是 [Run.waitCode] 的取值。和推送的 `tt.subtype` 一样。
     */
    val subtype: String? = null,
    /** 保险箱请求（[kind] 是 [InboxKind.VaultRequest] 时，`thinktin://vault/request/{id}`）。 */
    val vaultRequestId: String? = null,
)

data class InboxPage(val items: List<InboxItem>, val unread: Long)

data class Credential(
    val id: String,
    val vendor: String,
    val label: String,
    val last4: String,
    val dailyTokenLimit: Long?,
    val disabled: Boolean,
    val createdAtMs: Long,
    /** 能用哪些协议（anthropic、chat、responses）：给实例选 key 时要包含 agent 的 [AgentInfo.activeProtocol]。 */
    val protocols: List<String> = emptyList(),
)

data class NewCredential(
    val vendor: String,
    val label: String,
    val apiKey: String,
    val anthropicBase: String? = null,
    val openaiBase: String? = null,
    val responsesBase: String? = null,
    val dailyTokenLimit: Long? = null,
)

/** 修改 key：改备注、停用或重新启用；null 表示不改。换 key 本身用 replaceCredentialSecret。 */
data class CredentialUpdate(
    val label: String? = null,
    val disabled: Boolean? = null,
)

data class VendorInfo(
    val id: String,
    val name: String,
    val protocols: List<String>,
    val models: List<String>,
    val notes: String,
    /**
     * 订阅类 key 的前缀（11.9）：选这家时，key（去掉首尾空白）以其中一个开头（区分大小写）的服务端不收。
     * 空的就不用查。
     */
    val subscriptionKeyPrefixes: List<String> = emptyList(),
    /**
     * 这家套餐专用地址的前缀（11.9）：自定义接口的地址（去掉首尾空白、转小写）等于**任何一家**的其中一个、
     * 或者接着是 `/` 的，服务端不收。
     */
    val planOnlyBases: List<String> = emptyList(),
)

data class UsageBucket(
    val key: String,
    val requests: Long,
    val inputTokens: Long,
    val cacheReadTokens: Long,
    val cacheWriteTokens: Long,
    val outputTokens: Long,
    val chargedTokens: Long,
    val estimatedRequests: Long,
    val failedRequests: Long,
)

/**
 * 跨实例列运行的条件（[cn.thinktin.data.service.ThinktinService.listRuns]，11.8）。`RunFilter()` 是全部。
 */
data class RunFilter(
    /** 只要这个计划的（包括流水线的步骤；配合 [rootsOnly] 一次触发一行）。 */
    val planId: String? = null,
    /** 只要没结束的（排队、运行、等待、退避）：抽屉里的“进行中”。 */
    val activeOnly: Boolean = false,
    /** 只要根运行（不要流水线的步骤、委派的子任务）。 */
    val rootsOnly: Boolean = false,
)

data class UsageSummary(val buckets: List<UsageBucket>, val total: UsageBucket)

/** 用量的分组方式（usage 的 group 参数）。 */
enum class UsageGroup(val wire: String) {
    Day("day"),
    Instance("instance"),
    Model("model"),
    Credential("credential"),
}

data class StopAllResult(val runsCancelled: Long, val grantsRevoked: Long, val plansPaused: Long)

data class SignOutOthersResult(val devicesSignedOut: Long, val stopped: StopAllResult?)

data class DetectedSecret(
    /** private_key / url_password / api_key / token / labeled / high_entropy */
    val kind: String,
    /** UTF-16 下标（Kotlin String 下标）。 */
    val start: Int,
    val end: Int,
    val value: String,
    val suggestedName: String,
    val service: String,
    val storable: Boolean,
)

data class VaultItem(
    val id: String,
    val name: String,
    val purpose: String,
    val hasUsername: Boolean,
    val instanceIds: List<String>,
    val createdAtMs: Long,
    val updatedAtMs: Long,
    val lastUsedAtMs: Long?,
)

data class VaultItemDetail(val item: VaultItem, val username: String)

data class NewVaultItem(
    val name: String,
    val purpose: String,
    val username: String,
    val password: String,
    val instanceIds: List<String> = emptyList(),
)

data class VaultItemUpdate(
    val purpose: String? = null,
    val username: String? = null,
    val password: String? = null,
    val instanceIds: List<String>? = null,
)

data class SavedSecret(val item: VaultItem, val message: String)

data class VaultRequest(
    val id: String,
    val instanceId: String,
    val runId: String?,
    val name: String,
    val purpose: String,
    val fields: List<String>,
    val status: VaultRequestStatus,
    val itemId: String?,
    val createdAtMs: Long,
    val expiresAtMs: Long,
    val resolvedAtMs: Long?,
)

/** 登录着的一台设备（设置里的“登录设备”），最近活跃的在前。已吊销的不在列表里。 */
data class DeviceInfo(
    val id: String,
    val platform: DevicePlatform,
    val name: String,
    /** 推送通道（apns、fcm、unipush……）；没登记推送时为 null。 */
    val pushChannel: String?,
    /** 是不是正在用的这台。 */
    val current: Boolean,
    /** 电脑连着设备中继（14.1）；手机总是 false。 */
    val online: Boolean,
    val createdAtMs: Long,
    val lastSeenAtMs: Long,
)

/**
 * 手机和电脑之间经平台转发的一条消息（14.1，13.9 用）：配对应答、审批请求和决定、能力令牌、吊销。
 * 内容和签名的格式见 docs/pairing.md；[body] 是 [bodyJson] 解析后的对象（失败为空对象）。
 */
data class DeviceMessage(
    val id: String,
    val fromDeviceId: String,
    val toDeviceId: String,
    val kind: DeviceMessageKind,
    val bodyJson: String,
    val body: JsonObject,
    val createdAtMs: Long,
    val expiresAtMs: Long,
)

/** 团队里的一个实例。 */
data class TeamMember(
    val instanceId: String,
    /** 负责人（一个团队一个）或成员。 */
    val role: TeamRole,
    /** 显示顺序。 */
    val position: Int,
)

/** 团队（8.1）：几个实例编成一组，负责人分工。 */
data class Team(
    val id: String,
    val name: String,
    val members: List<TeamMember>,
    val createdAtMs: Long,
)

/** 团队模板里的一个成员：领养时用这个 agent 新领养一个实例。 */
data class TemplateMember(
    val agentId: String,
    /** 接入方式（同一个 agent 的几种）；null 用默认的。 */
    val harness: String?,
    val name: String,
    val role: TeamRole,
)

/** 团队模板：一键领养一整个团队。 */
data class TeamTemplate(
    val id: String,
    val name: String,
    val members: List<TemplateMember>,
    val createdAtMs: Long,
)

/** IM 群机器人（10.5，13.15 的界面）。token 和签名密钥服务端从不返回，[hint] 是 token 后 4 位。 */
data class ImChannel(
    val id: String,
    /** feishu、lark、wecom、dingtalk。 */
    val vendor: String,
    val label: String,
    val hint: String,
    val hasSecret: Boolean,
    /** run_finished、run_failed、approval 中的若干个。 */
    val events: List<String>,
    val enabled: Boolean,
    val lastSentAtMs: Long?,
    /** 最近一次推送失败的原因（服务端诊断，英文，不是本地化文案）。 */
    val lastError: String?,
    val createdAtMs: Long,
)

data class NewImChannel(
    val webhookUrl: String,
    val secret: String? = null,
    val label: String,
    /** null 表示全部事件。 */
    val events: List<String>? = null,
)

/** 修改 IM 渠道；null 表示不改。 */
data class ImChannelUpdate(
    val label: String? = null,
    val events: List<String>? = null,
    val enabled: Boolean? = null,
)

/** 一条内容举报（5.5）和它的处理结果（处理完也会发到收件箱和推送）。 */
data class ContentReport(
    val id: String,
    val runId: String,
    val instanceId: String,
    /** 举报的那条事件；null 表示举报产出物或整个运行。 */
    val eventSeq: Long?,
    val artifactId: String?,
    val reason: ReportReason,
    val note: String?,
    val state: ReportState,
    val resolution: String?,
    val createdAtMs: Long,
    val handledAtMs: Long?,
)
