package cn.thinktin.data

import cn.thinktin.data.model.ApprovalState
import cn.thinktin.data.model.ApprovalTimeoutAction
import cn.thinktin.data.model.CatchUp
import cn.thinktin.data.model.DeviceMessageKind
import cn.thinktin.data.model.ReportState
import cn.thinktin.data.model.SelfCodePurpose
import cn.thinktin.data.model.InboxKind
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.OptionKind
import cn.thinktin.data.model.RunKind
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.VaultRequestStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
        assertEquals(InboxKind.Unknown, InboxKind.fromWire("promo"))
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
        assertEquals(RunKind.Pipeline, RunKind.fromWire("pipeline"))
        assertEquals(
            listOf(InboxKind.RunFinished, InboxKind.RunFailed, InboxKind.Approval, InboxKind.ComputerApproval, InboxKind.Info),
            listOf("run_finished", "run_failed", "approval", "computer_approval", "info").map { InboxKind.fromWire(it) },
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
}
