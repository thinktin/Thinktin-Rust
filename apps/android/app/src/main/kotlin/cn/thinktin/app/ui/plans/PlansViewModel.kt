package cn.thinktin.app.ui.plans

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.Plan
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
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

data class PlansUiState(
    val loading: Boolean = true,
    val plans: List<Plan> = emptyList(),
    /** 实例 id → 实例（列表上显示实例名；拉不到时显示 id）。 */
    val instances: Map<String, Instance> = emptyMap(),
    val loadError: UiText? = null,
    /** 正在暂停 / 恢复、删除的计划。 */
    val busyPlanId: String? = null,
    /** “拒绝”agent 建的计划（删除）的确认框。 */
    val rejecting: Plan? = null,
) {
    /** agent 新建或修改、等用户确认的（置顶）。 */
    val awaiting: List<Plan> get() = plans.filter { it.awaitingConfirmation }

    /** 在跑的（按下一次触发排，没有下一次的在后）。 */
    val active: List<Plan>
        get() = plans.filter { !it.awaitingConfirmation && !it.paused }
            .sortedWith(compareBy<Plan> { it.nextFireAtMs ?: Long.MAX_VALUE }.thenBy { it.title })

    val paused: List<Plan> get() = plans.filter { !it.awaitingConfirmation && it.paused }

    /** 还没有实例：新建计划前得先领养一个 agent。 */
    val hasInstances: Boolean get() = instances.values.any { it.state != InstanceState.Deleted }
}

sealed interface PlansEvent {
    data class Message(val text: UiText) : PlansEvent
}

/**
 * 计划列表（13.6，路由 plans，第 4.6 节）：等确认的置顶（查看并确认 / 拒绝），其余分“在跑”“已暂停”；
 * 每行标题、实例、下一次触发、状态，可以直接暂停 / 恢复。新建、详情是单独的页面。
 */
class PlansViewModel(private val service: ThinktinService) : ViewModel() {
    private val state = MutableStateFlow(PlansUiState())
    val uiState: StateFlow<PlansUiState> = state.asStateFlow()

    private val eventChannel = Channel<PlansEvent>(Channel.BUFFERED)
    val events: Flow<PlansEvent> = eventChannel.receiveAsFlow()

    private var shownOnce = false

    init {
        load()
    }

    /** 页面每次显示时调（从详情、编辑页回来时重新取）；第一次已经在 init 里加载。 */
    fun onShown() {
        if (!shownOnce) {
            shownOnce = true
            return
        }
        load()
    }

    fun load() {
        state.update { it.copy(loading = it.plans.isEmpty(), loadError = null) }
        viewModelScope.launch {
            try {
                coroutineScope {
                    // 实例拉不到不影响列表：先用缓存，再用网络的。
                    val instances = async {
                        try {
                            service.instances()
                        } catch (_: ServiceError) {
                            service.cachedInstances()
                        }
                    }
                    val plans = service.plans()
                    val byId = instances.await().associateBy { it.id }
                    state.update { it.copy(loading = false, plans = plans, instances = byId.ifEmpty { it.instances }) }
                }
            } catch (e: ServiceError) {
                state.update { it.copy(loading = false, loadError = ErrorText.of(e)) }
            }
        }
    }

    /** 暂停（到点不再触发）或恢复（从现在起重新算下一次，暂停期间错过的不补）。等确认的计划要去详情页确认。 */
    fun setPaused(plan: Plan, paused: Boolean) {
        if (state.value.busyPlanId != null || plan.awaitingConfirmation) return
        state.update { it.copy(busyPlanId = plan.id) }
        viewModelScope.launch {
            try {
                val updated = service.setPlanPaused(plan.id, paused)
                replace(updated)
                message(UiText(if (paused) R.string.plans_paused_done else R.string.plans_resumed_done, listOf(updated.title)))
            } catch (e: ServiceError) {
                message(blockedOr(e, plan, state.value.instances))
            } finally {
                state.update { it.copy(busyPlanId = null) }
            }
        }
    }

    fun askReject(plan: Plan) {
        if (state.value.busyPlanId == null) state.update { it.copy(rejecting = plan) }
    }

    fun dismissReject() {
        if (state.value.busyPlanId == null) state.update { it.copy(rejecting = null) }
    }

    /** 拒绝 agent 建、改的计划：删掉它（agent 改的也一样，没有“退回原版本”的接口）。 */
    fun confirmReject() {
        val plan = state.value.rejecting ?: return
        state.update { it.copy(busyPlanId = plan.id) }
        viewModelScope.launch {
            try {
                service.deletePlan(plan.id)
                state.update { s -> s.copy(plans = s.plans.filterNot { it.id == plan.id }, rejecting = null) }
                message(UiText(R.string.plans_rejected_done, listOf(plan.title)))
            } catch (e: ServiceError) {
                state.update { it.copy(rejecting = null) }
                message(ErrorText.of(e))
            } finally {
                state.update { it.copy(busyPlanId = null) }
            }
        }
    }

    private fun replace(updated: Plan) {
        state.update { s -> s.copy(plans = s.plans.map { if (it.id == updated.id) updated else it }) }
    }

    private fun message(text: UiText) {
        eventChannel.trySend(PlansEvent.Message(text))
    }

    companion object {
        /**
         * 恢复、确认时 409：流水线有一步在已删除的实例上（11.9，删除实例时暂停了它），要先改步骤。和 iOS 一样按实例列表认
         * （不看服务端的英文说明）：步骤的实例已删除或不在列表里。认不出时按一般的冲突说。
         */
        fun blockedOr(e: ServiceError, plan: Plan, instances: Map<String, Instance>): UiText =
            if (e is ServiceError.Api && (e.status == 409 || e.code == "conflict") && blockedSteps(plan, instances).isNotEmpty()) {
                UiText(R.string.plan_blocked_steps)
            } else {
                ErrorText.of(e)
            }

        /** 在已删除（或已经看不到）的实例上的步骤。实例列表是空的（没拉到）时不判断。 */
        fun blockedSteps(plan: Plan, instances: Map<String, Instance>) =
            if (instances.isEmpty()) {
                emptyList()
            } else {
                plan.steps.filter { step -> instances[step.instanceId]?.state.let { it == null || it == InstanceState.Deleted } }
            }
    }
}
