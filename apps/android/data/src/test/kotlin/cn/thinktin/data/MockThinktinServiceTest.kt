package cn.thinktin.data

import app.cash.turbine.test
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.EventKinds
import cn.thinktin.data.model.EventStreamItem
import cn.thinktin.data.model.InboxKind
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.RunKind
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.StreamState
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.signedIn
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class MockThinktinServiceTest {
    private val now = 1_760_000_000_000L
    private fun service() = MockThinktinService(eventIntervalMs = 1_000, clock = { now })

    @Test
    fun catalogAndInstances() = runTest {
        val s = service()
        assertEquals(3, s.agents().size)
        val instances = s.instances()
        assertEquals(2, instances.size)
        assertEquals(setOf(InstanceState.Running, InstanceState.Paused), instances.map { it.state }.toSet())
        assertTrue(s.signedIn)
        assertTrue(s.isDemo)
    }

    @Test
    fun everyInstanceHasRuns() = runTest {
        val s = service()
        for (instance in s.instances()) {
            assertTrue("${instance.id} 没有运行", s.runs(instance.id).isNotEmpty())
            assertEquals(s.runs(instance.id), s.cachedRuns(instance.id))
        }
    }

    @Test
    fun runsCoverWaitingFailedAndPipelineChildren() = runTest {
        val s = service()
        val all = s.instances().flatMap { s.runs(it.id) }
        val states = all.map { it.state }.toSet()
        assertTrue(RunState.WaitingApproval in states)
        assertTrue(RunState.Failed in states)
        assertTrue(RunState.Running in states)
        assertTrue(RunState.Succeeded in states)
        val root = all.single { it.kind == RunKind.Pipeline }
        val children = all.filter { it.parentRunId == root.id && it.source == RunSource.Pipeline }
        assertEquals(2, children.size)
        assertEquals(root.id, s.runTree(root.id).first().id)
        assertEquals(3, s.runTree(root.id).size)
        // 新的在前
        val runs = s.runs("inst-coder")
        assertEquals(runs.sortedByDescending { it.createdAtMs }, runs)
    }

    @Test
    fun eventsAreOrderedBySeqAndCoverEveryKind() = runTest {
        val s = service()
        val kinds = mutableSetOf<String>()
        for (instance in s.instances()) {
            val events = s.cachedEvents(instance.id)
            assertTrue(events.isNotEmpty())
            val seqs = events.map { it.seq }
            assertEquals(seqs.sorted(), seqs)
            assertEquals(seqs.distinct(), seqs)
            assertTrue(events.all { it.instanceId == instance.id })
            // 时间和 seq 同向
            assertEquals(events.sortedBy { it.createdAtMs }.map { it.seq }, events.sortedBy { it.seq }.map { it.seq })
            kinds += events.map { it.kind }
            // afterSeq 过滤
            assertEquals(events.drop(3), s.cachedEvents(instance.id, afterSeq = events[2].seq))
        }
        val missing = EventKinds.ALL.toSet() - kinds
        assertTrue("没覆盖：$missing", missing.isEmpty())
    }

    @Test
    fun inboxCoversFiveKinds() = runTest {
        val s = service()
        val page = s.syncInbox()
        val kinds = page.items.map { it.kind }.toSet()
        assertEquals(
            setOf(InboxKind.RunFinished, InboxKind.RunFailed, InboxKind.Approval, InboxKind.ComputerApproval, InboxKind.Info),
            kinds,
        )
        assertEquals(page.unread, s.cachedUnread())
        assertEquals(3L, page.unread)
        assertEquals(0L, s.markInboxRead(emptyList(), upToId = page.items.first().id))
        assertEquals(0L, s.cachedUnread())
    }

    @Test
    fun plansHaveOneAwaitingConfirmationFirst() = runTest {
        val s = service()
        val plans = s.plans()
        assertEquals(2, plans.size)
        assertTrue(plans.first().awaitingConfirmation)
        assertEquals(1, plans.count { it.awaitingConfirmation })
        val confirmed = s.confirmPlan(plans.first().id, plans.first().revision)
        assertFalse(confirmed.awaitingConfirmation)
    }

    @Test
    fun keysVendorsAndVault() = runTest {
        val s = service()
        assertTrue(s.credentials().isNotEmpty())
        assertTrue(s.vendors().isNotEmpty())
        assertTrue(s.vaultItems().isNotEmpty())
        assertEquals(1, s.vaultRequests().size)
        assertTrue(s.approvals().any { it.state == cn.thinktin.data.model.ApprovalState.Pending })
    }

    @Test
    fun sendMessageWithSecretIsBlocked() = runTest {
        val s = service()
        assertTrue(s.detectSecrets("password: hunter2hunter2").isNotEmpty())
        assertTrue(s.detectSecrets("今天天气不错").isEmpty())
        try {
            s.sendMessage("inst-coder", "password: hunter2hunter2")
            fail("应该拦下")
        } catch (e: ServiceError.ContainsSecrets) {
            assertEquals(1, e.count)
        }
        val run = s.sendMessage("inst-coder", "你好")
        assertEquals(run.id, s.runs("inst-coder").first().id)
    }

    @Test
    fun liveEventsContinueSeq() = runTest {
        val s = service()
        val last = s.cachedEvents("inst-coder").last().seq
        s.events("inst-coder").test {
            assertEquals(EventStreamItem.Status(StreamState.Connecting), awaitItem())
            assertEquals(EventStreamItem.Status(StreamState.Live), awaitItem())
            val first = awaitItem() as EventStreamItem.Event
            val second = awaitItem() as EventStreamItem.Event
            assertEquals(last + 1, first.event.seq)
            assertEquals(last + 2, second.event.seq)
            cancelAndIgnoreRemainingEvents()
        }
        // 吐出的事件也进了缓存
        assertTrue(s.cachedEvents("inst-coder").last().seq >= last + 2)
    }

    @Test
    fun pausedInstanceStreamStaysQuiet() = runTest {
        val s = service()
        s.events("inst-research").test {
            assertEquals(EventStreamItem.Status(StreamState.Connecting), awaitItem())
            assertEquals(EventStreamItem.Status(StreamState.Live), awaitItem())
            expectNoEvents()
            cancelAndIgnoreRemainingEvents()
        }
        s.events("nope").test {
            assertEquals(EventStreamItem.Status(StreamState.Connecting), awaitItem())
            assertEquals(EventStreamItem.Status(StreamState.NotFound), awaitItem())
            awaitComplete()
        }
    }

    @Test
    fun logoutSignsOut() = runTest {
        val s = service()
        s.logout()
        assertEquals(AuthState.SignedOut, s.authState.value)
        try {
            s.instances()
            fail()
        } catch (_: ServiceError.SignedOut) {
        }
        s.login("+8613800000000", "123456")
        assertEquals(AuthState.SignedIn, s.authState.value)
    }

    @Test
    fun serverOnlyOperationsWorkInMock() = runTest {
        val s = service()
        assertEquals(3, s.devices().size)
        assertEquals(1, s.teams().size)
        assertEquals(1, s.teamTemplates().size)
        val team = s.adoptTeamTemplate("tpl-research")
        assertEquals(2, team.members.size)
        assertEquals(4, s.instances().size)
    }
}
