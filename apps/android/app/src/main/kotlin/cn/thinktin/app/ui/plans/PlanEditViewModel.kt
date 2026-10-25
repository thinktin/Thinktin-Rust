package cn.thinktin.app.ui.plans

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.CatchUp
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.NewPlan
import cn.thinktin.data.model.Plan
import cn.thinktin.data.model.PlanChange
import cn.thinktin.data.model.PlanStep
import cn.thinktin.data.schedule.TriggerDraft
import cn.thinktin.data.schedule.TriggerProblem
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
import java.time.Clock

/** 新建还是编辑。 */
sealed interface PlanEditMode {
    /** 新建；[instanceId] 是预选的实例。 */
    data class Create(val instanceId: String?) : PlanEditMode
    data class Edit(val planId: String) : PlanEditMode
}

/** 正在编的一条触发规则（盖在页面上的底部面板）：[itemId] 为 null 是新加的。 */
data class TriggerEditing(val itemId: String?, val draft: TriggerDraft, val problem: TriggerProblem? = null)

/** 计划表单的问题（保存按钮灰掉的原因）。 */
sealed interface PlanFormProblem {
    data object NoInstance : PlanFormProblem
    data class Title(val problem: TextProblem) : PlanFormProblem
    data class Goal(val problem: TextProblem) : PlanFormProblem
    data object NoTriggers : PlanFormProblem
    data object TooManyTriggers : PlanFormProblem
    data class Policy(val problem: PolicyProblem) : PlanFormProblem
}

data class PlanEditUiState(
    val mode: PlanEditMode,
    val loading: Boolean = false,
    val loadError: UiText? = null,
    val notFound: Boolean = false,
    /** 能选的实例（新建时；已删除的不列）。 */
    val instances: List<Instance> = emptyList(),
    val instanceId: String? = null,
    val title: String = "",
    val goal: String = "",
    val triggers: List<TriggerItem> = emptyList(),
    val policy: PlanPolicyDraft = PlanPolicyDraft(),
    val catchUp: CatchUp = CatchUp.Once,
    /** 流水线的步骤（只读；编辑在 13.7）。 */
    val steps: List<PlanStep> = emptyList(),
    /** 编辑时：接口上现在的计划（保存了一部分之后会更新）。 */
    val original: Plan? = null,
    /** 编辑时删掉的已有触发器（保存时 deleteTrigger）。 */
    val removedTriggerIds: List<String> = emptyList(),
    val editing: TriggerEditing? = null,
    val saving: Boolean = false,
    val saveError: UiText? = null,
    /** 保存失败时已经存上了一部分（再点保存只做剩下的）。 */
    val partiallySaved: Boolean = false,
    /** 关掉前确认放弃修改。 */
    val confirmDiscard: Boolean = false,
) {
    val isEditing: Boolean get() = mode is PlanEditMode.Edit

    /** 编辑、但计划还没拉到。 */
    val needsLoad: Boolean get() = isEditing && original == null

    val problems: List<PlanFormProblem>
        get() = buildList {
            if (instanceId == null) add(PlanFormProblem.NoInstance)
            PlanText.check(title, PlanLimits.MAX_TITLE)?.let { add(PlanFormProblem.Title(it)) }
            PlanText.check(goal, PlanLimits.MAX_GOAL)?.let { add(PlanFormProblem.Goal(it)) }
            if (triggers.isEmpty()) add(PlanFormProblem.NoTriggers)
            if (triggers.size > PlanLimits.MAX_TRIGGERS) add(PlanFormProblem.TooManyTriggers)
            policy.problems.forEach { add(PlanFormProblem.Policy(it)) }
        }

    /** 编辑时：标题、目标、策略、补跑方式里改了的（没改的不带）。 */
    val change: PlanChange
        get() {
            val o = original ?: return PlanChange()
            val t = title.trim()
            val g = goal.trim()
            val p = policy.policy
            return PlanChange(
                title = t.takeIf { it != o.title },
                goal = g.takeIf { it != o.goal },
                policy = p?.takeIf { it != o.policy },
                catchUp = catchUp.takeIf { it != o.catchUp },
            )
        }

    val hasChanges: Boolean
        get() = if (isEditing) {
            change != PlanChange() || removedTriggerIds.isNotEmpty() || triggers.any { it.isNew }
        } else {
            title.isNotBlank() || goal.isNotBlank() || triggers.isNotEmpty() || policy != PlanPolicyDraft() ||
                catchUp != CatchUp.Once
        }

    val canAddTrigger: Boolean get() = triggers.size < PlanLimits.MAX_TRIGGERS

    val canSave: Boolean get() = problems.isEmpty() && !saving && !needsLoad && (!isEditing || hasChanges)
}

sealed interface PlanEditEvent {
    /** 存好了：回到上一页（新建的去详情）。 */
    data class Saved(val plan: Plan, val created: Boolean) : PlanEditEvent

    /** 放弃修改、关掉。 */
    data object Closed : PlanEditEvent
}

/**
 * 新建、编辑计划（13.6，路由 plans/new、plan/{id}/edit）：实例（新建时选）、标题（最多 100 字）、目标（最多 8000 字）、
 * 触发规则（1 到 10 条，用 [TriggerDraft] 编）、策略、补跑方式。流水线的步骤只读（编辑在 13.7），保存时不动。
 *
 * 保存：新建 `createPlan`；编辑 `updatePlan` 只带改了的字段，触发器服务端没有“改”：删掉的 `deleteTrigger`、新加的
 * （包括改过的，改一条 = 删旧的、加新的）`addTrigger`，先删后加（免得满 10 条加不进去）。中途失败时已经做完的不再重做，
 * 再点保存只做剩下的。和 iOS 的 `PlanEditorModel` 一致。
 */
class PlanEditViewModel(
    private val service: ThinktinService,
    private val clock: Clock,
    mode: PlanEditMode,
) : ViewModel() {
    private val state = MutableStateFlow(
        PlanEditUiState(mode = mode, instanceId = (mode as? PlanEditMode.Create)?.instanceId, loading = mode is PlanEditMode.Edit),
    )
    val uiState: StateFlow<PlanEditUiState> = state.asStateFlow()

    private val eventChannel = Channel<PlanEditEvent>(Channel.BUFFERED)
    val events: Flow<PlanEditEvent> = eventChannel.receiveAsFlow()

    init {
        load()
    }

    fun load() {
        viewModelScope.launch {
            val instances = try {
                service.instances()
            } catch (_: ServiceError) {
                service.cachedInstances()
            }.filter { it.state != InstanceState.Deleted }
            state.update { s ->
                // 新建时只有一个实例：直接选它。
                val picked = s.instanceId ?: instances.singleOrNull()?.id?.takeIf { !s.isEditing }
                s.copy(instances = instances, instanceId = picked)
            }
            val mode = state.value.mode as? PlanEditMode.Edit ?: return@launch
            if (state.value.original != null) return@launch
            state.update { it.copy(loading = true, loadError = null) }
            try {
                fill(service.getPlan(mode.planId))
            } catch (e: ServiceError) {
                if (e is ServiceError.Api && (e.status == 404 || e.code == "not_found")) {
                    state.update { it.copy(loading = false, notFound = true) }
                } else {
                    state.update { it.copy(loading = false, loadError = ErrorText.of(e)) }
                }
            }
        }
    }

    private fun fill(plan: Plan) {
        state.update {
            it.copy(
                loading = false,
                original = plan,
                instanceId = plan.instanceId,
                title = plan.title,
                goal = plan.goal,
                triggers = plan.triggers.map(TriggerItem::existing),
                policy = PlanPolicyDraft(plan.policy),
                catchUp = plan.catchUp.takeIf { c -> c != CatchUp.Unknown } ?: CatchUp.Once,
                steps = plan.steps,
                removedTriggerIds = emptyList(),
            )
        }
    }

    // ---- 表单 ----

    fun setInstance(id: String) {
        if (!state.value.isEditing) state.update { it.copy(instanceId = id, saveError = null) }
    }

    fun setTitle(text: String) = state.update { it.copy(title = text, saveError = null) }

    fun setGoal(text: String) = state.update { it.copy(goal = text, saveError = null) }

    fun setCatchUp(value: CatchUp) = state.update { it.copy(catchUp = value, saveError = null) }

    fun updatePolicy(transform: (PlanPolicyDraft) -> PlanPolicyDraft) =
        state.update { it.copy(policy = transform(it.policy), saveError = null) }

    // ---- 触发规则 ----

    /** 新加一条：设备的时区、每天 09:00。 */
    fun addTrigger() {
        if (!state.value.canAddTrigger) return
        state.update { it.copy(editing = TriggerEditing(null, TriggerDraft.new(clock.zone, clock.millis()))) }
    }

    /** 编辑一条已有的规则。 */
    fun editTrigger(itemId: String) {
        val item = state.value.triggers.firstOrNull { it.id == itemId } ?: return
        state.update { it.copy(editing = TriggerEditing(itemId, TriggerDraft.from(item.schedule, clock.zone, clock.millis()))) }
    }

    fun updateDraft(transform: (TriggerDraft) -> TriggerDraft) {
        state.update { s -> s.editing?.let { e -> s.copy(editing = e.copy(draft = transform(e.draft), problem = null)) } ?: s }
    }

    fun setDraftKind(kind: TriggerDraft.Kind) = updateDraft { it.withKind(kind, clock.millis()) }

    fun dismissTrigger() = state.update { it.copy(editing = null) }

    /** 编好了：先按服务端的规则检查，有问题就留在面板上提示。 */
    fun applyTrigger() {
        val editing = state.value.editing ?: return
        val problem = editing.draft.problem(clock.millis())
        if (problem != null) {
            state.update { it.copy(editing = editing.copy(problem = problem)) }
            return
        }
        val schedule = editing.draft.schedule
        state.update { s ->
            val itemId = editing.itemId
            if (itemId == null) {
                s.copy(triggers = s.triggers + TriggerItem.new(schedule), editing = null, saveError = null)
            } else {
                val i = s.triggers.indexOfFirst { it.id == itemId }
                if (i < 0 || s.triggers[i].schedule == schedule) return@update s.copy(editing = null)
                val old = s.triggers[i]
                // 已有的改了内容就换成新加的一条（保存时删旧加新）。
                val removed = old.trigger?.let { s.removedTriggerIds + it.id } ?: s.removedTriggerIds
                val replaced = if (old.isNew) old.copy(schedule = schedule) else TriggerItem.new(schedule)
                s.copy(
                    triggers = s.triggers.toMutableList().also { it[i] = replaced },
                    removedTriggerIds = removed,
                    editing = null,
                    saveError = null,
                )
            }
        }
    }

    fun removeTrigger(itemId: String) {
        state.update { s ->
            val item = s.triggers.firstOrNull { it.id == itemId } ?: return@update s
            s.copy(
                triggers = s.triggers.filterNot { it.id == itemId },
                removedTriggerIds = item.trigger?.let { s.removedTriggerIds + it.id } ?: s.removedTriggerIds,
                saveError = null,
            )
        }
    }

    // ---- 关闭 ----

    /** 返回：有改动先问一句。 */
    fun requestClose() {
        val s = state.value
        when {
            s.editing != null -> dismissTrigger()
            s.hasChanges && !s.saving -> state.update { it.copy(confirmDiscard = true) }
            else -> eventChannel.trySend(PlanEditEvent.Closed)
        }
    }

    fun dismissDiscard() = state.update { it.copy(confirmDiscard = false) }

    fun discard() {
        state.update { it.copy(confirmDiscard = false) }
        eventChannel.trySend(PlanEditEvent.Closed)
    }

    // ---- 保存 ----

    fun save() {
        val s = state.value
        if (!s.canSave) return
        val policy = s.policy.policy ?: return
        state.update { it.copy(saving = true, saveError = null) }
        viewModelScope.launch {
            when (val mode = s.mode) {
                is PlanEditMode.Create -> create(s, policy)
                is PlanEditMode.Edit -> saveEdits(mode.planId)
            }
            state.update { it.copy(saving = false) }
        }
    }

    private suspend fun create(s: PlanEditUiState, policy: cn.thinktin.data.model.PlanPolicy) {
        val instanceId = s.instanceId ?: return
        try {
            val plan = service.createPlan(
                NewPlan(
                    instanceId = instanceId,
                    title = s.title.trim(),
                    goal = s.goal.trim(),
                    triggers = s.triggers.map { it.schedule },
                    policy = policy,
                    catchUp = s.catchUp,
                ),
            )
            eventChannel.trySend(PlanEditEvent.Saved(plan, created = true))
        } catch (e: ServiceError) {
            state.update { it.copy(saveError = ErrorText.of(e)) }
        }
    }

    private suspend fun saveEdits(planId: String) {
        var didSomething = false
        try {
            val change = state.value.change
            if (change != PlanChange()) {
                val updated = service.updatePlan(planId, change)
                state.update { it.copy(original = updated) }
                didSomething = true
            }
            while (true) {
                val id = state.value.removedTriggerIds.firstOrNull() ?: break
                try {
                    service.deleteTrigger(id)
                } catch (e: ServiceError.Api) {
                    // 别处已经删了。
                    if (e.status != 404 && e.code != "not_found") throw e
                }
                state.update { it.copy(removedTriggerIds = it.removedTriggerIds.drop(1)) }
                didSomething = true
            }
            for (item in state.value.triggers.filter { it.isNew }) {
                val trigger = service.addTrigger(planId, item.schedule)
                state.update { s ->
                    s.copy(triggers = s.triggers.map { if (it.id == item.id) TriggerItem.existing(trigger) else it })
                }
                didSomething = true
            }
        } catch (e: ServiceError) {
            state.update { it.copy(saveError = ErrorText.of(e), partiallySaved = it.partiallySaved || didSomething) }
            return
        }
        // 再拉一次：下一次触发时间以服务端算的为准。
        val saved = try {
            service.getPlan(planId)
        } catch (_: ServiceError) {
            state.value.original?.copy(triggers = state.value.triggers.mapNotNull { it.trigger })
        } ?: return
        state.update { it.copy(original = saved, partiallySaved = false) }
        eventChannel.trySend(PlanEditEvent.Saved(saved, created = false))
    }
}
