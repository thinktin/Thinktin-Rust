package cn.thinktin.app

import android.content.Intent
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.navigation.targetRoute
import cn.thinktin.app.ui.drawer.DRAWER_TEST_TAG
import cn.thinktin.app.ui.imchannels.IM_CHANNEL_ROW_TEST_TAG
import cn.thinktin.app.ui.imchannels.ImChannelEditorViewModel
import cn.thinktin.app.ui.imchannels.ImChannelEvent
import cn.thinktin.app.ui.imchannels.ImChannelsViewModel
import cn.thinktin.app.ui.imchannels.imLastErrorRes
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.ImChannelRules
import cn.thinktin.data.model.ImEvents
import cn.thinktin.data.model.ImVendors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** 13.15：IM 渠道的列表 / 绑定 / 修改的视图模型，失败原因的说法，以及从设置进 IM 渠道、绑定一个群的流程。 */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class ImChannelsTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private val dispatcher = StandardTestDispatcher()
    private var scenario: ActivityScenario<MainActivity>? = null
    private val inDrawer = hasAnyAncestor(hasTestTag(DRAWER_TEST_TAG))
    private val wecom = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abcd1234efgh"

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        scenario?.close()
        Dispatchers.resetMain()
    }

    private fun mock() = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() })

    @Test
    fun listTogglesTestsAndDeletes() = runTest(dispatcher) {
        val s = mock()
        val vm = ImChannelsViewModel(s)
        advanceUntilIdle()
        assertEquals(listOf("im-feishu", "im-wecom"), vm.uiState.value.channels.map { it.id })
        assertTrue(vm.uiState.value.canAdd)
        val wecomChannel = vm.uiState.value.channels.last()
        // 关着的：先提示打开，不发。
        vm.sendTest(wecomChannel)
        assertEquals(R.string.im_turn_on_first, (vm.events.first() as ImChannelEvent.Notice).text.resId)
        val feishu = vm.uiState.value.channels.first()
        vm.sendTest(feishu)
        advanceUntilIdle()
        assertEquals(R.string.im_test_queued, (vm.events.first() as ImChannelEvent.Notice).text.resId)
        repeat(ImChannelRules.TESTS_PER_HOUR - 1) {
            vm.sendTest(feishu)
            advanceUntilIdle()
            vm.events.first()
        }
        vm.sendTest(feishu)
        advanceUntilIdle()
        assertEquals(R.string.im_test_rate_limited, (vm.events.first() as ImChannelEvent.Notice).text.resId)

        vm.setEnabled(feishu, false)
        advanceUntilIdle()
        assertFalse(vm.uiState.value.channels.first().enabled)
        // 别处删了：照样拿掉，不报错。
        s.deleteImChannel("im-wecom")
        vm.delete(wecomChannel)
        advanceUntilIdle()
        assertEquals(listOf("im-feishu"), vm.uiState.value.channels.map { it.id })
    }

    @Test
    fun editorRecognisesTheVendorAndShowsProblemsAfterSave() = runTest(dispatcher) {
        val s = mock()
        val vm = ImChannelEditorViewModel(s, null)
        advanceUntilIdle()
        vm.onWebhookUrl("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=")
        assertEquals(ImVendors.WECOM, vm.uiState.value.vendor)
        assertFalse(vm.uiState.value.supportsSecret)
        assertFalse(vm.uiState.value.attempted)
        vm.save()
        assertTrue(vm.uiState.value.attempted)
        assertEquals(ImChannelRules.Problem.BadToken, vm.uiState.value.webhookProblem)
        vm.onWebhookUrl(wecom)
        vm.toggle(ImEvents.APPROVAL)
        vm.toggle(ImEvents.RUN_FINISHED)
        vm.toggle(ImEvents.RUN_FAILED)
        assertEquals(ImChannelRules.Problem.NoEvents, vm.uiState.value.eventsProblem)
        vm.toggle(ImEvents.APPROVAL)
        vm.toggle(ImEvents.RUN_FINISHED)
        assertEquals(listOf(ImEvents.RUN_FINISHED, ImEvents.APPROVAL), vm.uiState.value.events)
        vm.onLabel("  运维群 ")
        vm.save()
        advanceUntilIdle()
        val saved = (vm.events.first() as ImChannelEvent.Saved).channel
        assertEquals(ImVendors.WECOM, saved.vendor)
        assertEquals("运维群", saved.label)
        assertEquals("…efgh", saved.hint)
        assertEquals(listOf(ImEvents.RUN_FINISHED, ImEvents.APPROVAL), saved.events)
    }

    @Test
    fun replacingTheAddressReopensAChannelTheBackendTurnedOff() = runTest(dispatcher) {
        val s = mock()
        val vm = ImChannelEditorViewModel(s, "im-wecom")
        advanceUntilIdle()
        assertTrue(vm.uiState.value.editing)
        assertFalse(vm.uiState.value.hasChanges)
        assertEquals(ImVendors.WECOM, vm.uiState.value.vendor)
        vm.setReplacingWebhook(true)
        vm.onWebhookUrl("https://oapi.dingtalk.com/robot/send?access_token=0123456789abcdef")
        assertEquals(ImChannelRules.Problem.DifferentVendor, vm.uiState.value.webhookProblem)
        vm.onWebhookUrl("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=0123456789abcdef")
        assertNull(vm.uiState.value.webhookProblem)
        vm.save()
        advanceUntilIdle()
        val saved = (vm.events.first() as ImChannelEvent.Saved).channel
        assertEquals(ImVendors.WECOM, saved.vendor)
        assertTrue(saved.enabled)
        assertNull(saved.lastError)
        assertFalse(saved.hasSecret)
    }

    @Test
    fun deliveryErrorsBecomeWhatToDo() {
        assertEquals(R.string.im_error_keywords, imLastErrorRes("feishu 19024: the message has none of the bot's custom keywords"))
        assertEquals(
            R.string.im_error_security,
            imLastErrorRes("dingtalk 310000: security check failed (signing secret, custom keywords or IP list)"),
        )
        assertEquals(
            R.string.im_error_invalid,
            imLastErrorRes("wecom 93000: the webhook is invalid or the bot was removed from the group"),
        )
        assertNull(imLastErrorRes("feishu http 418: odd"))
    }

    @Test
    fun disabledChannelNoticesOpenImChannels() = runTest(dispatcher) {
        val item = mock().syncInbox().items.first().copy(
            kind = cn.thinktin.data.model.InboxKind.Info, subtype = "im_channel_disabled", runId = "run-done",
        )
        assertEquals(cn.thinktin.app.navigation.Routes.IM_CHANNELS, item.targetRoute())
        assertEquals("run/run-done", item.copy(subtype = null).targetRoute())
    }

    @Test
    fun settingsToImChannelsAndAddAGroup() {
        Dispatchers.resetMain()
        val app = ApplicationProvider.getApplicationContext<DemoTestApp>()
        scenario = ActivityScenario.launch(Intent(app, MainActivity::class.java))
        waitFor(hasContentDescription("打开菜单"))
        compose.onNode(hasContentDescription("打开菜单")).performClick()
        compose.waitForIdle()
        compose.onNode(hasContentDescription("设置") and inDrawer).performSemanticsAction(SemanticsActions.OnClick)
        waitFor(hasText("外观"))
        compose.onNode(hasText("IM 渠道")).performScrollTo().performClick()
        waitFor(hasTestTag(IM_CHANNEL_ROW_TEST_TAG + "im-feishu"))
        // 失效的机器人：说怎么处理。
        compose.onNode(hasText("机器人失效了", substring = true)).assertExists()

        compose.onNode(hasContentDescription("绑定群机器人")).performClick()
        waitFor(hasContentDescription("webhook 地址") and hasSetTextAction())
        compose.onNode(hasContentDescription("webhook 地址") and hasSetTextAction()).performTextInput("https://example.com/x")
        compose.onNode(hasText("保存")).performClick()
        waitFor(hasText("不是飞书", substring = true))
        compose.onNode(hasContentDescription("webhook 地址") and hasSetTextAction())
            .performSemanticsAction(SemanticsActions.SetText) { it(androidx.compose.ui.text.AnnotatedString(wecom)) }
        waitFor(hasText("认出来了：企业微信"))
        compose.onNode(hasContentDescription("备注（可选）") and hasSetTextAction()).performTextInput("运维群")
        compose.onNode(hasText("保存")).performClick()
        waitFor(hasText("运维群"))
    }

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }
}
