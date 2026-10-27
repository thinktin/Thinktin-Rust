package cn.thinktin.app

import app.cash.turbine.test
import cn.thinktin.app.ui.plans.MAX_PIPELINE_STEPS
import cn.thinktin.app.ui.plans.Pipeline
import cn.thinktin.app.ui.plans.PlanEditMode
import cn.thinktin.app.ui.plans.PlanEditViewModel
import cn.thinktin.app.ui.plans.StepDraft
import cn.thinktin.app.ui.plans.StepProblem
import cn.thinktin.app.ui.teams.TeamDetailEvent
import cn.thinktin.app.ui.teams.TeamDetailViewModel
import cn.thinktin.app.ui.teams.TeamEditEvent
import cn.thinktin.app.ui.teams.TeamEditViewModel
import cn.thinktin.app.ui.teams.TeamFormProblem
import cn.thinktin.app.ui.teams.TeamsEvent
import cn.thinktin.app.ui.teams.TeamsViewModel
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.NewPlan
import cn.thinktin.data.model.Plan
import cn.thinktin.data.model.PlanChange
import cn.thinktin.data.model.Team
import cn.thinktin.data.model.TeamRole
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
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
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** 13.7 的服务替身：演示数据，记下建计划、改计划的调用；[fail] 让某个方法下一次调用抛错。 */
private class TeamService(
    val mock: MockThinktinService = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() }),
) : ThinktinService by mock {
    private val failures = mutableMapOf<String, ServiceError>()
    val created = mutableListOf<NewPlan>()
    val changes = mutableListOf<PlanChange>()

    fun fail(method: String, error: ServiceError) {
        failures[method] = error
    }

    private fun maybeFail(method: String) {
        failures.remove(method)?.let { throw it }
    }

    override suspend fun adoptTeamTemplate(templateId: String, name: String?): Team {
        maybeFail("adoptTeamTemplate")
        return mock.adoptTeamTemplate(templateId, name)
    }

    override suspend fun createPlan(plan: NewPlan): Plan {
        created += plan
        return mock.createPlan(plan)
    }

    override suspend fun updatePlan(planId: String, change: PlanChange): Plan {
        changes += change
        return mock.updatePlan(planId, change)
    }
}

/** 13.7：流水线步骤的本地规则、团队列表 / 详情 / 编辑、用团队建流水线（路由里有 Uri.encode：用 Robolectric）。 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class)
class TeamsTest {
    private val dispatcher = StandardTestDispatcher()
    private val instances = setOf("a", "b", "c")

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun step(id: Long, key: String, vararg deps: String, instance: String? = "a", prompt: String = "做事") =
        StepDraft(id, key, instance, prompt, deps.toList())

    @Test
    fun stepRulesMatchTheServer() {
        assertTrue(Pipeline.isValidKey("step1"))
        assertTrue(Pipeline.isValidKey("9-a_b"))
        assertFalse(Pipeline.isValidKey("_x"))
        assertFalse(Pipeline.isValidKey("Step"))
        assertFalse(Pipeline.isValidKey("a".repeat(33)))
        val ok = listOf(step(1, "fetch"), step(2, "write", "fetch"), step(3, "review", "write", "fetch"))
        assertTrue(Pipeline.problems(ok, instances).isEmpty())
        // Kahn：同一层按声明顺序。
        assertEquals(listOf("a1", "a2", "b"), Pipeline.order(listOf(step(1, "b", "a2"), step(2, "a1"), step(3, "a2"))))

        val bad = listOf(
            step(1, "x"), step(2, "x"), step(3, "Bad Key"), step(4, "y", "nope", instance = null, prompt = " "),
            step(5, "z", "z", instance = "gone"),
        )
        val problems = Pipeline.problems(bad, instances)
        assertTrue(StepProblem.DuplicateKey(1) in problems && StepProblem.DuplicateKey(2) in problems)
        assertTrue(StepProblem.BadKey(3) in problems)
        assertTrue(StepProblem.NoInstance(4) in problems && StepProblem.EmptyPrompt(4) in problems)
        assertTrue(StepProblem.UnknownDependency(4, "nope") in problems)
        assertTrue(StepProblem.SelfDependency(5) in problems && StepProblem.DeletedInstance(5) in problems)
        assertTrue(StepProblem.Cycle !in problems)

        val cycle = listOf(step(1, "a", "c"), step(2, "b", "a"), step(3, "c", "b"))
        assertEquals(listOf(StepProblem.Cycle), Pipeline.problems(cycle, instances))
        assertNull(Pipeline.order(cycle))
        val many = (1..MAX_PIPELINE_STEPS + 1).map { step(it.toLong(), "s$it") }
        assertTrue(StepProblem.TooMany in Pipeline.problems(many, instances))
    }

    @Test
    fun stepEditsKeepDependenciesConsistent() {
        val steps = listOf(step(1, "fetch"), step(2, "write", "fetch"))
        val renamed = Pipeline.rename(steps, 1, "gather")
        assertEquals(listOf("gather"), renamed[1].dependsOn)
        assertEquals(listOf("write"), Pipeline.remove(renamed, 1).map { it.key })
        assertTrue(Pipeline.remove(renamed, 1).single().dependsOn.isEmpty())
        assertEquals(listOf("write", "fetch"), Pipeline.move(steps, 2, -1).map { it.key })
        assertEquals(steps, Pipeline.move(steps, 1, -1))
        assertEquals("step3", Pipeline.nextKey(listOf(step(1, "step1"), step(2, "step2"))))
        val team = Team(
            "t", "调研", listOf(
                cn.thinktin.data.model.TeamMember("lead", TeamRole.Lead, 0),
                cn.thinktin.data.model.TeamMember("m1", TeamRole.Member, 1),
                cn.thinktin.data.model.TeamMember("m2", TeamRole.Member, 2),
            ), 0,
        )
        val drafts = Pipeline.fromTeam(team)
        assertEquals(listOf("step1", "step2", "summary"), drafts.map { it.key })
        assertEquals(listOf("step1", "step2"), drafts.last().dependsOn)
        assertEquals("lead", drafts.last().instanceId)
    }

    @Test
    fun teamsListAdoptsAndDeletesTemplates() = runTest(dispatcher) {
        val service = TeamService()
        val vm = TeamsViewModel(service)
        advanceUntilIdle()
        assertEquals(listOf("调研小组"), vm.uiState.value.teams.map { it.name })
        assertEquals(listOf("调研 + 写作"), vm.uiState.value.templates.map { it.name })
        vm.events.test {
            vm.adopt(vm.uiState.value.templates.single())
            advanceUntilIdle()
            val open = awaitItem() as TeamsEvent.OpenTeam
            assertEquals(open.teamId, vm.uiState.value.teams.first().id)
            assertEquals(2, vm.uiState.value.teams.size)

            service.fail("adoptTeamTemplate", ServiceError.Api(409, "instance_limit", "too many", null))
            vm.adopt(vm.uiState.value.templates.single())
            advanceUntilIdle()
            assertEquals(R.string.error_limit_reached, (awaitItem() as TeamsEvent.Notice).text.resId)

            vm.deleteTemplate(vm.uiState.value.templates.single())
            advanceUntilIdle()
            assertEquals(R.string.team_template_deleted, (awaitItem() as TeamsEvent.Notice).text.resId)
            assertTrue(vm.uiState.value.templates.isEmpty())
        }
    }

    @Test
    fun teamDetailSavesTemplateAndDeletes() = runTest(dispatcher) {
        val service = TeamService()
        val vm = TeamDetailViewModel(service, "team-research")
        advanceUntilIdle()
        assertEquals(TeamRole.Lead, vm.uiState.value.members.first().role)
        vm.events.test {
            vm.saveAsTemplate()
            advanceUntilIdle()
            assertEquals(R.string.team_saved_as_template, (awaitItem() as TeamDetailEvent.Notice).text.resId)
            assertEquals(2, service.teamTemplates().size)
            vm.askDelete()
            vm.delete()
            advanceUntilIdle()
            assertEquals(TeamDetailEvent.Deleted, awaitItem())
        }
        assertTrue(service.teams().isEmpty())

        val missing = TeamDetailViewModel(service, "team-gone")
        advanceUntilIdle()
        assertTrue(missing.uiState.value.missing)
    }

    @Test
    fun teamEditorPicksMembersAndLead() = runTest(dispatcher) {
        val service = TeamService()
        val vm = TeamEditViewModel(service, null)
        advanceUntilIdle()
        assertTrue(TeamFormProblem.NameEmpty in vm.uiState.value.problems)
        assertTrue(TeamFormProblem.NoMembers in vm.uiState.value.problems)
        val ids = vm.uiState.value.instances.map { it.id }
        vm.onNameChange("  新团队 ")
        vm.toggle(ids[0])
        vm.toggle(ids[1])
        // 第一个选的当负责人；取消负责人时换成剩下的第一个。
        assertEquals(ids[0], vm.uiState.value.lead)
        vm.toggle(ids[0])
        assertEquals(ids[1], vm.uiState.value.lead)
        vm.setLead(ids[0])
        assertEquals(listOf(ids[1], ids[0]), vm.uiState.value.selected)
        assertTrue(vm.uiState.value.problems.isEmpty())
        vm.events.test {
            vm.save()
            advanceUntilIdle()
            val saved = awaitItem() as TeamEditEvent.Saved
            val team = service.team(saved.teamId)
            assertEquals("新团队", team.name)
            assertEquals(ids[0], team.members.single { it.role == TeamRole.Lead }.instanceId)
        }

        val edit = TeamEditViewModel(service, "team-research")
        advanceUntilIdle()
        assertEquals("调研小组", edit.uiState.value.name)
        assertEquals(2, edit.uiState.value.selected.size)
        assertNotNull(edit.uiState.value.lead)
    }

    @Test
    fun pipelineFromTeamIsSavedWithSteps() = runTest(dispatcher) {
        val service = TeamService()
        val vm = PlanEditViewModel(service, DemoTestApp.FIXED_CLOCK, PlanEditMode.Create(null, "team-research"))
        advanceUntilIdle()
        val state = vm.uiState.value
        assertEquals(listOf("step1", "summary"), state.steps.map { it.key })
        assertEquals(state.steps.last().instanceId, state.instanceId)
        vm.setTitle("每周调研")
        vm.setGoal("调研并写周报")
        vm.addTrigger()
        vm.applyTrigger()
        // 提示词没写：点保存先标出来，不发请求。
        vm.save()
        advanceUntilIdle()
        assertTrue(vm.uiState.value.showStepProblems)
        assertTrue(service.created.isEmpty())
        vm.uiState.value.steps.forEach { vm.setStepPrompt(it.id, "做 ${it.key}") }
        vm.save()
        advanceUntilIdle()
        val created = service.created.single()
        assertEquals(listOf("step1", "summary"), created.steps.map { it.key })
        assertEquals(listOf("step1"), created.steps.last().dependsOn)
    }
}
