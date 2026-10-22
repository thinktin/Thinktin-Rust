package cn.thinktin.app

import app.cash.turbine.test
import cn.thinktin.app.ui.drawer.DrawerViewModel
import cn.thinktin.app.ui.home.HomeEvent
import cn.thinktin.app.ui.home.HomeViewModel
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.Run
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** 可控的服务：数据来自 Mock，联网结果、失败、登录状态由测试控制，并记下发出的消息。 */
private class ScriptedService(
    private val mock: MockThinktinService = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() }),
) : ThinktinService by mock {
    var cached: List<Instance>? = null
    var network: List<Instance>? = null
    var instancesGate: CompletableDeferred<Unit>? = null
    var instancesError: ServiceError? = null
    var sendError: ServiceError? = null
    val sent = mutableListOf<String>()
    val auth = MutableStateFlow(AuthState.SignedIn)

    override val isDemo: Boolean = false
    override val authState: StateFlow<AuthState> get() = auth

    override suspend fun cachedInstances(): List<Instance> = cached ?: mock.cachedInstances()

    override suspend fun instances(): List<Instance> {
        instancesGate?.await()
        instancesError?.let { throw it }
        return network ?: mock.instances()
    }

    override suspend fun sendMessage(instanceId: String, text: String, allowSecrets: Boolean): Run {
        sent += text
        sendError?.let { throw it }
        return mock.sendMessage(instanceId, text, allowSecrets)
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun test(block: suspend TestScope.() -> Unit) = runTest(dispatcher) { block() }

    private fun home(service: ThinktinService) = HomeViewModel(service, DemoTestApp.FIXED_CLOCK)

    @Test
    fun homeRendersCacheBeforeNetwork() = test {
        val service = ScriptedService()
        service.instancesGate = CompletableDeferred()
        val vm = home(service)
        runCurrent()
        // 联网还没回来：缓存已经显示，不再转圈
        val cached = vm.uiState.value
        assertFalse(cached.loading)
        assertEquals(listOf("inst-coder", "inst-research"), cached.instances.map { it.id })
        assertEquals("inst-coder", cached.selectedInstanceId)
        assertTrue(cached.recentRuns.isNotEmpty())
        assertNull(cached.userName)

        service.instancesGate!!.complete(Unit)
        advanceUntilIdle()
        assertEquals("小码", vm.uiState.value.selectedInstance?.name)
        assertNull(vm.uiState.value.refreshError)
        assertTrue(vm.uiState.value.userName != null)
    }

    @Test
    fun homeHidesDeletedAndPicksMostRecentRunningInstance() = test {
        val service = ScriptedService()
        val base = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() }).instances()
        val coder = base.first { it.id == "inst-coder" }
        service.cached = emptyList()
        service.network = base + listOf(
            coder.copy(id = "inst-deleted", name = "已删除", state = InstanceState.Deleted, lastActiveAtMs = Long.MAX_VALUE),
            coder.copy(id = "inst-older", name = "旧的", state = InstanceState.Running, lastActiveAtMs = coder.lastActiveAtMs - 1),
            coder.copy(id = "inst-paused-new", name = "暂停", state = InstanceState.Paused, lastActiveAtMs = coder.lastActiveAtMs + 1),
        )
        val vm = home(service)
        advanceUntilIdle()
        val state = vm.uiState.value
        assertFalse(state.instances.any { it.state == InstanceState.Deleted })
        assertEquals("inst-coder", state.selectedInstanceId)
        assertFalse(state.loading)
    }

    @Test
    fun homeRefreshFailureKeepsCacheAndShowsError() = test {
        val service = ScriptedService()
        service.instancesError = ServiceError.Network("offline")
        val vm = home(service)
        advanceUntilIdle()
        val state = vm.uiState.value
        assertTrue(state.refreshError is ServiceError.Network)
        assertEquals(2, state.instances.size)
        assertFalse(state.loading)
    }

    @Test
    fun sendOpensChatAndClearsDraft() = test {
        val service = ScriptedService()
        val vm = home(service)
        advanceUntilIdle()
        vm.uiEvents.test {
            vm.onDraftChange("  帮我看看 CI  ")
            vm.send()
            assertEquals(HomeEvent.OpenChat("inst-coder"), awaitItem())
        }
        assertEquals(listOf("帮我看看 CI"), service.sent)
        assertEquals("", vm.uiState.value.draft)
        assertFalse(vm.uiState.value.sending)
        assertEquals("帮我看看 CI", vm.uiState.value.recentRuns.first().prompt)
    }

    @Test
    fun sendWithSecretIsBlockedLocally() = test {
        val service = ScriptedService()
        val vm = home(service)
        advanceUntilIdle()
        vm.uiEvents.test {
            vm.onDraftChange("password: hunter2hunter2")
            vm.send()
            val event = awaitItem() as HomeEvent.ShowError
            assertTrue(event.error is ServiceError.ContainsSecrets)
        }
        assertTrue(service.sent.isEmpty())
        assertFalse(vm.uiState.value.sending)
        assertEquals("password: hunter2hunter2", vm.uiState.value.draft)
    }

    @Test
    fun sendFailureRestoresComposer() = test {
        val service = ScriptedService()
        service.sendError = ServiceError.Network("timeout")
        val vm = home(service)
        advanceUntilIdle()
        vm.uiEvents.test {
            vm.onDraftChange("你好")
            vm.send()
            assertTrue((awaitItem() as HomeEvent.ShowError).error is ServiceError.Network)
        }
        assertFalse(vm.uiState.value.sending)
        assertEquals("你好", vm.uiState.value.draft)
    }

    @Test
    fun emptyDraftDoesNotSend() = test {
        val service = ScriptedService()
        val vm = home(service)
        advanceUntilIdle()
        vm.onDraftChange("   ")
        vm.send()
        advanceUntilIdle()
        assertTrue(service.sent.isEmpty())
    }

    @Test
    fun drawerLoadsAndClearsOnSignOut() = test {
        val service = ScriptedService()
        val vm = DrawerViewModel(service)
        advanceUntilIdle()
        val loaded = vm.uiState.value
        assertEquals(2, loaded.instances.size)
        assertTrue(loaded.unread > 0)
        assertTrue(loaded.user != null)

        // 换账号：退出时清掉上一个账号的数据，重新登录后再加载
        service.auth.value = AuthState.SignedOut
        advanceUntilIdle()
        val cleared = vm.uiState.value
        assertTrue(cleared.instances.isEmpty())
        assertNull(cleared.user)
        assertEquals(0L, cleared.unread)

        service.auth.value = AuthState.SignedIn
        advanceUntilIdle()
        assertEquals(2, vm.uiState.value.instances.size)
        assertTrue(vm.uiState.value.user != null)
    }

    @Test
    fun drawerSearchFiltersByNameOrAgent() = test {
        val vm = DrawerViewModel(ScriptedService())
        advanceUntilIdle()
        vm.onQueryChange("research")
        assertEquals(listOf("inst-research"), vm.uiState.value.visibleInstances.map { it.id })
        vm.onQueryChange("小码")
        assertEquals(listOf("inst-coder"), vm.uiState.value.visibleInstances.map { it.id })
    }
}
