package cn.thinktin.app.ui.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.ui.chat.DraftHandoff
import cn.thinktin.data.model.AgentInfo
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.Run
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import cn.thinktin.data.service.asServiceError
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Clock
import java.time.Instant

/** 问候语按时段：早上（5–12 点）、下午（12–18 点）、晚上。 */
enum class Greeting {
    Morning,
    Afternoon,
    Evening,
    ;

    companion object {
        fun at(clock: Clock): Greeting {
            val hour = Instant.ofEpochMilli(clock.millis()).atZone(clock.zone).hour
            return when (hour) {
                in 5..11 -> Morning
                in 12..17 -> Afternoon
                else -> Evening
            }
        }
    }
}

data class HomeUiState(
    val greeting: Greeting,
    val userName: String? = null,
    val instances: List<Instance> = emptyList(),
    val selectedInstanceId: String? = null,
    val recentRuns: List<Run> = emptyList(),
    /** 没有实例时首页展示的目录精选（前 [HomeViewModel.FEATURED_COUNT] 个）。 */
    val featured: List<AgentInfo> = emptyList(),
    /** 第一次加载（缓存也没有）时为真。 */
    val loading: Boolean = true,
    /** 刷新失败（网络等）：显示缓存 + 横幅。 */
    val refreshError: ServiceError? = null,
    val draft: String = "",
    val sending: Boolean = false,
    val isDemo: Boolean = false,
    val nowMs: Long = 0,
) {
    val selectedInstance: Instance? get() = instances.firstOrNull { it.id == selectedInstanceId }
}

sealed interface HomeEvent {
    data class OpenChat(val instanceId: String) : HomeEvent
    data class ShowError(val error: ServiceError) : HomeEvent
}

/**
 * 首页：先用缓存（实例、最近运行）渲染，再联网刷新（第 7 节）。
 */
class HomeViewModel(
    private val service: ThinktinService,
    private val clock: Clock,
    /** 拦下密码时把消息转给对话页（那里有保险箱表单）；null 时只提示。 */
    private val draftHandoff: DraftHandoff? = null,
) : ViewModel() {

    private val state = MutableStateFlow(
        HomeUiState(greeting = Greeting.at(clock), isDemo = service.isDemo, nowMs = clock.millis()),
    )
    val uiState: StateFlow<HomeUiState> = state.asStateFlow()

    private val events = Channel<HomeEvent>(Channel.BUFFERED)
    val uiEvents: Flow<HomeEvent> = events.receiveAsFlow()

    init {
        // 先缓存（cached* 在 IO 线程上读 SQLite），再联网；两步在同一个协程里，联网结果不会被缓存覆盖。
        viewModelScope.launch {
            val cached = service.cachedInstances()
            if (cached.isNotEmpty() && state.value.loading) applyInstances(cached, fromCache = true)
            refreshNow()
        }
    }

    private var shownOnce = false

    /**
     * 首页每次显示时调（从目录领养完、删掉实例回来）：第一次已经在 init 里加载，之后重新取实例列表。
     */
    fun onShown() {
        if (!shownOnce) {
            shownOnce = true
            return
        }
        refresh()
    }

    fun refresh() {
        viewModelScope.launch { refreshNow() }
    }

    private suspend fun refreshNow() {
        state.update { it.copy(greeting = Greeting.at(clock), nowMs = clock.millis()) }
        try {
            applyInstances(service.instances(), fromCache = false)
            state.value.selectedInstanceId?.let { loadRuns(it, network = true) }
            loadFeatured()
            val name = try {
                service.me().displayName
            } catch (_: ServiceError) {
                null
            }
            state.update { it.copy(userName = name, refreshError = null, loading = false) }
        } catch (e: ServiceError) {
            state.update { it.copy(refreshError = e, loading = false) }
        }
    }

    private suspend fun applyInstances(list: List<Instance>, fromCache: Boolean) {
        val visible = list.filter { it.state != InstanceState.Deleted }
        val current = state.value.selectedInstanceId
        val selected = current?.takeIf { id -> visible.any { it.id == id } } ?: defaultInstance(visible)?.id
        state.update {
            it.copy(
                instances = visible,
                selectedInstanceId = selected,
                loading = if (fromCache) false else it.loading,
            )
        }
        if (selected != null && fromCache) {
            val runs = service.cachedRuns(selected, RECENT_LIMIT)
            state.update { it.copy(recentRuns = runs) }
        }
    }

    /** 没有实例时拉目录精选（失败不提示：主按钮照样能进目录）。 */
    private suspend fun loadFeatured() {
        if (state.value.instances.isNotEmpty()) {
            if (state.value.featured.isNotEmpty()) state.update { it.copy(featured = emptyList()) }
            return
        }
        try {
            val agents = service.agents().take(FEATURED_COUNT)
            state.update { it.copy(featured = agents) }
        } catch (_: ServiceError) {
        }
    }

    /** 默认选最近活跃的运行中实例，没有就选最近活跃的。 */
    private fun defaultInstance(list: List<Instance>): Instance? =
        list.filter { it.state == InstanceState.Running }.maxByOrNull { it.lastActiveAtMs }
            ?: list.maxByOrNull { it.lastActiveAtMs }

    private suspend fun loadRuns(instanceId: String, network: Boolean) {
        val cached = service.cachedRuns(instanceId, RECENT_LIMIT)
        if (state.value.selectedInstanceId == instanceId) state.update { it.copy(recentRuns = cached) }
        if (!network) return
        val runs = service.runs(instanceId, RECENT_LIMIT)
        if (state.value.selectedInstanceId == instanceId) state.update { it.copy(recentRuns = runs) }
    }

    fun selectInstance(instanceId: String) {
        if (instanceId == state.value.selectedInstanceId) return
        state.update { it.copy(selectedInstanceId = instanceId) }
        viewModelScope.launch {
            try {
                loadRuns(instanceId, network = true)
            } catch (e: ServiceError) {
                state.update { it.copy(refreshError = e) }
            }
        }
    }

    fun onDraftChange(text: String) {
        state.update { it.copy(draft = text) }
    }

    fun send() {
        val current = state.value
        val instanceId = current.selectedInstanceId ?: return
        val text = current.draft.trim()
        if (text.isEmpty() || current.sending) return
        state.update { it.copy(sending = true) }
        viewModelScope.launch {
            try {
                // 密码拦截（11.6）：有命中先不发。首页没有保险箱表单：把消息转给对话页，在那里弹表单（13.5）。
                val secrets = service.detectSecrets(text)
                if (secrets.isNotEmpty()) {
                    if (draftHandoff == null) throw ServiceError.ContainsSecrets(secrets.size)
                    draftHandoff.put(instanceId, text)
                    state.update { it.copy(draft = "", sending = false) }
                    events.send(HomeEvent.OpenChat(instanceId))
                    return@launch
                }
                service.sendMessage(instanceId, text)
                state.update { it.copy(draft = "", sending = false) }
                loadRuns(instanceId, network = false)
                events.send(HomeEvent.OpenChat(instanceId))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                state.update { it.copy(sending = false) }
                events.send(HomeEvent.ShowError(e.asServiceError()))
            }
        }
    }

    companion object {
        const val RECENT_LIMIT = 20

        /** 首页空状态展示的目录精选个数。 */
        const val FEATURED_COUNT = 3
    }
}
