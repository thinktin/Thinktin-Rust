package cn.thinktin.data

import app.cash.turbine.test
import cn.thinktin.core.ClientException
import cn.thinktin.core.EventListener
import cn.thinktin.core.EventSubscription
import cn.thinktin.core.InternalException
import cn.thinktin.core.NoHandle
import cn.thinktin.core.StreamStatus
import cn.thinktin.core.ThinktinClient
import cn.thinktin.core.ThinktinClientInterface
import cn.thinktin.data.core.CoreThinktinService
import cn.thinktin.data.model.EventStreamItem
import cn.thinktin.data.model.ImChannelUpdate
import cn.thinktin.data.model.NewImChannel
import cn.thinktin.data.model.StreamState
import cn.thinktin.data.model.isTerminal
import cn.thinktin.data.model.string
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import cn.thinktin.core.ImChannel as CoreImChannel
import cn.thinktin.core.Instance as CoreInstance
import cn.thinktin.core.NewImChannel as CoreNewImChannel
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
        var closed = false
        var instancesError: Exception? = null
        var cachedError: Exception? = null
        var cachedEventsArgs: Pair<ULong, UInt>? = null
        var addedIm: CoreNewImChannel? = null
        var updatedIm: List<Any?>? = null

        override fun signedIn(): Boolean = true

        override fun upgradeRequired(): Boolean = false

        override suspend fun instances(): List<CoreInstance> {
            instancesError?.let { throw it }
            return listOf(CoreInstance("i1", "a1", "1.0", "codex", "小码", "paused", 1, 2))
        }

        override fun cachedInstances(): List<CoreInstance> {
            cachedError?.let { throw it }
            return listOf(CoreInstance("i1", "a1", "1.0", "codex", "小码", "paused", 1, 2))
        }

        override fun cachedUnread(): Long {
            cachedError?.let { throw it }
            return 4
        }

        override fun cachedEvents(instanceId: String, afterSeq: ULong, limit: UInt): List<CoreInstanceEvent> {
            cachedEventsArgs = afterSeq to limit
            return emptyList()
        }

        override fun subscribe(instanceId: String, listener: EventListener): EventSubscription {
            this.listener = listener
            return object : EventSubscription(NoHandle) {
                override fun stop() {
                    stopped = true
                }

                override fun close() {
                    closed = true
                }
            }
        }

        override suspend fun imChannels(): List<CoreImChannel> = listOf(im)

        override suspend fun addImChannel(channel: CoreNewImChannel): CoreImChannel {
            addedIm = channel
            return im
        }

        override suspend fun updateImChannel(
            channelId: String,
            label: String?,
            events: List<String>?,
            enabled: Boolean?,
        ): CoreImChannel {
            updatedIm = listOf(channelId, label, events, enabled)
            return im.copy(enabled = enabled ?: im.enabled)
        }

        companion object {
            val im = CoreImChannel("im1", "feishu", "研发群", "a1b2", true, listOf("approval"), true, null, null, 9)
        }
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
            fail("应该抛异常")
        } catch (e: ServiceError.Api) {
            assertEquals(503, e.status)
            assertEquals(60L, e.retryAfterSecs)
        }

        fake.instancesError = ClientException.AccountFrozen()
        try {
            s.instances()
            fail("应该抛异常")
        } catch (_: ServiceError.AccountFrozen) {
        }
        assertEquals(AuthState.Frozen, s.authState.value)

        fake.instancesError = ClientException.SignedOut()
        try {
            s.instances()
            fail("应该抛异常")
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
        assertTrue("取消收集时要 close()", fake.closed)
    }

    @Test
    fun streamSignedOutUpdatesAuthStateAndEnds() = runTest {
        val fake = FakeClient()
        val s = CoreThinktinService(fake)
        s.events("i1").test {
            fake.listener!!.onStatus(StreamStatus.SignedOut)
            assertEquals(EventStreamItem.Status(StreamState.SignedOut), awaitItem())
            awaitComplete()
        }
        assertEquals(AuthState.SignedOut, s.authState.value)
    }

    @Test
    fun streamUpgradeRequiredFlipsUpgradeStateAndEnds() = runTest {
        val fake = FakeClient()
        val s = CoreThinktinService(fake)
        assertEquals(false, s.upgradeState.value)
        s.events("i1").test {
            fake.listener!!.onStatus(StreamStatus.UpgradeRequired)
            assertEquals(EventStreamItem.Status(StreamState.UpgradeRequired), awaitItem())
            awaitComplete()
        }
        assertTrue("握手 426：界面进升级页", s.upgradeState.value)
        assertTrue(s.upgradeRequired())
        assertEquals("升级不改登录状态", AuthState.SignedIn, s.authState.value)
        assertTrue(fake.stopped)
    }

    @Test
    fun upgradeRequiredErrorFlipsUpgradeState() = runTest {
        val fake = FakeClient()
        val s = CoreThinktinService(fake)
        fake.instancesError = ClientException.UpgradeRequired()
        try {
            s.instances()
            fail("应该抛 UpgradeRequired")
        } catch (_: ServiceError.UpgradeRequired) {
        }
        assertTrue(s.upgradeState.value)
    }

    @Test
    fun terminalStatusEndsStreamAndReleasesSubscription() = runTest {
        for (
            terminal in listOf(
                StreamStatus.NotFound, StreamStatus.Stopped, StreamStatus.AccountFrozen, StreamStatus.UpgradeRequired,
            )
        ) {
            val fake = FakeClient()
            val s = CoreThinktinService(fake)
            s.events("i1").test {
                fake.listener!!.onStatus(StreamStatus.Live)
                fake.listener!!.onStatus(terminal)
                assertEquals(EventStreamItem.Status(StreamState.Live), awaitItem())
                assertTrue((awaitItem() as EventStreamItem.Status).state.isTerminal)
                awaitComplete()
            }
            assertTrue("$terminal 之后要 stop()", fake.stopped)
            assertTrue("$terminal 之后要 close() 释放原生句柄", fake.closed)
        }
    }

    @Test
    fun internalExceptionsBecomeServiceErrors() = runTest {
        val fake = FakeClient()
        val s = CoreThinktinService(fake)
        // Rust 里 panic 时 UniFFI 抛的 InternalException 不是 ClientException。
        fake.instancesError = InternalException("rust panicked")
        try {
            s.instances()
            fail("应该抛 ServiceError")
        } catch (e: ServiceError.Other) {
            assertEquals("InternalException", e.kind)
            assertTrue(e.cause is InternalException)
        }
        fake.instancesError = IllegalStateException("handle destroyed")
        try {
            s.instances()
            fail("应该抛 ServiceError")
        } catch (e: ServiceError.Other) {
            assertEquals("IllegalStateException", e.kind)
        }
        assertEquals(AuthState.SignedIn, s.authState.value)
    }

    @Test
    fun cacheFailuresFallBack() = runTest {
        val fake = FakeClient()
        val s = CoreThinktinService(fake, io = StandardTestDispatcher(testScheduler))
        assertEquals("小码", s.cachedInstances().single().name)
        assertEquals(4L, s.cachedUnread())
        fake.cachedError = InternalException("panic")
        assertEquals(emptyList<Any>(), s.cachedInstances())
        assertEquals(0L, s.cachedUnread())
        fake.cachedError = ClientException.Cache("disk full")
        assertEquals(emptyList<Any>(), s.cachedInstances())
        // 负数的 afterSeq 按 0、负数的 limit 按 0 传给 client-core。
        s.cachedEvents("i1", afterSeq = -3, limit = -1)
        assertEquals(0uL to 0u, fake.cachedEventsArgs)
    }

    @Test
    fun signedInFailureMeansSignedOut() {
        val fake = object : ThinktinClientInterface by ThinktinClient(NoHandle) {
            override fun signedIn(): Boolean = throw InternalException("panic")
        }
        assertEquals(AuthState.SignedOut, CoreThinktinService(fake).authState.value)
    }

    @Test
    fun imChannelsAreMapped() = runTest {
        val fake = FakeClient()
        val s = CoreThinktinService(fake)
        assertEquals("研发群", s.imChannels().single().label)
        s.addImChannel(NewImChannel(webhookUrl = "https://open.feishu.cn/hook/x", secret = "s", label = "新群"))
        assertEquals(CoreNewImChannel("https://open.feishu.cn/hook/x", "s", "新群", null), fake.addedIm)
        val updated = s.updateImChannel("im1", ImChannelUpdate(enabled = false))
        assertEquals(listOf("im1", null, null, false), fake.updatedIm)
        assertEquals(false, updated.enabled)
    }
}
