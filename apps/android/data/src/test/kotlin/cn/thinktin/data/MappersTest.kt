package cn.thinktin.data

import cn.thinktin.data.core.toCore
import cn.thinktin.data.core.toIntClamped
import cn.thinktin.data.core.toLongClamped
import cn.thinktin.data.core.toUIntNonNegative
import cn.thinktin.data.core.toULongNonNegative
import cn.thinktin.data.core.toModel
import cn.thinktin.data.model.ApprovalKey
import cn.thinktin.data.model.CatchUp
import cn.thinktin.data.model.EmptyJsonObject
import cn.thinktin.data.model.PlanPolicy
import cn.thinktin.data.model.InboxKind
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.OptionKind
import cn.thinktin.data.model.RunKind
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.Schedule
import cn.thinktin.data.model.StreamState
import cn.thinktin.data.model.TriggerDisabledReason
import cn.thinktin.data.model.isTerminal
import cn.thinktin.data.model.NewImChannel
import cn.thinktin.data.model.long
import cn.thinktin.data.model.parseJsonObject
import cn.thinktin.data.model.string
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import cn.thinktin.core.Approval as CoreApproval
import cn.thinktin.core.Artifact as CoreArtifact
import cn.thinktin.core.ImChannel as CoreImChannel
import cn.thinktin.core.NewImChannel as CoreNewImChannel
import cn.thinktin.core.ApprovalOption as CoreApprovalOption
import cn.thinktin.core.Credential as CoreCredential
import cn.thinktin.core.InboxItem as CoreInboxItem
import cn.thinktin.core.Instance as CoreInstance
import cn.thinktin.core.InstanceEvent as CoreInstanceEvent
import cn.thinktin.core.NewCredential as CoreNewCredential
import cn.thinktin.core.Plan as CorePlan
import cn.thinktin.core.Run as CoreRun
import cn.thinktin.core.Schedule as CoreSchedule
import cn.thinktin.core.StreamStatus as CoreStreamStatus
import cn.thinktin.core.Trigger as CoreTrigger
import cn.thinktin.core.UsageBucket as CoreUsageBucket
import cn.thinktin.data.model.NewCredential

class MappersTest {
    private val now = 1_760_000_000_000L

    @Test
    fun instanceKeepsTimesAndMapsState() {
        val core = CoreInstance("i1", "a1", "1.0", "codex", "小码", "running", now - 1000, now)
        val model = core.toModel()
        assertEquals(InstanceState.Running, model.state)
        assertEquals(now - 1000, model.createdAtMs)
        assertEquals(now, model.lastActiveAtMs)
        assertEquals(InstanceState.Unknown, core.copy(state = "frozen_solid").toModel().state)
    }

    @Test
    fun runConvertsUnsignedAndNullableFields() {
        val core = CoreRun(
            id = "r1", kind = "pipeline", instanceId = "i1", planId = null, parentRunId = null, rootRunId = "r1",
            stepKey = null, source = "plan", prompt = "hi", state = "waiting_quota", stateReason = "no key",
            attempt = 3u, tokensUsed = 12_345uL, summary = null, error = null, createdAtMs = now,
            startedAtMs = now + 5, finishedAtMs = null,
        )
        val run = core.toModel()
        assertEquals(RunKind.Pipeline, run.kind)
        assertEquals(RunSource.Plan, run.source)
        assertEquals(RunState.WaitingQuota, run.state)
        assertEquals(3, run.attempt)
        assertEquals(12_345L, run.tokensUsed)
        assertEquals(now + 5, run.startedAtMs)
        assertNull(run.finishedAtMs)
        assertEquals(95L, run.durationMs(now + 100))
        // 超出 Long 的计数不会变成负数。
        assertEquals(Long.MAX_VALUE, core.copy(tokensUsed = ULong.MAX_VALUE).toModel().tokensUsed)
    }

    @Test
    fun eventPayloadIsParsed() {
        val core = CoreInstanceEvent("i1", 42uL, "r1", "agent.message", """{"text":"你好","n":3}""", true, now)
        val event = core.toModel()
        assertEquals(42L, event.seq)
        assertEquals("你好", event.payload.string("text"))
        assertEquals(3L, event.payload.long("n"))
        assertEquals(now, event.createdAtMs)
        assertTrue(event.aiGenerated)
    }

    @Test
    fun brokenPayloadFallsBackToEmptyObject() {
        val broken = CoreInstanceEvent("i1", 1uL, null, "agent.message", "{not json", false, now).toModel()
        assertEquals(EmptyJsonObject, broken.payload)
        assertNull(broken.runId)
        assertEquals(EmptyJsonObject, parseJsonObject("[1,2,3]"))
        assertEquals(EmptyJsonObject, parseJsonObject(""))
        assertEquals(EmptyJsonObject, parseJsonObject("\"text\""))
    }

    @Test
    fun inboxKindAndUnknownKind() {
        val item = CoreInboxItem("n1", null, "r1", null, null, "run_failed", "t", "b", false, false, now)
        assertEquals(InboxKind.RunFailed, item.toModel().kind)
        assertNull(item.toModel().subtype)
        assertNull(item.toModel().vaultRequestId)
        // 不认识的按 info 显示（client-core 的约定）。
        assertEquals(InboxKind.Info, item.copy(kind = "marketing").toModel().kind)
        val vault = item.copy(kind = "vault_request", vaultRequestId = "vr1").toModel()
        assertEquals(InboxKind.VaultRequest, vault.kind)
        assertEquals("vr1", vault.vaultRequestId)
        val waiting = item.copy(kind = "info", subtype = "no_balance").toModel()
        assertEquals("no_balance", waiting.subtype)
        assertEquals(InboxKind.PlanConfirm, item.copy(kind = "plan_confirm").toModel().kind)
    }

    @Test
    fun approvalOptionsAndToolCall() {
        val core = CoreApproval(
            id = "a1", runId = "r1", instanceId = "i1", title = null,
            options = listOf(CoreApprovalOption("o1", "批准", "allow_once"), CoreApprovalOption("o2", "?", "weird")),
            toolCallJson = """{"title":"Bash"}""", state = "pending", expiresAtMs = now + 1, createdAtMs = now,
        )
        val approval = core.toModel()
        assertEquals(listOf(OptionKind.AllowOnce, OptionKind.Unknown), approval.options.map { it.kind })
        assertEquals("Bash", approval.toolCall.string("title"))
        assertEquals(now + 1, approval.expiresAtMs)
        // 老数据：没有 request_id / attempt / 决定。
        assertEquals("", approval.requestId)
        assertEquals(0, approval.attempt)
        assertNull(approval.decidedOption)
        assertNull(approval.decidedAtMs)

        val decided = core.copy(
            state = "approved", requestId = "perm-1", attempt = 2u, decidedOption = "o1", decidedAtMs = now + 5,
        ).toModel()
        assertEquals("perm-1", decided.requestId)
        assertEquals(2, decided.attempt)
        assertEquals("o1", decided.decidedOption)
        assertEquals(now + 5, decided.decidedAtMs)
        assertEquals(ApprovalKey(runId = "r1", attempt = 2, requestId = "perm-1"), decided.key)
        assertEquals(Int.MAX_VALUE, core.copy(attempt = UInt.MAX_VALUE).toModel().attempt)
    }

    @Test
    fun planWithSchedules() {
        val core = CorePlan(
            id = "p1", instanceId = "i1", title = "t", goal = "g", paused = false, createdBy = "agent",
            awaitingConfirmation = true, revision = 2u, policyJson = "oops", createdAtMs = now,
            triggers = listOf(
                CoreTrigger("t1", CoreSchedule.Cron("0 9 * * *", "Asia/Shanghai"), true, now + 10, null),
                CoreTrigger("t2", CoreSchedule.Once(now + 5), true, now + 5, null),
                CoreTrigger("t3", CoreSchedule.Rrule("RRULE:FREQ=DAILY"), false, now + 1, null, "invalid_rule"),
            ),
            steps = emptyList(),
            nextFireAtMs = now + 5,
            invalidTriggers = 1u,
        )
        val plan = core.toModel()
        assertEquals(2, plan.revision)
        // policy_json 只是保留给老版本的原文；结构化的 policy 用 core 的默认值。
        assertEquals("oops", plan.policyJson)
        assertEquals(PlanPolicy(), plan.policy)
        assertEquals(CatchUp.Once, plan.catchUp)
        assertEquals(Schedule.Cron("0 9 * * *", "Asia/Shanghai"), plan.triggers[0].schedule)
        assertEquals(Schedule.Once(now + 5), plan.triggers[1].schedule)
        // 下一次运行时间、失效触发器个数用服务端给的（11.8），不在 App 里自己算。
        assertEquals(now + 5, plan.nextFireAtMs)
        assertEquals(1, plan.invalidTriggers)
        assertEquals(TriggerDisabledReason.InvalidRule, plan.triggers[2].disabledReason)
        assertNull(plan.triggers[0].disabledReason)
        assertEquals(TriggerDisabledReason.Unknown, core.triggers[2].copy(disabledReason = "moon_phase").toModel().disabledReason)
        assertNull(core.copy(nextFireAtMs = null).toModel().nextFireAtMs)
        assertEquals(CoreSchedule.Rrule("RRULE:FREQ=DAILY"), Schedule.Rrule("RRULE:FREQ=DAILY").toCore())
    }

    @Test
    fun credentialLimits() {
        val core = CoreCredential("c1", "anthropic", "工作", "abcd", 1_000uL, false, now)
        assertEquals(1_000L, core.toModel().dailyTokenLimit)
        assertNull(core.copy(dailyTokenLimit = null).toModel().dailyTokenLimit)
        val out: CoreNewCredential = NewCredential("deepseek", "x", "sk-123", dailyTokenLimit = -5).toCore()
        assertEquals(0uL, out.dailyTokenLimit)
    }

    @Test
    fun usageBucket() {
        val bucket = CoreUsageBucket("2026-10-01", 1u.toULong(), 2uL, 3uL, 4uL, 5uL, 6uL, 7uL, 8uL).toModel()
        assertEquals(listOf(1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L), with(bucket) {
            listOf(requests, inputTokens, cacheReadTokens, cacheWriteTokens, outputTokens, chargedTokens, estimatedRequests, failedRequests)
        })
    }

    @Test
    fun streamStatusAllVariants() {
        val table = listOf(
            CoreStreamStatus.Connecting to StreamState.Connecting,
            CoreStreamStatus.Live to StreamState.Live,
            CoreStreamStatus.Reconnecting(1500uL) to StreamState.Reconnecting(1500),
            CoreStreamStatus.Reconnecting(ULong.MAX_VALUE) to StreamState.Reconnecting(Long.MAX_VALUE),
            CoreStreamStatus.SignedOut to StreamState.SignedOut,
            CoreStreamStatus.NotFound to StreamState.NotFound,
            CoreStreamStatus.AccountFrozen to StreamState.AccountFrozen,
            CoreStreamStatus.UpgradeRequired to StreamState.UpgradeRequired,
            CoreStreamStatus.Stopped to StreamState.Stopped,
        )
        for ((core, expected) in table) assertEquals("$core", expected, core.toModel())
        val terminal = table.map { it.second }.filter { it.isTerminal }.toSet()
        assertEquals(
            setOf(
                StreamState.SignedOut, StreamState.NotFound, StreamState.AccountFrozen, StreamState.UpgradeRequired,
                StreamState.Stopped,
            ),
            terminal,
        )
    }

    @Test
    fun unsignedBoundsAreClamped() {
        assertEquals(Int.MAX_VALUE, UInt.MAX_VALUE.toIntClamped())
        assertEquals(Int.MAX_VALUE, (Int.MAX_VALUE.toUInt() + 1u).toIntClamped())
        assertEquals(7, 7u.toIntClamped())
        assertEquals(Long.MAX_VALUE, ULong.MAX_VALUE.toLongClamped())
        assertEquals(0uL, (-1L).toULongNonNegative())
        assertEquals(0uL, Long.MIN_VALUE.toULongNonNegative())
        assertEquals(0u, (-5).toUIntNonNegative())

        val run = CoreRun(
            id = "r1", kind = "agent", instanceId = "i1", planId = null, parentRunId = null, rootRunId = "r1",
            stepKey = null, source = "user", prompt = "hi", state = "running", stateReason = null,
            attempt = UInt.MAX_VALUE, tokensUsed = 0uL, summary = null, error = null, createdAtMs = now,
            startedAtMs = null, finishedAtMs = null,
        )
        assertEquals(Int.MAX_VALUE, run.toModel().attempt)
        val event = CoreInstanceEvent("i1", ULong.MAX_VALUE, null, "agent.message", "{}", false, now).toModel()
        assertEquals(Long.MAX_VALUE, event.seq)
        val plan = CorePlan(
            id = "p1", instanceId = "i1", title = "t", goal = "g", paused = false, createdBy = "user",
            awaitingConfirmation = false, revision = UInt.MAX_VALUE, policyJson = "{}", createdAtMs = now,
            triggers = emptyList(), steps = emptyList(),
        )
        assertEquals(Int.MAX_VALUE, plan.toModel().revision)
        val artifact = CoreArtifact(
            id = "a1", instanceId = "i1", runId = "r1", name = "x.md", version = UInt.MAX_VALUE,
            contentType = "text/markdown", size = ULong.MAX_VALUE, sha256 = "00", createdAtMs = now,
        ).toModel()
        assertEquals(Int.MAX_VALUE, artifact.version)
        assertEquals(Long.MAX_VALUE, artifact.size)
    }

    @Test
    fun imChannelRoundTrip() {
        val core = CoreImChannel(
            id = "im1", vendor = "feishu", label = "研发群", hint = "a1b2", hasSecret = true,
            events = listOf("approval"), enabled = false, lastSentAtMs = null, lastError = "404", createdAtMs = now,
        )
        val model = core.toModel()
        assertEquals("im1", model.id)
        assertEquals(listOf("approval"), model.events)
        assertEquals("404", model.lastError)
        assertNull(model.lastSentAtMs)
        val out = NewImChannel(webhookUrl = "https://x/hook", secret = null, label = "群", events = null).toCore()
        assertEquals(CoreNewImChannel("https://x/hook", null, "群", null), out)
    }
}
