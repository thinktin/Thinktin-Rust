package cn.thinktin.app

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isPopup
import androidx.compose.ui.test.isSelectable
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.ui.chat.CHAT_RUN_HEADER_TEST_TAG
import cn.thinktin.app.ui.chat.CHAT_SCREEN_TEST_TAG
import cn.thinktin.app.ui.chat.CHAT_USER_PROMPT_TEST_TAG
import cn.thinktin.app.ui.drawer.DRAWER_TEST_TAG
import cn.thinktin.app.ui.run.RUN_DETAIL_TEST_TAG
import cn.thinktin.design.theme.Appearance
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 主界面的 Robolectric Compose 测试（演示模式、固定时间、中文）。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class AppUiTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null

    @After
    fun tearDown() {
        scenario?.close()
    }

    private fun launch(uri: String? = null) {
        val context = ApplicationProvider.getApplicationContext<DemoTestApp>()
        val intent = Intent(context, MainActivity::class.java)
        if (uri != null) {
            intent.action = Intent.ACTION_VIEW
            intent.data = Uri.parse(uri)
        }
        scenario = ActivityScenario.launch(intent)
    }

    private val inDrawer = hasAnyAncestor(hasTestTag(DRAWER_TEST_TAG))

    private fun hasClickLabel(label: String) = SemanticsMatcher("onClickLabel = $label") {
        it.config.getOrNull(SemanticsActions.OnClick)?.label == label
    }

    private fun ComposeTestRule.waitFor(matcher: SemanticsMatcher) {
        waitUntil(timeoutMillis = 10_000) { onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    @Test
    fun homeShowsGreetingAndRecentRuns() {
        launch()
        compose.waitFor(hasText("早上好", substring = true))
        compose.onNode(hasText("早上好", substring = true) and !inDrawer).assertIsDisplayed()
        compose.onNode(hasText("最近运行")).assertIsDisplayed()
        compose.waitFor(hasText("把 README 翻译成英文"))
        compose.onNode(hasText("把 README 翻译成英文")).assertIsDisplayed()
        compose.onNode(hasText("给登录页加单元测试")).assertIsDisplayed()
        // 底部输入框带着当前实例的名字（是输入框自己的无障碍名字）
        compose.onNode(hasContentDescription("让 小码 做点什么") and hasSetTextAction()).assertIsDisplayed()
        // agent 写的摘要带“AI 生成”标识（第 8.4 节）
        compose.onAllNodes(hasText("【AI 生成】")).onFirst().assertIsDisplayed()
        compose.onNode(hasText("已翻译并提交 README.en.md")).assertIsDisplayed()
    }

    @Test
    fun clickRecentRunOpensChatAtRun() {
        launch()
        compose.waitFor(hasText("把 README 翻译成英文"))
        compose.onNode(hasText("把 README 翻译成英文")).performClick()
        // 13.5：进对话页并定位到那个运行
        compose.waitFor(hasTestTag(CHAT_SCREEN_TEST_TAG + "inst-coder"))
        compose.waitFor(hasTestTag(CHAT_RUN_HEADER_TEST_TAG + "run-done"))
        // 返回回到首页
        compose.onNode(hasContentDescription("返回")).performClick()
        compose.waitFor(hasText("最近运行"))
    }

    @Test
    fun sendFromHomeOpensChat() {
        launch()
        val field = hasContentDescription("让 小码 做点什么") and hasSetTextAction()
        compose.waitFor(field)
        compose.onNode(field).performTextInput("帮我看看 CI")
        compose.onNode(hasContentDescription("发送")).performClick()
        compose.waitFor(hasTestTag(CHAT_SCREEN_TEST_TAG + "inst-coder"))
        // 发出去的那句在对话页里是用户气泡
        compose.waitFor(hasText("帮我看看 CI") and hasAnyAncestor(hasTestTag(CHAT_USER_PROMPT_TEST_TAG)))
    }

    @Test
    fun switchingInstanceShowsItsRuns() {
        launch()
        compose.waitFor(hasClickLabel("切换实例"))
        compose.onNode(hasClickLabel("切换实例")).performClick()
        compose.onNode(hasText("研究员") and hasAnyAncestor(isPopup())).performClick()
        compose.waitFor(hasContentDescription("让 研究员 做点什么"))
        compose.waitFor(hasText("查一下登录页用到的测试框架的最新版本"))
    }

    @Test
    fun settingsSwitchesAppearance() {
        launch()
        openSettingsFromDrawer()
        val dark = hasText("深色")
        compose.waitForIdle()
        compose.onNode(dark).performSemanticsAction(SemanticsActions.OnClick)
        // 等界面上“深色”变成选中（同步主线程；DataStore 的 transform 要在主线程上跑），再确认存进了设置
        compose.waitFor(dark and isSelectable() and isSelected())
        compose.onNode(hasText("跟随系统")).assertIsNotSelected()
        assertEquals(Appearance.Dark, runBlocking { app().container.settings.first().appearance })
        // debug 包里有演示模式开关，演示模式下没有“退出登录”
        compose.onNode(hasText("演示模式")).assertIsDisplayed()
        compose.onAllNodes(hasText("退出登录")).assertCountEquals(0)
    }

    @Test
    fun deepLinkWhileRunningNavigates() {
        launch()
        compose.waitFor(hasText("最近运行"))
        deliver("thinktin://run/run-done")
        compose.waitFor(hasTestTag(RUN_DETAIL_TEST_TAG))
        compose.onNode(hasText("运行详情")).assertIsDisplayed()
        // 返回栈是“首页 → 目标页”，和冷启动一样
        compose.onNode(hasContentDescription("返回")).performClick()
        compose.waitFor(hasText("最近运行"))
        // 再来一条：从首页跳到保险箱的填写请求
        deliver("thinktin://vault/request/vreq-pending")
        compose.waitFor(hasText("编号：vreq-pending"))
        compose.onNode(hasText("密码保险箱")).assertIsDisplayed()
    }

    @Test
    fun deepLinkWhileRunningClosesOpenDrawer() {
        launch()
        compose.waitFor(hasContentDescription("打开菜单"))
        compose.onNode(hasContentDescription("打开菜单")).performClick()
        compose.waitForIdle()
        deliver("thinktin://inbox/inbox-3")
        // 收件箱打开，那一条在面板里（13.8）。
        compose.waitFor(hasText("已翻译并提交 README.en.md。") and !inDrawer)
        compose.onNode(hasText("收件箱") and !inDrawer).assertIsDisplayed()
    }

    @Test
    fun nonDeepLinkIntentIsIgnored() {
        launch()
        compose.waitFor(hasText("最近运行"))
        deliver("https://thinktin.cn/run/run-done")
        compose.waitForIdle()
        compose.onNode(hasText("最近运行")).assertIsDisplayed()
        compose.onAllNodes(hasTestTag(RUN_DETAIL_TEST_TAG)).assertCountEquals(0)
    }

    private fun app(): DemoTestApp = ApplicationProvider.getApplicationContext()

    /** App 已在运行时收到深链（singleTask 走 onNewIntent）。 */
    private fun deliver(uri: String) {
        scenario!!.onActivity { it.onNewIntent(Intent(Intent.ACTION_VIEW, Uri.parse(uri))) }
    }

    private fun openSettingsFromDrawer() {
        compose.waitFor(hasContentDescription("打开菜单"))
        compose.onNode(hasContentDescription("打开菜单")).performClick()
        compose.waitForIdle()
        // Robolectric 的触摸注入点不到 ModalNavigationDrawer 里的条目（真机正常），用无障碍点击动作。
        compose.onNode(hasContentDescription("设置") and inDrawer).performSemanticsAction(SemanticsActions.OnClick)
        compose.waitFor(hasText("外观"))
    }

    @Test
    fun drawerListsBothInstances() {
        launch()
        compose.waitFor(hasContentDescription("打开菜单"))
        compose.onNode(hasContentDescription("打开菜单")).performClick()
        compose.waitForIdle()
        compose.onNode(hasText("我的 agent") and inDrawer).assertIsDisplayed()
        compose.onNode(hasText("小码") and inDrawer).assertIsDisplayed()
        compose.onNode(hasText("研究员") and inDrawer).assertIsDisplayed()
        // 第二行是 agent 的显示名（第 3 节：名字、agent、状态点）；目录拉到之前先显示 id
        compose.waitFor(hasText("代码助手") and inDrawer)
        compose.onNode(hasText("代码助手") and inDrawer).assertIsDisplayed()
        compose.onNode(hasText("调研助手") and inDrawer).assertIsDisplayed()
        compose.onNode(hasContentDescription("运行中") and inDrawer).assertIsDisplayed()
        compose.onNode(hasContentDescription("小码 的设置") and inDrawer).assertIsDisplayed()
        compose.onNode(hasText("收件箱") and inDrawer).assertIsDisplayed()
    }

    @Test
    fun drawerOpensSettings() {
        launch()
        openSettingsFromDrawer()
        compose.onNode(hasText("设置") and !inDrawer).assertIsDisplayed()
        compose.onNode(hasText("外观")).assertIsDisplayed()
    }

}
