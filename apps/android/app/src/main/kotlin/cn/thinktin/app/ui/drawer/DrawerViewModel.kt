package cn.thinktin.app.ui.drawer

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.User
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class DrawerUiState(
    val user: User? = null,
    val instances: List<Instance> = emptyList(),
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

/** 抽屉：实例列表、未读数、头像与名字。先缓存、再联网。 */
class DrawerViewModel(private val service: ThinktinService) : ViewModel() {
    private val state = MutableStateFlow(
        DrawerUiState(
            instances = service.cachedInstances().visible(),
            unread = service.cachedUnread(),
            isDemo = service.isDemo,
        ),
    )
    val uiState: StateFlow<DrawerUiState> = state.asStateFlow()

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            try {
                val instances = service.instances().visible()
                state.update { it.copy(instances = instances) }
                val page = service.syncInbox(limit = 1)
                state.update { it.copy(unread = page.unread) }
                val user = service.me()
                state.update { it.copy(user = user) }
            } catch (_: ServiceError) {
                // 抽屉只是导航：刷新失败就继续显示缓存，错误由各页面自己提示。
            }
        }
    }

    fun onQueryChange(query: String) {
        state.update { it.copy(query = query) }
    }

    private fun List<Instance>.visible() = filter { it.state != InstanceState.Deleted }
}
