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
    /** 新建；[instanceId] 是预选的实例，[teamId] 给了就用这个团队建流水线（13.7）。 */
    data class Create(val instanceId: String?, val teamId: String? = null) : PlanEditMode
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

    /** 流水线的步骤有问题（13.7，[Pipeline.problems]）。 */
    data object Steps : PlanFormProblem
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
    /** 流水线的步骤（13.7）：空的是普通计划（在 [instanceId] 上按目标跑）。 */
    val steps: List<StepDraft> = emptyList(),
    /** 保存时显示步骤的问题（点过保存之后）。 */
    val showStepProblems: Boolean = false,
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
            if (stepProblems.isNotEmpty()) add(PlanFormProblem.Steps)
        }

    /** 步骤的问题（实例按还在的算）。 */
    val stepProblems: List<StepProblem>
        get() = if (steps.isEmpty()) emptyList() else Pipeline.problems(steps, instances.map { it.id }.toSet())

    /** 要保存的步骤。 */
    val planSteps: List<PlanStep> get() = steps.map { it.toStep() }

    /** 编辑时步骤改了没有。 */
    val stepsChanged: Boolean get() = original != null && planSteps != original.steps

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
                steps = planSteps.takeIf { stepsChanged },
            )
        }

    val hasChanges: Boolean
        get() = if (isEditing) {
            change != PlanChange() || removedTriggerIds.isNotEmpty() || triggers.any { it.isNew }
        } else {
            title.isNotBlank() || goal.isNotBlank() || triggers.isNotEmpty() || policy != PlanPolicyDraft() ||
                catchUp != CatchUp.Once || steps.any { it.prompt.isNotBlank() }
        }

    val canAddTrigger: Boolean get() = triggers.size < PlanLimits.MAX_TRIGGERS

    /** 步骤的问题不灰掉保存：点保存时再标出来（[showStepProblems]），免得用户不知道哪里不对。 */
    val canSave: Boolean
        get() = problems.none { it != PlanFormProblem.Steps } && !saving && !needsLoad && (!isEditing || hasChanges)

    val canAddStep: Boolean get() = steps.size < MAX_PIPELINE_STEPS
}

sealed interface PlanEditEvent {
    /** 存好了：回到上一页（新建的去详情）。 */
    data class Saved(val plan: Plan, val created: Boolean) : PlanEditEvent

    /** 放弃修改、关掉。 */
    data object Closed : PlanEditEvent
}

/**
 * 新建、编辑计划（13.6，路由 plans/new、plan/{id}/edit）：实例（新建时选）、标题（最多 100 字）、目标（最多 8000 字）、
 * 触发规则（1 到 10 条，用 [TriggerDraft] 编）、策略、补跑方式、流水线的步骤（13.7：每步选实例、写提示词、勾依赖，本地
 * 按服务端的规则查键名、依赖和环，[Pipeline]）。从团队建（`plans/new?teamId=`）时按成员预填步骤，计划挂在负责人上。
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
            (state.value.mode as? PlanEditMode.Create)?.teamId?.let { prefillFromTeam(it) }
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
                steps = plan.steps.mapIndexed { i, step -> StepDraft.from(step, nextStepId + i) }
                    .also { list -> nextStepId += list.size },
                removedTriggerIds = emptyList(),
            )
        }
    }

    /** 本地步骤 id（改键名时认得出是哪一步）。 */
    private var nextStepId = 1L

    /** 用团队建流水线：每个成员一步，负责人最后汇总；计划挂在负责人上。拉不到团队就当普通新建。 */
    private suspend fun prefillFromTeam(teamId: String) {
        if (state.value.steps.isNotEmpty()) return
        val team = try {
            service.team(teamId)
        } catch (_: ServiceError) {
            return
        }
        val drafts = Pipeline.fromTeam(team, nextStepId)
        nextStepId += drafts.size
        val lead = team.members.firstOrNull { it.role == cn.thinktin.data.model.TeamRole.Lead }?.instanceId
        state.update { it.copy(steps = drafts, instanceId = lead ?: it.instanceId ?: drafts.firstOrNull()?.instanceId) }
    }

    // ---- 流水线步骤（13.7） ----

    fun addStep() {
        if (!state.value.canAddStep) return
        state.update { s ->
            val instance = s.steps.lastOrNull()?.instanceId ?: s.instanceId
            s.copy(steps = s.steps + StepDraft(nextStepId++, Pipeline.nextKey(s.steps), instance, ""), saveError = null)
        }
    }

    fun removeStep(id: Long) = state.update { it.copy(steps = Pipeline.remove(it.steps, id), saveError = null) }

    fun moveStep(id: Long, delta: Int) = state.update { it.copy(steps = Pipeline.move(it.steps, id, delta)) }

    /** 改键名：只收小写字母、数字、`_`、`-`（大写转小写），依赖它的步骤跟着改。 */
    fun setStepKey(id: Long, key: String) {
        val cleaned = key.lowercase().filter { it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '-' }.take(32)
        state.update { it.copy(steps = Pipeline.rename(it.steps, id, cleaned), saveError = null) }
    }

    fun setStepInstance(id: Long, instanceId: String) = updateStep(id) { it.copy(instanceId = instanceId) }

    fun setStepPrompt(id: Long, prompt: String) = updateStep(id) { it.copy(prompt = prompt) }

    /** 勾 / 取消一个依赖。 */
    fun toggleDependency(id: Long, key: String) = updateStep(id) { s ->
        s.copy(dependsOn = if (key in s.dependsOn) s.dependsOn - key else s.dependsOn + key)
    }

    private fun updateStep(id: Long, transform: (StepDraft) -> StepDraft) = state.update { s ->
        s.copy(steps = s.steps.map { if (it.id == id) transform(it) else it }, saveError = null)
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
        if (s.stepProblems.isNotEmpty()) {
            state.update { it.copy(showStepProblems = true) }
            return
        }
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
                    steps = s.planSteps,
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
