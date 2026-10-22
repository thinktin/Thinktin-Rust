package cn.thinktin.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/*
 * 审批卡片的数据（13.16，docs/android-design.md 第 4.3、8.5 节，docs/agent-integration.md 第 6 节）。
 *
 * 审批中心直接从审批记录（approvals() / getApproval）出卡片；对话页（13.5）从事件流里的
 * `agent.permission_requested` / `agent.permission_resolved` / `approval.decided` 出卡片，再和审批记录
 * 按 (run_id, attempt, request_id) 对上（[ApprovalCards.reconcile]），对上了才能提交决定。
 */

/** 谁做的决定（`agent.permission_resolved` 的 `by`；审批记录按状态推出来，见 [Approval.decisionSource]）。 */
enum class DecisionSource(override val wire: String) : WireEnum {
    /** 预授权策略直接决定（没有审批记录，也不会出 `permission_requested`）。 */
    Policy("policy"),
    User("user"),

    /** 平台判的超时（`approval_state` 是 expired 时，哪怕 `by` 是 user 也算这个）。 */
    Timeout("timeout"),

    /** 尝试结束、运行停了：没人回答。 */
    Cancelled("cancelled"),
    Unknown(""),
    ;

    companion object {
        fun fromWire(value: String?): DecisionSource = parseWire(value.orEmpty(), Unknown)
    }
}

/** 卡片的状态。[Superseded] 是 App 自己判的：待处理，但运行已经开始了更新的尝试（这条请求不会再有人等）。 */
enum class ApprovalCardStatus {
    Pending,
    Approved,
    Rejected,
    Expired,
    Cancelled,

    /** 作废：`attempt` 比运行当前的尝试小（那次尝试结束时没处理的审批会被取消）。 */
    Superseded,
    Unknown,
    ;

    val isFinal: Boolean get() = this != Pending
}

/** 选项是拒绝类的（拒绝不用生物识别）。不认识的 kind 不算拒绝：按批准处理，要验证。 */
val OptionKind.isReject: Boolean get() = this == OptionKind.RejectOnce || this == OptionKind.RejectAlways

/** 工具调用的摘要：标题、类别（read / edit / execute……）、参数的一句话、原始 JSON（排好版，展开时显示）。 */
data class ToolCallSummary(
    val title: String?,
    val kind: String?,
    val arguments: String?,
    val rawJson: String,
) {
    val isEmpty: Boolean get() = title == null && kind == null && arguments == null

    companion object {
        val EMPTY = ToolCallSummary(null, null, null, "")

        private val pretty = Json { prettyPrint = true }

        /** 参数里最能说明“要干什么”的字段，按顺序找第一个。 */
        private val KEY_ARGUMENTS = listOf(
            "command", "cmd", "path", "file_path", "filePath", "url", "query", "pattern", "old_path", "target",
        )

        /** 一句话摘要的上限（字符）；原始 JSON 不截。 */
        const val MAX_ARGUMENTS = 200

        /**
         * 从工具调用 JSON（ACP 的 ToolCallUpdate：`title`、`kind`、`rawInput`、`locations`……；驼峰和下划线都认）
         * 取摘要。[raw] 是原文（审批记录的 `tool_call_json`），为空时用 [toolCall] 序列化。
         */
        fun of(toolCall: JsonObject, raw: String? = null): ToolCallSummary {
            if (toolCall.isEmpty() && raw.isNullOrBlank()) return EMPTY
            val title = toolCall.string("title")?.takeIf { it.isNotBlank() }
            val kind = toolCall.string("kind")?.takeIf { it.isNotBlank() }
            val input = toolCall["rawInput"] ?: toolCall["raw_input"] ?: toolCall["input"] ?: toolCall["arguments"]
            val arguments = summarize(input)
                ?: (toolCall["locations"] as? JsonArray)?.firstNotNullOfOrNull { (it as? JsonObject)?.string("path") }
            val rawJson = if (toolCall.isEmpty()) raw.orEmpty() else pretty.encodeToString(JsonElement.serializer(), toolCall)
            return ToolCallSummary(title, kind, arguments?.let(::clip), rawJson)
        }

        private fun summarize(input: JsonElement?): String? = when (input) {
            null, JsonNull -> null
            is JsonPrimitive -> input.content.takeIf { it.isNotBlank() }
            is JsonArray -> input.joinToString(" ") { (it as? JsonPrimitive)?.content ?: it.toString() }.takeIf { it.isNotBlank() }
            is JsonObject -> {
                val key = KEY_ARGUMENTS.firstOrNull { k -> input[k].let { it is JsonPrimitive && it.content.isNotBlank() } }
                if (key != null) {
                    val value = input[key]
                    if (value is JsonPrimitive) value.content else null
                } else {
                    input.entries.take(3).joinToString(", ") { (k, v) ->
                        "$k=" + ((v as? JsonPrimitive)?.content ?: v.toString())
                    }.takeIf { it.isNotBlank() }
                }
            }
        }

        private fun clip(text: String): String {
            val oneLine = text.replace('\n', ' ').trim()
            return if (oneLine.length <= MAX_ARGUMENTS) oneLine else oneLine.take(MAX_ARGUMENTS - 1) + "…"
        }
    }
}

/**
 * 一张审批卡片。审批中心和对话页共用：
 * - [approval] 是对上的审批记录（有它才能 [decideApproval][cn.thinktin.data.service.ThinktinService.decideApproval]）；
 *   只从事件里来、还没对上记录的为 null（比如建审批失败的请求，事件里只有 `attempt`）。
 * - [title] 是 agent 写的（界面标 AI 生成，第 8.4 节）。
 */
data class ApprovalCardData(
    val key: ApprovalKey,
    val approvalId: String?,
    val instanceId: String?,
    val title: String?,
    val options: List<ApprovalOption>,
    val toolCall: ToolCallSummary,
    val status: ApprovalCardStatus,
    /** 选了哪个选项（`option_id`）。 */
    val decidedOption: String? = null,
    val decidedBy: DecisionSource? = null,
    val decidedAtMs: Long? = null,
    val createdAtMs: Long? = null,
    val expiresAtMs: Long? = null,
    val approval: Approval? = null,
) {
    /** 现在能批准 / 拒绝：卡片待处理，而且对上了还在待处理的审批记录。 */
    val canDecide: Boolean
        get() = status == ApprovalCardStatus.Pending && approval?.state == ApprovalState.Pending

    val decidedOptionInfo: ApprovalOption? get() = options.firstOrNull { it.optionId == decidedOption }
}

/** 审批记录是谁决定的：批准 / 拒绝只能是用户（策略决定的不建记录）；过期是平台超时；取消是尝试结束了。 */
val Approval.decisionSource: DecisionSource?
    get() = when (state) {
        ApprovalState.Approved, ApprovalState.Rejected -> DecisionSource.User
        ApprovalState.Expired -> DecisionSource.Timeout
        ApprovalState.Cancelled -> DecisionSource.Cancelled
        ApprovalState.Pending, ApprovalState.Unknown -> null
    }

/**
 * 同一条审批：`runId`、`requestId` 相等，`attempt` 相等。老数据的 `attempt` 是 0（不知道），这时只比另外两个；
 * `requestId` 为空（老数据）的认不出来，只能按审批 id 对。
 */
fun ApprovalKey.matches(other: ApprovalKey): Boolean =
    requestId.isNotEmpty() && runId == other.runId && requestId == other.requestId &&
        (attempt == other.attempt || attempt == 0 || other.attempt == 0)

/** 运行已经到了 [currentAttempt] 次尝试，这张 [attempt] 次的待处理卡片作废。 */
fun isSuperseded(attempt: Int, currentAttempt: Int?): Boolean =
    attempt > 0 && currentAttempt != null && currentAttempt > attempt

object ApprovalCards {
    /** 审批记录 → 卡片。[currentAttempt] 是运行当前的尝试（知道时传，用来判作废）。 */
    fun fromApproval(approval: Approval, currentAttempt: Int? = null): ApprovalCardData {
        val status = approval.cardStatus()
        return ApprovalCardData(
            key = approval.key,
            approvalId = approval.id,
            instanceId = approval.instanceId,
            title = approval.title?.takeIf { it.isNotBlank() },
            options = approval.options,
            toolCall = ToolCallSummary.of(approval.toolCall, approval.toolCallJson),
            status = if (status == ApprovalCardStatus.Pending && isSuperseded(approval.attempt, currentAttempt)) {
                ApprovalCardStatus.Superseded
            } else {
                status
            },
            decidedOption = approval.decidedOption,
            decidedBy = approval.decisionSource,
            decidedAtMs = approval.decidedAtMs,
            createdAtMs = approval.createdAtMs,
            expiresAtMs = approval.expiresAtMs,
            approval = approval,
        )
    }

    /**
     * 对话页（13.5）：一个实例的事件（任意顺序，按 seq 处理）+ 审批记录 → 卡片，按出现的先后排。
     *
     * - `agent.permission_requested` 出卡片，键是 (run_id, attempt, request_id)；
     * - `agent.permission_resolved`：有 `approval_state` 时以它为准（平台判的超时 `by` 是 user、`approval_state` 是
     *   expired），没有时按 `by` 和选项的 kind；按策略直接决定的没有请求，不出卡片；
     * - `approval.decided`：用户在别处（另一台设备、通知）做的决定；
     * - [approvals]（`approvals()` 的待处理列表、`getApproval` 查到的）按键或审批 id 对上卡片，补上审批 id、
     *   到期时间和完整的工具调用；没对上任何事件的（事件还没加载到）单独出卡片。事件已经是终态的，记录里的
     *   “待处理”不会把它改回去（列表比事件旧）。
     * - [runAttempts] 是各运行当前的尝试（`Run.attempt`）；事件里 `run.state` 的 `attempt` 也算，取大的。
     *   待处理的卡片 attempt 比它小就作废（[ApprovalCardStatus.Superseded]）。
     */
    fun reconcile(
        events: List<InstanceEvent>,
        approvals: List<Approval> = emptyList(),
        runAttempts: Map<String, Int> = emptyMap(),
    ): List<ApprovalCardData> {
        val attempts = runAttempts.toMutableMap()
        val cards = mutableListOf<ApprovalCardData>()

        fun indexOf(key: ApprovalKey?, approvalId: String?): Int {
            if (approvalId != null) {
                val byId = cards.indexOfFirst { it.approvalId == approvalId }
                if (byId >= 0) return byId
            }
            if (key == null) return -1
            // 同一个键可能出现多次（同一尝试里重发）：取最后一张。
            return cards.indexOfLast { it.key.matches(key) }
        }

        for (event in events.sortedBy { it.seq }) {
            val p = event.payload
            val runId = event.runId ?: p.string("run_id")
            val attempt = p.long("attempt")?.toInt() ?: 0
            when (event.kind) {
                EventKinds.RUN_STATE -> if (runId != null && attempt > 0) {
                    attempts[runId] = maxOf(attempts[runId] ?: 0, attempt)
                }
                EventKinds.AGENT_PERMISSION_REQUESTED -> {
                    val requestId = p.string("request_id") ?: continue
                    if (runId == null) continue
                    val key = ApprovalKey(runId, attempt, requestId)
                    val toolCall = p.obj("tool_call") ?: EmptyJsonObject
                    val card = ApprovalCardData(
                        key = key,
                        approvalId = p.string("approval_id"),
                        instanceId = event.instanceId,
                        title = p.string("title")?.takeIf { it.isNotBlank() },
                        options = parseOptions(p),
                        toolCall = ToolCallSummary.of(toolCall),
                        status = ApprovalCardStatus.Pending,
                        createdAtMs = event.createdAtMs,
                    )
                    val i = cards.indexOfFirst { it.key == key && it.status == ApprovalCardStatus.Pending }
                    if (i >= 0) cards[i] = card else cards += card
                }
                EventKinds.AGENT_PERMISSION_RESOLVED -> {
                    val requestId = p.string("request_id") ?: continue
                    val key = runId?.let { ApprovalKey(it, attempt, requestId) }
                    val i = indexOf(key, p.string("approval_id"))
                    if (i < 0) continue // 按策略直接决定的：没有请求，不出卡片
                    val card = cards[i]
                    val optionId = p.string("option_id")
                    val by = DecisionSource.fromWire(p.string("by"))
                    val approvalState = p.string("approval_state")?.let(ApprovalState::fromWire)
                    val (status, source) = resolvedStatus(card, optionId, by, approvalState)
                    cards[i] = card.copy(
                        status = status,
                        decidedOption = optionId ?: card.decidedOption,
                        decidedBy = source,
                        decidedAtMs = event.createdAtMs,
                        approvalId = card.approvalId ?: p.string("approval_id"),
                    )
                }
                EventKinds.APPROVAL_DECIDED -> {
                    val requestId = p.string("request_id")
                    val key = if (runId != null && requestId != null) ApprovalKey(runId, attempt, requestId) else null
                    val approvalId = p.string("approval_id")
                    val i = indexOf(key, approvalId)
                    if (i < 0) continue
                    val state = ApprovalState.fromWire(p.string("state").orEmpty())
                    val status = state.toCardStatus()
                    if (status == ApprovalCardStatus.Pending || status == ApprovalCardStatus.Unknown) continue
                    val card = cards[i]
                    cards[i] = card.copy(
                        status = status,
                        decidedOption = p.string("option_id") ?: card.decidedOption,
                        decidedBy = if (state == ApprovalState.Expired) DecisionSource.Timeout else DecisionSource.User,
                        decidedAtMs = event.createdAtMs,
                        approvalId = card.approvalId ?: approvalId,
                    )
                }
            }
        }

        for (approval in approvals) {
            val i = indexOf(approval.key, approval.id)
            if (i < 0) {
                cards += fromApproval(approval)
                continue
            }
            val card = cards[i]
            val fromRecord = fromApproval(approval)
            val merged = card.copy(
                approvalId = approval.id,
                instanceId = card.instanceId ?: approval.instanceId,
                title = card.title ?: fromRecord.title,
                options = approval.options.ifEmpty { card.options },
                toolCall = if (fromRecord.toolCall.isEmpty) card.toolCall else fromRecord.toolCall,
                createdAtMs = card.createdAtMs ?: approval.createdAtMs,
                expiresAtMs = approval.expiresAtMs,
                approval = approval,
            )
            cards[i] = if (card.status == ApprovalCardStatus.Pending && fromRecord.status != ApprovalCardStatus.Pending) {
                merged.copy(
                    status = fromRecord.status,
                    decidedOption = fromRecord.decidedOption ?: card.decidedOption,
                    decidedBy = fromRecord.decidedBy,
                    decidedAtMs = fromRecord.decidedAtMs ?: card.decidedAtMs,
                )
            } else {
                merged
            }
        }

        return cards
            .map { card ->
                if (card.status == ApprovalCardStatus.Pending && isSuperseded(card.key.attempt, attempts[card.key.runId])) {
                    card.copy(status = ApprovalCardStatus.Superseded)
                } else {
                    card
                }
            }
            .withIndex()
            .sortedWith(compareBy({ it.value.createdAtMs ?: Long.MAX_VALUE }, { it.index }))
            .map { it.value }
    }

    /**
     * 决定之后（[decided] 是 decideApproval / getApproval 返回的记录）更新卡片，保留事件里来的东西。
     * [currentAttempt] 同 [fromApproval]（记录还是待处理时判作废）。
     */
    fun applyDecision(card: ApprovalCardData, decided: Approval, currentAttempt: Int? = null): ApprovalCardData =
        fromApproval(decided, currentAttempt).let { fromRecord ->
            card.copy(
                approvalId = decided.id,
                status = fromRecord.status,
                decidedOption = fromRecord.decidedOption,
                decidedBy = fromRecord.decidedBy,
                decidedAtMs = fromRecord.decidedAtMs,
                expiresAtMs = decided.expiresAtMs,
                approval = decided,
            )
        }

    private fun parseOptions(payload: JsonObject): List<ApprovalOption> =
        payload.array("options").mapNotNull { element ->
            val o = element as? JsonObject ?: return@mapNotNull null
            val id = o.string("option_id") ?: o.string("optionId") ?: return@mapNotNull null
            ApprovalOption(id, o.string("name").orEmpty(), OptionKind.fromWire(o.string("kind").orEmpty()))
        }

    private fun resolvedStatus(
        card: ApprovalCardData,
        optionId: String?,
        by: DecisionSource,
        approvalState: ApprovalState?,
    ): Pair<ApprovalCardStatus, DecisionSource> {
        if (approvalState != null && approvalState != ApprovalState.Unknown && approvalState != ApprovalState.Pending) {
            val source = when (approvalState) {
                ApprovalState.Expired -> DecisionSource.Timeout
                ApprovalState.Cancelled -> DecisionSource.Cancelled
                else -> if (by == DecisionSource.Unknown) DecisionSource.User else by
            }
            return approvalState.toCardStatus() to source
        }
        return when (by) {
            DecisionSource.Timeout -> ApprovalCardStatus.Expired to by
            DecisionSource.Cancelled -> ApprovalCardStatus.Cancelled to by
            else -> {
                val kind = card.options.firstOrNull { it.optionId == optionId }?.kind
                val status = when {
                    optionId == null -> ApprovalCardStatus.Cancelled
                    kind?.isReject == true -> ApprovalCardStatus.Rejected
                    else -> ApprovalCardStatus.Approved
                }
                status to (if (optionId == null) DecisionSource.Cancelled else by)
            }
        }
    }

    private fun Approval.cardStatus(): ApprovalCardStatus = state.toCardStatus()

    private fun ApprovalState.toCardStatus(): ApprovalCardStatus = when (this) {
        ApprovalState.Pending -> ApprovalCardStatus.Pending
        ApprovalState.Approved -> ApprovalCardStatus.Approved
        ApprovalState.Rejected -> ApprovalCardStatus.Rejected
        ApprovalState.Expired -> ApprovalCardStatus.Expired
        ApprovalState.Cancelled -> ApprovalCardStatus.Cancelled
        ApprovalState.Unknown -> ApprovalCardStatus.Unknown
    }
}
