package cn.thinktin.data

import cn.thinktin.data.model.ApprovalState
import cn.thinktin.data.model.ApprovalTimeoutAction
import cn.thinktin.data.model.CatchUp
import cn.thinktin.data.model.DeviceMessageKind
import cn.thinktin.data.model.ReportState
import cn.thinktin.data.model.SelfCodePurpose
import cn.thinktin.data.model.InboxKind
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.KnownStateReason
import cn.thinktin.data.model.OptionKind
import cn.thinktin.data.model.RunKind
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.VaultRequestStatus
import cn.thinktin.data.model.WaitCode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StatesTest {
    @Test
    fun instanceStateParsesEveryKnownValue() {
        val wire = listOf("provisioning", "running", "paused", "archived", "deleted")
        assertEquals(
            listOf(
                InstanceState.Provisioning, InstanceState.Running, InstanceState.Paused,
                InstanceState.Archived, InstanceState.Deleted,
            ),
            wire.map { InstanceState.fromWire(it) },
        )
    }

    @Test
    fun unknownValuesMapToUnknown() {
        assertEquals(InstanceState.Unknown, InstanceState.fromWire("hibernating"))
        assertEquals(InstanceState.Unknown, InstanceState.fromWire(""))
        assertEquals(RunState.Unknown, RunState.fromWire("teleporting"))
        assertEquals(RunState.Unknown, RunState.fromWire("RUNNING"))
        assertEquals(RunSource.Unknown, RunSource.fromWire("cron"))
        assertEquals(RunKind.Unknown, RunKind.fromWire("workflow"))
        // 收件箱例外：不认识的按 info 显示（client-core 的约定）。
        assertEquals(InboxKind.Info, InboxKind.fromWire("promo"))
        assertEquals(InboxKind.Info, InboxKind.fromWire(""))
        assertEquals(ApprovalState.Unknown, ApprovalState.fromWire("maybe"))
        assertEquals(OptionKind.Unknown, OptionKind.fromWire("allow_sometimes"))
        assertEquals(VaultRequestStatus.Unknown, VaultRequestStatus.fromWire("lost"))
    }

    @Test
    fun runStateParsesEveryKnownValue() {
        val wire = listOf(
            "queued", "starting", "running", "waiting_approval", "waiting_device", "waiting_quota",
            "waiting_children", "backoff", "succeeded", "failed", "cancelled",
        )
        val parsed = wire.map { RunState.fromWire(it) }
        assertFalse(parsed.contains(RunState.Unknown))
        assertEquals(wire, parsed.map { it.wire })
    }

    @Test
    fun runStateHelpers() {
        assertTrue(RunState.Succeeded.isTerminal)
        assertTrue(RunState.Failed.isTerminal)
        assertTrue(RunState.Cancelled.isTerminal)
        assertFalse(RunState.Running.isTerminal)
        assertTrue(RunState.WaitingApproval.needsAttention)
        assertTrue(RunState.WaitingQuota.needsAttention)
        assertFalse(RunState.WaitingChildren.needsAttention)
        assertTrue(RunState.Queued.isActive)
        assertFalse(RunState.Unknown.isActive)
    }

    @Test
    fun otherEnumsParseKnownValues() {
        assertEquals(RunSource.Delegate, RunSource.fromWire("delegate"))
        assertEquals(RunSource.Ask, RunSource.fromWire("ask"))
        assertEquals(RunKind.Pipeline, RunKind.fromWire("pipeline"))
        assertEquals(
            InboxKind.entries.toList(),
            listOf(
                "run_finished", "run_failed", "approval", "computer_approval", "vault_request", "plan_confirm", "info",
            ).map { InboxKind.fromWire(it) },
        )
        assertEquals(ApprovalState.Expired, ApprovalState.fromWire("expired"))
        assertEquals(OptionKind.RejectAlways, OptionKind.fromWire("reject_always"))
        assertTrue(OptionKind.AllowAlways.isAllow)
        assertFalse(OptionKind.RejectOnce.isAllow)
    }

    @Test
    fun appApiEnumsMatchServerStrings() {
        // 和 crates/proto/src/domain.rs 的 str_enum 取值一致。
        assertEquals(listOf("once", "all", "skip"), CatchUp.entries.filter { it != CatchUp.Unknown }.map { it.wire })
        assertEquals(
            listOf("skip", "pause_plan", "fail"),
            ApprovalTimeoutAction.entries.filter { it != ApprovalTimeoutAction.Unknown }.map { it.wire },
        )
        assertEquals(listOf("open", "closed"), ReportState.entries.filter { it != ReportState.Unknown }.map { it.wire })
        assertEquals(listOf("delete_account", "change_phone"), SelfCodePurpose.entries.map { it.wire })
        assertEquals(
            listOf("pair_response", "pair_confirm", "approval_request", "approval_decision", "capability", "revocation"),
            DeviceMessageKind.entries.filter { it != DeviceMessageKind.Unknown }.map { it.wire },
        )
        for (kind in DeviceMessageKind.entries.filter { it != DeviceMessageKind.Unknown }) {
            assertEquals(kind, DeviceMessageKind.fromWire(kind.wire))
        }
        assertEquals(CatchUp.Unknown, CatchUp.fromWire("twice"))
        assertEquals(ApprovalTimeoutAction.Unknown, ApprovalTimeoutAction.fromWire("reject"))
    }

    /** 运行来源、wait_code 和 proto::domain 的取值一致（8.11 加了 ask、answer）。 */
    @Test
    fun runSourceAndWaitCodeMatchServerStrings() {
        assertEquals(
            listOf("user", "plan", "pipeline", "delegate", "ask"),
            RunSource.entries.filter { it != RunSource.Unknown }.map { it.wire },
        )
        // 只有用户自己的 prompt 不标；agent 写的、带上游摘要的标 AI 生成，计划和不认识的来源不标但也不算“你”。
        assertEquals(
            setOf(RunSource.Pipeline, RunSource.Delegate, RunSource.Ask),
            RunSource.entries.filter { it.promptAiGenerated }.toSet(),
        )
        assertEquals(WaitCode.Answer, WaitCode.fromWire("answer"))
        assertFalse("等队友回答会自己继续", WaitCode.Answer.needsUserAction)
    }

    /** run.state 里平台写的固定取消说明（crates/store/src/runs.rs）：只认取消状态下的，别的原样显示。 */
    @Test
    fun knownStateReasonsOnlyForCancelled() {
        assertEquals(KnownStateReason.Interrupted, KnownStateReason.of(RunState.Cancelled, "interrupted by a new message"))
        assertEquals(KnownStateReason.NoAnswerInTime, KnownStateReason.of(RunState.Cancelled, "no answer in time"))
        assertNull(KnownStateReason.of(RunState.Cancelled, "the asker stopped"))
        assertNull(KnownStateReason.of(RunState.Cancelled, "用户取消"))
        assertNull(KnownStateReason.of(RunState.Cancelled, null))
        assertNull(KnownStateReason.of(RunState.Failed, "no answer in time"))
        assertNull(KnownStateReason.of(RunState.Backoff, "interrupted by a new message"))
    }
}
