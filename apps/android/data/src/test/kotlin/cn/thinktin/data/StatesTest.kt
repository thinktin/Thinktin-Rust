package cn.thinktin.data

import cn.thinktin.data.model.ApprovalState
import cn.thinktin.data.model.InboxKind
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.OptionKind
import cn.thinktin.data.model.RunKind
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.VaultRequestStatus
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

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
}
