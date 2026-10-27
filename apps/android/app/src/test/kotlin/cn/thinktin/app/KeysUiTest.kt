package cn.thinktin.app

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
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
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.ui.keys.KEY_ROW_TEST_TAG
import cn.thinktin.app.ui.keys.VENDOR_LIST_TEST_TAG
import cn.thinktin.app.ui.keys.VENDOR_ROW_TEST_TAG
import cn.thinktin.app.ui.routes.ROUTE_CARD_TEST_TAG
import cn.thinktin.app.ui.usage.USAGE_CHART_TEST_TAG
import cn.thinktin.app.ui.usage.USAGE_LIST_TEST_TAG
import cn.thinktin.app.ui.usage.USAGE_ROW_TEST_TAG
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.CredentialUpdate
import cn.thinktin.data.model.ModelRoute
import cn.thinktin.data.model.RouteFallback
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
 * 13.4 的界面：key 列表渲染与删除确认（列出在用的别名）、添加 key 两步（含订阅类 key 的字段提示）、
 * 模型别名页（没有 main 的警告、加降级项并保存）、用量页切换分组。从实例设置（深链进入）进这些页面。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class KeysUiTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null
    private val app: DemoTestApp get() = ApplicationProvider.getApplicationContext()
    private val inDialog = hasAnyAncestor(isDialog())
    private val inPopup = hasAnyAncestor(isPopup())
    private val mock = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() })
    private val fake = FakeThinktinService(mock)

    @After
    fun tearDown() {
        scenario?.close()
    }

    private fun launch(uri: String) {
        app.container = testContainer(app, { fake })
        val intent = Intent(app, MainActivity::class.java)
            .setAction(Intent.ACTION_VIEW)
            .setData(Uri.parse(uri))
        scenario = ActivityScenario.launch(intent)
    }

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun waitGone(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isEmpty() }
    }

    private fun keyRow(id: String) = hasTestTag(KEY_ROW_TEST_TAG + id)

    /** 实例设置（深链）→ “模型 key” → key 列表。 */
    private fun openKeys(instanceId: String = "inst-coder") {
        launch("thinktin://instance/$instanceId")
        waitFor(hasText("实例设置"))
        waitFor(hasText("模型 key") and hasClickAction())
        compose.onNode(hasText("模型 key") and hasClickAction()).performScrollTo().performClick()
        waitFor(keyRow("cred-work"))
    }

    @Test
    fun keyListRendersAndDeleteListsAliases() {
        openKeys()
        compose.onNode(hasText("模型 key") and !hasClickAction()).assertIsDisplayed()
        // 每行：标签、厂商与后 4 位、每日限额、状态、协议
        compose.onNode(hasText("工作 key") and hasAnyAncestor(keyRow("cred-work"))).assertIsDisplayed()
        compose.onNode(hasText("Anthropic · …a1b2")).assertIsDisplayed()
        compose.onNode(hasText("每日限额 200 万 token")).assertIsDisplayed()
        compose.onNode(hasText("DeepSeek · …9z8y")).assertIsDisplayed()
        compose.onNode(hasText("不限每日用量")).assertIsDisplayed()
        compose.onAllNodes(hasContentDescription("状态：正常")).assertCountEquals(2)
        compose.onNode(hasContentDescription("模型协议：Responses") and hasAnyAncestor(keyRow("cred-home"))).assertExists()
        compose.onAllNodes(hasText("【AI 生成】")).assertCountEquals(0)

        // 更多 → 停用
        compose.onNode(hasContentDescription("“工作 key”的更多操作")).performClick()
        compose.onNode(hasText("停用") and inPopup).performClick()
        waitFor(hasContentDescription("状态：已停用"))
        assertTrue(runBlocking { mock.credentials() }.first { it.id == "cred-work" }.disabled)

        // 更多 → 删除：列出在用它的别名，确认后先从别名里拿掉再删
        compose.onNode(hasContentDescription("“个人”的更多操作")).performClick()
        compose.onNode(hasText("删除 key") and inPopup).performClick()
        waitFor(hasText("删除“个人”（…9z8y）？"))
        compose.onNode(hasText("这些实例的模型别名在用这把 key：") and inDialog).assertIsDisplayed()
        compose.onNode(hasText("• 小码：main（降级）") and inDialog).assertIsDisplayed()
        compose.onNode(hasText("• 研究员：main（主 key）") and inDialog).assertIsDisplayed()
        // 小码的别名里还用着刚停用的工作 key：11.9 起它原来就在用，可以留着，所以拿掉“个人”不会被拒
        compose.onNode(hasText("移除并删除") and inDialog).performClick()
        waitGone(keyRow("cred-home"))
        waitFor(hasText("已删除“个人”"))
        assertTrue(runBlocking { mock.credentials() }.none { it.id == "cred-home" })
        assertTrue(runBlocking { mock.modelRoutes("inst-research") }.isEmpty())
        assertEquals(
            listOf(ModelRoute("main", "cred-work", "claude-sonnet-4", emptyList())),
            runBlocking { mock.modelRoutes("inst-coder") },
        )
    }

    @Test
    fun editKeyChangesDailyLimit() {
        openKeys()
        compose.onNode(keyRow("cred-work")).performClick()
        waitFor(hasContentDescription("每日 token 限额（可选）") and hasText("2000000"))
        // 编辑页能改上限（11.9），不再提示“删了重加”
        compose.onNode(hasText("每日限额只能在添加时设置", substring = true)).assertDoesNotExist()
        compose.onNode(hasText("清空就是不限", substring = true)).assertExists()
        compose.onNode(hasContentDescription("每日 token 限额（可选）")).performTextReplacement("3,000,000")
        compose.onNode(hasText("保存")).performScrollTo().performClick()
        // 回到列表：显示新的上限
        waitFor(hasText("每日限额 300 万 token"))
        assertEquals(3_000_000L, runBlocking { mock.credentials() }.first { it.id == "cred-work" }.dailyTokenLimit)
    }

    @Test
    fun routesKeepDisabledKeyWithWarning() {
        // 小码的降级项用着“个人”，把它停用：别名页不报错、只提示，照样能保存
        runBlocking { mock.updateCredential("cred-home", CredentialUpdate(disabled = true)) }
        launch("thinktin://instance/inst-coder")
        waitFor(hasText("模型别名与降级"))
        compose.onNode(hasText("模型别名与降级")).performScrollTo().performClick()
        waitFor(hasText("这把 key 已停用，运行时会跳过它", substring = true))
        compose.onNode(hasText("这把 key 已停用，不能新选", substring = true)).assertDoesNotExist()
        compose.onNode(hasText("claude-opus-4") and hasClickAction()).performScrollTo().performClick()
        compose.onNode(hasText("保存")).performScrollTo().performClick()
        waitFor(hasText("模型别名已保存，等 key 的任务会接着跑"))
        assertEquals(
            listOf(ModelRoute("main", "cred-work", "claude-opus-4", listOf(RouteFallback("cred-home", "deepseek-chat")))),
            runBlocking { mock.modelRoutes("inst-coder") },
        )
    }

    @Test
    fun addKeyTwoSteps() {
        openKeys()
        compose.onNode(hasText("添加 key") and hasClickAction()).performScrollTo().performClick()

        // 第一步：按协议分组的厂商，最后是自定义接口
        waitFor(hasText("添加 key：选厂商"))
        waitFor(hasTestTag(VENDOR_ROW_TEST_TAG + "deepseek"))
        compose.onNode(hasText("支持 Anthropic Messages、Chat Completions、Responses")).assertIsDisplayed()
        compose.onNode(hasTestTag(VENDOR_ROW_TEST_TAG + "qwen-cn")).performClick()

        // 第二步：订阅类 key 粘贴进来就提示在字段下
        waitFor(hasText("添加 key：填写"))
        val keyField = hasContentDescription("API key") and hasSetTextAction()
        compose.onNode(keyField).performTextInput("  sk-sp-abcdef0123456789\n")
        waitFor(hasText("这是订阅类 key（sk-sp-…），只能在厂商自己的工具里用。请换一把按量付费的 API key。"))

        // 换厂商：回到第一步（返回键也一样），已填的保留
        compose.onNode(hasText("换厂商")).performClick()
        waitFor(hasText("添加 key：选厂商"))
        compose.onNode(hasTestTag(VENDOR_ROW_TEST_TAG + "deepseek")).performClick()
        waitFor(hasText("添加 key：填写"))
        val labelField = hasContentDescription("标签") and hasSetTextAction()
        compose.onNode(labelField and hasText("DeepSeek")).assertIsDisplayed()
        compose.onNode(hasText("这是订阅类 key", substring = true)).assertDoesNotExist()
        compose.onNode(hasContentDescription("每日 token 限额（可选）") and hasSetTextAction()).performScrollTo()
            .performTextInput("1,000,000")
        compose.onNode(hasText("保存 key")).performScrollTo().performClick()

        // 成功回列表，新 key 在里面
        waitFor(hasText("DeepSeek · …6789"))
        compose.onNode(hasText("每日限额 100 万 token")).assertIsDisplayed()
        val added = runBlocking { mock.credentials() }.single { it.last4 == "6789" }
        assertEquals("deepseek", added.vendor)
        assertEquals(1_000_000L, added.dailyTokenLimit)
    }

    @Test
    fun customEndpointShowsFieldErrors() {
        openKeys()
        compose.onNode(hasText("添加 key") and hasClickAction()).performScrollTo().performClick()
        waitFor(hasTestTag(VENDOR_ROW_TEST_TAG + "deepseek"))
        // 自定义接口在列表最后（LazyColumn，可能还没组合出来）：先滚过去
        compose.onNode(hasTestTag(VENDOR_LIST_TEST_TAG)).performScrollToNode(hasTestTag(VENDOR_ROW_TEST_TAG + "custom"))
        compose.onNode(hasClickAction() and hasAnyAncestor(hasTestTag(VENDOR_ROW_TEST_TAG + "custom"))).performClick()
        waitFor(hasText("这个接口支持的协议"))
        compose.onNode(hasContentDescription("API key") and hasSetTextAction()).performTextInput("sk-relay-0123456789")
        val chatBase = hasContentDescription("Chat Completions 地址") and hasSetTextAction()
        compose.onNode(chatBase).performTextInput("https://192.168.1.5/v1")
        compose.onNode(hasText("保存 key")).performScrollTo().performClick()
        waitFor(hasText("只能填公网地址：localhost、内网域名和内网 IP 都不行"))
        assertTrue(runBlocking { mock.credentials() }.none { it.vendor == "custom" })
    }

    @Test
    fun routesWarnWithoutMainAndSaveFallback() {
        runBlocking { mock.setModelRoutes("inst-research", emptyList()) }
        launch("thinktin://instance/inst-research")
        waitFor(hasText("模型别名与降级"))
        compose.onNode(hasText("模型别名与降级")).performScrollTo().performClick()

        // 没有 main：顶部警告；默认给一行空的 main
        waitFor(hasText("未配置模型（main），运行会等待 key"))
        val card = hasAnyAncestor(hasTestTag(ROUTE_CARD_TEST_TAG + "0"))
        compose.onNode(hasContentDescription("别名") and hasText("main") and card).assertIsDisplayed()
        compose.onNode(hasText("默认模型（必填）")).assertIsDisplayed()
        compose.onNode(hasText("保存")).performScrollTo().performClick()
        waitFor(hasText("请选一把 key"))

        // 选主 key：模型自动填上厂商推荐的第一个
        compose.onNode(hasText("选择 key") and card).performScrollTo().performClick()
        compose.onNode(hasText("个人（DeepSeek · …9z8y）") and inPopup).performClick()
        waitFor(hasContentDescription("上游模型") and hasText("deepseek-chat"))
        // 加一个备用：工作 key
        compose.onNode(hasText("给 main 添加备用")).performScrollTo().performClick()
        waitFor(hasText("备用 1"))
        compose.onNode(hasText("选择 key") and card).performScrollTo().performClick()
        compose.onNode(hasText("工作 key（Anthropic · …a1b2）") and inPopup).performClick()
        waitFor(hasContentDescription("备用 1 的上游模型") and hasText("claude-sonnet-4"))
        compose.onNode(hasText("deepseek-reasoner") and hasClickAction()).performScrollTo().performClick()
        compose.onNode(hasText("保存")).performScrollTo().performClick()

        waitFor(hasText("模型别名已保存，等 key 的任务会接着跑"))
        waitGone(hasText("未配置模型（main），运行会等待 key"))
        assertEquals(
            listOf(ModelRoute("main", "cred-home", "deepseek-reasoner", listOf(RouteFallback("cred-work", "claude-sonnet-4")))),
            runBlocking { mock.modelRoutes("inst-research") },
        )
    }

    @Test
    fun usageSwitchesGroups() {
        openKeys()
        compose.onNode(hasContentDescription("用量")).performClick()
        waitFor(hasText("总计"))
        compose.onNode(hasText("7 天")).assertIsSelected()
        compose.onNode(hasText("按天")).assertIsSelected()
        // 总计卡片（token 按第 5 节缩写）和按天柱状图
        compose.onNode(hasContentDescription("记账 token：33.6 万")).assertIsDisplayed()
        compose.onNode(hasContentDescription("失败的请求：3")).assertExists()
        compose.onNode(hasTestTag(USAGE_CHART_TEST_TAG)).assertExists()
        compose.onNode(hasContentDescription("按天柱状图：7 天，最多的一天是 10月22日，8.4 万 token")).assertExists()
        compose.onNode(hasTestTag(USAGE_LIST_TEST_TAG)).performScrollToNode(hasTestTag(USAGE_ROW_TEST_TAG + "2026-10-22"))
        compose.onNode(hasTestTag(USAGE_ROW_TEST_TAG + "2026-10-22")).assertIsDisplayed().assert(hasText("10月22日"))

        compose.onNode(hasText("按实例")).performClick()
        waitFor(hasTestTag(USAGE_ROW_TEST_TAG + "inst-coder"))
        compose.onNode(hasText("按实例")).assertIsSelected()
        compose.onNode(hasTestTag(USAGE_CHART_TEST_TAG)).assertDoesNotExist()
        compose.onNode(hasTestTag(USAGE_ROW_TEST_TAG + "inst-coder")).assertIsDisplayed().assert(hasText("小码"))
        compose.onNode(hasTestTag(USAGE_ROW_TEST_TAG + "inst-research")).assertIsDisplayed().assert(hasText("研究员"))

        compose.onNode(hasText("按 key")).performClick()
        waitFor(hasTestTag(USAGE_ROW_TEST_TAG + "cred-work"))
        compose.onNode(hasTestTag(USAGE_ROW_TEST_TAG + "cred-work")).assertIsDisplayed()
            .assert(hasText("工作 key")).assert(hasText("Anthropic · …a1b2"))

        compose.onNode(hasText("今天")).performClick()
        waitFor(hasContentDescription("记账 token：8.4 万"))
    }
}
