package cn.thinktin.app.ui.drawer

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.computer.ComputerLinkStore
import cn.thinktin.data.model.DeviceMessage
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.User
import cn.thinktin.data.model.pendingApprovals
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
    /** 待处理的审批数（13.16）。 */
    val pendingApprovals: Int = 0,
    /** 电脑发来、等这台手机批准的操作（13.9）。 */
    val computerApprovals: Int = 0,
    val query: String = "",
    val isDemo: Boolean = false,
) {
    /** 审批的角标：云端的加上电脑发来的。 */
    val approvalsBadge: Int get() = pendingApprovals + computerApprovals

    /** 按搜索框过滤后的实例（实例名、agent 的显示名或 agent id 包含关键字，不分大小写）。 */
    val visibleInstances: List<Instance>
        get() {
            val q = query.trim()
            if (q.isEmpty()) return instances
            return instances.filter {
                it.name.contains(q, ignoreCase = true) ||
                    agentNames[it.agentId].orEmpty().contains(q, ignoreCase = true) ||
                    it.agentId.contains(q, ignoreCase = true)
            }
        }
}

/**
 * 抽屉：实例列表、未读数、头像与名字。先缓存（cached* 在 IO 线程上读）、再联网。
 *
 * 抽屉的 ViewModel 在 Activity 作用域里，退出登录后不会销毁：跟着 [ThinktinService.authState] 走，
 * 变成未登录时清空上一个账号的数据，重新登录后再加载，不会显示旧账号的东西。
 *
 * 审批的角标也数电脑发来的（[computerLinks]，App 里的那一份）：审批中心处理了就跟着变；服务端还没收下的新请求在刷新时数。
 */
class DrawerViewModel(
    private val service: ThinktinService,
    private val computerLinks: ComputerLinkStore? = null,
    private val nowSecs: () -> Long = { System.currentTimeMillis() / 1000 },
) : ViewModel() {
    private val state = MutableStateFlow(DrawerUiState(isDemo = service.isDemo))
    val uiState: StateFlow<DrawerUiState> = state.asStateFlow()

    private var loadJob: Job? = null
    private var computerJob: Job? = null
    private var computerUser: String? = null
    private var computerMessages: List<DeviceMessage> = emptyList()

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
                        computerJob?.cancel()
                        computerJob = null
                        computerUser = null
                        computerMessages = emptyList()
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
            // 审批角标单独取：失败不影响其余部分。
            try {
                val pending = service.approvals().size
                state.update { it.copy(pendingApprovals = pending) }
            } catch (_: ServiceError) {
            }
            val page = service.syncInbox(limit = 1)
            state.update { it.copy(unread = page.unread) }
            val user = service.me()
            state.update { it.copy(user = user) }
            refreshComputerApprovals(user.id)
        } catch (_: ServiceError) {
            // 抽屉只是导航：刷新失败就继续显示缓存，错误由各页面自己提示。
        }
    }

    /** 电脑发来的审批：收一下服务端的新消息（只数，不确认），再跟着本机存的状态变。拉不到就只数存着的。 */
    private suspend fun refreshComputerApprovals(userId: String) {
        val links = computerLinks ?: return
        computerMessages = try {
            service.deviceMessages()
        } catch (_: ServiceError) {
            emptyList()
        }
        if (computerUser != userId) {
            computerJob?.cancel()
            computerUser = userId
            computerJob = viewModelScope.launch {
                var first = true
                links.state(userId).collect { linkState ->
                    // 存的状态变了：审批中心已经收下、确认掉了服务端的消息（之前取的那批会重复数），只数存着的。
                    if (!first) computerMessages = emptyList()
                    first = false
                    state.update { it.copy(computerApprovals = linkState.pendingApprovals(computerMessages, nowSecs())) }
                }
            }
        } else {
            val count = links.state(userId).value.pendingApprovals(computerMessages, nowSecs())
            state.update { it.copy(computerApprovals = count) }
        }
    }

    fun onQueryChange(query: String) {
        state.update { it.copy(query = query) }
    }

    private fun List<Instance>.visible() = filter { it.state != InstanceState.Deleted }
}
