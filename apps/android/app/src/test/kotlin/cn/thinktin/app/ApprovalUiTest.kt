package cn.thinktin.app

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.navigation.targetRoute
import cn.thinktin.app.ui.approval.APPROVAL_GROUP_TEST_TAG
import cn.thinktin.app.ui.approval.GateAvailability
import cn.thinktin.app.ui.drawer.DRAWER_TEST_TAG
import cn.thinktin.data.model.OptionKind
import cn.thinktin.design.component.APPROVAL_CARD_STATUS_TEST_TAG
import cn.thinktin.design.component.APPROVAL_CARD_TEST_TAG
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 13.16 的界面：抽屉进审批中心（按实例分组、角标）、批准经假的身份确认、拒绝直接发、没有锁屏时提示、
 * 深链 thinktin://approval/{id} 打开详情（待处理 / 已过期），返回回首页。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class ApprovalUiTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null
    private val app: DemoTestApp get() = ApplicationProvider.getApplicationContext()
    private val service = ApprovalService()
    private val gate = FakeApprovalGate()
    private val inDrawer = hasAnyAncestor(hasTestTag(DRAWER_TEST_TAG))
    private val inDialog = hasAnyAncestor(isDialog())
    private val inCard = hasAnyAncestor(hasTestTag(APPROVAL_CARD_TEST_TAG))

    @After
    fun tearDown() {
        scenario?.close()
    }

    private fun launch(uri: String? = null) {
        app.container = testContainer(app, { service }, approvalGate = gate)
        val intent = Intent(app, MainActivity::class.java)
        if (uri != null) intent.setAction(Intent.ACTION_VIEW).setData(Uri.parse(uri))
        scenario = ActivityScenario.launch(intent)
    }

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    /** 首页 → 抽屉 → 审批（Robolectric 点不到抽屉里的条目，用无障碍点击）。 */
    private fun openCenterFromDrawer() {
        launch()
        waitFor(hasContentDescription("打开菜单"))
        compose.onNode(hasContentDescription("打开菜单")).performClick()
        compose.waitForIdle()
        waitFor(hasContentDescription("条待处理的审批", substring = true) and inDrawer)
        compose.onNode(hasText("审批") and inDrawer).performSemanticsAction(SemanticsActions.OnClick)
        waitFor(hasTestTag(APPROVAL_GROUP_TEST_TAG + "inst-coder"))
    }

    @Test
    fun centerGroupsByInstanceAndApprovesThroughGate() {
        service.addResearchApproval()
        openCenterFromDrawer()
        compose.onNode(hasText("研究员 · 1 条待处理")).assertIsDisplayed()
        compose.onNode(hasText("小码 · 1 条待处理")).assertIsDisplayed()
        compose.onNode(hasText("抓取行业新闻网站") and inCard).assertIsDisplayed()
        compose.onNode(hasText("删除 build/ 下 30 天前的文件") and inCard).performScrollTo().assertIsDisplayed()
        compose.onAllNodes(hasText("【AI 生成】") and inCard, useUnmergedTree = true).assertCountEquals(2)
        compose.onNode(hasText("find build -mtime +30 -delete")).assertIsDisplayed()
        compose.onNode(hasText("23 小时 41 分钟后过期")).assertIsDisplayed()

        // 小码那张：一直允许 → 确认框 → 验证并批准（假的身份确认）
        compose.onNode(hasText("一直允许") and hasClickAction()).performScrollTo().performClick()
        waitFor(hasText("批准这个操作？"))
        compose.onNode(hasText("“一直允许”之后，这个 agent 的同类操作不再询问。") and inDialog).assertIsDisplayed()
        assertTrue("确认之前不验证", gate.requests.isEmpty())
        compose.onNode(hasText("验证并批准") and inDialog).performClick()
        waitFor(hasText("你已批准（一直允许）", substring = true))
        assertEquals(1, gate.requests.size)
        assertEquals(OptionKind.AllowAlways, gate.requests.single().optionKind)
        assertEquals(listOf(APPROVAL_PENDING to "always"), service.decisions)
        // 已经没有待处理的：组标题只剩名字
        compose.onNode(hasText("小码") and hasTestTag(APPROVAL_GROUP_TEST_TAG + "inst-coder")).assertExists()
    }

    @Test
    fun rejectIsSentDirectly() {
        openCenterFromDrawer()
        compose.onNode(hasText("拒绝") and hasClickAction()).performClick()
        waitFor(hasTestTag(APPROVAL_CARD_STATUS_TEST_TAG))
        compose.onNode(hasText("你已拒绝", substring = true)).assertIsDisplayed()
        compose.onAllNodes(hasText("批准这个操作？")).assertCountEquals(0)
        assertTrue(gate.requests.isEmpty())
        assertEquals(listOf(APPROVAL_PENDING to "reject"), service.decisions)
    }

    @Test
    fun noScreenLockShowsSetupPrompt() {
        gate.availability = GateAvailability.NoCredential
        openCenterFromDrawer()
        compose.onNode(hasText("批准") and hasClickAction()).performClick()
        waitFor(hasText("先设置锁屏密码"))
        compose.onNode(hasText("去设置") and inDialog).assertIsDisplayed()
        compose.onNode(hasText("取消") and inDialog).performClick()
        compose.waitForIdle()
        assertTrue(service.decisions.isEmpty())
        assertTrue(gate.requests.isEmpty())
    }

    @Test
    fun deepLinkOpensPendingDetail() {
        launch("thinktin://approval/$APPROVAL_PENDING")
        waitFor(hasText("审批详情"))
        waitFor(hasText("删除 build/ 下 30 天前的文件") and inCard)
        compose.onNode(hasText("小码", substring = true) and inCard).assertExists()
        // 详情里原始请求默认展开
        compose.onNode(hasText("收起原始请求")).assertExists()
        compose.onNode(hasText("第 2 次")).performScrollTo().assertIsDisplayed()
        compose.onNode(hasText("等待审批")).assertExists()

        compose.onNode(hasText("拒绝") and hasClickAction()).performScrollTo().performClick()
        waitFor(hasText("你已拒绝", substring = true))
        assertEquals(listOf(APPROVAL_PENDING to "reject"), service.decisions)

        compose.onNode(hasContentDescription("返回")).performClick()
        waitFor(hasText("最近运行"))
    }

    @Test
    fun deepLinkToExpiredApprovalShowsResult() {
        launch("thinktin://approval/approval-expired")
        waitFor(hasText("已过期：超时没有处理", substring = true))
        compose.onNode(hasText("下载阅读清单里的 PDF") and inCard).assertIsDisplayed()
        compose.onAllNodes(hasText("批准") and hasClickAction()).assertCountEquals(0)
        compose.onAllNodes(hasText("没能加载审批")).assertCountEquals(0)
    }

    @Test
    fun deepLinkToMissingApprovalSaysNotFound() {
        launch("thinktin://approval/approval-nope")
        waitFor(hasText("找不到这条审批"))
    }

    @Test
    fun inboxItemsTargetApprovalDetail() {
        val items = kotlinx.coroutines.runBlocking { service.mock.syncInbox(limit = 50).items }.associateBy { it.id }
        // 审批条目 → 审批详情；其他种类按各自的页面
        assertEquals("approval/$APPROVAL_PENDING", items.getValue("inbox-5").targetRoute())
        assertEquals("approvals", items.getValue("inbox-5").copy(approvalId = null).targetRoute())
        assertEquals("vault?requestId=vreq-pending", items.getValue("inbox-7").targetRoute())
        assertEquals("run/run-done", items.getValue("inbox-3").targetRoute())
        assertEquals("plan/plan-weekly", items.getValue("inbox-1").targetRoute())
    }
}
