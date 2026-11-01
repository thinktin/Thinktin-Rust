package cn.thinktin.app

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.text.AnnotatedString
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.ui.computer.COMPUTER_APPROVAL_CARD_TEST_TAG
import cn.thinktin.app.ui.computer.COMPUTER_PAIR_CODE_TEST_TAG
import cn.thinktin.app.ui.computer.COMPUTER_ROW_TEST_TAG
import cn.thinktin.app.ui.computer.prettyArguments
import cn.thinktin.app.ui.drawer.DRAWER_TEST_TAG
import cn.thinktin.data.mock.MockThinktinService
import cn.thinktin.data.model.ComputerLinkState
import cn.thinktin.data.model.DeviceMessageKind
import cn.thinktin.data.model.PairedComputer
import cn.thinktin.data.model.PairingEncoding
import cn.thinktin.data.model.PairingOffer
import cn.thinktin.data.model.string
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Rule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** 13.9：设备与账号 → 电脑，扫码（深链）配对、授权、吊销；审批中心里批准电脑上的操作。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class ComputerLinkUiTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null
    private val app: DemoTestApp get() = ApplicationProvider.getApplicationContext()
    private val mock = MockThinktinService(clock = { DemoTestApp.FIXED_CLOCK.millis() })
    private val signer = FakeSigner()
    private val inDrawer = hasAnyAncestor(hasTestTag(DRAWER_TEST_TAG))
    private val nowSecs = DemoTestApp.FIXED_CLOCK.millis() / 1000
    private val phoneKey = PairingEncoding.base64url("phone-key-1".toByteArray())

    @After
    fun tearDown() {
        scenario?.close()
    }

    private fun launch(uri: String? = null) {
        app.container = testContainer(app, { mock }, deviceSigner = signer)
        val intent = Intent(app, MainActivity::class.java)
        if (uri != null) intent.setAction(Intent.ACTION_VIEW).setData(Uri.parse(uri))
        scenario = ActivityScenario.launch(intent)
    }

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun waitGone(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isEmpty() }
    }

    /** 首页 → 设置 → 设备与账号 → 电脑。 */
    private fun openComputers() {
        waitFor(hasContentDescription("打开菜单"))
        compose.onNode(hasContentDescription("打开菜单")).performClick()
        compose.waitForIdle()
        compose.onNode(hasContentDescription("设置") and inDrawer).performSemanticsAction(SemanticsActions.OnClick)
        waitFor(hasText("安全"))
        compose.onNode(hasText("设备与账号")).performClick()
        waitFor(hasText("电脑配对和授权"))
        compose.onNode(hasText("电脑配对和授权")).performScrollTo().performClick()
        waitFor(hasTestTag(COMPUTER_ROW_TEST_TAG + "dev-mac"))
    }

    /** 已经配好了 MacBook Air（直接写进存储）。 */
    private fun pairMacDirectly() {
        app.container.computerLinks.update("user-demo") {
            ComputerLinkState(computers = listOf(PairedComputer("dev-mac", "dk-dev-mac", phoneKey, DemoTestApp.FIXED_CLOCK.millis())))
        }
    }

    @Test
    fun devicesPageLeadsToComputersAndPairing() {
        launch()
        openComputers()
        compose.onNode(hasText("在线 · 没有配对")).assertExists()
        compose.onNode(hasText("配对")).performClick()
        waitFor(hasText("配对“MacBook Air”"))
        compose.onNode(hasTestTag(COMPUTER_PAIR_CODE_TEST_TAG)).assertExists()
    }

    @Test
    fun pairsFromTheCameraLink() {
        launch("thinktin-pair:dev-mac:n1:${nowSecs + 600}")
        // 二维码深链：直接打开配对页，配对码填好了。
        waitFor(hasText("配对电脑"))
        waitFor(hasText("配对") and isEnabled())
        compose.onNode(hasText("配对")).performClick()
        waitFor(hasText("等电脑确认", substring = true))
        val response = mock.sentDeviceMessages().last()
        assertEquals(DeviceMessageKind.PairResponse, response.kind)
        assertEquals("n1", response.body.string("nonce"))
        assertEquals(listOf("和“MacBook Air”配对"), signer.reasons)

        val offer = PairingOffer("dev-mac", "dk-dev-mac", "n1", nowSecs + 600)
        mock.deliverDeviceMessage(
            "dev-mac",
            DeviceMessageKind.PairConfirm,
            buildJsonObject {
                put("nonce", "n1")
                put("signature", PairingEncoding.base64url(FakeCodec.confirmation(offer, "dev-this", phoneKey).toByteArray()))
            }.toString(),
        )
        waitFor(hasText("配对好了"))
        assertEquals("dk-dev-mac", app.container.computerLinks.state("user-demo").value.computers.single().desktopKey)
    }

    @Test
    fun grantsAndRevokesAccess() {
        launch()
        pairMacDirectly()
        openComputers()
        waitFor(hasText("在线 · 已配对", substring = true))
        compose.onNode(hasContentDescription("“MacBook Air”的更多操作")).performClick()
        waitFor(hasText("授权目录和应用"))
        compose.onNode(hasText("授权目录和应用")).performSemanticsAction(SemanticsActions.OnClick)
        waitFor(hasText("给“MacBook Air”授权"))
        // 目录不对时说清楚，改对了签名发出去，回到电脑页。
        val dirs = hasText("目录（一行一个，完整路径）") and hasSetTextAction()
        compose.onNode(dirs).performTextInput("Documents")
        waitFor(hasText("签名授权") and isEnabled())
        compose.onNode(hasText("签名授权")).performScrollTo().performClick()
        waitFor(hasText("至少给一个目录或一个应用", substring = true))
        compose.onNode(dirs).performSemanticsAction(SemanticsActions.SetText) { it(AnnotatedString("/Users/me/Documents")) }
        compose.onNode(hasText("1 天")).performClick()
        compose.onNode(hasText("签名授权")).performScrollTo().performClick()
        waitFor(hasText("目录：/Users/me/Documents"))
        assertEquals(DeviceMessageKind.Capability, mock.sentDeviceMessages().last().kind)
        assertEquals(listOf("给“MacBook Air”授权"), signer.reasons)
        compose.onNode(hasText("24 小时后到期")).assertExists()

        compose.onNode(hasContentDescription("吊销授权：目录：/Users/me/Documents")).performClick()
        waitGone(hasText("目录：/Users/me/Documents"))
        assertEquals(DeviceMessageKind.Revocation, mock.sentDeviceMessages().last().kind)
    }

    @Test
    fun approvalCenterSignsComputerRequests() {
        // 已经配好了 MacBook Air；电脑发来一条要批准的操作。
        launch()
        pairMacDirectly()
        mock.deliverDeviceMessage(
            "dev-mac",
            DeviceMessageKind.ApprovalRequest,
            buildJsonObject {
                put(
                    "request",
                    buildJsonObject {
                        put("desktop_id", "dev-mac"); put("request_id", "req-9"); put("tool", "computer_run")
                        put("arguments_json", """{"command":"rm -rf ~/Downloads/old","reason":"清理旧的下载"}""")
                        put("summary", "Run a command on your computer: rm -rf ~/Downloads/old\nWhy: 清理旧的下载")
                        put("issued_at", nowSecs); put("expires_at", nowSecs + 600)
                    },
                )
            }.toString(),
        )
        scenario?.onActivity { it.onNewIntent(Intent(Intent.ACTION_VIEW, Uri.parse("thinktin://approvals"))) }
        // 电脑发来的说明是英文的：手机按界面语言、照签名覆盖的参数说，理由照原话。
        val described = "在电脑上执行命令：rm -rf ~/Downloads/old\n理由：清理旧的下载"
        waitFor(hasText(described))
        compose.onNode(hasText("Run a command", substring = true)).assertDoesNotExist()
        compose.onNode(hasText("电脑上的操作")).assertExists()
        compose.onNode(hasText("computer_run")).assertExists()
        compose.onNode(hasText("批准") and hasAnyAncestor(hasTestTag(COMPUTER_APPROVAL_CARD_TEST_TAG + "req-9"))).performScrollTo().performClick()
        waitFor(hasText("已批准，电脑会接着做。"))
        waitGone(hasText(described))
        val decision = mock.sentDeviceMessages().last()
        assertEquals(DeviceMessageKind.ApprovalDecision, decision.kind)
        assertEquals("req-9", decision.body.string("request_id"))
        assertEquals(true, decision.body["approve"]?.jsonPrimitive?.booleanOrNull)
        assertEquals(listOf("批准“MacBook Air”上的操作"), signer.reasons)
    }

    @Test
    fun argumentsArePrettyPrinted() {
        assertTrue(prettyArguments("""{"paths":["/a"]}""").contains("\n"))
        assertEquals("not json", prettyArguments("not json"))
    }
}
