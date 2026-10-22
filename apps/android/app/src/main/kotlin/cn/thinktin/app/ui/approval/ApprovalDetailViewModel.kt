package cn.thinktin.app.ui.approval

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.ApprovalCardData
import cn.thinktin.data.model.ApprovalCards
import cn.thinktin.data.model.Run
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class ApprovalDetailUiState(
    val loading: Boolean = true,
    val card: ApprovalCardData? = null,
    /** 所在实例的名字（拉不到时为 null）。 */
    val instanceName: String? = null,
    /** 所在运行（拉不到时为 null，这时不判作废）。 */
    val run: Run? = null,
    /** 审批不存在（404）。 */
    val notFound: Boolean = false,
    val loadError: UiText? = null,
)

/**
 * 审批详情（13.16，路由 approval/{id}，推送深链 thinktin://approval/{id}、收件箱的审批条目进来）：
 * `getApproval` 什么状态都能查——已处理、过期、取消的显示结果，不当错误；待处理的可以直接批准 / 拒绝。
 * 所在运行已经开始了更新的尝试时作废。
 */
class ApprovalDetailViewModel(
    private val service: ThinktinService,
    gate: ApprovalGate,
    private val approvalId: String,
) : ViewModel() {
    private val state = MutableStateFlow(ApprovalDetailUiState())
    val uiState: StateFlow<ApprovalDetailUiState> = state.asStateFlow()

    val actions = ApprovalActions(
        scope = viewModelScope,
        decider = ApprovalDecider(service, gate),
        onUpdated = ::applyApproval,
        onGone = { state.update { it.copy(card = null, notFound = true) } },
    )

    private var loadJob: Job? = null

    init {
        load()
    }

    fun load() {
        loadJob?.cancel()
        state.update { it.copy(loading = true, loadError = null) }
        loadJob = viewModelScope.launch {
            try {
                val approval = service.getApproval(approvalId)
                // 运行（判作废）和实例名都是附带的：拉不到不影响显示审批本身。
                val (run, name) = coroutineScope {
                    val run = async { runCatchingService { service.getRun(approval.runId) } }
                    val instance = async { runCatchingService { service.instance(approval.instanceId) } }
                    run.await() to instance.await()?.name
                }
                state.update {
                    it.copy(
                        loading = false,
                        card = ApprovalCards.fromApproval(approval, run?.attempt),
                        run = run,
                        instanceName = name,
                        notFound = false,
                        loadError = null,
                    )
                }
            } catch (e: ServiceError) {
                val notFound = e is ServiceError.Api && (e.status == 404 || e.code == "not_found")
                state.update {
                    it.copy(loading = false, notFound = notFound, loadError = if (notFound) null else ErrorText.of(e))
                }
            }
        }
    }

    private fun applyApproval(approval: Approval) {
        state.update { s ->
            val card = s.card
            val attempt = s.run?.attempt
            s.copy(
                card = if (card == null) {
                    ApprovalCards.fromApproval(approval, attempt)
                } else {
                    ApprovalCards.applyDecision(card, approval, attempt)
                },
            )
        }
    }

    private suspend fun <T> runCatchingService(block: suspend () -> T): T? = try {
        block()
    } catch (_: ServiceError) {
        null
    }
}
