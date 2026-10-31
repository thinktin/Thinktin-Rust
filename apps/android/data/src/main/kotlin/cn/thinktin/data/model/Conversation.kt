package cn.thinktin.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull

/*
 * 对话页（13.5）的时间线：把一个实例的运行（Run）和事件（InstanceEvent）归并成按运行分组的条目
 * （docs/android-design.md 第 4.3、8.2、8.4 节）。纯函数，界面只管画 [Conversation]。
 *
 * - 按 run_id 归到运行区块，区块内按 seq；seq 重复的只算一次，乱序的先排好。
 * - 连续的 agent.message 拼成一段，连续的 agent.thought 拼成一个折叠块；tool_call + tool_call_update 按
 *   tool_call_id 合成一张卡；审批事件交给 [ApprovalCards.reconcile] 按 (run_id, attempt, request_id) 对上审批记录；
 *   vault.requested / fulfilled / declined 合成一张填写请求卡。
 * - agent.usage、turn_started、turn_ended、ready、update、instance.state 不进时间线（turn_ended 结束流式状态，
 *   usage 记在区块上给运行详情用）；不认识的 kind 显示成灰色系统行。payload 缺字段、类型不对都不崩。
 */

/** 工具调用的状态（agent.tool_call / agent.tool_call_update 的 status）。不认识的按 [Pending]。 */
enum class ToolCallState(override val wire: String) : WireEnum {
    Pending("pending"),
    InProgress("in_progress"),
    Completed("completed"),
    Failed("failed"),
    ;

    companion object {
        fun fromWire(value: String?): ToolCallState = parseWire(value.orEmpty(), Pending)
    }
}

/** 运行区块里用户那句话是谁写的（[Run.source]）。委派子运行的 prompt 是负责人 agent 写的，不能显示成“你”。 */
enum class PromptAuthor {
    User,
    Plan,
    Pipeline,
    Delegate,
    Unknown,
    ;

    companion object {
        fun of(source: RunSource): PromptAuthor = when (source) {
            RunSource.User -> User
            RunSource.Plan -> Plan
            RunSource.Pipeline -> Pipeline
            RunSource.Delegate -> Delegate
            RunSource.Unknown -> Unknown
        }
    }
}

/** 运行的过程记录缺了一段：只能显示 prompt、summary、error。 */
enum class HistoryGap {
    None,

    /** 事件流重置过（on_reset），这个运行比保留期早：过程记录已超过保留期。 */
    Expired,

    /** 本机缓存翻到头了也没有它的事件（缓存每个实例只留最近的一部分）。 */
    Missing,
}

/** agent 计划清单里的一项（agent.plan 的 entries，ACP 的 PlanEntry）。 */
data class PlanEntry(val content: String, val status: String, val priority: String?) {
    val done: Boolean get() = status == "completed"
    val inProgress: Boolean get() = status == "in_progress"
}

/** 一次 run.state 之外、需要单独说明的系统行（灰色小字；[isError] 用错误色）。 */
sealed interface SystemLine {
    val isError: Boolean get() = false

    /** agent.error：agent 或 shim 报的错（原文，不是本地化文案）。 */
    data class AgentError(val message: String?) : SystemLine {
        override val isError: Boolean get() = true
    }

    /** agent.session_lost：之前的会话接不回来，开了新会话。 */
    data class SessionLost(val reason: String?) : SystemLine

    /** agent.exited：agent 进程退出；[willRestart] 时会自动重启。 */
    data class Exited(val code: Long?, val willRestart: Boolean) : SystemLine

    /** run.log_truncated：日志超出上限，后续输出未记录。 */
    data class LogTruncated(val limitBytes: Long?) : SystemLine

    /** agent.turn_ended 的异常 stop_reason（max_tokens、max_turn_requests、refusal）。 */
    data class TurnStopped(val stopReason: String) : SystemLine

    /** 不认识的 kind（服务端以后加的）。 */
    data class Unknown(val kind: String) : SystemLine
}

/** 时间线上的一条。[key] 在整个对话里唯一（LazyColumn 的 key）。 */
sealed interface TimelineItem {
    val key: String

    /** 用户那句话（[Run.prompt]，不在事件流里）。委派、流水线步骤的是 agent 写的或带着上游摘要：[aiGenerated]。 */
    data class Prompt(
        override val key: String,
        val runId: String,
        val text: String,
        val author: PromptAuthor,
    ) : TimelineItem {
        /** 第 8.4 节：委派子运行的 prompt 是负责人 agent 写的；流水线步骤的 prompt 里附带上游摘要。 */
        val aiGenerated: Boolean get() = author == PromptAuthor.Delegate || author == PromptAuthor.Pipeline

        /** 用户自己说的（右侧气泡，“你”）。 */
        val fromUser: Boolean get() = author == PromptAuthor.User
    }

    /** agent 的回复（相邻的 agent.message 拼好的 Markdown）。 */
    data class AgentText(
        override val key: String,
        val text: String,
        val aiGenerated: Boolean,
        val firstSeq: Long,
    ) : TimelineItem

    /** 思考过程（默认收起）。 */
    data class Thought(override val key: String, val text: String, val aiGenerated: Boolean) : TimelineItem

    /** 工具调用卡片：[title] 是 agent 写的（标 AI 生成）；[rawJson] 是展开后显示的原始内容（排好版）。 */
    data class ToolCall(
        override val key: String,
        val toolCallId: String,
        val title: String?,
        val kind: String?,
        val status: ToolCallState,
        val summary: ToolCallSummary,
        val rawJson: String,
    ) : TimelineItem

    /** 平台工具调用（schedule_*、artifact_*、delegate……）：[title] 是参数里 agent 写的标题。 */
    data class PlatformToolCall(
        override val key: String,
        val callId: String,
        val name: String,
        val title: String?,
        val rawJson: String,
    ) : TimelineItem

    /** agent 的计划清单。 */
    data class AgentPlan(override val key: String, val entries: List<PlanEntry>, val aiGenerated: Boolean) : TimelineItem

    /** 审批卡片（13.16 的 [ApprovalCardData]）。 */
    data class ApprovalCard(override val key: String, val card: ApprovalCardData) : TimelineItem

    /**
     * agent 的账号密码填写请求（vault.requested）：[purpose] 是 agent 写的（标 AI 生成）。
     * [request] 是对上的保险箱请求记录（有它才知道过期时间）。
     */
    data class VaultRequestCard(
        override val key: String,
        val requestId: String,
        val name: String,
        val purpose: String?,
        val fields: List<String>,
        val status: VaultRequestStatus,
        val request: VaultRequest? = null,
    ) : TimelineItem

    /** “使用了保险箱：名字”（agent.vault_reveal、vault.used）。 */
    data class VaultUsed(override val key: String, val names: List<String>) : TimelineItem

    /** 产出物卡片（artifact.published）。 */
    data class Artifact(
        override val key: String,
        val artifactId: String,
        val name: String,
        val version: Int,
        val size: Long?,
    ) : TimelineItem

    /** 子运行入口（pipeline.step_started、delegate.started）：点进运行树。[title] 是委派时 agent 写的标题。 */
    data class ChildRun(
        override val key: String,
        val childRunId: String,
        val instanceId: String?,
        val delegated: Boolean,
        val step: String?,
        val to: String?,
        val title: String?,
    ) : TimelineItem

    /**
     * 运行状态行（run.state 里值得说一句的：等待、重试、失败、取消、新的一次尝试）。[reason] 不是本地化文案：
     * waiting_quota 的是服务端按用户语言写的，waiting_approval 的是 agent 写的审批标题（[reasonAiGenerated]），
     * 失败原因是英文诊断。
     */
    data class RunStateLine(
        override val key: String,
        val state: RunState,
        val attempt: Int,
        val reason: String?,
        val waitCode: WaitCode?,
        val steps: Int?,
        /** 进入了新的一次尝试（第 [attempt] 次）。 */
        val newAttempt: Boolean,
    ) : TimelineItem {
        val reasonAiGenerated: Boolean get() = state == RunState.WaitingApproval
    }

    /** 计划卡片（plan.needs_confirmation 带“去确认”；plan.cancelled 只是告知）。 */
    data class PlanCard(
        override val key: String,
        val planId: String,
        val title: String?,
        val change: String?,
        val needsConfirmation: Boolean,
    ) : TimelineItem

    /** 系统提示行。 */
    data class System(override val key: String, val line: SystemLine) : TimelineItem
}

/** 一个运行区块。[run] 为 null：事件里有、运行列表里还没有（新建的、别的设备发的；ViewModel 会去取）。 */
data class RunBlock(
    val runId: String,
    val run: Run?,
    /** 当前状态：运行已结束时以 [Run.state] 为准，否则以最新的 run.state 事件为准。 */
    val state: RunState,
    val attempt: Int,
    val stateReason: String?,
    val waitCode: WaitCode?,
    val items: List<TimelineItem>,
    /** agent 正在这一轮里（turn_started 之后、turn_ended 之前，运行没结束）。 */
    val streaming: Boolean,
    /** 最近一次 agent.usage 的 raw（运行详情显示；不进时间线）。 */
    val usage: JsonObject?,
    val history: HistoryGap,
    val createdAtMs: Long,
) {
    val prompt: TimelineItem.Prompt? get() = items.firstOrNull() as? TimelineItem.Prompt

    /** 区块里的审批卡片。 */
    val approvalCards: List<ApprovalCardData>
        get() = items.mapNotNull { (it as? TimelineItem.ApprovalCard)?.card }
}

/** 对话的一段：一个运行区块，或不属于任何运行的一条（计划卡、没有 run_id 的填写请求、系统行）。 */
sealed interface ConversationSection {
    val key: String
    val timeMs: Long

    data class RunSection(val block: RunBlock) : ConversationSection {
        override val key: String get() = "run/${block.runId}"
        override val timeMs: Long get() = block.createdAtMs
    }

    data class Loose(val item: TimelineItem, override val timeMs: Long) : ConversationSection {
        override val key: String get() = item.key
    }
}

/** 归并的结果，旧的在前。 */
data class Conversation(val sections: List<ConversationSection> = emptyList()) {
    val blocks: List<RunBlock> get() = sections.mapNotNull { (it as? ConversationSection.RunSection)?.block }

    fun block(runId: String): RunBlock? = blocks.firstOrNull { it.runId == runId }

    /** 最新的还在进行的运行（输入框的停止按钮停它）。 */
    val activeBlock: RunBlock? get() = blocks.lastOrNull { it.state.isActive }

    /** 最新的在等用户处理的运行（等审批 / 等 key / 等电脑：警告色横幅）。 */
    val attentionBlock: RunBlock? get() = blocks.lastOrNull { it.state.needsAttention }

    /** 全部审批卡片（按出现顺序）。 */
    val approvalCards: List<ApprovalCardData>
        get() = sections.flatMap { section ->
            when (section) {
                is ConversationSection.RunSection -> section.block.approvalCards
                is ConversationSection.Loose -> listOfNotNull((section.item as? TimelineItem.ApprovalCard)?.card)
            }
        }

    val isEmpty: Boolean get() = sections.isEmpty()
}

/** 事件的加载范围（翻页、on_reset）：决定哪些运行显示、哪些标注“没有过程记录”。 */
data class HistoryWindow(
    /** 本机缓存往前翻到头了：更早的事件本机没有。 */
    val exhausted: Boolean = false,
    /** 事件流重置过（on_reset 的 oldest_seq）：比它早的运行没有过程记录（超过保留期）。 */
    val resetOldestSeq: Long? = null,
)

object ConversationBuilder {
    /** agent 写的文字里 ai_generated 为真的 kind（proto::labels::is_ai_generated_event）。 */
    val AI_GENERATED_KINDS: Set<String> = setOf(EventKinds.AGENT_MESSAGE, EventKinds.AGENT_THOUGHT, EventKinds.AGENT_PLAN)

    /** 有这些就说明 agent 这一轮在进行（照 iOS reducer 的 markActive）：审批通过后接着流、加载窗口从一轮中间开始时都没有 turn_started。 */
    private val OUTPUT_KINDS: Set<String> = setOf(
        EventKinds.AGENT_MESSAGE, EventKinds.AGENT_THOUGHT, EventKinds.AGENT_TOOL_CALL, EventKinds.AGENT_TOOL_CALL_UPDATE,
        EventKinds.AGENT_PLATFORM_TOOL_CALL,
    )

    /** 不进时间线的 kind。 */
    val HIDDEN_KINDS: Set<String> = setOf(
        EventKinds.AGENT_USAGE, EventKinds.AGENT_TURN_STARTED, EventKinds.AGENT_TURN_ENDED, EventKinds.AGENT_READY,
        EventKinds.AGENT_UPDATE, EventKinds.APPROVAL_DECIDED, EventKinds.AGENT_PERMISSION_RESOLVED, INSTANCE_STATE,
    )

    const val INSTANCE_STATE = "instance.state"

    /** 异常结束、要说一句的 stop_reason。 */
    private val NOTABLE_STOP_REASONS = setOf("max_tokens", "max_turn_requests", "refusal")

    /** 要出状态行的运行状态（成功、运行中由区块头表示）。 */
    private val STATE_LINE_STATES = setOf(
        RunState.WaitingApproval, RunState.WaitingDevice, RunState.WaitingQuota, RunState.WaitingChildren,
        RunState.Backoff, RunState.Failed, RunState.Cancelled,
    )

    private val pretty = Json { prettyPrint = true }

    /**
     * 归并。[runs]、[events] 顺序随意（事件按 seq 去重排好）；[approvals] 是审批记录（待处理列表、决定后的记录），
     * [vaultRequests] 是保险箱请求记录（状态、过期时间）；[window] 见 [HistoryWindow]。
     */
    fun build(
        runs: Collection<Run>,
        events: Collection<InstanceEvent>,
        approvals: List<Approval> = emptyList(),
        vaultRequests: List<VaultRequest> = emptyList(),
        window: HistoryWindow = HistoryWindow(),
    ): Conversation {
        val sorted = events.sortedBy { it.seq }.distinctBy { it.seq }
        val runById = runs.associateBy { it.id }
        val accumulators = LinkedHashMap<String, Accumulator>()
        val loose = Accumulator(scope = "instance", runId = null)

        for (event in sorted) {
            val runId = event.runId ?: event.payload.string("run_id")?.takeIf { event.kind != EventKinds.PIPELINE_STEP_STARTED }
            val acc = if (runId == null) loose else accumulators.getOrPut(runId) { Accumulator("run/$runId", runId) }
            acc.apply(event)
        }

        // 审批卡片：事件里的请求和审批记录对上（关联键、作废、超时以 approval_state 为准）。
        val cards = ApprovalCards.reconcile(sorted, approvals, runById.mapValues { it.value.attempt })
        val used = mutableSetOf<Int>()
        (accumulators.values + loose).forEach { acc -> acc.fillApprovalSlots(cards, used) }
        cards.forEachIndexed { i, card ->
            // 事件还没加载到的待处理审批：挂在它的运行区块末尾（区块在的话）。
            if (i !in used && card.status == ApprovalCardStatus.Pending) {
                accumulators[card.key.runId]?.appendOrphanCard(card)
            }
        }
        val requestsById = vaultRequests.associateBy { it.id }
        (accumulators.values + loose).forEach { it.mergeVaultRequests(requestsById) }

        val floorMs = sorted.minOfOrNull { it.createdAtMs }
        val sections = mutableListOf<ConversationSection>()
        val allRunIds = LinkedHashSet<String>().apply {
            addAll(runById.keys)
            addAll(accumulators.keys)
        }
        for (runId in allRunIds) {
            val run = runById[runId]
            val acc = accumulators[runId]
            val gap = historyGap(run, acc, floorMs, window) ?: continue
            sections += ConversationSection.RunSection(block(runId, run, acc, gap))
        }
        loose.timedItems().forEach { (item, time) -> sections += ConversationSection.Loose(item, time) }
        return Conversation(
            sections.withIndex()
                .sortedWith(compareBy({ it.value.timeMs }, { it.index }))
                .map { it.value },
        )
    }

    /**
     * 这个运行的过程记录缺不缺；返回 null 表示先不显示（比已加载的最早事件还早、还没翻到它：往上翻时再出来）。
     */
    private fun historyGap(run: Run?, acc: Accumulator?, floorMs: Long?, window: HistoryWindow): HistoryGap? {
        if (acc != null && acc.hasEvents) return HistoryGap.None
        if (run == null) return null
        if (run.state.isActive) return HistoryGap.None
        val older = floorMs == null || run.createdAtMs < floorMs
        return when {
            window.resetOldestSeq != null && older -> HistoryGap.Expired
            window.exhausted && older -> HistoryGap.Missing
            floorMs == null -> HistoryGap.None
            older -> null
            else -> HistoryGap.None
        }
    }

    private fun block(runId: String, run: Run?, acc: Accumulator?, gap: HistoryGap): RunBlock {
        val ev = acc?.lastState
        val state: RunState
        val reason: String?
        val waitCode: WaitCode?
        when {
            run != null && (run.state.isTerminal || ev == null) -> {
                state = run.state
                reason = run.stateReason
                waitCode = run.waitCode
            }
            ev != null -> {
                state = ev.state
                reason = ev.reason ?: run?.stateReason
                waitCode = ev.waitCode ?: run?.waitCode?.takeIf { run.state == ev.state }
            }
            else -> {
                state = RunState.Unknown
                reason = null
                waitCode = null
            }
        }
        val attempt = maxOf(run?.attempt ?: 0, acc?.maxAttempt ?: 0)
        val items = buildList {
            if (run != null && run.prompt.isNotBlank()) {
                add(TimelineItem.Prompt("run/$runId/prompt", runId, run.prompt, PromptAuthor.of(run.source)))
            }
            acc?.items?.let { addAll(it) }
        }
        return RunBlock(
            runId = runId,
            run = run,
            state = state,
            attempt = attempt,
            stateReason = reason,
            waitCode = waitCode,
            items = items,
            streaming = state.isActive && acc?.inTurn == true,
            usage = acc?.usage,
            history = gap,
            createdAtMs = run?.createdAtMs ?: acc?.firstTimeMs ?: 0L,
        )
    }

    private data class StateEvent(val state: RunState, val attempt: Int, val reason: String?, val waitCode: WaitCode?)

    /** 一个区块（或不属于运行的那些事件）的累积状态。 */
    private class Accumulator(val scope: String, val runId: String?) {
        val items = mutableListOf<TimelineItem>()
        private val times = mutableMapOf<String, Long>()
        private val toolCalls = mutableMapOf<String, Int>()
        private val toolRaw = mutableMapOf<String, JsonObject>()
        private val vaultRequests = mutableMapOf<String, Int>()
        private val artifacts = mutableSetOf<String>()
        private val approvalSlots = mutableMapOf<Int, Pair<ApprovalKey, String?>>()
        private var planIndex: Int? = null
        var hasEvents = false
        var firstTimeMs: Long? = null
        var lastState: StateEvent? = null
        var maxAttempt = 0
        var inTurn = false
        /** 这一轮已经结束（turn_ended）：之后零星到的输出不再算在回复。 */
        private var turnEnded = false
        var usage: JsonObject? = null

        fun timedItems(): List<Pair<TimelineItem, Long>> = items.map { it to (times[it.key] ?: 0L) }

        private fun add(item: TimelineItem, timeMs: Long) {
            items += item
            times.putIfAbsent(item.key, timeMs)
        }

        private fun key(suffix: String) = "$scope/$suffix"

        fun apply(e: InstanceEvent) {
            hasEvents = true
            if (firstTimeMs == null) firstTimeMs = e.createdAtMs
            val p = e.payload
            if (e.kind in OUTPUT_KINDS && !turnEnded) inTurn = true
            when (e.kind) {
                EventKinds.AGENT_MESSAGE -> {
                    val text = p.string("text") ?: return
                    val last = items.lastOrNull()
                    if (last is TimelineItem.AgentText && last.aiGenerated == e.aiGenerated) {
                        items[items.lastIndex] = last.copy(text = last.text + text)
                    } else {
                        add(TimelineItem.AgentText(key("msg-${e.seq}"), text, e.aiGenerated, e.seq), e.createdAtMs)
                    }
                }
                EventKinds.AGENT_THOUGHT -> {
                    val text = p.string("text") ?: return
                    val last = items.lastOrNull()
                    if (last is TimelineItem.Thought && last.aiGenerated == e.aiGenerated) {
                        items[items.lastIndex] = last.copy(text = last.text + text)
                    } else {
                        add(TimelineItem.Thought(key("thought-${e.seq}"), text, e.aiGenerated), e.createdAtMs)
                    }
                }
                EventKinds.AGENT_TOOL_CALL, EventKinds.AGENT_TOOL_CALL_UPDATE -> toolCall(e)
                EventKinds.AGENT_PLAN -> {
                    val entries = p.array("entries").mapNotNull { el ->
                        val o = el as? JsonObject ?: return@mapNotNull null
                        val content = o.string("content") ?: o.string("title") ?: return@mapNotNull null
                        PlanEntry(content, o.string("status") ?: "pending", o.string("priority"))
                    }
                    val i = planIndex
                    if (i != null) {
                        val old = items[i] as TimelineItem.AgentPlan
                        items[i] = old.copy(entries = entries, aiGenerated = old.aiGenerated || e.aiGenerated)
                    } else {
                        planIndex = items.size
                        add(TimelineItem.AgentPlan(key("plan-${e.seq}"), entries, e.aiGenerated), e.createdAtMs)
                    }
                }
                EventKinds.AGENT_USAGE -> usage = p.obj("raw") ?: p
                EventKinds.AGENT_TURN_STARTED -> {
                    inTurn = true
                    turnEnded = false
                }
                EventKinds.AGENT_TURN_ENDED -> {
                    inTurn = false
                    turnEnded = true
                    val reason = p.string("stop_reason")
                    if (reason != null && reason in NOTABLE_STOP_REASONS) {
                        add(TimelineItem.System(key("stop-${e.seq}"), SystemLine.TurnStopped(reason)), e.createdAtMs)
                    }
                }
                EventKinds.AGENT_PERMISSION_REQUESTED -> {
                    val requestId = p.string("request_id") ?: return
                    val run = runId ?: p.string("run_id") ?: return
                    val apKey = ApprovalKey(run, p.long("attempt")?.toInt() ?: 0, requestId)
                    // 同一尝试里重发的同一个请求：只留一张卡片（位置在第一次出现的地方）。
                    if (approvalSlots.values.any { it.first == apKey }) return
                    val placeholder = ApprovalCardData(
                        key = apKey, approvalId = p.string("approval_id"), instanceId = e.instanceId,
                        title = p.string("title"), options = emptyList(), toolCall = ToolCallSummary.EMPTY,
                        status = ApprovalCardStatus.Pending, createdAtMs = e.createdAtMs,
                    )
                    approvalSlots[items.size] = apKey to p.string("approval_id")
                    add(TimelineItem.ApprovalCard(key("approval-${e.seq}"), placeholder), e.createdAtMs)
                }
                EventKinds.AGENT_PLATFORM_TOOL_CALL -> {
                    val callId = p.string("call_id") ?: "seq-${e.seq}"
                    val args = p.obj("arguments")
                    add(
                        TimelineItem.PlatformToolCall(
                            key = key("ptc-$callId-${e.seq}"),
                            callId = callId,
                            name = p.string("name").orEmpty(),
                            title = args?.string("title")?.takeIf { it.isNotBlank() },
                            rawJson = args?.let(::prettyJson).orEmpty(),
                        ),
                        e.createdAtMs,
                    )
                }
                EventKinds.AGENT_VAULT_REVEAL -> vaultUsed(
                    p.array("refs").mapNotNull { (it as? JsonPrimitive)?.contentOrNull?.substringBefore('.') },
                    e,
                )
                EventKinds.VAULT_USED -> vaultUsed(p.array("names").mapNotNull { (it as? JsonPrimitive)?.contentOrNull }, e)
                EventKinds.AGENT_ERROR -> system(SystemLine.AgentError(p.string("message")), e)
                EventKinds.AGENT_SESSION_LOST -> system(SystemLine.SessionLost(p.string("reason")), e)
                EventKinds.AGENT_EXITED -> system(
                    SystemLine.Exited(p.long("code"), (p["will_restart"] as? JsonPrimitive)?.booleanOrNull ?: false),
                    e,
                )
                EventKinds.RUN_LOG_TRUNCATED -> system(SystemLine.LogTruncated(p.long("limit_bytes")), e)
                EventKinds.RUN_STATE -> runState(e)
                EventKinds.PIPELINE_STEP_STARTED, EventKinds.DELEGATE_STARTED -> {
                    val delegated = e.kind == EventKinds.DELEGATE_STARTED
                    val child = (if (delegated) p.string("child_run_id") else p.string("run_id")) ?: return
                    add(
                        TimelineItem.ChildRun(
                            key = key("child-$child-${e.seq}"),
                            childRunId = child,
                            instanceId = p.string("instance_id"),
                            delegated = delegated,
                            step = p.string("step"),
                            to = p.string("to"),
                            title = p.string("title")?.takeIf { it.isNotBlank() },
                        ),
                        e.createdAtMs,
                    )
                }
                EventKinds.ARTIFACT_PUBLISHED -> {
                    val id = p.string("artifact_id") ?: return
                    val version = p.long("version")?.toInt() ?: 1
                    if (!artifacts.add("$id@$version")) return
                    add(
                        TimelineItem.Artifact(
                            key = key("artifact-$id-$version"),
                            artifactId = id,
                            name = p.string("name") ?: id,
                            version = version,
                            size = p.long("size"),
                        ),
                        e.createdAtMs,
                    )
                }
                EventKinds.PLAN_NEEDS_CONFIRMATION, EventKinds.PLAN_CANCELLED -> {
                    val planId = p.string("plan_id") ?: return
                    add(
                        TimelineItem.PlanCard(
                            key = key("plan-card-$planId-${e.seq}"),
                            planId = planId,
                            title = p.string("title")?.takeIf { it.isNotBlank() },
                            change = p.string("change"),
                            needsConfirmation = e.kind == EventKinds.PLAN_NEEDS_CONFIRMATION,
                        ),
                        e.createdAtMs,
                    )
                }
                EventKinds.VAULT_REQUESTED -> {
                    val requestId = p.string("request_id") ?: return
                    val card = TimelineItem.VaultRequestCard(
                        key = key("vault-$requestId"),
                        requestId = requestId,
                        name = p.string("name") ?: requestId,
                        purpose = p.string("purpose")?.takeIf { it.isNotBlank() },
                        fields = p.array("fields").mapNotNull { (it as? JsonPrimitive)?.contentOrNull },
                        status = VaultRequestStatus.Pending,
                    )
                    val i = vaultRequests[requestId]
                    if (i != null) {
                        // 已经先收到了处理结果（乱序）：保留结果，补上内容。
                        val old = items[i] as TimelineItem.VaultRequestCard
                        items[i] = card.copy(key = old.key, status = old.status)
                    } else {
                        vaultRequests[requestId] = items.size
                        add(card, e.createdAtMs)
                    }
                }
                EventKinds.VAULT_FULFILLED, EventKinds.VAULT_DECLINED -> {
                    val requestId = p.string("request_id") ?: return
                    val status = if (e.kind == EventKinds.VAULT_FULFILLED) {
                        VaultRequestStatus.Fulfilled
                    } else {
                        VaultRequestStatus.Declined
                    }
                    val i = vaultRequests[requestId]
                    if (i != null) {
                        items[i] = (items[i] as TimelineItem.VaultRequestCard).copy(status = status)
                    } else {
                        vaultRequests[requestId] = items.size
                        add(
                            TimelineItem.VaultRequestCard(
                                key = key("vault-$requestId"), requestId = requestId,
                                name = p.string("name") ?: requestId, purpose = null, fields = emptyList(),
                                status = status,
                            ),
                            e.createdAtMs,
                        )
                    }
                }
                in HIDDEN_KINDS -> Unit
                else -> system(SystemLine.Unknown(e.kind), e)
            }
        }

        private fun system(line: SystemLine, e: InstanceEvent) {
            add(TimelineItem.System(key("sys-${e.seq}"), line), e.createdAtMs)
        }

        private fun vaultUsed(names: List<String>, e: InstanceEvent) {
            val clean = names.filter { it.isNotBlank() }.distinct()
            if (clean.isEmpty()) return
            // agent.vault_reveal 之后紧跟的 vault.used 是同一次使用：只说一次。
            val last = items.lastOrNull()
            if (last is TimelineItem.VaultUsed && last.names.toSet() == clean.toSet()) return
            add(TimelineItem.VaultUsed(key("vault-used-${e.seq}"), clean), e.createdAtMs)
        }

        private fun runState(e: InstanceEvent) {
            val p = e.payload
            // 没有 state（坏数据）的不算；不认识的取值（服务端新加的）照样记成 Unknown。
            val state = RunState.fromWire(p.string("state") ?: return)
            val attempt = p.long("attempt")?.toInt() ?: lastState?.attempt ?: 0
            val waitCode = p.string("wait_code")?.let(WaitCode::fromWire)
            val previous = lastState
            lastState = StateEvent(state, attempt, p.string("reason"), waitCode)
            val newAttempt = previous != null && previous.attempt in 1 until attempt
            maxAttempt = maxOf(maxAttempt, attempt)
            when (state) {
                // 回到运行中（开始、审批通过、重试）：这一轮接着输出，不会再来一次 turn_started。
                RunState.Running -> {
                    inTurn = true
                    turnEnded = false
                }
                RunState.Starting -> turnEnded = false
                // 排队、等待、退避、结束：没在输出。
                else -> inTurn = false
            }
            if (state !in STATE_LINE_STATES && !newAttempt) return
            // 同一状态连着报两次（重放、重连）只说一次。
            val last = items.lastOrNull()
            if (!newAttempt && last is TimelineItem.RunStateLine && last.state == state && last.attempt == attempt &&
                last.waitCode == waitCode
            ) {
                return
            }
            add(
                TimelineItem.RunStateLine(
                    key = key("state-${e.seq}"),
                    state = state,
                    attempt = attempt,
                    reason = p.string("reason")?.takeIf { it.isNotBlank() },
                    waitCode = waitCode,
                    steps = p.long("steps")?.toInt(),
                    newAttempt = newAttempt,
                ),
                e.createdAtMs,
            )
        }

        private fun toolCall(e: InstanceEvent) {
            val p = e.payload
            val raw = p.obj("raw") ?: EmptyJsonObject
            val id = p.string("tool_call_id") ?: raw.string("toolCallId") ?: "seq-${e.seq}"
            val merged = JsonObject((toolRaw[id] ?: EmptyJsonObject) + raw)
            toolRaw[id] = merged
            val title = p.string("title") ?: raw.string("title")
            val kind = p.string("kind") ?: raw.string("kind")
            val status = (p.string("status") ?: raw.string("status"))?.let(ToolCallState::fromWire)
            val i = toolCalls[id]
            if (i == null) {
                toolCalls[id] = items.size
                add(
                    TimelineItem.ToolCall(
                        key = key("tool-$id"),
                        toolCallId = id,
                        title = title?.takeIf { it.isNotBlank() },
                        kind = kind?.takeIf { it.isNotBlank() },
                        status = status ?: ToolCallState.Pending,
                        summary = ToolCallSummary.of(merged),
                        rawJson = prettyJson(merged),
                    ),
                    e.createdAtMs,
                )
            } else {
                val old = items[i] as TimelineItem.ToolCall
                items[i] = old.copy(
                    title = title?.takeIf { it.isNotBlank() } ?: old.title,
                    kind = kind?.takeIf { it.isNotBlank() } ?: old.kind,
                    status = status ?: old.status,
                    summary = ToolCallSummary.of(merged),
                    rawJson = prettyJson(merged),
                )
            }
        }

        fun fillApprovalSlots(cards: List<ApprovalCardData>, used: MutableSet<Int>) {
            for ((index, slot) in approvalSlots) {
                val (apKey, approvalId) = slot
                val found = cards.indices.firstOrNull { it !in used && approvalId != null && cards[it].approvalId == approvalId }
                    ?: cards.indices.lastOrNull { it !in used && cards[it].key == apKey }
                    ?: cards.indices.lastOrNull { it !in used && cards[it].key.matches(apKey) }
                val item = items[index] as TimelineItem.ApprovalCard
                if (found != null) {
                    used += found
                    items[index] = item.copy(card = cards[found])
                }
            }
        }

        fun appendOrphanCard(card: ApprovalCardData) {
            items += TimelineItem.ApprovalCard(key("approval-${card.approvalId ?: card.key.requestId}"), card)
        }

        fun mergeVaultRequests(records: Map<String, VaultRequest>) {
            for ((requestId, i) in vaultRequests) {
                val record = records[requestId] ?: continue
                val card = items[i] as TimelineItem.VaultRequestCard
                // 记录比事件新（处理了、过期了）；事件已经是终态的不被旧记录改回待处理。
                val status = if (record.status != VaultRequestStatus.Pending && record.status != VaultRequestStatus.Unknown) {
                    record.status
                } else {
                    card.status
                }
                items[i] = card.copy(
                    status = status,
                    purpose = card.purpose ?: record.purpose.takeIf { it.isNotBlank() },
                    fields = card.fields.ifEmpty { record.fields },
                    request = record,
                )
            }
        }
    }

    private fun prettyJson(obj: JsonObject): String =
        if (obj.isEmpty()) "" else pretty.encodeToString(JsonElement.serializer(), obj)
}
