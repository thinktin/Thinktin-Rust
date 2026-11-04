package cn.thinktin.data

import cn.thinktin.data.mock.MockData
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.ApprovalCardStatus
import cn.thinktin.data.model.ApprovalOption
import cn.thinktin.data.model.ApprovalState
import cn.thinktin.data.model.ConversationBuilder
import cn.thinktin.data.model.ConversationSection
import cn.thinktin.data.model.DecisionSource
import cn.thinktin.data.model.EventKinds
import cn.thinktin.data.model.HistoryGap
import cn.thinktin.data.model.HistoryWindow
import cn.thinktin.data.model.InstanceEvent
import cn.thinktin.data.model.OptionKind
import cn.thinktin.data.model.PromptAuthor
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunKind
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.SystemLine
import cn.thinktin.data.model.TimelineItem
import cn.thinktin.data.model.ToolCallState
import cn.thinktin.data.model.VaultRequest
import cn.thinktin.data.model.VaultRequestStatus
import cn.thinktin.data.model.WaitCode
import cn.thinktin.data.model.parseJsonObject
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 对话页的事件归并（13.5，docs/android-design.md 第 8.2 节）：表里的每一种 kind、相邻消息拼接、工具调用合卡、
 * 审批的关联键与作废、填写请求、乱序 / 重复 seq、坏 payload、不认识的 kind、on_reset 之后的保留期、运行树。
 */
class ConversationBuilderTest {
    private val now = 1_800_000_000_000L
    private var seq = 0L

    private fun run(
        id: String = "r1",
        state: RunState = RunState.Running,
        source: RunSource = RunSource.User,
        createdAt: Long = now,
        attempt: Int = 1,
        prompt: String = "帮我做点事",
        parent: String? = null,
        root: String = id,
        summary: String? = null,
        error: String? = null,
        waitCode: WaitCode? = null,
    ) = Run(
        id = id, kind = RunKind.Agent, instanceId = "i1", planId = null, parentRunId = parent, rootRunId = root,
        stepKey = null, source = source, prompt = prompt, state = state, stateReason = null, attempt = attempt,
        tokensUsed = 100, summary = summary, error = error, createdAtMs = createdAt, startedAtMs = createdAt,
        finishedAtMs = if (state.isTerminal) createdAt + 60_000 else null, waitCode = waitCode,
    )

    private fun ev(
        kind: String,
        runId: String? = "r1",
        at: Long = now + seq * 1000,
        ai: Boolean = kind in ConversationBuilder.AI_GENERATED_KINDS,
        seqOverride: Long? = null,
        payload: JsonObject = JsonObject(emptyMap()),
    ): InstanceEvent {
        val s = seqOverride ?: ++seq
        return InstanceEvent(
            instanceId = "i1", seq = s, runId = runId, kind = kind, payload = payload, aiGenerated = ai, createdAtMs = at,
        )
    }

    private fun obj(build: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit) = buildJsonObject(build)

    private fun items(events: List<InstanceEvent>, runs: List<Run> = listOf(run())): List<TimelineItem> =
        ConversationBuilder.build(runs, events).block("r1")!!.items

    @Test
    fun everyKindInTheTableRendersOrHides() {
        val events = listOf(
            ev(EventKinds.RUN_STATE, payload = obj { put("state", "running"); put("attempt", 1) }),
            ev(EventKinds.AGENT_READY, payload = obj { put("harness", "claude-code") }),
            ev(EventKinds.AGENT_TURN_STARTED),
            ev(EventKinds.AGENT_THOUGHT, payload = obj { put("text", "先想想，") }),
            ev(EventKinds.AGENT_THOUGHT, payload = obj { put("text", "再动手。") }),
            ev(EventKinds.AGENT_PLAN, payload = obj {
                putJsonArray("entries") {
                    addJsonObject { put("content", "读代码"); put("status", "completed") }
                    addJsonObject { put("content", "写测试"); put("status", "in_progress"); put("priority", "high") }
                }
            }),
            ev(EventKinds.AGENT_TOOL_CALL, payload = obj {
                put("tool_call_id", "tc1"); put("title", "运行测试"); put("kind", "execute"); put("status", "pending")
                putJsonObject("raw") { putJsonObject("rawInput") { put("command", "gradle test") } }
            }),
            ev(EventKinds.AGENT_TOOL_CALL_UPDATE, payload = obj {
                put("tool_call_id", "tc1"); put("status", "completed")
                putJsonObject("raw") { put("rawOutput", "ok") }
            }),
            ev(EventKinds.AGENT_USAGE, payload = obj { putJsonObject("raw") { put("input_tokens", 10) } }),
            ev(EventKinds.AGENT_PERMISSION_REQUESTED, payload = obj {
                put("request_id", "perm-1"); put("attempt", 1); put("approval_id", "a1"); put("title", "删除文件")
                putJsonArray("options") {
                    addJsonObject { put("option_id", "ok"); put("name", "Allow"); put("kind", "allow_once") }
                }
                putJsonObject("tool_call") { put("tool_call_id", "tc2") }
            }),
            ev(EventKinds.APPROVAL_DECIDED, payload = obj {
                put("approval_id", "a1"); put("state", "approved"); put("option_id", "ok"); put("request_id", "perm-1"); put("attempt", 1)
            }),
            ev(EventKinds.AGENT_PERMISSION_RESOLVED, payload = obj {
                put("request_id", "perm-1"); put("option_id", "ok"); put("by", "user"); put("attempt", 1); put("approval_state", "approved")
            }),
            ev(EventKinds.AGENT_PLATFORM_TOOL_CALL, payload = obj {
                put("call_id", "p1"); put("name", "delegate")
                putJsonObject("arguments") { put("title", "查版本") }
            }),
            ev(EventKinds.AGENT_VAULT_REVEAL, payload = obj { put("call_id", "v1"); putJsonArray("refs") { add("github.username"); add("github") } }),
            ev(EventKinds.VAULT_USED, payload = obj { putJsonArray("names") { add("github") } }),
            ev(EventKinds.DELEGATE_STARTED, payload = obj {
                put("child_run_id", "child"); put("instance_id", "i2"); put("to", "研究员"); put("title", "查版本")
            }),
            ev(EventKinds.PIPELINE_STEP_STARTED, payload = obj { put("step", "write"); put("run_id", "step-run"); put("instance_id", "i1") }),
            ev(EventKinds.AGENT_UPDATE, payload = obj { put("kind", "mode") }),
            ev(EventKinds.AGENT_MESSAGE, payload = obj { put("text", "测试跑完了，") }),
            ev(EventKinds.AGENT_USAGE, payload = obj { putJsonObject("raw") { put("input_tokens", 99) } }),
            ev(EventKinds.AGENT_MESSAGE, payload = obj { put("text", "**全部通过**。") }),
            ev(EventKinds.ARTIFACT_PUBLISHED, payload = obj { put("artifact_id", "art"); put("name", "report.md"); put("version", 2); put("size", 1234) }),
            ev(EventKinds.ARTIFACT_PUBLISHED, payload = obj { put("artifact_id", "art"); put("name", "report.md"); put("version", 2); put("size", 1234) }),
            ev(EventKinds.VAULT_REQUESTED, payload = obj {
                put("request_id", "vr1"); put("name", "oss"); put("purpose", "上传报告"); putJsonArray("fields") { add("username"); add("password") }
            }),
            ev(EventKinds.VAULT_FULFILLED, payload = obj { put("request_id", "vr1"); put("name", "oss") }),
            ev(EventKinds.VAULT_REQUESTED, payload = obj { put("request_id", "vr2"); put("name", "pocket") }),
            ev(EventKinds.VAULT_DECLINED, payload = obj { put("request_id", "vr2") }),
            ev(EventKinds.PLAN_NEEDS_CONFIRMATION, payload = obj { put("plan_id", "pl1"); put("title", "每天检查"); put("change", "created") }),
            ev(EventKinds.PLAN_CANCELLED, payload = obj { put("plan_id", "pl2"); put("title", "旧计划"); put("change", "cancelled") }),
            ev(EventKinds.AGENT_ERROR, payload = obj { put("message", "boom") }),
            ev(EventKinds.AGENT_SESSION_LOST, payload = obj { put("reason", "sandbox_restarted") }),
            ev(EventKinds.AGENT_EXITED, payload = obj { put("code", 1); put("will_restart", true) }),
            ev(EventKinds.RUN_LOG_TRUNCATED, payload = obj { put("limit_bytes", 1024) }),
            ev(EventKinds.RUN_STATE, payload = obj { put("state", "backoff"); put("attempt", 1); put("reason", "upstream") }),
            ev(EventKinds.RUN_STATE, payload = obj { put("state", "running"); put("attempt", 2) }),
            ev(EventKinds.AGENT_TURN_ENDED, payload = obj { put("stop_reason", "max_tokens") }),
            ev(ConversationBuilder.INSTANCE_STATE, runId = null, payload = obj { put("state", "running") }),
            ev("agent.brand_new_thing", payload = obj { put("x", 1) }),
        )
        val conversation = ConversationBuilder.build(listOf(run()), events)
        val block = conversation.block("r1")!!
        val items = block.items
        // 用户那句话在最前面。
        val prompt = items.first() as TimelineItem.Prompt
        assertEquals("帮我做点事", prompt.text)
        assertTrue(prompt.fromUser)
        assertFalse(prompt.aiGenerated)

        val thought = items.filterIsInstance<TimelineItem.Thought>().single()
        assertEquals("先想想，再动手。", thought.text)
        assertTrue(thought.aiGenerated)

        val plan = items.filterIsInstance<TimelineItem.AgentPlan>().single()
        assertEquals(listOf("读代码", "写测试"), plan.entries.map { it.content })
        assertTrue(plan.entries[0].done)
        assertTrue(plan.entries[1].inProgress)

        val tool = items.filterIsInstance<TimelineItem.ToolCall>().single()
        assertEquals("运行测试", tool.title)
        assertEquals("execute", tool.kind)
        assertEquals(ToolCallState.Completed, tool.status)
        assertEquals("gradle test", tool.summary.arguments)
        assertTrue(tool.rawJson.contains("rawOutput"))

        val card = items.filterIsInstance<TimelineItem.ApprovalCard>().single().card
        assertEquals(ApprovalCardStatus.Approved, card.status)
        assertEquals("a1", card.approvalId)
        assertEquals(DecisionSource.User, card.decidedBy)

        val platform = items.filterIsInstance<TimelineItem.PlatformToolCall>().single()
        assertEquals("delegate", platform.name)
        assertEquals("查版本", platform.title)

        // vault_reveal 后面跟着同样名字的 vault.used：只说一次；github.username 只算 github。
        assertEquals(listOf(listOf("github")), items.filterIsInstance<TimelineItem.VaultUsed>().map { it.names })

        val children = items.filterIsInstance<TimelineItem.ChildRun>()
        assertEquals(listOf("child", "step-run"), children.map { it.childRunId })
        assertTrue(children[0].delegated)
        assertEquals("查版本", children[0].title)
        assertEquals("write", children[1].step)

        // 中间隔着 usage（不进时间线）的两段消息拼成一段。
        val text = items.filterIsInstance<TimelineItem.AgentText>().single()
        assertEquals("测试跑完了，**全部通过**。", text.text)
        assertTrue(text.aiGenerated)

        // 同一个产出物版本只出一张卡。
        val artifact = items.filterIsInstance<TimelineItem.Artifact>().single()
        assertEquals(1234L, artifact.size)
        assertEquals(2, artifact.version)

        val vault = items.filterIsInstance<TimelineItem.VaultRequestCard>()
        assertEquals(listOf(VaultRequestStatus.Fulfilled, VaultRequestStatus.Declined), vault.map { it.status })
        assertEquals("上传报告", vault[0].purpose)
        assertEquals(listOf("username", "password"), vault[0].fields)

        val plans = items.filterIsInstance<TimelineItem.PlanCard>()
        assertEquals(listOf(true, false), plans.map { it.needsConfirmation })

        val lines = items.filterIsInstance<TimelineItem.System>().map { it.line }
        assertEquals(
            listOf(
                SystemLine.AgentError("boom"),
                SystemLine.SessionLost("sandbox_restarted"),
                SystemLine.Exited(1, true),
                SystemLine.LogTruncated(1024),
                SystemLine.TurnStopped("max_tokens"),
                SystemLine.Unknown("agent.brand_new_thing"),
            ),
            lines,
        )
        assertTrue(lines.first().isError)

        // run.state：重试等待出一行，第 2 次尝试出一行；运行中本身不出行。
        val states = items.filterIsInstance<TimelineItem.RunStateLine>()
        assertEquals(listOf(RunState.Backoff, RunState.Running), states.map { it.state })
        assertTrue(states[1].newAttempt)
        assertEquals(2, block.attempt)

        // 不进时间线的：ready、update、usage、turn_*、approval.decided、permission_resolved、instance.state。
        assertTrue(items.none { it is TimelineItem.System && it.line is SystemLine.Unknown && (it.line as SystemLine.Unknown).kind != "agent.brand_new_thing" })
        assertEquals(JsonPrimitive(99), block.usage?.get("input_tokens"))
        assertFalse(block.streaming)
        // instance.state 没有 run_id 也不出单独的一段。
        assertEquals(1, conversation.sections.size)
    }

    @Test
    fun messagesSplitWhenSomethingVisibleIsBetween() {
        val events = listOf(
            ev(EventKinds.AGENT_MESSAGE, payload = obj { put("text", "先读文件。") }),
            ev(EventKinds.AGENT_TOOL_CALL, payload = obj { put("tool_call_id", "t"); put("title", "Read") }),
            ev(EventKinds.AGENT_MESSAGE, payload = obj { put("text", "读完了。") }),
        )
        val texts = items(events).filterIsInstance<TimelineItem.AgentText>().map { it.text }
        assertEquals(listOf("先读文件。", "读完了。"), texts)
    }

    @Test
    fun outOfOrderAndDuplicateSeqAreSortedAndDeduped() {
        val a = ev(EventKinds.AGENT_MESSAGE, seqOverride = 1, payload = obj { put("text", "一") })
        val b = ev(EventKinds.AGENT_MESSAGE, seqOverride = 2, payload = obj { put("text", "二") })
        val c = ev(EventKinds.AGENT_MESSAGE, seqOverride = 3, payload = obj { put("text", "三") })
        // 重连补发时同一条会再来一次；顺序也可能乱。
        val text = items(listOf(c, a, b, a.copy(), c)).filterIsInstance<TimelineItem.AgentText>().single().text
        assertEquals("一二三", text)
    }

    @Test
    fun toolCallUpdateBeforeTheCallStillMakesOneCard() {
        val update = ev(EventKinds.AGENT_TOOL_CALL_UPDATE, seqOverride = 5, payload = obj { put("tool_call_id", "t"); put("status", "failed") })
        val call = ev(EventKinds.AGENT_TOOL_CALL, seqOverride = 4, payload = obj { put("tool_call_id", "t"); put("title", "Fetch"); put("kind", "fetch") })
        val cards = items(listOf(update, call)).filterIsInstance<TimelineItem.ToolCall>()
        assertEquals(1, cards.size)
        assertEquals(ToolCallState.Failed, cards[0].status)
        assertEquals("Fetch", cards[0].title)
    }

    @Test
    fun badPayloadsDoNotCrash() {
        val events = listOf(
            ev(EventKinds.AGENT_MESSAGE, payload = obj { put("text", 42) }),
            ev(EventKinds.AGENT_MESSAGE, payload = parseJsonObject("not json")),
            ev(EventKinds.AGENT_TOOL_CALL, payload = obj { put("raw", "oops"); put("status", 3) }),
            ev(EventKinds.AGENT_PLAN, payload = obj { put("entries", "nope") }),
            ev(EventKinds.AGENT_PERMISSION_REQUESTED, payload = obj { put("title", "没有 request_id") }),
            ev(EventKinds.ARTIFACT_PUBLISHED, payload = obj { put("name", "没有 id") }),
            ev(EventKinds.PIPELINE_STEP_STARTED, payload = obj { put("step", "x") }),
            ev(EventKinds.RUN_STATE, payload = obj { put("state", 7); put("attempt", "two") }),
            ev(EventKinds.VAULT_REQUESTED, payload = obj { putJsonArray("fields") { add(1) } }),
            ev(EventKinds.AGENT_EXITED, payload = obj { put("will_restart", "yes") }),
            ev(EventKinds.PLAN_NEEDS_CONFIRMATION),
            ev(EventKinds.AGENT_PLATFORM_TOOL_CALL, payload = obj { put("arguments", "x") }),
        )
        val items = items(events)
        assertEquals(TimelineItem.Prompt::class, items.first()::class)
        // 工具调用没有 id 也出卡（按 seq 编号）；计划清单为空；退出行照样出。
        assertEquals(1, items.filterIsInstance<TimelineItem.ToolCall>().size)
        assertTrue(items.filterIsInstance<TimelineItem.AgentPlan>().single().entries.isEmpty())
        assertEquals(SystemLine.Exited(null, false), items.filterIsInstance<TimelineItem.System>().single().line)
        assertEquals(1, items.filterIsInstance<TimelineItem.PlatformToolCall>().size)
        assertTrue(items.none { it is TimelineItem.AgentText || it is TimelineItem.ApprovalCard || it is TimelineItem.Artifact })
    }

    @Test
    fun approvalsMatchByRunAttemptAndRequestIdAndStaleOnesAreVoid() {
        fun requested(attempt: Int, approvalId: String) = ev(EventKinds.AGENT_PERMISSION_REQUESTED, payload = obj {
            put("request_id", "perm-1"); put("attempt", attempt); put("approval_id", approvalId); put("title", "rm")
            putJsonArray("options") { addJsonObject { put("option_id", "ok"); put("name", "ok"); put("kind", "allow_once") } }
        })
        val events = listOf(
            ev(EventKinds.RUN_STATE, payload = obj { put("state", "running"); put("attempt", 1) }),
            requested(1, "old"),
            ev(EventKinds.RUN_STATE, payload = obj { put("state", "running"); put("attempt", 2) }),
            requested(2, "new"),
            ev(EventKinds.RUN_STATE, payload = obj { put("state", "waiting_approval"); put("attempt", 2) }),
        )
        val pending = Approval(
            id = "new", runId = "r1", instanceId = "i1", title = "rm",
            options = listOf(ApprovalOption("ok", "ok", OptionKind.AllowOnce)), toolCallJson = "{}",
            toolCall = JsonObject(emptyMap()), state = ApprovalState.Pending, expiresAtMs = now + 86_400_000,
            createdAtMs = now, requestId = "perm-1", attempt = 2,
        )
        val conversation = ConversationBuilder.build(listOf(run(attempt = 2)), events, approvals = listOf(pending))
        val cards = conversation.block("r1")!!.approvalCards
        assertEquals(listOf("old", "new"), cards.map { it.approvalId })
        assertEquals(ApprovalCardStatus.Superseded, cards[0].status)
        assertEquals(ApprovalCardStatus.Pending, cards[1].status)
        assertTrue(cards[1].canDecide)
        assertFalse(cards[0].canDecide)
        assertEquals(RunState.WaitingApproval, conversation.attentionBlock?.state)
    }

    @Test
    fun platformTimeoutReportedByUserShowsAsExpired() {
        val events = listOf(
            ev(EventKinds.AGENT_PERMISSION_REQUESTED, payload = obj {
                put("request_id", "perm-1"); put("attempt", 1)
                putJsonArray("options") { addJsonObject { put("option_id", "no"); put("name", "no"); put("kind", "reject_once") } }
            }),
            ev(EventKinds.AGENT_PERMISSION_RESOLVED, payload = obj {
                put("request_id", "perm-1"); put("attempt", 1); put("by", "user"); put("option_id", "no"); put("approval_state", "expired")
            }),
        )
        val card = items(events).filterIsInstance<TimelineItem.ApprovalCard>().single().card
        assertEquals(ApprovalCardStatus.Expired, card.status)
        assertEquals(DecisionSource.Timeout, card.decidedBy)
    }

    @Test
    fun policyDecisionsMakeNoCard() {
        val events = listOf(
            ev(EventKinds.AGENT_PERMISSION_RESOLVED, payload = obj { put("request_id", "perm-1"); put("option_id", "ok"); put("by", "policy") }),
        )
        assertTrue(items(events).none { it is TimelineItem.ApprovalCard })
    }

    @Test
    fun pendingApprovalWithoutLoadedEventsHangsOffItsRun() {
        val pending = Approval(
            id = "a9", runId = "r1", instanceId = "i1", title = "rm", options = emptyList(), toolCallJson = "{}",
            toolCall = JsonObject(emptyMap()), state = ApprovalState.Pending, expiresAtMs = now + 1, createdAtMs = now,
            requestId = "perm-3", attempt = 1,
        )
        val events = listOf(ev(EventKinds.AGENT_MESSAGE, payload = obj { put("text", "hi") }))
        val block = ConversationBuilder.build(listOf(run()), events, approvals = listOf(pending)).block("r1")!!
        assertEquals("a9", block.approvalCards.single().approvalId)
        assertTrue(block.items.last() is TimelineItem.ApprovalCard)
    }

    @Test
    fun streamingFollowsTurnsAndRunState() {
        val started = listOf(ev(EventKinds.AGENT_TURN_STARTED), ev(EventKinds.AGENT_MESSAGE, payload = obj { put("text", "正在…") }))
        assertTrue(ConversationBuilder.build(listOf(run()), started).block("r1")!!.streaming)
        val ended = started + ev(EventKinds.AGENT_TURN_ENDED, payload = obj { put("stop_reason", "end_turn") })
        val block = ConversationBuilder.build(listOf(run()), ended).block("r1")!!
        assertFalse(block.streaming)
        // end_turn 是正常结束：不出系统行。
        assertTrue(block.items.none { it is TimelineItem.System })
        // 运行已经结束（Run 是终态）：就算没收到 turn_ended 也不算在回复。
        assertFalse(ConversationBuilder.build(listOf(run(state = RunState.Cancelled)), started).block("r1")!!.streaming)
    }

    /** 审批通过后同一轮接着输出（不会再来 turn_started）、加载窗口从一轮中间开始：照 iOS reducer，有输出就算在回复。 */
    @Test
    fun streamingResumesAfterApprovalAndFollowsOutput() {
        val text = { s: String -> ev(EventKinds.AGENT_MESSAGE, payload = obj { put("text", s) }) }
        val state = { s: String -> ev(EventKinds.RUN_STATE, payload = obj { put("state", s); put("attempt", 1) }) }
        fun streaming(events: List<InstanceEvent>) = ConversationBuilder.build(listOf(run()), events).block("r1")!!.streaming

        val waiting = listOf(ev(EventKinds.AGENT_TURN_STARTED), text("先删文件，"), state("waiting_approval"))
        assertFalse(streaming(waiting))
        // 批准了：run.state 回到 running、文字接着流。
        assertTrue(streaming(waiting + state("running")))
        assertTrue(streaming(waiting + state("running") + text("删好了。")))
        // 窗口刚好切在 turn_started 之后：只有输出也算。
        val midTurn = listOf(text("……接着写"))
        assertTrue(streaming(midTurn))
        assertTrue(streaming(listOf(ev(EventKinds.AGENT_TOOL_CALL, payload = obj { put("tool_call_id", "t1"); put("title", "读文件") }))))
        // turn_ended 之后零星到的输出不算；退避、排队中也没在输出。
        assertFalse(streaming(midTurn + ev(EventKinds.AGENT_TURN_ENDED, payload = obj { put("stop_reason", "end_turn") }) + text("晚到的")))
        assertFalse(streaming(midTurn + state("backoff")))
        assertFalse(streaming(midTurn + state("queued")))
        // 重试：running 之后又在回复。
        assertTrue(streaming(midTurn + state("backoff") + state("running")))
    }

    @Test
    fun blockStateUsesTerminalRunOrLatestEvent() {
        val waiting = listOf(
            ev(EventKinds.RUN_STATE, payload = obj { put("state", "waiting_quota"); put("attempt", 1); put("wait_code", "no_balance") }),
        )
        val live = ConversationBuilder.build(listOf(run(state = RunState.Running)), waiting).block("r1")!!
        assertEquals(RunState.WaitingQuota, live.state)
        assertEquals(WaitCode.NoBalance, live.waitCode)
        val line = live.items.filterIsInstance<TimelineItem.RunStateLine>().single()
        assertEquals(WaitCode.NoBalance, line.waitCode)
        val done = ConversationBuilder.build(listOf(run(state = RunState.Succeeded)), waiting).block("r1")!!
        assertEquals(RunState.Succeeded, done.state)
        assertNull(done.waitCode)
    }

    @Test
    fun eventsForUnknownRunsMakeABlockWithoutPrompt() {
        val events = listOf(ev(EventKinds.AGENT_MESSAGE, runId = "new-run", payload = obj { put("text", "别的设备发的") }))
        val block = ConversationBuilder.build(emptyList(), events).block("new-run")!!
        assertNull(block.run)
        assertNull(block.prompt)
        assertEquals("别的设备发的", (block.items.single() as TimelineItem.AgentText).text)
    }

    @Test
    fun delegatedPromptIsAiGeneratedAndNotFromUser() {
        val child = run(id = "r1", source = RunSource.Delegate, prompt = "查一下版本", parent = "p", root = "p")
        val prompt = ConversationBuilder.build(listOf(child), emptyList()).block("r1")!!.prompt!!
        assertEquals(PromptAuthor.Delegate, prompt.author)
        assertTrue(prompt.aiGenerated)
        assertFalse(prompt.fromUser)
        val plan = ConversationBuilder.build(listOf(run(source = RunSource.Plan)), emptyList()).block("r1")!!.prompt!!
        assertFalse(plan.aiGenerated)
        assertFalse(plan.fromUser)
    }

    @Test
    fun runsOlderThanLoadedEventsWaitForPagingThenShowGap() {
        val old = run(id = "old", state = RunState.Succeeded, createdAt = now - 3_600_000, summary = "做完了")
        val activeOld = run(id = "old-active", state = RunState.WaitingQuota, createdAt = now - 7_200_000)
        val current = run(id = "r1", createdAt = now)
        val events = listOf(ev(EventKinds.AGENT_MESSAGE, at = now + 1, payload = obj { put("text", "hi") }))
        val runs = listOf(old, activeOld, current)

        // 还没翻到：旧的已结束运行先不显示；还在等的照样显示。
        val partial = ConversationBuilder.build(runs, events)
        assertNull(partial.block("old"))
        assertEquals(HistoryGap.None, partial.block("old-active")!!.history)

        // 缓存翻到头了：本机没有它的过程记录。
        val exhausted = ConversationBuilder.build(runs, events, window = HistoryWindow(exhausted = true))
        assertEquals(HistoryGap.Missing, exhausted.block("old")!!.history)

        // on_reset：比保留期早的只有 prompt / summary，标“超过保留期”。
        val reset = ConversationBuilder.build(runs, events, window = HistoryWindow(exhausted = true, resetOldestSeq = 50))
        val block = reset.block("old")!!
        assertEquals(HistoryGap.Expired, block.history)
        assertEquals(listOf(TimelineItem.Prompt::class), block.items.map { it::class })
        assertEquals(HistoryGap.None, reset.block("r1")!!.history)
        // 旧的在前。
        assertEquals(listOf("old-active", "old", "r1"), reset.blocks.map { it.runId })
    }

    @Test
    fun withoutAnyEventsAllRunsShow() {
        val runs = listOf(run(id = "a", state = RunState.Succeeded, createdAt = now - 10), run(id = "b", createdAt = now))
        val conversation = ConversationBuilder.build(runs, emptyList())
        assertEquals(listOf("a", "b"), conversation.blocks.map { it.runId })
        assertEquals("b", conversation.activeBlock?.runId)
    }

    @Test
    fun looseEventsAreSortedByTimeBetweenRuns() {
        val r0 = run(id = "r0", state = RunState.Succeeded, createdAt = now)
        val r2 = run(id = "r2", state = RunState.Succeeded, createdAt = now + 20_000)
        val events = listOf(
            ev(EventKinds.AGENT_MESSAGE, runId = "r0", at = now + 1, payload = obj { put("text", "a") }),
            ev(EventKinds.PLAN_NEEDS_CONFIRMATION, runId = null, at = now + 10_000, payload = obj { put("plan_id", "p") }),
            ev(EventKinds.AGENT_MESSAGE, runId = "r2", at = now + 20_001, payload = obj { put("text", "b") }),
        )
        val sections = ConversationBuilder.build(listOf(r2, r0), events).sections
        assertEquals(3, sections.size)
        assertEquals("r0", (sections[0] as ConversationSection.RunSection).block.runId)
        assertTrue((sections[1] as ConversationSection.Loose).item is TimelineItem.PlanCard)
        assertEquals("r2", (sections[2] as ConversationSection.RunSection).block.runId)
    }

    @Test
    fun vaultRequestRecordsUpdateStatusButNotBackToPending() {
        val events = listOf(
            ev(EventKinds.VAULT_REQUESTED, payload = obj { put("request_id", "vr"); put("name", "oss") }),
            ev(EventKinds.VAULT_REQUESTED, payload = obj { put("request_id", "vr2"); put("name", "zotero") }),
            ev(EventKinds.VAULT_FULFILLED, payload = obj { put("request_id", "vr2") }),
        )
        fun record(id: String, status: VaultRequestStatus) = VaultRequest(
            id = id, instanceId = "i1", runId = "r1", name = "x", purpose = "用途", fields = listOf("password"), status = status,
            itemId = null, createdAtMs = now, expiresAtMs = now + 1, resolvedAtMs = null,
        )
        val items = ConversationBuilder.build(
            listOf(run()),
            events,
            vaultRequests = listOf(record("vr", VaultRequestStatus.Expired), record("vr2", VaultRequestStatus.Pending)),
        ).block("r1")!!.items.filterIsInstance<TimelineItem.VaultRequestCard>()
        assertEquals(listOf(VaultRequestStatus.Expired, VaultRequestStatus.Fulfilled), items.map { it.status })
        assertEquals("用途", items[0].purpose)
        assertEquals(listOf("password"), items[0].fields)
        assertNotNull(items[0].request)
    }

    @Test
    fun abnormalStopReasonsSayWhy() {
        for (reason in listOf("max_tokens", "max_turn_requests", "refusal")) {
            val line = items(listOf(ev(EventKinds.AGENT_TURN_ENDED, payload = obj { put("stop_reason", reason) })))
                .filterIsInstance<TimelineItem.System>().single().line
            assertEquals(SystemLine.TurnStopped(reason), line)
        }
        assertTrue(items(listOf(ev(EventKinds.AGENT_TURN_ENDED, payload = obj { put("stop_reason", "cancelled") }))).none { it is TimelineItem.System })
    }

    @Test
    fun repeatedStateEventsMakeOneLine() {
        val events = List(3) {
            ev(EventKinds.RUN_STATE, payload = obj { put("state", "waiting_device"); put("attempt", 1); put("wait_code", "device_offline") })
        }
        assertEquals(1, items(events).filterIsInstance<TimelineItem.RunStateLine>().size)
    }

    @Test
    fun keysAreUniqueAcrossTheConversation() {
        val data = MockData(now)
        for (instance in data.instances) {
            val conversation = ConversationBuilder.build(
                data.runs.filter { it.instanceId == instance.id },
                data.events.filter { it.instanceId == instance.id },
                data.approvals.filter { it.instanceId == instance.id },
                data.vaultRequests.filter { it.instanceId == instance.id },
                HistoryWindow(exhausted = true),
            )
            val keys = conversation.sections.flatMap { s ->
                when (s) {
                    is ConversationSection.RunSection -> listOf(s.key) + s.block.items.map { it.key }
                    is ConversationSection.Loose -> listOf(s.key)
                }
            }
            assertEquals(keys.size, keys.toSet().size)
        }
    }

    @Test
    fun mockDataUsesOnlyKnownKinds() {
        val data = MockData(now)
        val coder = ConversationBuilder.build(
            data.runs.filter { it.instanceId == "inst-coder" },
            data.events.filter { it.instanceId == "inst-coder" },
            // 和服务端一样只有待处理的（approvals()）：第 1 次尝试那条靠 attempt 判作废。
            data.approvals.filter { it.state == ApprovalState.Pending },
            window = HistoryWindow(exhausted = true),
        )
        val all = coder.sections.flatMap { s ->
            when (s) {
                is ConversationSection.RunSection -> s.block.items
                is ConversationSection.Loose -> listOf(s.item)
            }
        }
        assertTrue(all.none { it is TimelineItem.System && it.line is SystemLine.Unknown })
        // 等待审批的运行：第 1 次尝试的卡作废、第 2 次的待处理。
        val waiting = coder.block("run-waiting")!!.approvalCards
        assertEquals(listOf(ApprovalCardStatus.Superseded, ApprovalCardStatus.Pending), waiting.map { it.status })
        // 流水线根运行有两个子运行入口。
        assertEquals(2, coder.block("run-pipeline")!!.items.count { it is TimelineItem.ChildRun })
    }
}
