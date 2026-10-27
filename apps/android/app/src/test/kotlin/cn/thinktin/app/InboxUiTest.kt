package cn.thinktin.app

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.push.PushMessage
import cn.thinktin.app.ui.inbox.INBOX_ITEM_PANEL_TEST_TAG
import cn.thinktin.app.ui.inbox.INBOX_LIST_TEST_TAG
import cn.thinktin.app.ui.inbox.INBOX_ROW_TEST_TAG
import cn.thinktin.data.model.InboxKind
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 13.8 的界面：收件箱（未读数、按天分组、全部已读、点一条去对应的页面、没有更具体页面的在面板里打开）、
 * 点开推送（Intent 带 `tt_*`）跳到对应的页面并把那条通知标已读。演示数据。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class InboxUiTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null
    private val app: DemoTestApp get() = ApplicationProvider.getApplicationContext()

    @After
    fun tearDown() {
        scenario?.close()
    }

    private fun launch(intent: Intent) {
        scenario = ActivityScenario.launch(intent)
    }

    private fun launch(uri: String) =
        launch(Intent(app, MainActivity::class.java).setAction(Intent.ACTION_VIEW).setData(Uri.parse(uri)))

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    @Test
    fun listsUnreadAndMarksAllRead() {
        launch("thinktin://inbox")
        waitFor(hasTestTag(INBOX_LIST_TEST_TAG))
        waitFor(hasText("3 条未读"))
        compose.onNode(hasText("今天")).assertIsDisplayed()
        compose.onNode(hasTestTag(INBOX_ROW_TEST_TAG + "inbox-5")).assertIsDisplayed()
        compose.onNode(hasContentDescription("全部已读")).performClick()
        waitFor(hasText("都读过了"))
    }

    @Test
    fun openingARowGoesToItsPage() {
        launch("thinktin://inbox")
        waitFor(hasTestTag(INBOX_ROW_TEST_TAG + "inbox-5"))
        compose.onNode(hasTestTag(INBOX_ROW_TEST_TAG + "inbox-5")).performClick()
        waitFor(hasText("审批详情"))
        compose.onNode(hasContentDescription("返回")).performClick()
        waitFor(hasText("2 条未读"))
    }

    @Test
    fun pushedItemOpensInAPanel() {
        launch("thinktin://inbox/inbox-4")
        val inPanel = hasAnyAncestor(hasTestTag(INBOX_ITEM_PANEL_TEST_TAG))
        waitFor(hasText("打开“下载”文件夹里的 report.pdf。") and inPanel)
        compose.onNode(hasText("电脑审批") and inPanel).assertExists()
        compose.onNode(hasText("删除") and inPanel).performSemanticsAction(SemanticsActions.OnClick)
        waitFor(hasText("已删除"))
    }

    @Test
    fun openingAPushGoesToItsPageAndMarksItRead() {
        val push = PushMessage(
            kind = InboxKind.Approval, approvalId = APPROVAL_PENDING, inboxId = "inbox-5", instanceId = "inst-coder",
        )
        launch(Intent(app, MainActivity::class.java).putExtras(push.toExtras()))
        waitFor(hasText("审批详情"))
        val service = app.container.demoService()
        compose.waitUntil(timeoutMillis = 10_000) { runBlocking { service.inboxItem("inbox-5").read } }
        assertTrue(app.container.push.pendingReads.value.isEmpty())
    }
}
