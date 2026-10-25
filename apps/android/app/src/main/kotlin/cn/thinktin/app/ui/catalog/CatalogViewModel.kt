package cn.thinktin.app.ui.catalog

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.data.model.AgentInfo
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class CatalogUiState(
    val loading: Boolean = true,
    val agents: List<AgentInfo> = emptyList(),
    val query: String = "",
    /** 拉取失败：页面上显示错误和“重试”（已经拉到过的列表照常显示）。 */
    val loadError: ServiceError? = null,
) {
    /** 按搜索框过滤后的 agent。 */
    val visibleAgents: List<AgentInfo> get() = filterAgents(agents, query)

    /** 拉取成功但目录是空的。 */
    val emptyCatalog: Boolean get() = !loading && loadError == null && agents.isEmpty()
}

/**
 * 搜索：名字、一句话介绍、id、许可证、接入方式、协议里包含关键字（不分大小写，空白分隔的每个词都要命中）。
 */
fun filterAgents(agents: List<AgentInfo>, query: String): List<AgentInfo> {
    val words = query.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
    if (words.isEmpty()) return agents
    return agents.filter { agent ->
        val haystack = buildList {
            add(agent.name)
            add(agent.description)
            add(agent.id)
            agent.license?.let(::add)
            addAll(agent.harnesses)
            addAll(agent.protocols)
        }
        words.all { word -> haystack.any { it.contains(word, ignoreCase = true) } }
    }
}

/** Agent 目录（13.3，路由 catalog）：拉取目录、搜索过滤、失败重试。 */
class CatalogViewModel(private val service: ThinktinService) : ViewModel() {
    private val state = MutableStateFlow(CatalogUiState())
    val uiState: StateFlow<CatalogUiState> = state.asStateFlow()

    private var loadJob: Job? = null

    init {
        load()
    }

    /** 拉取（第一次进页面、点“重试”）；正在拉时不重复发。 */
    fun load() {
        if (loadJob?.isActive == true) return
        state.update { it.copy(loading = true, loadError = null) }
        loadJob = viewModelScope.launch {
            try {
                val agents = service.agents()
                state.update { it.copy(loading = false, agents = agents) }
            } catch (e: ServiceError) {
                state.update { it.copy(loading = false, loadError = e) }
            }
        }
    }

    fun onQueryChange(query: String) {
        state.update { it.copy(query = query) }
    }
}
