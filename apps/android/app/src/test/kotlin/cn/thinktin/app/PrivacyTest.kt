package cn.thinktin.app

import android.content.Intent
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
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
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.app.ui.drawer.DRAWER_TEST_TAG
import cn.thinktin.app.ui.privacy.PrivacyInfo
import cn.thinktin.data.service.AuthState
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * 13.11：首次启动的隐私政策页（同意之前不建客户端；不同意先说明、可以再看看；清单能看）、设置里的个人信息与权限
 * （清单、权限、撤回同意后退出登录回到隐私政策页）、同意记录的存取、权限清单的整理。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class PrivacyTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null
    private val app: DemoTestApp get() = ApplicationProvider.getApplicationContext()
    private val inDrawer = hasAnyAncestor(hasTestTag(DRAWER_TEST_TAG))
    private val inDialog = hasAnyAncestor(isDialog())
    private val phoneField = hasContentDescription("手机号") and hasSetTextAction()

    @After
    fun tearDown() {
        scenario?.close()
    }

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun waitGone(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isEmpty() }
    }

    @Test
    fun firstLaunchAsksForConsentBeforeAnything() {
        val fake = FakeThinktinService(initial = AuthState.SignedOut)
        var created = 0
        app.container = testContainer(app, { created++; fake }, privacyAccepted = false)
        scenario = ActivityScenario.launch(Intent(app, MainActivity::class.java))
        waitFor(hasText("同意并继续"))
        compose.onNode(hasText("阅读《隐私政策》")).assertExists()
        compose.onNode(phoneField).assertDoesNotExist()
        assertEquals(0, created)

        // 清单：收集的、共享的、SDK；返回到隐私政策页。
        compose.onNode(hasText("收集的信息和第三方清单")).performScrollTo().performClick()
        waitFor(hasText("收集的个人信息"))
        compose.onNode(hasText("手机号")).assertExists()
        compose.onNode(hasText("短信服务商（阿里云）")).assertExists()
        compose.onNode(hasText("目前 App 里没有收集个人信息的第三方 SDK。用到的开源组件见“开源许可”。")).assertExists()
        compose.onNode(hasContentDescription("返回")).performClick()
        waitFor(hasText("同意并继续"))

        // 不同意：说明为什么，可以再看看。
        compose.onNode(hasText("不同意")).performScrollTo().performClick()
        waitFor(hasText("不同意就无法使用 ThinkTin"))
        compose.onNode(hasText("退出应用") and inDialog).assertExists()
        compose.onNode(hasText("再看看") and inDialog).performClick()
        waitGone(hasText("不同意就无法使用 ThinkTin"))
        assertEquals(0, created)

        // 同意：进登录页，记下同意。
        compose.onNode(hasText("同意并继续")).performScrollTo().performClick()
        waitFor(phoneField)
        assertEquals(1, created)
        assertTrue(runBlocking { app.container.settings.first().privacyAccepted })
    }

    @Test
    fun privacyInfoPageListsPermissionsAndWithdrawingSignsOut() {
        val fake = FakeThinktinService(initial = AuthState.SignedIn)
        app.container = testContainer(app, { fake })
        scenario = ActivityScenario.launch(Intent(app, MainActivity::class.java))
        waitFor(hasContentDescription("打开菜单"))
        compose.onNode(hasContentDescription("打开菜单")).performClick()
        compose.waitForIdle()
        compose.onNode(hasContentDescription("设置") and inDrawer).performSemanticsAction(SemanticsActions.OnClick)
        waitFor(hasText("外观"))
        compose.onNode(hasText("个人信息与权限")).performScrollTo().performClick()
        waitFor(hasText("收集的个人信息"))
        compose.onNode(hasText("系统权限")).performScrollTo()
        compose.onNode(hasText("网络")).assertExists()
        compose.onNode(hasText("通知")).assertExists()
        compose.onNode(hasText("生物识别（指纹、人脸）")).assertExists()
        // 自己包名下的权限（AndroidX 加的）不列。
        compose.onNode(hasText("cn.thinktin.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION")).assertDoesNotExist()

        compose.onNode(hasText("撤回隐私政策同意")).performScrollTo().performClick()
        waitFor(hasText("撤回同意？"))
        compose.onNode(hasText("撤回") and inDialog).performClick()
        waitFor(hasText("同意并继续"))
        assertEquals(1, fake.logoutCalls)
        assertFalse(runBlocking { app.container.settings.first().privacyAccepted })
    }

    @Test
    fun consentIsStoredByPolicyVersion() = runBlocking {
        val repository = testContainer(app, { FakeThinktinService() }, privacyAccepted = false).settingsRepository
        assertFalse(repository.settings.first().privacyAccepted)
        repository.acceptPrivacy()
        assertTrue(repository.settings.first().privacyAccepted)
        repository.withdrawPrivacy()
        assertFalse(repository.settings.first().privacyAccepted)
        // 测试里默认当成同意过；撤回照样生效。
        val preaccepted = testContainer(app, { FakeThinktinService() }).settingsRepository
        assertTrue(preaccepted.settings.first().privacyAccepted)
        preaccepted.withdrawPrivacy()
        assertFalse(preaccepted.settings.first().privacyAccepted)
    }

    @Test
    fun permissionListSkipsOwnPermissionsAndMergesBiometrics() {
        val list = PrivacyInfo.permissions(
            listOf(
                "android.permission.INTERNET",
                "android.permission.USE_BIOMETRIC",
                "android.permission.USE_FINGERPRINT",
                "cn.thinktin.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION",
                "android.permission.CAMERA",
                "android.permission.INTERNET",
            ),
            packageName = "cn.thinktin.app",
        )
        assertEquals(
            listOf("android.permission.INTERNET", "android.permission.USE_BIOMETRIC", "android.permission.CAMERA"),
            list.map { it.first },
        )
        assertNull(list.last().second)
        assertEquals(R.string.privacy_perm_biometric, list[1].second?.name)
    }
}
