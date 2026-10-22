package cn.thinktin.app

import app.cash.turbine.test
import cn.thinktin.app.ui.agent.AgentDetailEvent
import cn.thinktin.app.ui.agent.AgentDetailViewModel
import cn.thinktin.app.ui.agent.InstanceNames
import cn.thinktin.app.ui.catalog.CatalogViewModel
import cn.thinktin.app.ui.catalog.filterAgents
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.drawer.DrawerViewModel
import cn.thinktin.app.ui.home.HomeViewModel
import cn.thinktin.app.ui.instance.DeleteImpact
import cn.thinktin.app.ui.instance.InstanceDialog
import cn.thinktin.app.ui.instance.InstanceNameEvent
import cn.thinktin.app.ui.instance.InstanceNameViewModel
import cn.thinktin.app.ui.instance.InstanceSettingsEvent
import cn.thinktin.app.ui.instance.InstanceSettingsViewModel
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.AgentInfo
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.CredentialUpdate
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.ModelRoute
import cn.thinktin.data.model.NewPlan
import cn.thinktin.data.model.Plan
import cn.thinktin.data.model.PlanStep
import cn.thinktin.data.model.Team
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
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

/**
 * 13.3 的服务替身：数据来自 Mock，[fail] 让某个方法下一次调用抛指定错误（只抛一次），并记下调用。
 */
private class CatalogService(
    val mock: MockThinktinService = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() }),
) : ThinktinService by mock {
    private val failures = mutableMapOf<String, ServiceError>()
    var agentsOverride: List<AgentInfo>? = null
    var agentsGate: CompletableDeferred<Unit>? = null
    var agentsCalls = 0
    val adoptions = mutableListOf<Triple<String, String, String?>>()
    val versionCalls = mutableListOf<String?>()
    val deleted = mutableListOf<String>()
    val auth = MutableStateFlow(AuthState.SignedIn)

    override val isDemo: Boolean = false
    override val authState: StateFlow<AuthState> get() = auth

    fun fail(method: String, error: ServiceError) {
        failures[method] = error
    }

    private fun maybeFail(method: String) {
        failures.remove(method)?.let { throw it }
    }

    override suspend fun agents(): List<AgentInfo> {
        agentsCalls++
        agentsGate?.await()
        maybeFail("agents")
        return agentsOverride ?: mock.agents()
    }

    override suspend fun adopt(agentId: String, name: String, harness: String?): Instance {
        adoptions += Triple(agentId, name, harness)
        maybeFail("adopt")
        return mock.adopt(agentId, name, harness)
    }

    override suspend fun instance(instanceId: String): Instance {
        maybeFail("instance")
        return mock.instance(instanceId)
    }

    override suspend fun renameInstance(instanceId: String, name: String): Instance {
        maybeFail("renameInstance")
        return mock.renameInstance(instanceId, name)
    }

    override suspend fun setInstanceVersion(instanceId: String, version: String?): Instance {
        versionCalls += version
        maybeFail("setInstanceVersion")
        return mock.setInstanceVersion(instanceId, version)
    }

    override suspend fun plans(instanceId: String?): List<Plan> {
        maybeFail("plans")
        return mock.plans(instanceId)
    }

    override suspend fun teams(): List<Team> {
        maybeFail("teams")
        return mock.teams()
    }

    override suspend fun deleteInstance(instanceId: String) {
        deleted += instanceId
        maybeFail("deleteInstance")
        mock.deleteInstance(instanceId)
    }

    override suspend fun credentials(): List<Credential> {
        maybeFail("credentials")
        return mock.credentials()
    }

    val routeSets = mutableListOf<Pair<String, List<ModelRoute>>>()

    override suspend fun setModelRoutes(instanceId: String, routes: List<ModelRoute>) {
        routeSets += instanceId to routes
        maybeFail("setModelRoutes")
        mock.setModelRoutes(instanceId, routes)
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class AgentViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun test(block: suspend TestScope.() -> Unit) = runTest(dispatcher) { block() }

    private fun api(status: Int, code: String, detail: String = "", retry: Long? = null) =
        ServiceError.Api(status, code, detail, retry)

    // ---- 目录 ----

    @Test
    fun catalogLoadsAgents() = test {
        val service = CatalogService()
        val vm = CatalogViewModel(service)
        assertTrue(vm.uiState.value.loading)
        advanceUntilIdle()
        val state = vm.uiState.value
        assertFalse(state.loading)
        assertNull(state.loadError)
        assertEquals(listOf("agent-coder", "agent-research", "agent-writer"), state.visibleAgents.map { it.id })
        assertFalse(state.emptyCatalog)
    }

    @Test
    fun catalogFiltersByNameDescriptionLicenseAndProtocol() = test {
        val vm = CatalogViewModel(CatalogService())
        advanceUntilIdle()
        vm.onQueryChange("MIT")
        assertEquals(listOf("agent-research"), vm.uiState.value.visibleAgents.map { it.id })
        vm.onQueryChange("  写作 ")
        assertEquals(listOf("agent-writer"), vm.uiState.value.visibleAgents.map { it.id })
        // 每个词都要命中：codex + chat 只有代码助手和调研助手；再加 Apache 只剩代码助手
        vm.onQueryChange("codex chat")
        assertEquals(listOf("agent-coder", "agent-research"), vm.uiState.value.visibleAgents.map { it.id })
        vm.onQueryChange("codex apache")
        assertEquals(listOf("agent-coder"), vm.uiState.value.visibleAgents.map { it.id })
        // 介绍里的字也能搜（不分大小写）
        vm.onQueryChange("PR")
        assertEquals(listOf("agent-coder"), vm.uiState.value.visibleAgents.map { it.id })
        vm.onQueryChange("没有这个")
        assertTrue(vm.uiState.value.visibleAgents.isEmpty())
        assertFalse("没有匹配不是空目录", vm.uiState.value.emptyCatalog)
        vm.onQueryChange("")
        assertEquals(3, vm.uiState.value.visibleAgents.size)
    }

    @Test
    fun filterAgentsWithBlankQueryReturnsAll() = test {
        val agents = CatalogService().mock.agents()
        assertEquals(agents, filterAgents(agents, "   "))
    }

    @Test
    fun catalogErrorThenRetry() = test {
        val service = CatalogService()
        service.fail("agents", ServiceError.Network("offline"))
        val vm = CatalogViewModel(service)
        advanceUntilIdle()
        assertTrue(vm.uiState.value.loadError is ServiceError.Network)
        assertFalse(vm.uiState.value.loading)
        assertFalse(vm.uiState.value.emptyCatalog)

        vm.load()
        assertTrue(vm.uiState.value.loading)
        assertNull(vm.uiState.value.loadError)
        advanceUntilIdle()
        assertEquals(3, vm.uiState.value.agents.size)
        assertNull(vm.uiState.value.loadError)
    }

    @Test
    fun catalogRetryWhileLoadingDoesNotRefetch() = test {
        val service = CatalogService()
        service.agentsGate = CompletableDeferred()
        val vm = CatalogViewModel(service)
        runCurrent()
        vm.load()
        vm.load()
        runCurrent()
        assertEquals(1, service.agentsCalls)
        service.agentsGate!!.complete(Unit)
        advanceUntilIdle()
        assertEquals(3, vm.uiState.value.agents.size)
    }

    @Test
    fun emptyCatalog() = test {
        val service = CatalogService()
        service.agentsOverride = emptyList()
        val vm = CatalogViewModel(service)
        advanceUntilIdle()
        assertTrue(vm.uiState.value.emptyCatalog)
    }

    // ---- 详情与领养 ----

    private fun detail(service: CatalogService, agentId: String = "agent-coder") =
        AgentDetailViewModel(service, agentId)

    @Test
    fun detailFindsAgentOrNotFound() = test {
        val service = CatalogService()
        val vm = detail(service)
        advanceUntilIdle()
        assertEquals("代码助手", vm.uiState.value.agent?.name)
        assertFalse(vm.uiState.value.notFound)

        val missing = detail(service, "agent-gone")
        advanceUntilIdle()
        assertNull(missing.uiState.value.agent)
        assertTrue(missing.uiState.value.notFound)
    }

    @Test
    fun detailLoadErrorThenRetry() = test {
        val service = CatalogService()
        service.fail("agents", ServiceError.Network("offline"))
        val vm = detail(service)
        advanceUntilIdle()
        assertEquals(UiText(R.string.error_network), vm.uiState.value.loadError)
        vm.load()
        advanceUntilIdle()
        assertNull(vm.uiState.value.loadError)
        assertNotNull(vm.uiState.value.agent)
    }

    @Test
    fun adoptSuccessWithChosenHarness() = test {
        val service = CatalogService()
        val vm = detail(service)
        advanceUntilIdle()
        vm.openAdopt("代码助手 的实例")
        val form = vm.uiState.value.adopt!!
        assertEquals("代码助手 的实例", form.name)
        assertEquals("默认选 defaultHarness", "claude-code", form.harness)
        vm.onHarnessChange("not-a-harness")
        assertEquals("claude-code", vm.uiState.value.adopt!!.harness)
        vm.onHarnessChange("codex")
        vm.onNameChange("  我的码农  ")
        vm.events.test {
            vm.adopt()
            assertTrue(vm.uiState.value.adopt!!.submitting)
            val event = awaitItem() as AgentDetailEvent.Adopted
            assertEquals("我的码农", event.instance.name)
            assertEquals("codex", event.instance.harness)
            assertFalse("key 列表还没到就提交：当作跳过", event.routesConfigured)
        }
        assertEquals(listOf(Triple("agent-coder", "我的码农", "codex")), service.adoptions)
        assertNull("成功后收起表单", vm.uiState.value.adopt)
        assertTrue(service.mock.instances().any { it.name == "我的码农" })
    }

    @Test
    fun adoptWithKeyConfiguresMainAlias() = test {
        val service = CatalogService()
        val vm = detail(service)
        advanceUntilIdle()
        vm.openAdopt("代码助手 的实例")
        assertTrue(vm.uiState.value.keys.loading)
        advanceUntilIdle()
        // 代码助手用 Anthropic Messages：两把 key 都支持；默认选第一把，预填厂商推荐的第一个模型
        assertEquals(listOf("cred-work", "cred-home"), vm.uiState.value.keys.usable.map { it.id })
        var form = vm.uiState.value.adopt!!
        assertEquals("cred-work", form.credentialId)
        assertEquals("claude-sonnet-4", form.model)

        // 换 key：模型没改过就换成新厂商推荐的；改过就保留
        vm.onKeyChange("cred-home")
        assertEquals("deepseek-chat", vm.uiState.value.adopt!!.model)
        vm.onModelChange("deepseek-reasoner")
        vm.onKeyChange("cred-work")
        assertEquals("deepseek-reasoner", vm.uiState.value.adopt!!.model)
        vm.onKeyChange("cred-nope")
        assertEquals("不在可选列表里的 key 不收", "cred-work", vm.uiState.value.adopt!!.credentialId)

        // 模型名本地校验
        vm.onModelChange("  ")
        vm.adopt()
        assertEquals(UiText(R.string.routes_error_model_empty), vm.uiState.value.adopt!!.modelError)
        advanceUntilIdle()
        assertTrue(service.adoptions.isEmpty())

        vm.onModelChange(" claude-opus-4 ")
        form = vm.uiState.value.adopt!!
        assertNull(form.modelError)
        vm.events.test {
            vm.adopt()
            val event = awaitItem() as AgentDetailEvent.Adopted
            assertTrue(event.routesConfigured)
            assertEquals(
                listOf(ModelRoute("main", "cred-work", "claude-opus-4", emptyList())),
                service.mock.modelRoutes(event.instance.id),
            )
        }
        assertNull(vm.uiState.value.adopt)
    }

    @Test
    fun adoptSkippingModelOpensRoutes() = test {
        val service = CatalogService()
        val vm = detail(service)
        advanceUntilIdle()
        vm.openAdopt("代码助手 的实例")
        advanceUntilIdle()
        vm.onKeyChange(null)
        assertNull(vm.uiState.value.adopt!!.credentialId)
        vm.events.test {
            vm.adopt()
            val event = awaitItem() as AgentDetailEvent.Adopted
            assertFalse(event.routesConfigured)
            assertTrue(service.mock.modelRoutes(event.instance.id).isEmpty())
        }
        assertTrue("跳过不调 setModelRoutes", service.routeSets.isEmpty())
    }

    @Test
    fun adoptKeyListFiltersByProtocolAndHandlesNoKeys() = test {
        val service = CatalogService()
        service.mock.updateCredential("cred-work", CredentialUpdate(disabled = true))
        val vm = detail(service, "agent-research")
        advanceUntilIdle()
        vm.openAdopt("调研助手 的实例")
        advanceUntilIdle()
        assertEquals("停用的 key 不能选", listOf("cred-home"), vm.uiState.value.keys.usable.map { it.id })
        assertEquals("cred-home", vm.uiState.value.adopt!!.credentialId)
        vm.closeAdopt()

        // 没有能用的 key：只能跳过
        service.mock.updateCredential("cred-home", CredentialUpdate(disabled = true))
        val none = detail(service, "agent-research")
        advanceUntilIdle()
        none.openAdopt("调研助手 的实例")
        advanceUntilIdle()
        assertTrue(none.uiState.value.keys.usable.isEmpty())
        assertNull(none.uiState.value.adopt!!.credentialId)
        none.events.test {
            none.adopt()
            assertFalse((awaitItem() as AgentDetailEvent.Adopted).routesConfigured)
        }

        // key 列表加载失败：也当作跳过，下次打开表单重新取
        val failing = detail(service, "agent-research")
        advanceUntilIdle()
        service.fail("credentials", ServiceError.Network("offline"))
        failing.openAdopt("调研助手 的实例")
        advanceUntilIdle()
        assertTrue(failing.uiState.value.keys.failed)
        assertNull(failing.uiState.value.adopt!!.credentialId)
        assertTrue(service.routeSets.isEmpty())
    }

    @Test
    fun adoptStillSucceedsWhenRoutesFail() = test {
        val service = CatalogService()
        val vm = detail(service)
        advanceUntilIdle()
        vm.openAdopt("代码助手 的实例")
        advanceUntilIdle()
        service.fail("setModelRoutes", ServiceError.Network("offline"))
        vm.events.test {
            vm.adopt()
            val event = awaitItem() as AgentDetailEvent.Adopted
            assertFalse("配 main 失败：照样算领养成功，界面打开模型别名页", event.routesConfigured)
            assertTrue(service.mock.instances().any { it.id == event.instance.id })
        }
        assertEquals(1, service.routeSets.size)
        assertNull(vm.uiState.value.adopt)
    }

    @Test
    fun adoptWithSingleHarnessLetsServerPickDefault() = test {
        val service = CatalogService()
        val vm = detail(service, "agent-research")
        advanceUntilIdle()
        vm.openAdopt("调研助手 的实例")
        vm.events.test {
            vm.adopt()
            awaitItem()
        }
        assertEquals(listOf(Triple("agent-research", "调研助手 的实例", null)), service.adoptions)
    }

    @Test
    fun adoptValidatesNameLocally() = test {
        val service = CatalogService()
        val vm = detail(service)
        advanceUntilIdle()
        vm.openAdopt("x")
        vm.onNameChange("   ")
        vm.adopt()
        assertEquals(UiText(R.string.instance_name_required), vm.uiState.value.adopt!!.nameError)
        vm.onNameChange("名".repeat(65))
        vm.adopt()
        assertEquals(UiText(R.string.instance_name_too_long, listOf(64)), vm.uiState.value.adopt!!.nameError)
        advanceUntilIdle()
        assertTrue("本地校验不过不发请求", service.adoptions.isEmpty())
        // 改名字清掉提示
        vm.onNameChange("好名字")
        assertNull(vm.uiState.value.adopt!!.nameError)
    }

    @Test
    fun defaultNameIsClippedToLimit() = test {
        val vm = detail(CatalogService())
        advanceUntilIdle()
        vm.openAdopt("长".repeat(70) + " 的实例")
        assertEquals(64, InstanceNames.length(vm.uiState.value.adopt!!.name))
        // 按码点算：emoji 算一个字
        assertEquals(2, InstanceNames.length("😀a"))
    }

    @Test
    fun adoptFailuresMapToFieldOrFormErrors() = test {
        val service = CatalogService()
        val vm = detail(service)
        advanceUntilIdle()
        vm.openAdopt("代码助手 的实例")

        // 409 conflict 和 instance_limit 服务端目前不返回（名字没有唯一约束、没有数量上限），这两条是防将来加上的分支。
        service.fail("adopt", api(409, "conflict", "instance already exists"))
        vm.adopt()
        advanceUntilIdle()
        var form = vm.uiState.value.adopt!!
        assertEquals("conflict 提示在名字下", UiText(R.string.adopt_conflict), form.nameError)
        assertNull(form.error)
        assertFalse(form.submitting)

        service.fail("adopt", api(429, "rate_limited", "slow down", 30))
        vm.adopt()
        advanceUntilIdle()
        form = vm.uiState.value.adopt!!
        assertNull(form.nameError)
        assertEquals(UiText(R.string.adopt_rate_limited, listOf(30)), form.error)

        service.fail("adopt", api(422, "instance_limit", "too many instances"))
        vm.adopt()
        advanceUntilIdle()
        assertEquals(UiText(R.string.adopt_limit_reached), vm.uiState.value.adopt!!.error)

        service.fail("adopt", api(422, "invalid", "name must be 1-64 characters"))
        vm.adopt()
        advanceUntilIdle()
        assertEquals(UiText(R.string.instance_name_too_long, listOf(64)), vm.uiState.value.adopt!!.nameError)

        service.fail("adopt", api(422, "invalid", "version 1.4.0 of agent-coder was withdrawn"))
        vm.adopt()
        advanceUntilIdle()
        assertEquals(UiText(R.string.adopt_invalid), vm.uiState.value.adopt!!.error)

        service.fail("adopt", api(404, "not_found", "unknown agent"))
        vm.adopt()
        advanceUntilIdle()
        assertEquals(UiText(R.string.adopt_agent_gone), vm.uiState.value.adopt!!.error)

        service.fail("adopt", ServiceError.Network("timeout"))
        vm.adopt()
        advanceUntilIdle()
        assertEquals(UiText(R.string.error_network), vm.uiState.value.adopt!!.error)
        assertEquals("失败后表单保留", "代码助手 的实例", vm.uiState.value.adopt!!.name)
        assertEquals(7, service.adoptions.size)
    }

    @Test
    fun cannotCloseOrEditWhileSubmitting() = test {
        val vm = detail(CatalogService())
        advanceUntilIdle()
        vm.openAdopt("a")
        vm.adopt()
        vm.closeAdopt()
        vm.onNameChange("b")
        assertEquals("a", vm.uiState.value.adopt!!.name)
        advanceUntilIdle()
        assertNull(vm.uiState.value.adopt)
    }

    // ---- 实例设置 ----

    private fun settings(service: CatalogService, id: String = "inst-coder") =
        InstanceSettingsViewModel(service, id, DemoTestApp.FIXED_CLOCK)

    @Test
    fun settingsLoadsInstanceAndVersions() = test {
        val service = CatalogService()
        val vm = settings(service)
        advanceUntilIdle()
        val state = vm.uiState.value
        assertEquals("小码", state.instance?.name)
        assertEquals("代码助手", state.agent?.name)
        assertFalse("1.4.0 已是最新", state.canUpgrade)
        assertEquals(listOf("1.3.2"), state.otherVersions.map { it.version })
        assertTrue(state.otherVersions.single().older)
    }

    @Test
    fun rollbackThenUpgrade() = test {
        val service = CatalogService()
        val vm = settings(service)
        advanceUntilIdle()
        vm.events.test {
            vm.askVersion(vm.uiState.value.otherVersions.single())
            val dialog = vm.uiState.value.dialog as InstanceDialog.ChangeVersion
            assertEquals("1.3.2", dialog.version)
            assertTrue(dialog.older)
            vm.confirmVersion()
            assertEquals(InstanceSettingsEvent.Changed, awaitItem())
            assertEquals(
                InstanceSettingsEvent.Message(UiText(R.string.instance_version_changed, listOf("1.3.2"))),
                awaitItem(),
            )
            assertNull(vm.uiState.value.dialog)
            assertEquals("1.3.2", vm.uiState.value.instance?.agentVersion)
            assertTrue("回滚后可以升级", vm.uiState.value.canUpgrade)
            assertTrue(vm.uiState.value.otherVersions.isEmpty())

            vm.askUpgrade()
            val upgrade = vm.uiState.value.dialog as InstanceDialog.ChangeVersion
            assertNull("升级传 null（最新）", upgrade.version)
            assertEquals("1.4.0", upgrade.target)
            vm.confirmVersion()
            assertEquals(InstanceSettingsEvent.Changed, awaitItem())
            awaitItem()
        }
        assertEquals(listOf("1.3.2", null), service.versionCalls)
        assertEquals("1.4.0", vm.uiState.value.instance?.agentVersion)
        assertFalse(vm.uiState.value.canUpgrade)
    }

    @Test
    fun writerVersionsSplitIntoNewerAndOlder() = test {
        val service = CatalogService()
        val adopted = service.mock.adopt("agent-writer", "写手", null)
        service.mock.setInstanceVersion(adopted.id, "2.0.0")
        val vm = settings(service, adopted.id)
        advanceUntilIdle()
        val state = vm.uiState.value
        assertTrue(state.canUpgrade)
        assertEquals("2.0.1", state.latestVersion)
        assertEquals(listOf("1.9.0"), state.otherVersions.map { it.version })
        assertTrue(state.otherVersions.single().older)
    }

    @Test
    fun versionFailureClosesDialogAndShowsMessage() = test {
        val service = CatalogService()
        val vm = settings(service)
        advanceUntilIdle()
        service.fail("setInstanceVersion", api(422, "invalid", "version not available"))
        vm.events.test {
            vm.askVersion(vm.uiState.value.otherVersions.single())
            vm.confirmVersion()
            assertEquals(InstanceSettingsEvent.Message(UiText(R.string.error_invalid)), awaitItem())
        }
        assertNull(vm.uiState.value.dialog)
        assertFalse(vm.uiState.value.busy)
        assertEquals("1.4.0", vm.uiState.value.instance?.agentVersion)
    }

    @Test
    fun settingsWithoutCatalogStillShowsInstance() = test {
        val service = CatalogService()
        service.fail("agents", ServiceError.Network("offline"))
        val vm = settings(service)
        advanceUntilIdle()
        assertEquals("小码", vm.uiState.value.instance?.name)
        assertNull(vm.uiState.value.agent)
        assertNull(vm.uiState.value.loadError)
        assertFalse(vm.uiState.value.canUpgrade)
        assertTrue(vm.uiState.value.otherVersions.isEmpty())
    }

    @Test
    fun settingsLoadErrorFallsBackToCache() = test {
        val service = CatalogService()
        service.fail("instance", ServiceError.Network("offline"))
        val vm = settings(service)
        advanceUntilIdle()
        assertEquals("缓存里的实例照常显示", "小码", vm.uiState.value.instance?.name)
        assertEquals(UiText(R.string.error_network), vm.uiState.value.loadError)
    }

    @Test
    fun deleteImpactListsPipelinesTeamsAndOwnPlans() = test {
        val service = CatalogService().mock
        val plans = service.plans()
        val teams = service.teams()
        val coder = "inst-coder"
        val research = "inst-research"
        val weekly = plans.first { it.id == "plan-weekly" }
        val pipeline = weekly.copy(
            id = "plan-pipe",
            title = "周报流水线",
            steps = listOf(
                PlanStep("collect", research, "收集", emptyList()),
                PlanStep("code", coder, "写代码", listOf("collect")),
                PlanStep("review", coder, "检查", listOf("code")),
            ),
        )
        val impact = DeleteImpact.of(coder, plans + pipeline, teams)
        assertEquals(listOf("plan-daily"), impact.ownPlans.map { it.id })
        assertEquals(listOf("plan-pipe"), impact.pipelinePlans.map { it.id })
        assertEquals(2, impact.removedSteps(pipeline, coder))
        assertEquals(listOf("调研小组"), impact.teams.map { it.name })
        assertFalse(impact.isEmpty)

        // 没人引用的实例
        val none = DeleteImpact.of("inst-lonely", plans + pipeline, teams)
        assertTrue(none.isEmpty)
    }

    @Test
    fun deleteAsksImpactThenConfirmsTwice() = test {
        val service = CatalogService()
        service.mock.createPlan(
            NewPlan(
                instanceId = "inst-research",
                title = "周报流水线",
                goal = "收集后写代码",
                triggers = emptyList(),
                steps = listOf(
                    PlanStep("collect", "inst-research", "收集", emptyList()),
                    PlanStep("code", "inst-coder", "写代码", listOf("collect")),
                ),
            ),
        )
        val vm = settings(service)
        advanceUntilIdle()
        vm.events.test {
            vm.askDelete()
            assertTrue(vm.uiState.value.checkingImpact)
            advanceUntilIdle()
            val notice = vm.uiState.value.dialog as InstanceDialog.DeleteImpactNotice
            assertEquals(listOf("周报流水线"), notice.impact.pipelinePlans.map { it.title })
            assertEquals(listOf("每日依赖检查"), notice.impact.ownPlans.map { it.title })
            assertEquals(listOf("调研小组"), notice.impact.teams.map { it.name })
            assertTrue("第一步不删", service.deleted.isEmpty())

            vm.continueDelete()
            assertTrue(vm.uiState.value.dialog is InstanceDialog.DeleteConfirm)
            vm.confirmDelete()
            assertEquals(InstanceSettingsEvent.Deleted, awaitItem())
        }
        assertEquals(listOf("inst-coder"), service.deleted)
        // 服务端（Mock 同样）只是软删除：流水线步骤还在（之后运行会失败），团队读取时看不到它
        val pipeline = service.mock.plans().first { it.title == "周报流水线" }
        assertEquals(listOf("collect", "code"), pipeline.steps.map { it.key })
        assertTrue(service.mock.teams().none { team -> team.members.any { it.instanceId == "inst-coder" } })
    }

    @Test
    fun deleteBlockedWhenImpactUnknown() = test {
        val service = CatalogService()
        val vm = settings(service)
        advanceUntilIdle()
        service.fail("teams", ServiceError.Network("offline"))
        vm.events.test {
            vm.askDelete()
            val message = awaitItem() as InstanceSettingsEvent.Message
            assertEquals(
                UiText(R.string.instance_delete_impact_failed, listOf(UiText(R.string.error_network))),
                message.text,
            )
        }
        assertNull(vm.uiState.value.dialog)
        assertFalse(vm.uiState.value.checkingImpact)
        assertTrue(service.deleted.isEmpty())
    }

    @Test
    fun deleteAlreadyGoneCountsAsSuccessButOtherErrorsDoNot() = test {
        val service = CatalogService()
        val vm = settings(service)
        advanceUntilIdle()
        vm.events.test {
            service.fail("deleteInstance", ServiceError.Network("offline"))
            vm.askDelete()
            advanceUntilIdle()
            vm.continueDelete()
            vm.confirmDelete()
            assertEquals(InstanceSettingsEvent.Message(UiText(R.string.error_network)), awaitItem())
            assertNull(vm.uiState.value.dialog)

            service.fail("deleteInstance", api(404, "not_found", "instance"))
            vm.askDelete()
            advanceUntilIdle()
            vm.continueDelete()
            vm.confirmDelete()
            assertEquals(InstanceSettingsEvent.Deleted, awaitItem())
        }
    }

    // ---- 改名 ----

    @Test
    fun renameSavesTrimmedNameAndMapsErrors() = test {
        val service = CatalogService()
        val vm = InstanceNameViewModel(service, "inst-coder")
        advanceUntilIdle()
        assertEquals("小码", vm.uiState.value.name)
        assertTrue(vm.uiState.value.editable)

        vm.onNameChange("")
        vm.save()
        assertEquals(UiText(R.string.instance_name_required), vm.uiState.value.error)

        vm.onNameChange("码农")
        // 服务端改名目前不返回 409（防御分支）
        service.fail("renameInstance", api(409, "conflict"))
        vm.save()
        advanceUntilIdle()
        assertEquals(UiText(R.string.adopt_conflict), vm.uiState.value.error)
        assertFalse(vm.uiState.value.saving)

        vm.events.test {
            vm.onNameChange("  码农  ")
            vm.save()
            val saved = awaitItem() as InstanceNameEvent.Saved
            assertEquals("码农", saved.instance?.name)
            // 保存成功后再点（退出动画期间）：不再发 Saved
            assertFalse(vm.uiState.value.editable)
            vm.save()
            advanceUntilIdle()
            expectNoEvents()
        }
        assertEquals("码农", service.mock.instance("inst-coder").name)
    }

    @Test
    fun renameUnchangedNameJustCloses() = test {
        val service = CatalogService()
        val vm = InstanceNameViewModel(service, "inst-coder")
        advanceUntilIdle()
        vm.events.test {
            vm.onNameChange(" 小码 ")
            vm.save()
            assertEquals(InstanceNameEvent.Saved(null), awaitItem())
            vm.save()
            expectNoEvents()
        }
    }

    // ---- 首页与抽屉 ----

    @Test
    fun homeWithoutInstancesShowsFeaturedAgents() = test {
        val service = CatalogService()
        service.mock.instances().forEach { service.mock.deleteInstance(it.id) }
        val base = service.mock.agents().first()
        // 目录比精选多：只取前 3 个，顺序不变
        service.agentsOverride = (1..5).map { base.copy(id = "agent-$it", name = "Agent $it") }
        val vm = HomeViewModel(service, DemoTestApp.FIXED_CLOCK)
        advanceUntilIdle()
        assertTrue(vm.uiState.value.instances.isEmpty())
        assertEquals(listOf("agent-1", "agent-2", "agent-3"), vm.uiState.value.featured.map { it.id })
        service.agentsOverride = null

        // 领养后回到首页：重新加载，精选收起
        service.mock.adopt("agent-coder", "新的", null)
        vm.onShown()
        vm.onShown()
        advanceUntilIdle()
        assertEquals(listOf("新的"), vm.uiState.value.instances.map { it.name })
        assertTrue(vm.uiState.value.featured.isEmpty())
    }

    @Test
    fun homeFeaturedFailureIsSilent() = test {
        val service = CatalogService()
        service.mock.instances().forEach { service.mock.deleteInstance(it.id) }
        service.fail("agents", ServiceError.Network("offline"))
        val vm = HomeViewModel(service, DemoTestApp.FIXED_CLOCK)
        advanceUntilIdle()
        val s = vm.uiState.value
        assertTrue(s.instances.isEmpty())
        assertTrue(s.featured.isEmpty())
        assertNull(s.refreshError)
        assertFalse(s.loading)
    }

    @Test
    fun homeWithInstancesDoesNotFetchCatalog() = test {
        val service = CatalogService()
        val vm = HomeViewModel(service, DemoTestApp.FIXED_CLOCK)
        advanceUntilIdle()
        assertTrue(vm.uiState.value.featured.isEmpty())
        assertEquals(0, service.agentsCalls)
    }

    @Test
    fun drawerShowsAgentNames() = test {
        val service = CatalogService()
        val vm = DrawerViewModel(service)
        advanceUntilIdle()
        assertEquals("代码助手", vm.uiState.value.agentNames["agent-coder"])
        assertEquals("调研助手", vm.uiState.value.agentNames["agent-research"])
        // 搜索也匹配行上显示的 agent 名（不只是实例名和 agent id）
        vm.onQueryChange("调研助手")
        assertEquals(listOf("inst-research"), vm.uiState.value.visibleInstances.map { it.id })
        vm.onQueryChange("代码")
        assertEquals(listOf("inst-coder"), vm.uiState.value.visibleInstances.map { it.id })
        vm.onQueryChange("")
        assertEquals(2, vm.uiState.value.visibleInstances.size)

        // 目录拉不到：照样有实例，名字回退到 id（界面上）
        val failing = CatalogService()
        failing.fail("agents", ServiceError.Network("offline"))
        val vm2 = DrawerViewModel(failing)
        advanceUntilIdle()
        assertEquals(2, vm2.uiState.value.instances.size)
        assertTrue(vm2.uiState.value.agentNames.isEmpty())
        assertTrue(vm2.uiState.value.user != null)
    }
}
