package cn.thinktin.app

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isPopup
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.ui.chat.CHAT_ARTIFACT_TEST_TAG
import cn.thinktin.app.ui.chat.CHAT_LIST_TEST_TAG
import cn.thinktin.app.ui.chat.CHAT_RUN_HEADER_TEST_TAG
import cn.thinktin.app.ui.chat.CHAT_SCREEN_TEST_TAG
import cn.thinktin.app.ui.chat.CHAT_USER_PROMPT_TEST_TAG
import cn.thinktin.app.ui.chat.CHAT_VAULT_REQUEST_TEST_TAG
import cn.thinktin.app.ui.chat.SECRET_SHEET_TEST_TAG
import cn.thinktin.app.ui.chat.VAULT_SHEET_TEST_TAG
import cn.thinktin.app.ui.run.RUN_DETAIL_TEST_TAG
import cn.thinktin.app.ui.run.RUN_NODE_TEST_TAG
import cn.thinktin.data.model.VaultRequestStatus
import cn.thinktin.design.component.APPROVAL_CARD_TEST_TAG
import cn.thinktin.design.component.MARKDOWN_CODE_TEST_TAG
import cn.thinktin.design.component.TOOL_CALL_CARD_TEST_TAG
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
 * 13.5 的界面：首页“最近运行”进对话页并定位、对话页渲染 Mock 里的各类事件（用户气泡、AI 标识、Markdown 代码块、
 * 工具调用、审批、产出物、子运行、系统行）、发送后出现用户气泡、密码拦截弹保险箱表单、agent 的填写请求、运行页的运行树。
 * 事件流用 [ChatService]（Mock 自己的会一直吐演示事件）。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class ChatUiTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null
    private val app: DemoTestApp get() = ApplicationProvider.getApplicationContext()
    private val service = ChatService()
    private val list = hasTestTag(CHAT_LIST_TEST_TAG)

    @After
    fun tearDown() {
        scenario?.close()
    }

    private fun launch(uri: String? = null) {
        app.container = testContainer(app, { service }, approvalGate = FakeApprovalGate())
        val intent = Intent(app, MainActivity::class.java)
        if (uri != null) intent.setAction(Intent.ACTION_VIEW).setData(Uri.parse(uri))
        scenario = ActivityScenario.launch(intent)
    }

    private fun hasClickLabel(label: String) = SemanticsMatcher("onClickLabel = $label") {
        it.config.getOrNull(SemanticsActions.OnClick)?.label == label
    }

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun scrollTo(matcher: SemanticsMatcher) {
        compose.onNode(list).performScrollToNode(matcher)
        compose.waitForIdle()
    }

    /** 首页最近运行 → 对话页（定位到那个运行）。 */
    private fun openCoderChatAt(prompt: String) {
        launch()
        waitFor(hasText(prompt))
        compose.onNode(hasText(prompt)).performClick()
        waitFor(hasTestTag(CHAT_SCREEN_TEST_TAG + "inst-coder"))
        waitFor(list)
    }

    @Test
    fun recentRunOpensChatAtThatRun() {
        openCoderChatAt("把 README 翻译成英文")
        // 定位到那个运行：区块头和用户气泡在屏幕上。
        waitFor(hasTestTag(CHAT_RUN_HEADER_TEST_TAG + "run-done"))
        compose.onNode(hasText("把 README 翻译成英文") and hasAnyAncestor(hasTestTag(CHAT_USER_PROMPT_TEST_TAG)), useUnmergedTree = true)
            .assertExists()
        // 顶栏是实例名（点进实例设置）。
        compose.onNode(hasText("小码") and hasClickAction()).assertExists()
        compose.onNode(hasContentDescription("返回")).performClick()
        waitFor(hasText("最近运行"))
    }

    @Test
    fun rendersEveryKindOfEvent() {
        openCoderChatAt("把 README 翻译成英文")
        // 成功的运行：思考、计划、工具调用、已批准的审批、Markdown（标题、代码块）、产出物。
        scrollTo(hasText("思考过程"))
        scrollTo(hasText("计划清单"))
        scrollTo(hasText("读取 README.md"))
        compose.onNode(hasTestTag(TOOL_CALL_CARD_TEST_TAG) and hasAnyAncestor(list)).assertExists()
        scrollTo(hasText("你已批准", substring = true))
        scrollTo(hasText("改动"))
        scrollTo(hasTestTag(MARKDOWN_CODE_TEST_TAG))
        compose.onNode(hasContentDescription("复制代码")).assertExists()
        scrollTo(hasTestTag(CHAT_ARTIFACT_TEST_TAG + "art-readme"))
        compose.onNode(hasText("README.en.md") and hasAnyAncestor(hasTestTag(CHAT_ARTIFACT_TEST_TAG + "art-readme")), useUnmergedTree = true)
            .assertExists()
        compose.onNode(hasText("已翻译并提交 README.en.md")).assertExists()
        // 失败的计划运行：系统行（错误色）、日志截断、失败原因（不标 AI）。
        scrollTo(hasText("agent 出错：fetch https://registry.example.com 超时"))
        scrollTo(hasText("日志超出上限，后续输出未记录"))
        scrollTo(hasText("失败原因：上游仓库连接超时（重试 3 次后放弃）"))
        // 流水线：子运行入口。
        scrollTo(hasText("流水线步骤：research"))
        // 等待审批：第 1 次尝试的卡片作废，第 2 次的能点。
        scrollTo(hasText("已作废：运行已重试，这次请求不再有效"))
        scrollTo(hasText("一直允许"))
        // 正在运行：保险箱使用、委派、agent 的回复带 AI 标识。
        scrollTo(hasText("使用了保险箱：github"))
        scrollTo(hasText("委派给 研究员"))
        scrollTo(hasText("我先看看登录页现有的结构，"))
        assertTrue(compose.onAllNodes(hasText("【AI 生成】"), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty())
        // 等审批的横幅、运行中的停止按钮。
        compose.onNode(hasText("等待你批准")).assertIsDisplayed()
        compose.onNode(hasContentDescription("停止")).assertIsDisplayed()
    }

    @Test
    fun sendingShowsUserBubble() {
        openCoderChatAt("把 README 翻译成英文")
        val field = hasContentDescription("让 小码 做点什么") and hasSetTextAction()
        compose.onNode(field).performTextInput("再加一个边界情况")
        compose.onNode(hasContentDescription("发送")).performClick()
        waitFor(hasText("再加一个边界情况") and hasAnyAncestor(hasTestTag(CHAT_USER_PROMPT_TEST_TAG)))
        assertEquals(listOf("再加一个边界情况" to false), service.sent)
    }

    @Test
    fun secretIsInterceptedIntoVaultSheet() {
        openCoderChatAt("把 README 翻译成英文")
        val field = hasContentDescription("让 小码 做点什么") and hasSetTextAction()
        compose.onNode(field).performTextInput("password: hunter2hunter2")
        compose.onNode(hasContentDescription("发送")).performClick()
        waitFor(hasTestTag(SECRET_SHEET_TEST_TAG))
        val inSheet = hasAnyAncestor(hasTestTag(SECRET_SHEET_TEST_TAG))
        compose.onNode(hasText("对话里不收明文密码") and inSheet).assertExists()
        compose.onNode(hasContentDescription("密码") and hasSetTextAction() and inSheet).assertExists()
        // 盖在页面上的层：Robolectric 的触摸点不到，用无障碍点击。
        compose.onNode(hasText("存进保险箱") and inSheet).performSemanticsAction(SemanticsActions.OnClick)
        waitFor(field and hasText("password: [vault:password]"))
        assertTrue(service.sent.isEmpty())
        assertTrue(runBlocking { service.mock.vaultItems() }.any { it.name == "password" })
    }

    @Test
    fun vaultRequestCanBeFilledFromChat() {
        launch()
        waitFor(hasContentDescription("让 小码 做点什么"))
        // 换到研究员，再从最近运行进对话页。
        compose.onNode(hasClickLabel("切换实例")).performClick()
        compose.onNode(hasText("研究员") and hasAnyAncestor(isPopup())).performClick()
        waitFor(hasText("整理上周的阅读清单"))
        compose.onNode(hasText("整理上周的阅读清单")).performClick()
        waitFor(hasTestTag(CHAT_SCREEN_TEST_TAG + "inst-research"))
        val card = hasTestTag(CHAT_VAULT_REQUEST_TEST_TAG + "vreq-pending")
        waitFor(list)
        scrollTo(card)
        compose.onNode(hasText("上传调研报告")).assertExists()
        compose.onNode(hasText("填写") and hasAnyAncestor(card)).performClick()
        waitFor(hasTestTag(VAULT_SHEET_TEST_TAG))
        val inSheet = hasAnyAncestor(hasTestTag(VAULT_SHEET_TEST_TAG))
        compose.onNode(hasContentDescription("密码") and hasSetTextAction() and inSheet).performTextInput("s3cret")
        compose.onNode(hasText("保存并交给 agent") and inSheet).performSemanticsAction(SemanticsActions.OnClick)
        waitFor(hasText("已填写") and hasAnyAncestor(card))
        assertEquals(
            VaultRequestStatus.Fulfilled,
            runBlocking { service.mock.vaultRequests(all = true) }.single { it.id == "vreq-pending" }.status,
        )
    }

    @Test
    fun runPageShowsTreeAndSelectsChild() {
        launch("thinktin://run/run-pipeline-write")
        waitFor(hasTestTag(RUN_DETAIL_TEST_TAG))
        compose.onNode(hasText("运行详情")).assertIsDisplayed()
        compose.onNode(hasText("根据调研结果写周报")).assertExists()
        waitFor(hasTestTag(RUN_NODE_TEST_TAG + "run-pipeline"))
        compose.onNode(hasTestTag(RUN_NODE_TEST_TAG + "run-pipeline-research")).assertExists()
        compose.onNode(hasTestTag(RUN_NODE_TEST_TAG + "run-pipeline-write")).assertExists()
        compose.onAllNodes(hasText("当前", substring = true)).onFirst().assertExists()
        // 点根节点：详情换成根运行。
        compose.onNode(hasTestTag(RUN_NODE_TEST_TAG + "run-pipeline")).performClick()
        waitFor(hasText("调研竞品并写周报"))
        compose.onNode(hasContentDescription("返回")).performClick()
        waitFor(hasText("最近运行"))
    }

    @Test
    fun runTreeMenuOpensRunPage() {
        openCoderChatAt("给登录页加单元测试")
        compose.onNode(hasContentDescription("更多")).performClick()
        compose.onNode(hasText("运行树") and hasAnyAncestor(isPopup())).performClick()
        waitFor(hasTestTag(RUN_DETAIL_TEST_TAG))
        // 正在运行的运行（它委派了一个子运行）：树里有两个节点，可以停止。
        waitFor(hasTestTag(RUN_NODE_TEST_TAG + "run-delegate"))
        compose.onNode(hasTestTag(RUN_NODE_TEST_TAG + "run-live")).assertExists()
        compose.onNode(hasContentDescription("停止 小码")).performClick()
        waitFor(hasText("已停止"))
        assertEquals(listOf("run-live" to false), service.cancelled)
    }
}
