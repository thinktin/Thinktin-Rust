package cn.thinktin.app.ui.plans

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.Plan
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunFilter
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class PlanDetailUiState(
    val loading: Boolean = true,
    val plan: Plan? = null,
    val instances: Map<String, Instance> = emptyMap(),
    val loadError: UiText? = null,
    /** 计划不在了（删掉了、别的设备上拒绝了）。 */
    val notFound: Boolean = false,
    /** 运行历史（新的在前，只要根运行：流水线一次触发一行）。 */
    val runs: List<Run> = emptyList(),
    val runsLoading: Boolean = false,
    val hasMoreRuns: Boolean = false,
    val runsError: UiText? = null,
    val pausing: Boolean = false,
    val confirming: Boolean = false,
    val deleting: Boolean = false,
    val confirmDelete: Boolean = false,
    /** 确认时发现计划刚被 agent 又改过：内容已经换成新的，请再看一遍。 */
    val changedSinceShown: Boolean = false,
) {
    val busy: Boolean get() = pausing || confirming || deleting

    /** 流水线在已删除的实例上的步骤（11.9）：恢复、确认前要先改步骤。 */
    val blockedSteps get() = plan?.let { PlansViewModel.blockedSteps(it, instances) }.orEmpty()
}

sealed interface PlanDetailEvent {
    data class Message(val text: UiText) : PlanDetailEvent

    /** 删掉了：回列表。 */
    data object Deleted : PlanDetailEvent
}

/**
 * 计划详情（13.6，路由 plan/{planId}，深链 thinktin://plan/{id}）：目标、触发规则（下一次、失效停用的提示）、策略、
 * 补跑方式、流水线步骤（只读，编辑在 13.7）、运行历史；暂停 / 恢复、编辑、删除；agent 新建或修改的计划在这里确认
 * （带看到的版本号，冲突时换成新内容、提示再看一遍）。
 */
class PlanDetailViewModel(
    private val service: ThinktinService,
    private val planId: String,
) : ViewModel() {
    private val state = MutableStateFlow(PlanDetailUiState())
    val uiState: StateFlow<PlanDetailUiState> = state.asStateFlow()

    private val eventChannel = Channel<PlanDetailEvent>(Channel.BUFFERED)
    val events: Flow<PlanDetailEvent> = eventChannel.receiveAsFlow()

    private var shownOnce = false

    init {
        load()
    }

    /** 页面每次显示时调（从编辑页回来时重新取）；第一次已经在 init 里加载。 */
    fun onShown() {
        if (!shownOnce) {
            shownOnce = true
            return
        }
        load()
    }

    fun load() {
        state.update { it.copy(loading = it.plan == null, loadError = null) }
        viewModelScope.launch {
            val instances = try {
                service.instances()
            } catch (_: ServiceError) {
                service.cachedInstances()
            }
            state.update { s -> s.copy(instances = instances.associateBy { it.id }.ifEmpty { s.instances }) }
            try {
                val plan = service.getPlan(planId)
                state.update { it.copy(loading = false, plan = plan, notFound = false) }
            } catch (e: ServiceError) {
                if (e.isNotFound) {
                    state.update { it.copy(loading = false, notFound = true) }
                    return@launch
                }
                val error = ErrorText.of(e)
                if (state.value.plan != null) eventChannel.trySend(PlanDetailEvent.Message(error))
                state.update { it.copy(loading = false, loadError = error) }
                return@launch
            }
            loadRuns(reset = true)
        }
    }

    /** 运行历史：第一页，或者接着往下翻。 */
    fun loadRuns(reset: Boolean = false) {
        val s = state.value
        if (s.runsLoading || (!reset && !s.hasMoreRuns)) return
        state.update { it.copy(runsLoading = true, runsError = null) }
        viewModelScope.launch {
            try {
                val before = if (reset) null else state.value.runs.lastOrNull()?.id
                val page = service.listRuns(RunFilter(planId = planId, rootsOnly = true), before, RUNS_PAGE)
                state.update {
                    it.copy(
                        runs = if (reset) page else it.runs + page.filter { r -> it.runs.none { o -> o.id == r.id } },
                        hasMoreRuns = page.size >= RUNS_PAGE,
                    )
                }
            } catch (e: ServiceError) {
                state.update { it.copy(runsError = ErrorText.of(e)) }
            } finally {
                state.update { it.copy(runsLoading = false) }
            }
        }
    }

    fun setPaused(paused: Boolean) {
        val plan = state.value.plan ?: return
        if (state.value.busy || plan.awaitingConfirmation) return
        state.update { it.copy(pausing = true) }
        viewModelScope.launch {
            try {
                val updated = service.setPlanPaused(planId, paused)
                state.update { it.copy(plan = updated) }
                message(UiText(if (paused) R.string.plans_paused_done else R.string.plans_resumed_done, listOf(updated.title)))
            } catch (e: ServiceError) {
                message(PlansViewModel.blockedOr(e, plan, state.value.instances))
            } finally {
                state.update { it.copy(pausing = false) }
            }
        }
    }

    /**
     * 确认 agent 新建或修改的计划（带用户看到的版本号）。冲突时重新拉：还在等确认、版本变了的换成新内容、提示再看一遍；
     * 版本没变的是流水线有步骤在已删除的实例上（先改步骤）；已经不用确认的（别处确认过）说一声。
     */
    fun confirm() {
        val plan = state.value.plan ?: return
        if (state.value.busy || !plan.awaitingConfirmation) return
        state.update { it.copy(confirming = true) }
        viewModelScope.launch {
            try {
                val updated = service.confirmPlan(planId, plan.revision)
                state.update { it.copy(plan = updated, changedSinceShown = false) }
                message(UiText(R.string.plan_confirmed_done, listOf(updated.title)))
            } catch (e: ServiceError) {
                if (e.isConflict) onConfirmConflict(plan, e) else message(ErrorText.of(e))
            } finally {
                state.update { it.copy(confirming = false) }
            }
        }
    }

    private suspend fun onConfirmConflict(shown: Plan, error: ServiceError) {
        val fresh = try {
            service.getPlan(planId)
        } catch (e: ServiceError) {
            if (e.isNotFound) {
                state.update { it.copy(notFound = true) }
            } else {
                message(ErrorText.of(error))
            }
            return
        }
        state.update { it.copy(plan = fresh) }
        when {
            !fresh.awaitingConfirmation -> message(UiText(R.string.plan_already_confirmed))
            fresh.revision != shown.revision -> {
                state.update { it.copy(changedSinceShown = true) }
                message(UiText(R.string.plan_changed_since_shown))
            }
            else -> message(PlansViewModel.blockedOr(error, fresh, state.value.instances))
        }
    }

    fun askDelete() {
        if (!state.value.busy) state.update { it.copy(confirmDelete = true) }
    }

    fun dismissDelete() {
        if (!state.value.deleting) state.update { it.copy(confirmDelete = false) }
    }

    fun delete() {
        if (state.value.busy) return
        state.update { it.copy(deleting = true) }
        viewModelScope.launch {
            try {
                service.deletePlan(planId)
                state.update { it.copy(confirmDelete = false) }
                eventChannel.trySend(PlanDetailEvent.Deleted)
            } catch (e: ServiceError) {
                state.update { it.copy(confirmDelete = false) }
                message(ErrorText.of(e))
            } finally {
                state.update { it.copy(deleting = false) }
            }
        }
    }

    private fun message(text: UiText) {
        eventChannel.trySend(PlanDetailEvent.Message(text))
    }

    companion object {
        const val RUNS_PAGE = 20

        private val ServiceError.isNotFound: Boolean
            get() = this is ServiceError.Api && (status == 404 || code == "not_found")

        private val ServiceError.isConflict: Boolean
            get() = this is ServiceError.Api && (status == 409 || code == "conflict")
    }
}
