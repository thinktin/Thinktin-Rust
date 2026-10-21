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
    data object Stopped : StreamState
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
)

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
    val policyJson: String,
    val policy: JsonObject,
    val createdAtMs: Long,
    val triggers: List<Trigger>,
    val steps: List<PlanStep>,
) {
    /** 最近一次要触发的时间（启用的触发器里最早的）。 */
    val nextFireAtMs: Long?
        get() = triggers.filter { it.enabled }.mapNotNull { it.nextFireAtMs }.minOrNull()
}

data class NewPlan(
    val instanceId: String,
    val title: String,
    val goal: String,
    val triggers: List<Schedule>,
    val steps: List<PlanStep> = emptyList(),
)

/** 修改计划（服务端 PATCH /v1/plans/{id}；client-core 还没有）。null 表示不改。 */
data class PlanUpdate(
    val title: String? = null,
    val goal: String? = null,
    val policyJson: String? = null,
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

/** 修改 key（服务端 PATCH /v1/credentials/{id}；client-core 还没有）。null 表示不改。 */
data class CredentialUpdate(
    val label: String? = null,
    val dailyTokenLimit: Long? = null,
    val disabled: Boolean? = null,
)

data class VendorInfo(
    val id: String,
    val name: String,
    val protocols: List<String>,
    val models: List<String>,
    val notes: String,
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

/** 登录过的设备（服务端 GET /v1/devices；client-core 还没有）。 */
data class Device(
    val id: String,
    val platform: DevicePlatform,
    val name: String,
    val current: Boolean,
    val createdAtMs: Long,
    val lastSeenAtMs: Long,
    val revokedAtMs: Long?,
)

data class TeamMember(val instanceId: String, val role: TeamRole, val position: Int)

/** 团队（服务端 /v1/teams；client-core 还没有）。 */
data class Team(
    val id: String,
    val name: String,
    val members: List<TeamMember>,
    val createdAtMs: Long,
)

data class TemplateMember(val agentId: String, val harness: String?, val name: String, val role: TeamRole)

/** 团队模板（服务端 /v1/team-templates；client-core 还没有）。 */
data class TeamTemplate(
    val id: String,
    val name: String,
    val members: List<TemplateMember>,
    val createdAtMs: Long,
)
