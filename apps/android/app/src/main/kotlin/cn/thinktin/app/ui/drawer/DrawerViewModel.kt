package cn.thinktin.app.ui.drawer

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.User
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class DrawerUiState(
    val user: User? = null,
    val instances: List<Instance> = emptyList(),
    /** agent id → 显示名（目录拉到之前为空，界面先显示 id）。 */
    val agentNames: Map<String, String> = emptyMap(),
    val unread: Long = 0,
    val query: String = "",
    val isDemo: Boolean = false,
) {
    /** 按搜索框过滤后的实例（名字或 agent id 包含关键字）。 */
    val visibleInstances: List<Instance>
        get() = if (query.isBlank()) {
            instances
        } else {
            instances.filter { it.name.contains(query.trim(), ignoreCase = true) || it.agentId.contains(query.trim(), ignoreCase = true) }
        }
}

/**
 * 抽屉：实例列表、未读数、头像与名字。先缓存（cached* 在 IO 线程上读）、再联网。
 *
 * 抽屉的 ViewModel 在 Activity 作用域里，退出登录后不会销毁：跟着 [ThinktinService.authState] 走，
 * 变成未登录时清空上一个账号的数据，重新登录后再加载，不会显示旧账号的东西。
 */
class DrawerViewModel(private val service: ThinktinService) : ViewModel() {
    private val state = MutableStateFlow(DrawerUiState(isDemo = service.isDemo))
    val uiState: StateFlow<DrawerUiState> = state.asStateFlow()

    private var loadJob: Job? = null

    init {
        viewModelScope.launch {
            service.authState
                .map { it != AuthState.SignedOut }
                .distinctUntilChanged()
                .collect { signedIn ->
                    if (signedIn) {
                        load()
                    } else {
                        loadJob?.cancel()
                        state.value = DrawerUiState(isDemo = service.isDemo, query = state.value.query)
                    }
                }
        }
    }

    /** 新会话：先显示缓存，再联网刷新。 */
    private fun load() {
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            val cached = service.cachedInstances().visible()
            val unread = service.cachedUnread()
            state.update { it.copy(instances = cached, unread = unread) }
            refreshNow()
        }
    }

    fun refresh() {
        viewModelScope.launch { refreshNow() }
    }

    private suspend fun refreshNow() {
        try {
            val instances = service.instances().visible()
            state.update { it.copy(instances = instances) }
            // 实例行显示 agent 名（第 3 节）；目录拉不到就继续显示 id，不影响其余部分。
            if (instances.any { it.agentId !in state.value.agentNames }) {
                try {
                    val names = service.agents().associate { it.id to it.name }
                    state.update { it.copy(agentNames = names) }
                } catch (_: ServiceError) {
                }
            }
            val page = service.syncInbox(limit = 1)
            state.update { it.copy(unread = page.unread) }
            val user = service.me()
            state.update { it.copy(user = user) }
        } catch (_: ServiceError) {
            // 抽屉只是导航：刷新失败就继续显示缓存，错误由各页面自己提示。
        }
    }

    fun onQueryChange(query: String) {
        state.update { it.copy(query = query) }
    }

    private fun List<Instance>.visible() = filter { it.state != InstanceState.Deleted }
}
