package cn.thinktin.app

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.semantics.SemanticsActions
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.ui.drawer.DRAWER_TEST_TAG
import org.junit.After
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
        // 底部输入框带着当前实例的名字
        compose.onNode(hasText("让 小码 做点什么")).assertIsDisplayed()
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
        compose.onNode(hasText("收件箱") and inDrawer).assertIsDisplayed()
    }

    @Test
    fun drawerOpensSettings() {
        launch()
        compose.waitFor(hasContentDescription("打开菜单"))
        compose.onNode(hasContentDescription("打开菜单")).performClick()
        compose.waitForIdle()
        // Robolectric 的触摸注入点不到 ModalNavigationDrawer 里的条目（真机正常），用无障碍点击动作。
        compose.onNode(hasContentDescription("设置") and inDrawer).performSemanticsAction(SemanticsActions.OnClick)
        compose.waitFor(hasText("外观"))
        compose.onNode(hasText("设置") and !inDrawer).assertIsDisplayed()
        compose.onNode(hasText("外观")).assertIsDisplayed()
    }

    @Test
    fun deepLinkOpensInbox() {
        launch("thinktin://inbox")
        compose.waitFor(hasText("即将推出"))
        compose.onNode(hasText("收件箱") and !inDrawer).assertIsDisplayed()
        compose.onNode(hasText("即将推出")).assertIsDisplayed()
        compose.onNode(hasContentDescription("返回")).assertIsDisplayed()
    }

    @Test
    fun deepLinkWithIdOpensRun() {
        launch("thinktin://run/run-done")
        compose.waitFor(hasText("运行详情"))
        compose.onNode(hasText("编号：run-done")).assertIsDisplayed()
    }
}
