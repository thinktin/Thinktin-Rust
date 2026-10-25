package cn.thinktin.app

import app.cash.turbine.test
import cn.thinktin.app.ui.plans.PlanDetailEvent
import cn.thinktin.app.ui.plans.PlanDetailViewModel
import cn.thinktin.app.ui.plans.PlanEditEvent
import cn.thinktin.app.ui.plans.PlanEditMode
import cn.thinktin.app.ui.plans.PlanEditViewModel
import cn.thinktin.app.ui.plans.PlanFormProblem
import cn.thinktin.app.ui.plans.PlanPolicyDraft
import cn.thinktin.app.ui.plans.PlansEvent
import cn.thinktin.app.ui.plans.PlansViewModel
import cn.thinktin.app.ui.plans.PolicyProblem
import cn.thinktin.app.ui.plans.TextProblem
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.ApprovalTimeoutAction
import cn.thinktin.data.model.CatchUp
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.NewPlan
import cn.thinktin.data.model.Plan
import cn.thinktin.data.model.PlanChange
import cn.thinktin.data.model.PlanPolicy
import cn.thinktin.data.model.Schedule
import cn.thinktin.data.model.Trigger
import cn.thinktin.data.schedule.TriggerDraft
import cn.thinktin.data.schedule.TriggerProblem
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Mock 的演示数据里用到的（`MockData` 是 :data 的内部类）。 */
private object Demo {
    const val INSTANCE_CODER = "inst-coder"
    const val INSTANCE_RESEARCH = "inst-research"
    const val PLAN_DAILY = "plan-daily"
    const val PLAN_WEEKLY = "plan-weekly"
    const val RUN_FAILED = "run-failed"

    /** 每日依赖检查的策略（同 MockData.DAILY_POLICY）。 */
    val DAILY_POLICY = PlanPolicy(
        preauthorizedTools = listOf("read", "search"),
        maxTokens = 50_000,
        maxDurationSecs = 1_800,
        onApprovalTimeout = ApprovalTimeoutAction.Skip,
    )
}

/** 13.6 的服务替身：数据来自 Mock，记下改计划的调用，[fail] 让某个方法下一次调用抛指定错误（只抛一次）。 */
private class PlanService(
    val mock: MockThinktinService = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() }),
) : ThinktinService by mock {
    private val failures = mutableMapOf<String, ServiceError>()
    val created = mutableListOf<NewPlan>()
    val changes = mutableListOf<Pair<String, PlanChange>>()
    val deletedTriggers = mutableListOf<String>()
    val addedTriggers = mutableListOf<Pair<String, Schedule>>()
    val confirms = mutableListOf<Pair<String, Int>>()

    /** 设了就用它代替 Mock 的实例列表（模拟实例被删除）。 */
    var instancesOverride: List<Instance>? = null

    fun fail(method: String, error: ServiceError) {
        failures[method] = error
    }

    private fun maybeFail(method: String) {
        failures.remove(method)?.let { throw it }
    }

    override suspend fun instances(): List<Instance> = instancesOverride ?: mock.instances()

    override suspend fun plans(instanceId: String?): List<Plan> {
        maybeFail("plans")
        return mock.plans(instanceId)
    }

    override suspend fun createPlan(plan: NewPlan): Plan {
        created += plan
        maybeFail("createPlan")
        return mock.createPlan(plan)
    }

    override suspend fun updatePlan(planId: String, change: PlanChange): Plan {
        changes += planId to change
        maybeFail("updatePlan")
        return mock.updatePlan(planId, change)
    }

    override suspend fun confirmPlan(planId: String, revision: Int): Plan {
        confirms += planId to revision
        maybeFail("confirmPlan")
        return mock.confirmPlan(planId, revision)
    }

    override suspend fun setPlanPaused(planId: String, paused: Boolean): Plan {
        maybeFail("setPlanPaused")
        return mock.setPlanPaused(planId, paused)
    }

    override suspend fun deleteTrigger(triggerId: String) {
        deletedTriggers += triggerId
        maybeFail("deleteTrigger")
        mock.deleteTrigger(triggerId)
    }

    override suspend fun addTrigger(planId: String, schedule: Schedule): Trigger {
        addedTriggers += planId to schedule
        maybeFail("addTrigger")
        return mock.addTrigger(planId, schedule)
    }
}

/** 13.6：计划列表、详情（确认、冲突、暂停、删除、运行历史）、新建与编辑（触发规则、策略、分步保存）。 */
@OptIn(ExperimentalCoroutinesApi::class)
class PlansViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val clock = DemoTestApp.FIXED_CLOCK

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun test(block: suspend TestScope.() -> Unit) = runTest(dispatcher) { block() }

    private fun conflict(detail: String = "") = ServiceError.Api(409, "conflict", detail, null)

    // ---- 列表 ----

    @Test
    fun listPutsAwaitingFirstAndSplitsActiveAndPaused() = test {
        val service = PlanService()
        val vm = PlansViewModel(service)
        advanceUntilIdle()
        val s = vm.uiState.value
        assertFalse(s.loading)
        assertEquals(listOf(Demo.PLAN_WEEKLY), s.awaiting.map { it.id })
        assertEquals(listOf(Demo.PLAN_DAILY), s.active.map { it.id })
        assertTrue(s.paused.isEmpty())
        assertTrue(s.hasInstances)
        assertEquals("小码", s.instances[Demo.INSTANCE_CODER]?.name)
    }

    @Test
    fun pauseAndResumeFromTheList() = test {
        val service = PlanService()
        val vm = PlansViewModel(service)
        advanceUntilIdle()
        vm.events.test {
            vm.setPaused(vm.uiState.value.active.single(), paused = true)
            advanceUntilIdle()
            assertEquals(listOf(Demo.PLAN_DAILY), vm.uiState.value.paused.map { it.id })
            assertEquals(R.string.plans_paused_done, (awaitItem() as PlansEvent.Message).text.resId)
            vm.setPaused(vm.uiState.value.paused.single(), paused = false)
            advanceUntilIdle()
            assertEquals(listOf(Demo.PLAN_DAILY), vm.uiState.value.active.map { it.id })
            assertEquals(R.string.plans_resumed_done, (awaitItem() as PlansEvent.Message).text.resId)
        }
        // 等确认的不能用开关绕过确认。
        vm.setPaused(vm.uiState.value.awaiting.single(), paused = false)
        advanceUntilIdle()
        assertTrue(service.mock.getPlan(Demo.PLAN_WEEKLY).awaitingConfirmation)
    }

    @Test
    fun rejectingAnAgentPlanDeletesIt() = test {
        val service = PlanService()
        val vm = PlansViewModel(service)
        advanceUntilIdle()
        vm.askReject(vm.uiState.value.awaiting.single())
        assertNotNull(vm.uiState.value.rejecting)
        vm.confirmReject()
        advanceUntilIdle()
        assertNull(vm.uiState.value.rejecting)
        assertTrue(vm.uiState.value.awaiting.isEmpty())
        assertTrue(service.mock.plans().none { it.id == Demo.PLAN_WEEKLY })
    }

    @Test
    fun resumeBlockedByAStepOnADeletedInstance() = test {
        val service = PlanService()
        val vm = PlansViewModel(service)
        advanceUntilIdle()
        // 研究员被删了：每周计划的 collect 步骤在它上面。
        service.instancesOverride = service.mock.instances().map {
            if (it.id == Demo.INSTANCE_RESEARCH) it.copy(state = InstanceState.Deleted) else it
        }
        vm.load()
        advanceUntilIdle()
        val weekly = service.mock.getPlan(Demo.PLAN_WEEKLY)
        val blocked = PlansViewModel.blockedOr(conflict(), weekly, vm.uiState.value.instances)
        assertEquals(R.string.plan_blocked_steps, blocked.resId)
        // 别的冲突照常说“内容已被修改”。
        val daily = service.mock.getPlan(Demo.PLAN_DAILY)
        assertEquals(R.string.error_conflict, PlansViewModel.blockedOr(conflict(), daily, vm.uiState.value.instances).resId)
    }

    @Test
    fun listLoadError() = test {
        val service = PlanService()
        service.fail("plans", ServiceError.Network("offline"))
        val vm = PlansViewModel(service)
        advanceUntilIdle()
        assertEquals(R.string.error_network, vm.uiState.value.loadError?.resId)
        vm.load()
        advanceUntilIdle()
        assertNull(vm.uiState.value.loadError)
        assertEquals(2, vm.uiState.value.plans.size)
    }

    // ---- 详情 ----

    @Test
    fun detailLoadsThePlanAndItsRuns() = test {
        val vm = PlanDetailViewModel(PlanService(), Demo.PLAN_DAILY)
        advanceUntilIdle()
        val s = vm.uiState.value
        assertEquals("每日依赖检查", s.plan?.title)
        assertEquals(listOf(Demo.RUN_FAILED), s.runs.map { it.id })
        assertFalse(s.hasMoreRuns)
        assertTrue(s.blockedSteps.isEmpty())
    }

    @Test
    fun confirmWithTheShownRevision() = test {
        val service = PlanService()
        val vm = PlanDetailViewModel(service, Demo.PLAN_WEEKLY)
        advanceUntilIdle()
        vm.events.test {
            vm.confirm()
            advanceUntilIdle()
            assertEquals(R.string.plan_confirmed_done, (awaitItem() as PlanDetailEvent.Message).text.resId)
        }
        assertEquals(listOf(Demo.PLAN_WEEKLY to 1), service.confirms)
        assertFalse(vm.uiState.value.plan!!.awaitingConfirmation)
    }

    @Test
    fun confirmConflictShowsTheNewVersion() = test {
        val service = PlanService()
        val vm = PlanDetailViewModel(service, Demo.PLAN_WEEKLY)
        advanceUntilIdle()
        // agent 在用户看的时候又改了一次（版本 1 → 2）。
        service.mock.updatePlan(Demo.PLAN_WEEKLY, PlanChange(goal = "每周一汇总，并标出和上周相比的变化。"))
        vm.events.test {
            vm.confirm()
            advanceUntilIdle()
            assertEquals(R.string.plan_changed_since_shown, (awaitItem() as PlanDetailEvent.Message).text.resId)
        }
        val s = vm.uiState.value
        assertTrue(s.changedSinceShown)
        assertEquals(2, s.plan?.revision)
        assertTrue(s.plan!!.awaitingConfirmation)
        // 看过新版本再确认就成了。
        vm.confirm()
        advanceUntilIdle()
        assertFalse(vm.uiState.value.plan!!.awaitingConfirmation)
        assertFalse(vm.uiState.value.changedSinceShown)
    }

    @Test
    fun confirmConflictBecauseTheStepsAreBlocked() = test {
        val service = PlanService()
        service.instancesOverride = service.mock.instances().map {
            if (it.id == Demo.INSTANCE_RESEARCH) it.copy(state = InstanceState.Deleted) else it
        }
        val vm = PlanDetailViewModel(service, Demo.PLAN_WEEKLY)
        advanceUntilIdle()
        assertEquals(listOf("collect"), vm.uiState.value.blockedSteps.map { it.key })
        service.fail("confirmPlan", conflict("step collect runs on a deleted instance"))
        vm.events.test {
            vm.confirm()
            advanceUntilIdle()
            assertEquals(R.string.plan_blocked_steps, (awaitItem() as PlanDetailEvent.Message).text.resId)
        }
        assertFalse(vm.uiState.value.changedSinceShown)
    }

    @Test
    fun confirmedElsewhere() = test {
        val service = PlanService()
        val vm = PlanDetailViewModel(service, Demo.PLAN_WEEKLY)
        advanceUntilIdle()
        service.mock.confirmPlan(Demo.PLAN_WEEKLY, 1)
        service.fail("confirmPlan", conflict())
        vm.events.test {
            vm.confirm()
            advanceUntilIdle()
            assertEquals(R.string.plan_already_confirmed, (awaitItem() as PlanDetailEvent.Message).text.resId)
        }
    }

    @Test
    fun pauseAndDeleteFromTheDetail() = test {
        val service = PlanService()
        val vm = PlanDetailViewModel(service, Demo.PLAN_DAILY)
        advanceUntilIdle()
        vm.events.test {
            vm.setPaused(true)
            advanceUntilIdle()
            assertTrue(vm.uiState.value.plan!!.paused)
            assertEquals(R.string.plans_paused_done, (awaitItem() as PlanDetailEvent.Message).text.resId)
            vm.askDelete()
            assertTrue(vm.uiState.value.confirmDelete)
            vm.delete()
            advanceUntilIdle()
            assertEquals(PlanDetailEvent.Deleted, awaitItem())
        }
        assertTrue(service.mock.plans().none { it.id == Demo.PLAN_DAILY })
    }

    @Test
    fun detailOfAMissingPlan() = test {
        val vm = PlanDetailViewModel(PlanService(), "plan-gone")
        advanceUntilIdle()
        assertTrue(vm.uiState.value.notFound)
    }

    // ---- 新建、编辑 ----

    @Test
    fun createAPlan() = test {
        val service = PlanService()
        val vm = PlanEditViewModel(service, clock, PlanEditMode.Create(null))
        advanceUntilIdle()
        val s0 = vm.uiState.value
        assertFalse(s0.canSave)
        assertTrue(PlanFormProblem.NoInstance in s0.problems)
        assertTrue(PlanFormProblem.Title(TextProblem.Empty) in s0.problems)
        assertTrue(PlanFormProblem.NoTriggers in s0.problems)
        vm.setInstance(Demo.INSTANCE_CODER)
        vm.setTitle("  晨报  ")
        vm.setGoal("整理昨晚到现在的科技新闻，挑 5 条发给我。")
        // 加一条：工作日 08:30。
        vm.addTrigger()
        vm.setDraftKind(TriggerDraft.Kind.Weekly)
        vm.updateDraft { it.copy(weekdays = setOf(1, 2, 3, 4, 5), hour = 8, minute = 30) }
        vm.applyTrigger()
        assertNull(vm.uiState.value.editing)
        vm.setCatchUp(CatchUp.Skip)
        vm.updatePolicy { it.copy(maxTokens = "80000", preauthorizedTools = setOf("read")) }
        assertTrue(vm.uiState.value.canSave)
        vm.events.test {
            vm.save()
            advanceUntilIdle()
            val saved = awaitItem() as PlanEditEvent.Saved
            assertTrue(saved.created)
            assertEquals("晨报", saved.plan.title)
        }
        val sent = service.created.single()
        assertEquals(Demo.INSTANCE_CODER, sent.instanceId)
        assertEquals("晨报", sent.title)
        assertEquals(listOf(Schedule.Cron("30 8 * * 1-5", "Asia/Shanghai")), sent.triggers)
        assertEquals(CatchUp.Skip, sent.catchUp)
        assertEquals(80_000L, sent.policy?.maxTokens)
        assertEquals(listOf("read"), sent.policy?.preauthorizedTools)
    }

    @Test
    fun aTriggerThatBreaksTheServerRulesStaysInThePanel() = test {
        val vm = PlanEditViewModel(PlanService(), clock, PlanEditMode.Create(Demo.INSTANCE_CODER))
        advanceUntilIdle()
        vm.addTrigger()
        vm.setDraftKind(TriggerDraft.Kind.Cron)
        vm.updateDraft { it.copy(cronExpression = "* * * * *") }
        vm.applyTrigger()
        assertEquals(TriggerProblem.TooFrequent(5), vm.uiState.value.editing?.problem)
        assertTrue(vm.uiState.value.triggers.isEmpty())
        // 一改就清掉提示。
        vm.updateDraft { it.copy(cronExpression = "*/10 * * * *") }
        assertNull(vm.uiState.value.editing?.problem)
        vm.applyTrigger()
        assertEquals(1, vm.uiState.value.triggers.size)
    }

    @Test
    fun editSendsOnlyWhatChangedAndReplacesEditedTriggers() = test {
        val service = PlanService()
        val vm = PlanEditViewModel(service, clock, PlanEditMode.Edit(Demo.PLAN_DAILY))
        advanceUntilIdle()
        val s0 = vm.uiState.value
        assertEquals("每日依赖检查", s0.title)
        assertEquals(2, s0.triggers.size)
        assertFalse(s0.hasChanges)
        assertFalse(s0.canSave)
        assertEquals(PlanPolicyDraft(Demo.DAILY_POLICY).policy, Demo.DAILY_POLICY)
        // 改标题；把 09:00 改成 07:00；删掉失效的那条。
        vm.setTitle("每日依赖检查（早）")
        vm.editTrigger("trg-daily")
        vm.updateDraft { it.copy(hour = 7) }
        vm.applyTrigger()
        vm.removeTrigger("trg-daily-broken")
        assertTrue(vm.uiState.value.canSave)
        vm.events.test {
            vm.save()
            advanceUntilIdle()
            assertTrue(awaitItem() is PlanEditEvent.Saved)
        }
        assertEquals(listOf(Demo.PLAN_DAILY to PlanChange(title = "每日依赖检查（早）")), service.changes)
        assertEquals(listOf("trg-daily", "trg-daily-broken"), service.deletedTriggers)
        assertEquals(listOf(Demo.PLAN_DAILY to Schedule.Cron("0 7 * * *", "Asia/Shanghai")), service.addedTriggers)
        val plan = service.mock.getPlan(Demo.PLAN_DAILY)
        assertEquals(listOf(Schedule.Cron("0 7 * * *", "Asia/Shanghai")), plan.triggers.map { it.schedule })
    }

    @Test
    fun aFailedSaveOnlyRedoesWhatIsLeft() = test {
        val service = PlanService()
        val vm = PlanEditViewModel(service, clock, PlanEditMode.Edit(Demo.PLAN_DAILY))
        advanceUntilIdle()
        vm.setGoal("每天检查依赖的安全更新。")
        vm.addTrigger()
        vm.applyTrigger()
        service.fail("addTrigger", ServiceError.Network("offline"))
        vm.save()
        advanceUntilIdle()
        val failed = vm.uiState.value
        assertEquals(R.string.error_network, failed.saveError?.resId)
        assertTrue(failed.partiallySaved)
        assertEquals(1, service.changes.size)
        vm.events.test {
            vm.save()
            advanceUntilIdle()
            assertTrue(awaitItem() is PlanEditEvent.Saved)
        }
        // 目标已经改好了，不再改第二次；触发器这次加上了。
        assertEquals(1, service.changes.size)
        assertEquals(2, service.addedTriggers.size)
        assertEquals(3, service.mock.getPlan(Demo.PLAN_DAILY).triggers.size)
    }

    @Test
    fun closingWithChangesAsksFirst() = test {
        val vm = PlanEditViewModel(PlanService(), clock, PlanEditMode.Create(Demo.INSTANCE_CODER))
        advanceUntilIdle()
        vm.events.test {
            vm.requestClose()
            assertEquals(PlanEditEvent.Closed, awaitItem())
            vm.setTitle("草稿")
            vm.requestClose()
            assertTrue(vm.uiState.value.confirmDiscard)
            vm.discard()
            assertEquals(PlanEditEvent.Closed, awaitItem())
        }
    }

    @Test
    fun policyDraftKeepsUntouchedValuesAndChecksTheServerLimits() {
        val odd = PlanPolicy(approvalTimeoutSecs = 5_400, maxDurationSecs = 100)
        val draft = PlanPolicyDraft(odd)
        assertEquals("1.5", draft.approvalTimeoutHours)
        assertEquals("0.03", draft.maxDurationHours)
        // 没动过的不被四舍五入改掉。
        assertEquals(odd, draft.policy)
        assertEquals(1_800L, draft.copy(maxDurationHours = "0.5").policy?.maxDurationSecs)
        assertEquals(listOf(PolicyProblem.MaxDuration), draft.copy(maxDurationHours = "25").problems)
        assertEquals(listOf(PolicyProblem.ApprovalTimeout), draft.copy(approvalTimeoutHours = "200").problems)
        assertEquals(listOf(PolicyProblem.WaitTimeout), draft.copy(waitTimeoutHours = "abc").problems)
        assertEquals(listOf(PolicyProblem.MaxTokens), draft.copy(maxTokens = "-5").problems)
        assertNull(draft.copy(maxSteps = "1.5").policy)
        assertEquals(ApprovalTimeoutAction.Fail, draft.copy(onApprovalTimeout = ApprovalTimeoutAction.Fail).policy?.onApprovalTimeout)
        assertNull(PlanPolicyDraft().copy(maxTokens = "").policy?.maxTokens)
    }
}
