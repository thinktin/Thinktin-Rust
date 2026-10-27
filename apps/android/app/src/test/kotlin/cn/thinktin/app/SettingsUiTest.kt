package cn.thinktin.app

import android.content.Intent
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.ui.drawer.DRAWER_TEST_TAG
import cn.thinktin.app.ui.settings.licenses.LICENSES_LIST_TEST_TAG
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** 13.13 的界面：设置页的语言、通知、关于；开源许可页（测试包里没有客户端核心的清单：说一声，App 自己的库照常列）。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class SettingsUiTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null
    private val inDrawer = hasAnyAncestor(hasTestTag(DRAWER_TEST_TAG))

    @After
    fun tearDown() {
        scenario?.close()
    }

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun openSettings() {
        val app = ApplicationProvider.getApplicationContext<DemoTestApp>()
        scenario = ActivityScenario.launch(Intent(app, MainActivity::class.java))
        waitFor(hasContentDescription("打开菜单"))
        compose.onNode(hasContentDescription("打开菜单")).performClick()
        compose.waitForIdle()
        compose.onNode(hasContentDescription("设置") and inDrawer).performSemanticsAction(SemanticsActions.OnClick)
        waitFor(hasText("外观"))
    }

    @Test
    fun settingsHasLanguageNotificationsAndAbout() {
        openSettings()
        compose.onNode(hasText("语言")).assertIsDisplayed()
        compose.onNode(hasText("跟随系统语言")).assertExists()
        compose.onNode(hasText("English")).assertExists()
        compose.onNode(hasText("未允许：点这里去系统设置打开")).performScrollTo().assertIsDisplayed()
        compose.onNode(hasText("隐私政策")).performScrollTo().assertIsDisplayed()
        compose.onNode(hasText("用户协议")).performScrollTo().assertIsDisplayed()
    }

    @Test
    fun licensesPageListsAppLibrariesWithoutTheCoreInventory() {
        openSettings()
        compose.onNode(hasText("开源许可")).performScrollTo().performClick()
        waitFor(hasTestTag(LICENSES_LIST_TEST_TAG))
        waitFor(hasText("这个安装包没有带客户端核心的许可证清单（开发包）。"))
        compose.onNode(hasText("JNA")).assertIsDisplayed()
        compose.onNode(hasContentDescription("返回")).performClick()
        waitFor(hasText("外观"))
    }
}
