package cn.thinktin.app

import android.content.Intent
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.ui.drawer.DRAWER_TEST_TAG
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 13.2 的界面：登录（手机号 → 验证码 → 首页）、验证码错误、登录时被冻结、设备页（列表、远程下线确认）、
 * 注销账号的三步、设置页的安全区和退出登录。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class AuthUiTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null
    private val app: DemoTestApp get() = ApplicationProvider.getApplicationContext()
    private val inDrawer = hasAnyAncestor(hasTestTag(DRAWER_TEST_TAG))
    private val inDialog = hasAnyAncestor(isDialog())

    @After
    fun tearDown() {
        scenario?.close()
    }

    /** 用 [service] 当真实服务启动（null：DemoTestApp 自己的演示模式）。 */
    private fun launch(service: ThinktinService? = null): AppContainer? {
        val container = service?.let { fake -> testContainer(app, { fake }) }
        if (container != null) app.container = container
        scenario = ActivityScenario.launch(Intent(app, MainActivity::class.java))
        return container
    }

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun waitGone(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isEmpty() }
    }

    private val phoneField = hasContentDescription("手机号") and hasSetTextAction()
    private val codeField = hasContentDescription("6 位验证码") and hasSetTextAction()

    private fun enterPhoneAndRequestCode() {
        waitFor(phoneField)
        compose.onNode(hasText("欢迎使用 ThinkTin")).assertIsDisplayed()
        compose.onNode(hasText("继续即表示你已阅读并同意《用户协议》和《隐私政策》。")).assertIsDisplayed()
        compose.onNode(hasContentDescription("国家或地区：中国大陆 +86")).assertIsDisplayed()
        compose.onNode(phoneField).performTextInput("13800138000")
        compose.onNode(hasText("获取验证码")).performClick()
        waitFor(hasText("6 位验证码已发送至 +86 13800138000"))
    }

    @Test
    fun loginPhoneThenCodeThenHome() {
        val fake = FakeThinktinService(initial = AuthState.SignedOut, userLocale = "en")
        launch(fake)
        enterPhoneAndRequestCode()
        assertEquals(listOf("+8613800138000"), fake.sentCodes)
        // 60 秒倒计时，期间不能重发
        compose.onNode(hasText("秒后可重新获取", substring = true)).assertIsDisplayed()
        // 满 6 位自动提交
        waitFor(codeField)
        compose.onNode(codeField).performTextInput("123456")
        waitFor(hasText("最近运行"))
        assertEquals(listOf("+8613800138000" to "123456"), fake.logins)
        // 服务端记的是 en、App 跟随系统（中文）：登录后改成 zh-CN
        compose.waitUntil(timeoutMillis = 10_000) { fake.locales.isNotEmpty() }
        assertEquals(listOf("zh-CN"), fake.locales)
    }

    @Test
    fun wrongCodeShowsErrorAndChangeNumberGoesBack() {
        val fake = FakeThinktinService(initial = AuthState.SignedOut)
        launch(fake)
        enterPhoneAndRequestCode()
        waitFor(codeField)
        compose.onNode(codeField).performTextInput("000000")
        waitFor(hasText("验证码错误或已过期，请重新输入"))
        compose.onNode(hasText("欢迎使用 ThinkTin")).assertDoesNotExist()
        // 改号码：回到手机号页
        compose.onNode(hasText("更换手机号")).performClick()
        waitFor(phoneField)
        compose.onNode(hasText("获取验证码")).assertIsDisplayed()
    }

    @Test
    fun invalidPhoneFormatShowsFieldError() {
        val fake = FakeThinktinService(initial = AuthState.SignedOut)
        launch(fake)
        waitFor(phoneField)
        compose.onNode(phoneField).performTextInput("12345")
        compose.onNode(hasText("获取验证码")).performClick()
        waitFor(hasText("手机号格式不对，请检查国家或地区和号码"))
        assertEquals(emptyList<String>(), fake.sentCodes)
    }

    @Test
    fun rateLimitedShowsRemainingSeconds() {
        val fake = FakeThinktinService(initial = AuthState.SignedOut)
        fake.failNext("sendCode", ServiceError.Api(429, "rate_limited", "too many codes", 42))
        launch(fake)
        waitFor(phoneField)
        compose.onNode(phoneField).performTextInput("13800138000")
        compose.onNode(hasText("获取验证码")).performClick()
        waitFor(hasText("操作太频繁，请", substring = true))
        compose.onNode(hasText("秒后再试", substring = true)).assertIsDisplayed()
    }

    @Test
    fun frozenAtLoginShowsFrozenPageAndBack() {
        val fake = FakeThinktinService(initial = AuthState.SignedOut)
        launch(fake)
        enterPhoneAndRequestCode()
        fake.failNext("login", ServiceError.AccountFrozen())
        waitFor(codeField)
        compose.onNode(codeField).performTextInput("123456")
        waitFor(hasText("账号已冻结"))
        compose.onNode(hasText("这个账号已被冻结，暂时无法登录。请联系客服处理。")).assertIsDisplayed()
        compose.onNode(hasText("返回登录")).performClick()
        waitFor(phoneField)
    }

    @Test
    fun frozenWhileSignedInCanCheckAgain() {
        val fake = FakeThinktinService(initial = AuthState.Frozen)
        launch(fake)
        waitFor(hasText("账号已冻结"))
        compose.onNode(hasText("重新检查")).performClick()
        waitFor(hasText("账号仍处于冻结状态"))
        // 解冻（服务回到已登录）后回主界面
        fake.auth.value = AuthState.SignedIn
        waitFor(hasText("最近运行"))
    }

    private fun openSettings() {
        waitFor(hasContentDescription("打开菜单"))
        compose.onNode(hasContentDescription("打开菜单")).performClick()
        compose.waitForIdle()
        compose.onNode(hasContentDescription("设置") and inDrawer).performSemanticsAction(SemanticsActions.OnClick)
        waitFor(hasText("安全"))
    }

    @Test
    fun devicesPageListsDevicesAndRevokesAfterConfirm() {
        launch()
        openSettings()
        compose.onNode(hasText("设备与账号")).performClick()
        waitFor(hasText("Pixel 8"))
        compose.onNode(hasText("本机")).assertIsDisplayed()
        compose.onNode(hasText("MacBook Air")).assertIsDisplayed()
        compose.onNode(hasText("在线")).assertIsDisplayed()
        compose.onNode(hasText("iPhone 15")).assertIsDisplayed()
        compose.onNode(hasContentDescription("iPhone / iPad")).assertIsDisplayed()
        // 本机没有“下线”按钮
        compose.onAllNodes(hasContentDescription("下线 Pixel 8")).assertCountEquals(0)
        compose.onNode(hasContentDescription("下线 iPhone 15")).performClick()
        waitFor(hasText("下线“iPhone 15”？"))
        compose.onNode(hasText("下线") and inDialog).performClick()
        waitFor(hasText("已下线“iPhone 15”"))
        waitGone(hasText("iPhone 15"))
    }

    @Test
    fun stopAllFromSettingsAsksTwiceAndShowsCounts() {
        launch()
        openSettings()
        compose.onNode(hasText("全部停止")).performScrollTo().performClick()
        waitFor(hasText("继续") and inDialog)
        compose.onNode(hasText("继续") and inDialog).performClick()
        waitFor(hasText("确定全部停止？"))
        compose.onNode(hasText("全部停止") and inDialog).performClick()
        waitFor(hasText("已全部停止"))
        compose.onNode(hasText("取消的运行：", substring = true)).assertIsDisplayed()
        compose.onNode(hasText("暂停的计划：", substring = true)).assertIsDisplayed()
    }

    @Test
    fun deleteAccountThreeStepsReturnsToLogin() {
        val fake = FakeThinktinService()
        launch(fake)
        openSettings()
        compose.onNode(hasText("注销账号")).performScrollTo().performClick()
        // 第 1 步：说明不可恢复、保险箱密钥一并销毁
        waitFor(hasText("注销账号（第 1 步，共 3 步）"))
        compose.onNode(hasText("加密密钥（DEK）", substring = true)).assertIsDisplayed()
        compose.onNode(hasText("发送验证码")).performClick()
        // 第 2 步：验证码
        waitFor(hasText("输入验证码（第 2 步，共 3 步）"))
        assertEquals(1, fake.selfCodes)
        compose.onNode(codeField).performTextInput("123456")
        compose.onNode(hasText("下一步")).performClick()
        // 第 3 步：最后确认
        waitFor(hasText("最后确认（第 3 步，共 3 步）"))
        compose.onNode(hasText("永久注销")).performClick()
        waitFor(hasText("欢迎使用 ThinkTin"))
        assertEquals("123456", fake.deletedWith)
    }

    @Test
    fun editNicknameFromSettings() {
        launch()
        openSettings()
        waitFor(hasText("昵称") and !inDrawer)
        compose.onNode(hasText("昵称") and !inDrawer).performClick()
        val field = hasContentDescription("昵称") and hasSetTextAction()
        waitFor(field)
        compose.onNode(hasText("修改昵称")).assertIsDisplayed()
        compose.onNode(field).performTextClearance()
        compose.onNode(field).performTextInput("小陈")
        compose.onNode(hasText("保存")).performClick()
        // 保存后回到设置页，显示新昵称
        waitFor(hasText("小陈") and !inDrawer and !hasSetTextAction())
        compose.onNode(hasText("安全")).assertIsDisplayed()
    }

    @Test
    fun settingsShowsAccountSecurityAndConfirmsSignOut() {
        val fake = FakeThinktinService()
        launch(fake)
        openSettings()
        waitFor(hasText("+86 138****0000") and !inDrawer)
        compose.onNode(hasText("演示用户") and !inDrawer).assertIsDisplayed()
        compose.onNode(hasText("下线其他设备")).assertIsDisplayed()
        compose.onNode(hasText("退出登录")).performScrollTo().performClick()
        waitFor(hasText("只退出这台设备，其他设备和正在运行的 agent 不受影响。本机的缓存会一并清掉。"))
        compose.onNode(hasText("退出登录？")).assertIsDisplayed()
        compose.onNode(hasText("退出登录") and inDialog).performClick()
        waitFor(hasText("欢迎使用 ThinkTin"))
        assertEquals(1, fake.logoutCalls)
    }
}
