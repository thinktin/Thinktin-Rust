package cn.thinktin.app.ui.approval

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.ApprovalCardData
import cn.thinktin.data.model.ApprovalCards
import cn.thinktin.data.model.Instance
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** 一个实例的待处理审批。[instanceName] 拉不到实例时为 null（界面显示“已删除的实例”）。 */
data class ApprovalGroup(val instanceId: String, val instanceName: String?, val cards: List<ApprovalCardData>)

data class ApprovalCenterUiState(
    /** 第一次加载（还没有数据）。 */
    val loading: Boolean = true,
    /** 下拉刷新中。 */
    val refreshing: Boolean = false,
    val groups: List<ApprovalGroup> = emptyList(),
    /** 加载失败且没有数据：整页显示错误和重试；有数据时刷新失败用 Snackbar。 */
    val loadError: UiText? = null,
) {
    val isEmpty: Boolean get() = groups.isEmpty()

    /** 还能处理的条数（顶栏、读屏用）。 */
    val pendingCount: Int get() = groups.sumOf { g -> g.cards.count { it.canDecide } }
}

/**
 * 审批中心（13.16，路由 approvals）：跨实例的待处理审批（`approvals()`），按实例分组，下拉刷新。
 *
 * - 每条审批查一次所在运行（`getRun`）拿当前的尝试：待处理但 attempt 比它小的作废（不能再批），
 *   查不到运行的照常显示；
 * - 决定之后卡片原地变成结果（留到下次刷新，刷新后只剩待处理的）；已处理 / 过期的显示最新结果，审批没了就移走。
 */
class ApprovalCenterViewModel(
    private val service: ThinktinService,
    gate: ApprovalGate,
) : ViewModel() {
    private val state = MutableStateFlow(ApprovalCenterUiState())
    val uiState: StateFlow<ApprovalCenterUiState> = state.asStateFlow()

    val actions = ApprovalActions(
        scope = viewModelScope,
        decider = ApprovalDecider(service, gate),
        onUpdated = ::applyApproval,
        onGone = ::removeApproval,
    )

    private val noticeChannel = Channel<UiText>(Channel.BUFFERED)

    /** 刷新失败（已经有列表时）的提示。 */
    val notices: Flow<UiText> = noticeChannel.receiveAsFlow()

    /** 实例名：先缓存，联网拿到后更新。 */
    private var instanceNames: Map<String, String> = emptyMap()
    /** 各运行当前的尝试（上次加载时查到的）。 */
    private var attempts: Map<String, Int> = emptyMap()
    private var loadJob: Job? = null
    private var shownOnce = false

    init {
        viewModelScope.launch {
            instanceNames = service.cachedInstances().names()
            load(initial = true)
        }
    }

    /** 页面每次显示时调：第一次已经在 init 里加载了；之后（比如从详情页处理完回来）重新取。 */
    fun onShown() {
        if (!shownOnce) {
            shownOnce = true
            return
        }
        refresh()
    }

    /** 下拉刷新。 */
    fun refresh() = load(initial = false)

    /** 整页错误上的“重试”：显示加载中。 */
    fun retry() = load(initial = true)

    private fun load(initial: Boolean) {
        loadJob?.cancel()
        state.update { it.copy(loading = initial, refreshing = !initial, loadError = null) }
        loadJob = viewModelScope.launch {
            try {
                val approvals = service.approvals()
                attempts = currentAttempts(approvals)
                try {
                    instanceNames = service.instances().names()
                } catch (_: ServiceError) {
                    // 实例名拉不到：用缓存里的，没有就显示“已删除的实例”。
                }
                val cards = approvals.map { ApprovalCards.fromApproval(it, attempts[it.runId]) }
                state.update { it.copy(loading = false, refreshing = false, groups = group(cards), loadError = null) }
            } catch (e: ServiceError) {
                val text = ErrorText.of(e)
                // 已经有列表：保留，错误用 Snackbar；没有列表：整页显示错误和重试。
                if (!state.value.isEmpty) noticeChannel.trySend(text)
                state.update {
                    it.copy(loading = false, refreshing = false, loadError = if (it.isEmpty) text else null)
                }
            }
        }
    }

    /** 各运行当前的尝试（查不到的不判作废）。 */
    private suspend fun currentAttempts(approvals: List<Approval>): Map<String, Int> = coroutineScope {
        approvals.map { it.runId }.distinct().map { runId ->
            async {
                try {
                    runId to service.getRun(runId).attempt
                } catch (_: ServiceError) {
                    null
                }
            }
        }.awaitAll().filterNotNull().toMap()
    }

    /** 新的实例在前（按组里最新的审批），组内新的在前。 */
    private fun group(cards: List<ApprovalCardData>): List<ApprovalGroup> =
        cards.groupBy { it.instanceId.orEmpty() }
            .map { (instanceId, list) ->
                ApprovalGroup(
                    instanceId = instanceId,
                    instanceName = instanceNames[instanceId],
                    cards = list.sortedByDescending { it.createdAtMs ?: 0 },
                )
            }
            .sortedByDescending { g -> g.cards.maxOf { it.createdAtMs ?: 0 } }

    private fun applyApproval(approval: Approval) {
        state.update { s ->
            s.copy(
                groups = s.groups.map { g ->
                    g.copy(
                        cards = g.cards.map {
                            if (it.approvalId == approval.id) {
                                ApprovalCards.applyDecision(it, approval, attempts[approval.runId])
                            } else {
                                it
                            }
                        },
                    )
                },
            )
        }
    }

    private fun removeApproval(approvalId: String) {
        state.update { s ->
            s.copy(
                groups = s.groups
                    .map { g -> g.copy(cards = g.cards.filterNot { it.approvalId == approvalId }) }
                    .filter { it.cards.isNotEmpty() },
            )
        }
    }

    private fun List<Instance>.names(): Map<String, String> = associate { it.id to it.name }
}
