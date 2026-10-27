package cn.thinktin.app.ui.run

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.Artifact
import cn.thinktin.data.model.EventKinds
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunAttention
import cn.thinktin.data.model.RunTreeNode
import cn.thinktin.data.model.RunTrees
import cn.thinktin.data.model.long
import cn.thinktin.data.model.obj
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** agent.usage 里的输入 / 输出 token（ACP 的 usage；字段名两种写法都认）。 */
data class RunUsage(val inputTokens: Long?, val outputTokens: Long?)

data class RunUiState(
    val loading: Boolean = true,
    /** 选中的运行（深链指向的；在树上点别的节点会换）。 */
    val selectedId: String,
    val nodes: List<RunTreeNode> = emptyList(),
    val artifacts: List<Artifact> = emptyList(),
    val usage: RunUsage? = null,
    /** 实例 id → 名字（拉不到的显示 id）。 */
    val instanceNames: Map<String, String> = emptyMap(),
    val notFound: Boolean = false,
    val loadError: UiText? = null,
    /** 正在停止的运行（整棵树时是根）。 */
    val stopping: String? = null,
    val confirmStopTree: Boolean = false,
) {
    val selected: Run? get() = nodes.firstOrNull { it.run.id == selectedId }?.run
    val root: RunTreeNode? get() = nodes.firstOrNull { it.depth == 0 }

    /** 根节点要显示的等待（子孙里卡住的冒泡上来，第 8.6 节）。 */
    val rootAttention: RunAttention? get() = root?.attention
    val hasActive: Boolean get() = RunTrees.hasActive(nodes)
}

sealed interface RunEvent {
    data class Message(val text: UiText) : RunEvent
}

/**
 * 运行页（13.5，路由 run/{runId}，深链 thinktin://run/{id}）：运行详情（状态、来源、尝试次数、用量、摘要 / 错误、
 * 产出物）+ 运行树（runTree：缩进树，单个停止、停止整棵树）。深链指向子运行时选中树上的那个节点。
 */
class RunViewModel(
    private val service: ThinktinService,
    runId: String,
) : ViewModel() {
    private val state = MutableStateFlow(RunUiState(selectedId = runId))
    val uiState: StateFlow<RunUiState> = state.asStateFlow()

    private val eventChannel = Channel<RunEvent>(Channel.BUFFERED)
    val events: Flow<RunEvent> = eventChannel.receiveAsFlow()

    private var loadJob: Job? = null
    private var detailJob: Job? = null

    init {
        load()
    }

    fun load() {
        loadJob?.cancel()
        state.update { it.copy(loading = true, loadError = null) }
        loadJob = viewModelScope.launch {
            try {
                val nodes = loadTree()
                state.update { it.copy(loading = false, nodes = nodes, notFound = false) }
                loadNames(nodes.map { it.run.instanceId }.distinct())
                loadDetail()
            } catch (e: ServiceError) {
                val notFound = e is ServiceError.Api && (e.status == 404 || e.code == "not_found")
                state.update { it.copy(loading = false, notFound = notFound, loadError = if (notFound) null else ErrorText.of(e)) }
            }
        }
    }

    /** 从根取整棵树（深链可能指向子运行）；树里没有它自己时补上。 */
    private suspend fun loadTree(): List<RunTreeNode> {
        val run = service.getRun(state.value.selectedId)
        val tree = service.runTree(run.rootRunId)
        return RunTrees.build(if (tree.any { it.id == run.id }) tree else tree + run)
    }

    /** 在树上点了一个节点：详情换成它。 */
    fun select(runId: String) {
        if (runId == state.value.selectedId) return
        state.update { it.copy(selectedId = runId, artifacts = emptyList(), usage = null) }
        loadDetail()
    }

    private suspend fun loadNames(ids: List<String>) {
        val names = try {
            service.instances().associate { it.id to it.name }
        } catch (_: ServiceError) {
            service.cachedInstances().associate { it.id to it.name }
        }
        state.update { it.copy(instanceNames = names.filterKeys { id -> id in ids }) }
    }

    /** 选中运行的产出物和用量（附带的：拉不到不报错）。 */
    private fun loadDetail() {
        detailJob?.cancel()
        val run = state.value.selected ?: return
        detailJob = viewModelScope.launch {
            val (artifacts, usage) = coroutineScope {
                val artifacts = async {
                    try {
                        service.runArtifacts(run.id)
                    } catch (_: ServiceError) {
                        emptyList()
                    }
                }
                val usage = async { usageOf(run) }
                artifacts.await() to usage.await()
            }
            state.update { if (it.selectedId == run.id) it.copy(artifacts = artifacts, usage = usage) else it }
        }
    }

    /** 最近一次 agent.usage（本机缓存里这个运行的事件）。 */
    private suspend fun usageOf(run: Run): RunUsage? {
        val events = service.cachedEventsBefore(run.instanceId, null, ThinktinService.DEFAULT_EVENTS)
        val raw = events.lastOrNull { it.runId == run.id && it.kind == EventKinds.AGENT_USAGE }?.payload ?: return null
        val usage = raw.obj("raw") ?: raw
        val input = usage.long("input_tokens") ?: usage.long("inputTokens")
        val output = usage.long("output_tokens") ?: usage.long("outputTokens")
        return if (input == null && output == null) null else RunUsage(input, output)
    }

    /** 停止一个运行（只停它自己）。 */
    fun stop(runId: String) = cancel(runId, wholeTree = false)

    fun askStopTree() {
        state.update { it.copy(confirmStopTree = true) }
    }

    fun dismissStopTree() {
        state.update { it.copy(confirmStopTree = false) }
    }

    /** 停止整棵树（从根停）。 */
    fun stopTree() {
        val root = state.value.root?.run?.id ?: return
        state.update { it.copy(confirmStopTree = false) }
        cancel(root, wholeTree = true)
    }

    private fun cancel(runId: String, wholeTree: Boolean) {
        if (state.value.stopping != null) return
        state.update { it.copy(stopping = runId) }
        viewModelScope.launch {
            try {
                service.cancelRun(runId, wholeTree)
                eventChannel.trySend(RunEvent.Message(UiText(R.string.run_tree_stopped)))
                state.update { it.copy(nodes = loadTree()) }
            } catch (e: ServiceError) {
                eventChannel.trySend(RunEvent.Message(ErrorText.of(e)))
            } finally {
                state.update { it.copy(stopping = null) }
            }
        }
    }
}
