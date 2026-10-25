package cn.thinktin.app

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.isPopup
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.ui.chat.CHAT_SCREEN_TEST_TAG
import cn.thinktin.app.ui.agent.ADOPT_SHEET_TEST_TAG
import cn.thinktin.app.ui.catalog.AGENT_CARD_TEST_TAG
import cn.thinktin.app.ui.drawer.DRAWER_TEST_TAG
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.ModelRoute
import cn.thinktin.data.model.NewPlan
import cn.thinktin.data.model.PlanStep
import cn.thinktin.data.service.ServiceError
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 13.3 的界面：首页空状态与目录精选、目录渲染与搜索、加载失败重试、详情页领养（选默认模型到对话页、跳过到模型别名页）、
 * 实例设置（深链进入、返回键回首页、改名、删除确认列出受影响的计划和团队）。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class CatalogUiTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null
    private val app: DemoTestApp get() = ApplicationProvider.getApplicationContext()
    private val inDialog = hasAnyAncestor(isDialog())
    private val inSheet = hasAnyAncestor(hasTestTag(ADOPT_SHEET_TEST_TAG))
    private val mock = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() })
    private val fake = FakeThinktinService(mock)

    @After
    fun tearDown() {
        scenario?.close()
    }

    private fun launch(uri: String? = null) {
        app.container = testContainer(app, { fake })
        val intent = Intent(app, MainActivity::class.java)
        if (uri != null) {
            intent.action = Intent.ACTION_VIEW
            intent.data = Uri.parse(uri)
        }
        scenario = ActivityScenario.launch(intent)
    }

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    /**
     * 点领养表单里的控件：Robolectric 的触摸注入点不到盖在页面上的面板（落到了下面的遮罩上，和抽屉一样，真机正常），
     * 用无障碍点击动作。
     */
    private fun SemanticsNodeInteraction.tap() = performSemanticsAction(SemanticsActions.OnClick)

    private fun card(agentId: String) = hasTestTag(AGENT_CARD_TEST_TAG + agentId)

    private val searchField = hasContentDescription("搜索 agent") and hasSetTextAction()

    /** 有实例时从首页右上角的溢出菜单进目录。 */
    private fun openCatalogFromMenu() {
        waitFor(hasText("最近运行"))
        compose.waitForIdle()
        compose.onNode(hasContentDescription("更多")).performClick()
        compose.onNode(hasText("Agent 目录") and hasAnyAncestor(isPopup())).performClick()
        waitFor(searchField)
    }

    @Test
    fun emptyHomeShowsFeaturedAndCatalogSearches() {
        runBlocking { mock.instances().forEach { mock.deleteInstance(it.id) } }
        launch()
        // 没有实例：衬线问候 + 主按钮 + 目录精选
        waitFor(hasText("精选 agent"))
        compose.onNode(hasText("早上好", substring = true)).assertIsDisplayed()
        compose.onNode(hasText("领养一个 agent")).assertIsDisplayed()
        compose.onNode(card("agent-coder")).assertExists()
        compose.onNode(card("agent-writer")).assertExists()
        compose.onAllNodes(hasText("让", substring = true) and hasSetTextAction()).assertCountEquals(0)

        compose.onNode(hasText("领养一个 agent")).performClick()
        waitFor(searchField)
        compose.onNode(hasText("Agent 目录")).assertIsDisplayed()
        waitFor(card("agent-research"))
        // 卡片：名字、一句话介绍（上游写的，不标 AI 生成）、许可证、接入方式、协议
        compose.onNode(hasText("代码助手") and hasAnyAncestor(card("agent-coder"))).assertIsDisplayed()
        compose.onNode(hasText("读代码、改代码、跑测试，按你的要求提交 PR。")).assertIsDisplayed()
        compose.onNode(hasContentDescription("许可证：Apache-2.0")).assertIsDisplayed()
        compose.onNode(hasContentDescription("接入方式：codex") and hasAnyAncestor(card("agent-coder"))).assertIsDisplayed()
        compose.onNode(hasContentDescription("模型协议：Anthropic Messages") and hasAnyAncestor(card("agent-coder")))
            .assertIsDisplayed()
        compose.onNode(hasContentDescription("许可证：专有许可") and hasAnyAncestor(card("agent-writer"))).assertExists()
        compose.onAllNodes(hasText("【AI 生成】")).assertCountEquals(0)

        compose.onNode(searchField).performTextInput("MIT")
        waitFor(card("agent-research"))
        compose.onNode(card("agent-coder")).assertDoesNotExist()
        compose.onNode(card("agent-writer")).assertDoesNotExist()

        compose.onNode(searchField).performTextClearance()
        compose.onNode(searchField).performTextInput("没有这个")
        waitFor(hasText("没有找到和“没有这个”相关的 agent"))
        compose.onNode(card("agent-research")).assertDoesNotExist()

        compose.onNode(hasContentDescription("清除搜索")).performClick()
        waitFor(card("agent-coder"))
        compose.onNode(card("agent-research")).assertExists()
    }

    @Test
    fun catalogLoadErrorShowsRetry() {
        launch()
        waitFor(hasText("最近运行"))
        compose.waitForIdle()
        fake.failNext("agents", ServiceError.Network("offline"))
        openCatalogFromMenu()
        waitFor(hasText("目录加载失败"))
        compose.onNode(hasText("网络不通，请稍后重试")).assertIsDisplayed()
        compose.onNode(hasText("重试")).performClick()
        waitFor(card("agent-coder"))
        compose.onNode(hasText("目录加载失败")).assertDoesNotExist()
    }

    @Test
    fun adoptFromDetailOpensChat() {
        launch()
        openCatalogFromMenu()
        waitFor(card("agent-coder"))
        compose.onNode(card("agent-coder")).performClick()

        // 详情：介绍、版本、许可证、接入方式、协议、上游链接
        waitFor(hasText("最新版本 1.4.0"))
        compose.onNode(hasContentDescription("接入方式：claude-code（默认）")).assertIsDisplayed()
        compose.onNode(hasText("运行时使用 Anthropic Messages：给它配的模型 key 要支持这个协议。")).performScrollTo().assertIsDisplayed()
        compose.onNode(hasText("1.3.2")).performScrollTo().assertIsDisplayed()
        compose.onNode(hasText("https://github.com/example/coder")).performScrollTo().assertIsDisplayed()

        // 领养：底部表单，名字默认“<agent 名> 的实例”，两种接入方式可选
        compose.onNode(hasText("领养") and hasClickAction()).performClick()
        waitFor(hasTestTag(ADOPT_SHEET_TEST_TAG))
        val nameField = hasContentDescription("实例名字") and hasSetTextAction()
        compose.onNode(nameField and hasText("代码助手 的实例")).assertIsDisplayed()
        compose.onNode(hasText("codex") and inSheet).tap()
        compose.onNode(hasText("codex") and inSheet).assertIsSelected()
        compose.onNode(nameField).performTextClearance()
        compose.onNode(nameField).performTextInput("我的码农")
        // 默认模型（main）：默认选第一把能用的 key，预填厂商推荐的模型
        val workKey = hasText("工作 key（Anthropic · …a1b2）") and inSheet
        waitFor(workKey)
        compose.onNode(workKey).assertIsSelected()
        compose.onNode(hasContentDescription("上游模型") and hasSetTextAction() and hasText("claude-sonnet-4")).assertExists()
        compose.onNode(hasText("claude-opus-4") and inSheet).tap()
        compose.onNode(hasText("领养") and inSheet).tap()

        // 成功：跳到新实例的对话页，返回回到首页
        waitFor(hasText("开始对话"))
        val adopted = runBlocking { mock.instances() }.single { it.name == "我的码农" }
        assertEquals("codex", adopted.harness)
        assertEquals(
            listOf(ModelRoute("main", "cred-work", "claude-opus-4", emptyList())),
            runBlocking { mock.modelRoutes(adopted.id) },
        )
        compose.onNode(hasTestTag(CHAT_SCREEN_TEST_TAG + adopted.id)).assertExists()
        compose.onNode(hasContentDescription("返回")).performClick()
        waitFor(hasText("最近运行"))
        compose.onNode(searchField).assertDoesNotExist()
    }

    @Test
    fun adoptSkippingModelOpensRoutes() {
        launch()
        openCatalogFromMenu()
        waitFor(card("agent-research"))
        compose.onNode(card("agent-research")).performClick()
        waitFor(hasText("最新版本 0.9.2"))
        compose.onNode(hasText("领养") and hasClickAction()).performClick()
        waitFor(hasTestTag(ADOPT_SHEET_TEST_TAG))
        waitFor(hasText("跳过") and inSheet)
        compose.onNode(hasText("跳过") and inSheet).tap()
        waitFor(hasText("领养后会打开模型别名页；配好之前任务会一直等 key。"))
        compose.onAllNodes(hasContentDescription("上游模型") and hasSetTextAction()).assertCountEquals(0)
        compose.onNode(hasText("领养") and inSheet).tap()

        // 没配默认模型：打开模型别名页（顶部提示会等 key），返回到新实例的对话页
        waitFor(hasText("未配置模型（main），运行会等待 key"))
        compose.onNode(hasText("模型别名")).assertIsDisplayed()
        val adopted = runBlocking { mock.instances() }.single { it.name == "调研助手 的实例" }
        assertTrue(runBlocking { mock.modelRoutes(adopted.id) }.isEmpty())
        compose.onNode(hasContentDescription("返回")).performClick()
        waitFor(hasTestTag(CHAT_SCREEN_TEST_TAG + adopted.id))
        compose.onNode(hasContentDescription("返回")).performClick()
        waitFor(hasText("最近运行"))
    }

    @Test
    fun adoptRejectedShowsFormError() {
        launch()
        openCatalogFromMenu()
        waitFor(card("agent-research"))
        compose.onNode(card("agent-research")).performClick()
        waitFor(hasText("最新版本 0.9.2"))
        compose.onNode(hasText("领养") and hasClickAction()).performClick()
        waitFor(hasTestTag(ADOPT_SHEET_TEST_TAG))
        // 只有一种接入方式：不让选
        compose.onAllNodes(hasText("接入方式") and inSheet).assertCountEquals(0)
        // 服务端真会返回的两种：版本下架（422 invalid）、agent 不在目录里（404）
        fake.failNextAdopt(ServiceError.Api(422, "invalid", "version 0.9.2 of agent-research was withdrawn", null))
        compose.onNode(hasText("领养") and inSheet).tap()
        waitFor(hasText("这个 agent 当前不能领养，请稍后再试"))
        compose.onNode(hasTestTag(ADOPT_SHEET_TEST_TAG)).assertIsDisplayed()
        fake.failNextAdopt(ServiceError.Api(404, "not_found", "unknown agent agent-research", null))
        compose.onNode(hasText("领养") and inSheet).tap()
        waitFor(hasText("这个 agent 已经下架，不能领养"))
        compose.onNode(hasTestTag(ADOPT_SHEET_TEST_TAG)).assertIsDisplayed()
        // 取消收起表单
        compose.onNode(hasText("取消") and inSheet).tap()
        waitFor(hasText("领养") and hasClickAction() and !inSheet)
        compose.onNode(hasTestTag(ADOPT_SHEET_TEST_TAG)).assertDoesNotExist()
    }

    @Test
    fun instanceDeepLinkRenameAndDeleteListsAffectedPlans() {
        runBlocking {
            mock.createPlan(
                NewPlan(
                    instanceId = "inst-research",
                    title = "周报流水线",
                    goal = "调研后写代码",
                    triggers = emptyList(),
                    steps = listOf(
                        PlanStep("collect", "inst-research", "收集", emptyList()),
                        PlanStep("code", "inst-coder", "写代码", listOf("collect")),
                    ),
                ),
            )
        }
        launch("thinktin://instance/inst-coder")
        waitFor(hasText("代码助手 · claude-code"))
        compose.onNode(hasText("实例设置")).assertIsDisplayed()
        compose.onNode(hasText("1.4.0（已是最新）")).assertIsDisplayed()
        compose.onNode(hasContentDescription("回滚到 1.3.2")).performScrollTo().assertIsDisplayed()
        compose.onNode(hasText("模型别名与降级")).performScrollTo().assertIsDisplayed()

        // 改名：单独的页面（不用对话框），保存后回到设置页
        compose.onNode(hasText("名字") and hasClickAction()).performScrollTo().performClick()
        val nameField = hasContentDescription("名字") and hasSetTextAction()
        waitFor(nameField and hasText("小码"))
        compose.onNode(nameField).performTextClearance()
        compose.onNode(nameField).performTextInput("码农")
        compose.onNode(hasText("保存")).performClick()
        waitFor(hasText("代码助手 · claude-code"))
        waitFor(hasText("码农") and hasClickAction() and !hasAnyAncestor(hasTestTag(DRAWER_TEST_TAG)))
        assertEquals("码农", runBlocking { mock.instance("inst-coder") }.name)

        // 删除：先列出受影响的计划和团队，再二次确认
        compose.onNode(hasText("删除实例")).performScrollTo().performClick()
        waitFor(hasText("删除“码农”？"))
        compose.onNode(hasText("删除会影响下面这些计划和团队：") and inDialog).assertIsDisplayed()
        compose.onNode(hasText("每日依赖检查") and inDialog).assertIsDisplayed()
        compose.onNode(hasText("周报流水线（1 个步骤）") and inDialog).assertIsDisplayed()
        compose.onNode(hasText("• 调研小组") and inDialog).assertIsDisplayed()
        // 11.9 的语义：自己的计划删除、流水线暂停（改步骤才能恢复）、团队移出
        compose.onNode(hasText("它自己的计划（将被删除）") and inDialog).assertIsDisplayed()
        compose.onNode(hasText("有步骤用到它的流水线（将被暂停，需改步骤后才能恢复）") and inDialog).assertIsDisplayed()
        compose.onNode(hasText("它所在的团队（将把它移出）") and inDialog).assertIsDisplayed()
        compose.onNode(hasText("继续") and inDialog).performClick()
        waitFor(hasText("确定删除“码农”？"))
        compose.onNode(hasText("它的模型别名一起删除", substring = true) and inDialog).assertIsDisplayed()
        assertTrue("第一步不删", runBlocking { mock.instances() }.any { it.id == "inst-coder" })
        compose.onNode(hasText("删除实例") and inDialog).performClick()

        // 成功回首页：剩下的实例是“研究员”
        waitFor(hasText("最近运行"))
        waitFor(hasContentDescription("让 研究员 做点什么"))
        val left = runBlocking { mock.instances() }
        assertTrue(left.none { it.id == "inst-coder" || it.state == InstanceState.Deleted })
        // 服务端（Mock 同样）：流水线暂停、步骤留着（改了步骤才能恢复）；自己的计划没了
        val pipeline = runBlocking { mock.plans() }.single { it.title == "周报流水线" }
        assertEquals(listOf("collect", "code"), pipeline.steps.map { it.key })
        assertTrue(pipeline.paused)
        assertTrue(runBlocking { mock.plans() }.none { it.title == "每日依赖检查" })
    }

    @Test
    fun instanceDeepLinkBackReturnsHome() {
        launch("thinktin://instance/inst-coder")
        waitFor(hasText("代码助手 · claude-code"))
        compose.onNode(hasText("实例设置")).assertIsDisplayed()
        compose.onNode(hasContentDescription("返回")).performClick()
        waitFor(hasText("最近运行"))
    }

    @Test
    fun deleteWithoutImpactUsesSimpleConfirm() {
        val lonely = runBlocking { mock.adopt("agent-writer", "写手", null) }
        launch("thinktin://instance/${lonely.id}")
        waitFor(hasText("删除实例"))
        compose.onNode(hasText("删除实例")).performScrollTo().performClick()
        waitFor(hasText("删除“写手”？"))
        compose.onNode(hasText("没有计划或团队用到这个实例。删除后不能恢复。") and inDialog).assertIsDisplayed()
        compose.onNode(hasText("继续") and inDialog).performClick()
        waitFor(hasText("确定删除“写手”？"))
        compose.onNode(
            hasText("实例会被永久删除，进行中的运行会被取消，它的模型别名一起删除。这个操作不能撤销。") and inDialog,
        ).assertIsDisplayed()
    }
}
