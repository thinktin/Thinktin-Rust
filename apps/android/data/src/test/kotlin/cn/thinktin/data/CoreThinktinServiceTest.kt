package cn.thinktin.data

import app.cash.turbine.test
import cn.thinktin.core.ClientException
import cn.thinktin.core.EventListener
import cn.thinktin.core.EventSubscription
import cn.thinktin.core.NoHandle
import cn.thinktin.core.StreamStatus
import cn.thinktin.core.ThinktinClient
import cn.thinktin.core.ThinktinClientInterface
import cn.thinktin.data.core.CoreThinktinService
import cn.thinktin.data.model.EventStreamItem
import cn.thinktin.data.model.StreamState
import cn.thinktin.data.model.string
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import cn.thinktin.core.Instance as CoreInstance
import cn.thinktin.core.InstanceEvent as CoreInstanceEvent

/**
 * CoreThinktinService 的适配逻辑。UniFFI 的 NoHandle 构造出不连 Rust 的假对象：
 * 没覆盖的方法一调就会去找本机库，所以这里只覆盖用到的。
 */
class CoreThinktinServiceTest {

    private class FakeClient(
        private val base: ThinktinClient = ThinktinClient(NoHandle),
    ) : ThinktinClientInterface by base {
        var listener: EventListener? = null
        var stopped = false
        var instancesError: ClientException? = null

        override fun signedIn(): Boolean = true

        override suspend fun instances(): List<CoreInstance> {
            instancesError?.let { throw it }
            return listOf(CoreInstance("i1", "a1", "1.0", "codex", "小码", "paused", 1, 2))
        }

        override fun subscribe(instanceId: String, listener: EventListener): EventSubscription {
            this.listener = listener
            return object : EventSubscription(NoHandle) {
                override fun stop() {
                    stopped = true
                }
            }
        }
    }

    private suspend fun expectUnsupported(name: String, block: suspend () -> Unit) {
        try {
            block()
            fail("$name 应该抛 Unsupported")
        } catch (e: ServiceError.Unsupported) {
            assertEquals(name, e.operation)
        }
    }

    @Test
    fun serverOnlyOperationsAreUnsupported() = runTest {
        val s: ThinktinService = CoreThinktinService(ThinktinClient(NoHandle))
        expectUnsupported("devices") { s.devices() }
        expectUnsupported("signOutDevice") { s.signOutDevice("d") }
        expectUnsupported("sendAccountCode") { s.sendAccountCode() }
        expectUnsupported("deleteAccount") { s.deleteAccount("123456") }
        expectUnsupported("olderRuns") { s.olderRuns("i", "r") }
        expectUnsupported("instanceArtifacts") { s.instanceArtifacts("i") }
        expectUnsupported("deleteArtifact") { s.deleteArtifact("a") }
        expectUnsupported("updatePlan") { s.updatePlan("p", cn.thinktin.data.model.PlanUpdate(title = "x")) }
        expectUnsupported("addTrigger") { s.addTrigger("p", cn.thinktin.data.model.Schedule.Once(1)) }
        expectUnsupported("deleteTrigger") { s.deleteTrigger("t") }
        expectUnsupported("teams") { s.teams() }
        expectUnsupported("createTeam") { s.createTeam("t", emptyList()) }
        expectUnsupported("updateTeam") { s.updateTeam("t") }
        expectUnsupported("deleteTeam") { s.deleteTeam("t") }
        expectUnsupported("teamTemplates") { s.teamTemplates() }
        expectUnsupported("saveTeamAsTemplate") { s.saveTeamAsTemplate("t", "n") }
        expectUnsupported("deleteTeamTemplate") { s.deleteTeamTemplate("t") }
        expectUnsupported("adoptTeamTemplate") { s.adoptTeamTemplate("t") }
        expectUnsupported("markInboxUnread") { s.markInboxUnread("n") }
        expectUnsupported("deleteInboxItem") { s.deleteInboxItem("n") }
        expectUnsupported("updateCredential") { s.updateCredential("c", cn.thinktin.data.model.CredentialUpdate(label = "x")) }
    }

    @Test
    fun mapsResultsAndErrors() = runTest {
        val fake = FakeClient()
        val s = CoreThinktinService(fake)
        assertEquals("小码", s.instances().single().name)
        assertEquals(AuthState.SignedIn, s.authState.value)

        fake.instancesError = ClientException.Api(503u, "unavailable", "maintenance", 60uL)
        try {
            s.instances()
            fail()
        } catch (e: ServiceError.Api) {
            assertEquals(503, e.status)
            assertEquals(60L, e.retryAfterSecs)
        }

        fake.instancesError = ClientException.AccountFrozen()
        try {
            s.instances()
            fail()
        } catch (_: ServiceError.AccountFrozen) {
        }
        assertEquals(AuthState.Frozen, s.authState.value)

        fake.instancesError = ClientException.SignedOut()
        try {
            s.instances()
            fail()
        } catch (_: ServiceError.SignedOut) {
        }
        assertEquals(AuthState.SignedOut, s.authState.value)
    }

    @Test
    fun eventsBridgeListenerAndStopOnCancel() = runTest {
        val fake = FakeClient()
        val s = CoreThinktinService(fake)
        s.events("i1").test {
            val listener = fake.listener!!
            // 回调可能来自任意线程；这里直接调，确认会进流。
            listener.onStatus(StreamStatus.Live)
            listener.onEvent(CoreInstanceEvent("i1", 7uL, "r1", "agent.message", """{"text":"hi"}""", true, 5))
            listener.onReset(3uL, null)
            listener.onStatus(StreamStatus.Reconnecting(250uL))

            assertEquals(EventStreamItem.Status(StreamState.Live), awaitItem())
            val event = (awaitItem() as EventStreamItem.Event).event
            assertEquals(7L, event.seq)
            assertEquals("hi", event.payload.string("text"))
            assertEquals(EventStreamItem.Reset(3, null), awaitItem())
            assertEquals(EventStreamItem.Status(StreamState.Reconnecting(250)), awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
        assertTrue("取消收集时要 stop()", fake.stopped)
    }

    @Test
    fun streamSignedOutUpdatesAuthState() = runTest {
        val fake = FakeClient()
        val s = CoreThinktinService(fake)
        s.events("i1").test {
            fake.listener!!.onStatus(StreamStatus.SignedOut)
            assertEquals(EventStreamItem.Status(StreamState.SignedOut), awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
        assertEquals(AuthState.SignedOut, s.authState.value)
    }
}
