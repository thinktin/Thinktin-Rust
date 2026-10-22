package cn.thinktin.app

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.ui.drawer.DRAWER_TEST_TAG
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 冷启动深链（第 3 节除 instance/{id} 外的 6 种）：每种都落到对应页面，参数传对，返回键回首页。
 * 这里是还在骨架阶段的页面；`thinktin://instance/{id}`（13.3 已做实例设置页）见 CatalogUiTest
 * （instanceDeepLinkBackReturnsHome 测返回键回首页）。
 * 热启动（App 已在运行，走 onNewIntent）见 AppUiTest。
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class DeepLinkTest(
    private val uri: String,
    private val title: String,
    private val argument: String?,
) {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null

    @After
    fun tearDown() {
        scenario?.close()
    }

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    @Test
    fun coldStartOpensPage() {
        val context = ApplicationProvider.getApplicationContext<DemoTestApp>()
        val intent = Intent(context, MainActivity::class.java)
            .setAction(Intent.ACTION_VIEW)
            .setData(Uri.parse(uri))
        scenario = ActivityScenario.launch(intent)
        val page = hasText(title) and !hasAnyAncestor(hasTestTag(DRAWER_TEST_TAG))
        waitFor(hasText("即将推出"))
        compose.onNode(page).assertIsDisplayed()
        compose.onNode(hasText("即将推出")).assertIsDisplayed()
        if (argument != null) {
            compose.onNode(hasText("编号：$argument")).assertIsDisplayed()
        } else {
            compose.onAllNodes(hasText("编号：", substring = true)).assertCountEquals(0)
        }
        compose.onNode(hasContentDescription("返回")).performClick()
        waitFor(hasText("最近运行"))
    }

    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}")
        fun links(): List<Array<Any?>> = listOf(
            arrayOf("thinktin://run/run-done", "运行详情", "run-done"),
            arrayOf("thinktin://approval/approval-pending", "审批详情", "approval-pending"),
            arrayOf("thinktin://plan/plan-daily", "计划详情", "plan-daily"),
            // 可选参数：vault/request/{id} → vault?requestId=…，inbox/{id} → inbox?itemId=…
            arrayOf("thinktin://vault/request/vreq-pending", "密码保险箱", "vreq-pending"),
            arrayOf("thinktin://inbox", "收件箱", null),
            arrayOf("thinktin://inbox/inbox-3", "收件箱", "inbox-3"),
        )
    }
}
