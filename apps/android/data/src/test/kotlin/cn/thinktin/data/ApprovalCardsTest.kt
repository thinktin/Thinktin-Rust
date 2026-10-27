package cn.thinktin.data

import cn.thinktin.data.mock.MockData
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.ApprovalCardStatus
import cn.thinktin.data.model.ApprovalCards
import cn.thinktin.data.model.ApprovalKey
import cn.thinktin.data.model.ApprovalOption
import cn.thinktin.data.model.ApprovalState
import cn.thinktin.data.model.DecisionSource
import cn.thinktin.data.model.EventKinds
import cn.thinktin.data.model.InstanceEvent
import cn.thinktin.data.model.OptionKind
import cn.thinktin.data.model.ToolCallSummary
import cn.thinktin.data.model.isSuperseded
import cn.thinktin.data.model.matches
import cn.thinktin.data.model.parseJsonObject
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 审批卡片（13.16）：从审批记录出卡片、事件 + 记录按 (run_id, attempt, request_id) 对上、作废、谁决定的。 */
class ApprovalCardsTest {
    private val now = 1_800_000_000_000L
    private var seq = 0L

    private fun event(kind: String, runId: String? = "r1", at: Long = now, payload: JsonObject) = InstanceEvent(
        instanceId = "i1", seq = ++seq, runId = runId, kind = kind, payload = payload, aiGenerated = false, createdAtMs = at,
    )

    private fun requested(attempt: Int, requestId: String = "perm-1", approvalId: String? = null, at: Long = now) = event(
        EventKinds.AGENT_PERMISSION_REQUESTED,
        at = at,
        payload = buildJsonObject {
            put("request_id", requestId); put("attempt", attempt); put("title", "删除旧文件")
            approvalId?.let { put("approval_id", it) }
            putJsonArray("options") {
                addJsonObject { put("option_id", "allow"); put("name", "Allow"); put("kind", "allow_once") }
                addJsonObject { put("option_id", "reject"); put("name", "Reject"); put("kind", "reject_once") }
            }
            putJsonObject("tool_call") { put("tool_call_id", "tc-1") }
        },
    )

    private fun resolved(
        attempt: Int,
        optionId: String?,
        by: String,
        approvalState: String? = null,
        requestId: String = "perm-1",
    ) = event(
        EventKinds.AGENT_PERMISSION_RESOLVED,
        payload = buildJsonObject {
            put("request_id", requestId); put("attempt", attempt); put("by", by)
            optionId?.let { put("option_id", it) }
            approvalState?.let { put("approval_state", it) }
        },
    )

    private fun runState(attempt: Int) = event(
        EventKinds.RUN_STATE,
        payload = buildJsonObject { put("state", "running"); put("attempt", attempt) },
    )

    private fun approval(
        id: String,
        attempt: Int,
        state: ApprovalState = ApprovalState.Pending,
        requestId: String = "perm-1",
        decidedOption: String? = null,
    ) = Approval(
        id = id, runId = "r1", instanceId = "i1", title = "删除旧文件",
        options = listOf(
            ApprovalOption("allow", "Allow", OptionKind.AllowOnce),
            ApprovalOption("reject", "Reject", OptionKind.RejectOnce),
        ),
        toolCallJson = """{"title":"Bash","kind":"execute","rawInput":{"command":"rm -rf build/old"}}""",
        toolCall = parseJsonObject("""{"title":"Bash","kind":"execute","rawInput":{"command":"rm -rf build/old"}}"""),
        state = state, expiresAtMs = now + 86_400_000, createdAtMs = now,
        requestId = requestId, attempt = attempt, decidedOption = decidedOption,
        decidedAtMs = if (decidedOption != null) now + 1 else null,
    )

    @Test
    fun fromApprovalMapsStateAndWhoDecided() {
        val pending = ApprovalCards.fromApproval(approval("a1", 2))
        assertEquals(ApprovalCardStatus.Pending, pending.status)
        assertTrue(pending.canDecide)
        assertNull(pending.decidedBy)
        assertEquals("Bash", pending.toolCall.title)
        assertEquals("execute", pending.toolCall.kind)
        assertEquals("rm -rf build/old", pending.toolCall.arguments)
        assertTrue(pending.toolCall.rawJson.contains("\"command\": \"rm -rf build/old\""))

        val approved = ApprovalCards.fromApproval(approval("a1", 2, ApprovalState.Approved, decidedOption = "allow"))
        assertEquals(ApprovalCardStatus.Approved, approved.status)
        assertEquals(DecisionSource.User, approved.decidedBy)
        assertEquals(OptionKind.AllowOnce, approved.decidedOptionInfo?.kind)
        assertFalse(approved.canDecide)
        assertEquals(DecisionSource.Timeout, ApprovalCards.fromApproval(approval("a", 1, ApprovalState.Expired)).decidedBy)
        assertEquals(DecisionSource.Cancelled, ApprovalCards.fromApproval(approval("a", 1, ApprovalState.Cancelled)).decidedBy)
    }

    @Test
    fun pendingCardOfOlderAttemptIsSuperseded() {
        val card = ApprovalCards.fromApproval(approval("a1", 1), currentAttempt = 2)
        assertEquals(ApprovalCardStatus.Superseded, card.status)
        assertFalse("作废的不能再批", card.canDecide)
        // 同一次尝试、不知道当前尝试、老数据（attempt 0）都不作废
        assertEquals(ApprovalCardStatus.Pending, ApprovalCards.fromApproval(approval("a1", 2), 2).status)
        assertEquals(ApprovalCardStatus.Pending, ApprovalCards.fromApproval(approval("a1", 2), null).status)
        assertFalse(isSuperseded(0, 3))
        // 已经有结果的不改成作废
        assertEquals(
            ApprovalCardStatus.Cancelled,
            ApprovalCards.fromApproval(approval("a1", 1, ApprovalState.Cancelled), 2).status,
        )
    }

    @Test
    fun keyMatchingNeedsAllThreeUnlessAttemptUnknown() {
        val key = ApprovalKey("r1", 2, "perm-1")
        assertTrue(key.matches(ApprovalKey("r1", 2, "perm-1")))
        assertFalse(key.matches(ApprovalKey("r1", 1, "perm-1")))
        assertFalse(key.matches(ApprovalKey("r2", 2, "perm-1")))
        assertFalse(key.matches(ApprovalKey("r1", 2, "perm-2")))
        assertTrue("老数据 attempt 为 0 时只比 run 和 request", key.matches(ApprovalKey("r1", 0, "perm-1")))
        assertFalse("request_id 为空认不出来", ApprovalKey("r1", 1, "").matches(ApprovalKey("r1", 1, "")))
    }

    @Test
    fun reconcileSeparatesAttemptsWithSameRequestId() {
        // 第 1 次尝试的 perm-1 没处理，沙箱重启，第 2 次尝试又从 perm-1 编号。
        val events = listOf(
            runState(1),
            requested(attempt = 1, approvalId = "a-stale", at = now - 10),
            runState(2),
            requested(attempt = 2, at = now),
        )
        val cards = ApprovalCards.reconcile(events, approvals = listOf(approval("a-new", 2)))
        assertEquals(2, cards.size)
        val (stale, current) = cards
        assertEquals(ApprovalKey("r1", 1, "perm-1"), stale.key)
        assertEquals(ApprovalCardStatus.Superseded, stale.status)
        assertFalse(stale.canDecide)
        assertEquals(ApprovalKey("r1", 2, "perm-1"), current.key)
        assertEquals(ApprovalCardStatus.Pending, current.status)
        assertEquals("对上了审批记录", "a-new", current.approvalId)
        assertTrue(current.canDecide)
        assertEquals(now + 86_400_000, current.expiresAtMs)
        // 事件里只有 tool_call_id：用记录里完整的工具调用
        assertEquals("rm -rf build/old", current.toolCall.arguments)
    }

    @Test
    fun runAttemptsArgumentAlsoSupersedes() {
        val cards = ApprovalCards.reconcile(listOf(requested(attempt = 1)), runAttempts = mapOf("r1" to 3))
        assertEquals(ApprovalCardStatus.Superseded, cards.single().status)
    }

    @Test
    fun platformTimeoutWithByUserIsExpired() {
        // 平台判的超时：shim 回 by=user，approval_state=expired。
        val cards = ApprovalCards.reconcile(
            listOf(requested(attempt = 1), resolved(attempt = 1, optionId = "reject", by = "user", approvalState = "expired")),
        )
        val card = cards.single()
        assertEquals(ApprovalCardStatus.Expired, card.status)
        assertEquals(DecisionSource.Timeout, card.decidedBy)
    }

    @Test
    fun resolvedByUserUsesOptionKindAndApprovalState() {
        val approved = ApprovalCards.reconcile(
            listOf(requested(attempt = 1), resolved(attempt = 1, optionId = "allow", by = "user", approvalState = "approved")),
        ).single()
        assertEquals(ApprovalCardStatus.Approved, approved.status)
        assertEquals(DecisionSource.User, approved.decidedBy)
        assertEquals("allow", approved.decidedOption)

        val rejected = ApprovalCards.reconcile(
            listOf(requested(attempt = 1), resolved(attempt = 1, optionId = "reject", by = "user")),
        ).single()
        assertEquals(ApprovalCardStatus.Rejected, rejected.status)

        val cancelled = ApprovalCards.reconcile(
            listOf(requested(attempt = 1), resolved(attempt = 1, optionId = null, by = "cancelled")),
        ).single()
        assertEquals(ApprovalCardStatus.Cancelled, cancelled.status)
        assertEquals(DecisionSource.Cancelled, cancelled.decidedBy)

        val timeout = ApprovalCards.reconcile(
            listOf(requested(attempt = 1), resolved(attempt = 1, optionId = null, by = "timeout")),
        ).single()
        assertEquals(ApprovalCardStatus.Expired, timeout.status)
    }

    @Test
    fun resolutionOnlyAppliesToTheSameAttempt() {
        // 第 1 次尝试的 perm-1 被取消，不影响第 2 次尝试的 perm-1。
        val cards = ApprovalCards.reconcile(
            listOf(
                requested(attempt = 1),
                resolved(attempt = 1, optionId = null, by = "cancelled"),
                requested(attempt = 2),
            ),
        )
        assertEquals(listOf(ApprovalCardStatus.Cancelled, ApprovalCardStatus.Pending), cards.map { it.status })
    }

    @Test
    fun policyDecisionWithoutRequestMakesNoCard() {
        val cards = ApprovalCards.reconcile(listOf(resolved(attempt = 1, optionId = "allow", by = "policy")))
        assertTrue(cards.isEmpty())
    }

    @Test
    fun approvalDecidedEventUpdatesCard() {
        val request = requested(attempt = 1, approvalId = "a1")
        val decided = event(
            EventKinds.APPROVAL_DECIDED,
            payload = buildJsonObject {
                put("approval_id", "a1"); put("state", "rejected"); put("option_id", "reject")
                put("request_id", "perm-1"); put("attempt", 1)
            },
        )
        // 顺序按 seq，不按列表：先放决定也一样
        val card = ApprovalCards.reconcile(listOf(decided, request)).single()
        assertEquals(ApprovalCardStatus.Rejected, card.status)
        assertEquals(DecisionSource.User, card.decidedBy)
        assertEquals("reject", card.decidedOption)
    }

    @Test
    fun staleListDoesNotRevertResolvedCard() {
        // 列表比事件旧：事件已经批准了，列表里还是待处理。
        val card = ApprovalCards.reconcile(
            listOf(requested(attempt = 1), resolved(attempt = 1, optionId = "allow", by = "user", approvalState = "approved")),
            approvals = listOf(approval("a1", 1)),
        ).single()
        assertEquals(ApprovalCardStatus.Approved, card.status)
        assertFalse(card.canDecide)
    }

    @Test
    fun recordResultWinsOverPendingEventAndUnmatchedRecordsAreAppended() {
        val cards = ApprovalCards.reconcile(
            listOf(requested(attempt = 1)),
            approvals = listOf(
                approval("a1", 1, ApprovalState.Expired),
                approval("a2", 1, requestId = "perm-2"),
            ),
        )
        assertEquals(2, cards.size)
        assertEquals(ApprovalCardStatus.Expired, cards[0].status)
        assertEquals(DecisionSource.Timeout, cards[0].decidedBy)
        assertEquals("a2", cards[1].approvalId)
        assertEquals(ApprovalCardStatus.Pending, cards[1].status)
    }

    @Test
    fun applyDecisionKeepsEventFieldsAndUpdatesResult() {
        val card = ApprovalCards.reconcile(listOf(requested(attempt = 2)), approvals = listOf(approval("a1", 2))).single()
        val updated = ApprovalCards.applyDecision(card, approval("a1", 2, ApprovalState.Approved, decidedOption = "allow"))
        assertEquals(ApprovalCardStatus.Approved, updated.status)
        assertEquals(DecisionSource.User, updated.decidedBy)
        assertEquals(now + 1, updated.decidedAtMs)
        assertEquals(card.createdAtMs, updated.createdAtMs)
        assertFalse(updated.canDecide)
    }

    @Test
    fun toolCallSummaryPicksMeaningfulArgument() {
        val acp = parseJsonObject(
            """{"toolCallId":"t1","title":"Read file","kind":"read","rawInput":{"limit":10,"file_path":"src/a.kt"}}""",
        )
        val summary = ToolCallSummary.of(acp)
        assertEquals("Read file", summary.title)
        assertEquals("read", summary.kind)
        assertEquals("src/a.kt", summary.arguments)

        val other = ToolCallSummary.of(parseJsonObject("""{"title":"x","raw_input":{"a":1,"b":"two"}}"""))
        assertEquals("a=1, b=two", other.arguments)

        val locations = ToolCallSummary.of(parseJsonObject("""{"title":"Edit","locations":[{"path":"README.md"}]}"""))
        assertEquals("README.md", locations.arguments)

        val long = ToolCallSummary.of(parseJsonObject("""{"rawInput":{"command":"${"x".repeat(500)}"}}"""))
        assertEquals(ToolCallSummary.MAX_ARGUMENTS, long.arguments!!.length)
        assertTrue(long.arguments!!.endsWith("…"))

        assertTrue(ToolCallSummary.of(JsonObject(emptyMap())).isEmpty)
        assertEquals("not json", ToolCallSummary.of(JsonObject(emptyMap()), "not json").rawJson)
    }

    @Test
    fun mockConversationReconcilesToStaleAndPendingCards() = runTest {
        val s = MockThinktinService(clock = { now })
        val events = s.cachedEvents(MockData.INSTANCE_CODER, 0, 500)
        val run = s.getRun(MockData.RUN_WAITING)
        val cards = ApprovalCards.reconcile(
            events.filter { it.runId == MockData.RUN_WAITING },
            approvals = s.approvals(),
            runAttempts = mapOf(run.id to run.attempt),
        )
        assertEquals(listOf(ApprovalCardStatus.Superseded, ApprovalCardStatus.Pending), cards.map { it.status })
        assertEquals(MockData.APPROVAL_PENDING, cards[1].approvalId)
        assertTrue(cards[1].canDecide)

        val done = ApprovalCards.reconcile(events.filter { it.runId == MockData.RUN_DONE }).single()
        assertEquals(ApprovalCardStatus.Approved, done.status)
        assertEquals(MockData.APPROVAL_DONE, done.approvalId)

        val expired = s.getApproval(MockData.APPROVAL_EXPIRED)
        assertEquals(ApprovalState.Expired, expired.state)
        assertTrue(s.approvals().none { it.id == MockData.APPROVAL_EXPIRED })
    }
}
