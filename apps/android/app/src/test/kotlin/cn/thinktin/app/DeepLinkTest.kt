package cn.thinktin.app

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.SemanticsMatcher
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
 * 冷启动深链（第 3 节除 instance/{id}、approval/{id}、run/{id}、plan/{id} 外的）：落到对应页面，参数传对，
 * 返回键回首页。`thinktin://instance/{id}`（13.3 已做实例设置页）见 CatalogUiTest
 * （instanceDeepLinkBackReturnsHome 测返回键回首页），`thinktin://approval/{id}`（13.16）见 ApprovalUiTest，
 * `thinktin://run/{id}`（13.5 运行页）见 ChatUiTest，`thinktin://plan/{id}`（13.6 计划详情）见 PlansUiTest。
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
        waitFor(page)
        compose.onNode(page).assertIsDisplayed()
        // 参数传对了：页面上有那条记录的内容。
        if (argument != null) waitFor(hasText(argument))
        compose.onNode(hasContentDescription("返回")).performClick()
        waitFor(hasText("最近运行"))
    }

    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}")
        fun links(): List<Array<Any?>> = listOf(
            // 可选参数：vault/request/{id} → vault?requestId=…，直接是填写请求页（13.14）；参数对了能看到请求的用途。
            // 收件箱的 inbox/{id} 在 InboxUiTest 里测。
            arrayOf("thinktin://vault/request/vreq-pending", "填写请求", "上传调研报告"),
        )
    }
}
