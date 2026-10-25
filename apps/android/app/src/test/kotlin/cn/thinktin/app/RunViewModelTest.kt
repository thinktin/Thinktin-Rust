package cn.thinktin.app

import app.cash.turbine.test
import cn.thinktin.app.ui.run.RunEvent
import cn.thinktin.app.ui.run.RunViewModel
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.WaitCode
import cn.thinktin.data.service.ServiceError
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** 运行服务的替身：可以把树换成自己的（等 key 冒泡），也可以让某个方法抛错。 */
private class TreeService(val chat: ChatService = ChatService()) : cn.thinktin.data.service.ThinktinService by chat {
    var tree: List<Run>? = null
    var error: ServiceError? = null
    val cancelled get() = chat.cancelled

    override suspend fun getRun(runId: String): Run {
        error?.let { throw it }
        return tree?.first { it.id == runId } ?: chat.mock.getRun(runId)
    }

    override suspend fun runTree(runId: String): List<Run> = tree ?: chat.mock.runTree(runId)

    override suspend fun cancelRun(runId: String, wholeTree: Boolean): Run {
        chat.cancelled += runId to wholeTree
        val t = tree
        if (t != null) {
            tree = t.map { if (it.id == runId || wholeTree) it.copy(state = RunState.Cancelled) else it }
            return tree!!.first { it.id == runId }
        }
        return chat.mock.cancelRun(runId, wholeTree)
    }
}

/** 13.5 运行页：深链指向子运行时选中那个节点、详情（用量、产出物）、等 key 冒泡、单个停止 / 停止整棵树、找不到。 */
@OptIn(ExperimentalCoroutinesApi::class)
class RunViewModelTest {
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

    @Test
    fun deepLinkToChildSelectsItInTheWholeTree() = test {
        val vm = RunViewModel(TreeService(), "run-pipeline-write")
        advanceUntilIdle()
        val state = vm.uiState.value
        assertEquals(listOf("run-pipeline", "run-pipeline-research", "run-pipeline-write"), state.nodes.map { it.run.id })
        assertEquals(listOf(0, 1, 1), state.nodes.map { it.depth })
        assertEquals("run-pipeline-write", state.selected?.id)
        assertEquals("weekly-report.md", state.artifacts.single().name)
        assertEquals("小码", state.instanceNames["inst-coder"])
        assertEquals("研究员", state.instanceNames["inst-research"])
        assertFalse(state.hasActive)

        vm.select("run-pipeline")
        advanceUntilIdle()
        assertEquals("run-pipeline", vm.uiState.value.selected?.id)
        assertTrue(vm.uiState.value.artifacts.isEmpty())
    }

    @Test
    fun usageComesFromCachedEvents() = test {
        val vm = RunViewModel(TreeService(), "run-done")
        advanceUntilIdle()
        val usage = vm.uiState.value.usage!!
        assertEquals(10_200L, usage.inputTokens)
        assertEquals(2_640L, usage.outputTokens)
    }

    @Test
    fun waitingStepBubblesToRootAndStopping() = test {
        val service = TreeService()
        val base = service.chat.mock.getRun("run-pipeline")
        service.tree = listOf(
            base.copy(state = RunState.WaitingChildren),
            base.copy(id = "step-a", parentRunId = base.id, state = RunState.WaitingQuota, waitCode = WaitCode.Invalid, instanceId = "inst-research", createdAtMs = base.createdAtMs + 1),
            base.copy(id = "step-b", parentRunId = base.id, state = RunState.Running, createdAtMs = base.createdAtMs + 2),
        )
        val vm = RunViewModel(service, "step-b")
        advanceUntilIdle()
        val state = vm.uiState.value
        assertEquals("step-a", state.rootAttention?.run?.id)
        assertEquals(WaitCode.Invalid, state.rootAttention?.waitCode)
        assertTrue(state.hasActive)

        vm.events.test {
            vm.stop("step-b")
            advanceUntilIdle()
            assertTrue(awaitItem() is RunEvent.Message)
            assertEquals(listOf("step-b" to false), service.cancelled)
            vm.askStopTree()
            assertTrue(vm.uiState.value.confirmStopTree)
            vm.stopTree()
            advanceUntilIdle()
            assertTrue(awaitItem() is RunEvent.Message)
        }
        assertEquals("run-pipeline" to true, service.cancelled.last())
        assertFalse(vm.uiState.value.hasActive)
        assertNull(vm.uiState.value.stopping)
    }

    @Test
    fun missingRunShowsNotFoundAndErrorsCanRetry() = test {
        val service = TreeService()
        service.error = ServiceError.Api(404, "not_found", "gone", null)
        val vm = RunViewModel(service, "nope")
        advanceUntilIdle()
        assertTrue(vm.uiState.value.notFound)

        service.error = ServiceError.Network("down")
        val failing = RunViewModel(service, "run-done")
        advanceUntilIdle()
        assertNotNull(failing.uiState.value.loadError)
        service.error = null
        failing.load()
        advanceUntilIdle()
        assertEquals("run-done", failing.uiState.value.selected?.id)
        assertNull(failing.uiState.value.loadError)
    }
}

