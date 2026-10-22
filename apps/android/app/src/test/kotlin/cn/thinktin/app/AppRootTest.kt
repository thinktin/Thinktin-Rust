package cn.thinktin.app

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * AppRoot 的各个分支：真实服务（非演示）的登录流、冻结页、运行中被踢下线、核心库不可用，
 * 以及 release 包（demoAllowed = false）不给演示模式入口。
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = DemoTestApp::class, qualifiers = "zh-rCN-w411dp-h891dp")
class AppRootTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null
    private val app: DemoTestApp get() = ApplicationProvider.getApplicationContext()

    @After
    fun tearDown() {
        scenario?.close()
    }

    private fun launch(
        createCore: () -> ThinktinService,
        demoAllowed: Boolean = true,
        uri: String? = null,
    ): AppContainer {
        val container = testContainer(app, createCore, demoAllowed = demoAllowed)
        app.container = container
        val intent = Intent(app, MainActivity::class.java)
        if (uri != null) intent.setAction(Intent.ACTION_VIEW).setData(Uri.parse(uri))
        scenario = ActivityScenario.launch(intent)
        return container
    }

    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(timeoutMillis = 10_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }

    @Test
    fun frozenAccountShowsFrozenPageAndSignsOut() {
        val fake = FakeThinktinService(initial = AuthState.Frozen)
        launch({ fake })
        waitFor(hasText("账号已冻结"))
        compose.onNode(hasText("退出登录")).performClick()
        waitFor(hasText("欢迎使用 ThinkTin"))
        assertEquals(1, fake.logoutCalls)
    }

    @Test
    fun signedOutShowsLoginAndDemoEntryInDebug() {
        val container = launch({ FakeThinktinService(initial = AuthState.SignedOut) })
        waitFor(hasText("欢迎使用 ThinkTin"))
        compose.onNode(hasText("登录")).assertIsDisplayed()
        compose.onNode(hasText("使用演示模式")).performClick()
        // 换成演示服务，进首页
        waitFor(hasText("最近运行"))
        assertEquals(true, runBlocking { container.settings.first().demoMode })
    }

    @Test
    fun releaseHasNoDemoEntryAndIgnoresStoredDemoMode() {
        val container = launch({ FakeThinktinService(initial = AuthState.SignedOut) }, demoAllowed = false)
        waitFor(hasText("欢迎使用 ThinkTin"))
        compose.onAllNodes(hasText("使用演示模式")).assertCountEquals(0)
        // 即使存过 demo_mode=true（比如从 debug 包覆盖安装），release 也不进演示模式
        runBlocking { container.settingsRepository.setDemoMode(true) }
        assertFalse(runBlocking { container.settings.first().demoMode })
        compose.waitForIdle()
        compose.onNode(hasText("欢迎使用 ThinkTin")).assertIsDisplayed()
    }

    @Test
    fun signingOutWhileRunningShowsLogin() {
        val fake = FakeThinktinService()
        launch({ fake })
        waitFor(hasText("最近运行"))
        fake.auth.value = AuthState.SignedOut
        waitFor(hasText("欢迎使用 ThinkTin"))
        // 再登录回来，主界面重建
        fake.auth.value = AuthState.SignedIn
        waitFor(hasText("最近运行"))
    }

    @Test
    fun deepLinkWaitsUntilSignedIn() {
        val fake = FakeThinktinService(initial = AuthState.SignedOut)
        launch({ fake }, uri = "thinktin://approval/approval-pending")
        waitFor(hasText("欢迎使用 ThinkTin"))
        // 登录后才跳（推送点进来时还没登录）
        fake.auth.value = AuthState.SignedIn
        waitFor(hasText("编号：approval-pending"))
        compose.onNode(hasText("审批详情")).assertIsDisplayed()
    }

    @Test
    fun missingNativeLibraryShowsCoreUnavailable() {
        launch({ throw UnsatisfiedLinkError("dlopen failed: library \"libclient_core.so\" not found") })
        waitFor(hasText("无法加载核心库"))
        compose.onNode(hasText("libclient_core.so", substring = true)).assertIsDisplayed()
        compose.onNode(hasText("重试")).assertIsDisplayed()
        compose.onNode(hasText("使用演示模式")).performClick()
        waitFor(hasText("最近运行"))
    }

    @Test
    fun anyInitFailureShowsCoreUnavailableAndRetryWorks() {
        var attempts = 0
        val fake = FakeThinktinService()
        launch(
            {
                attempts++
                // 第一次：绑定和库的契约版本不一致（UniFFI 在首次访问时抛的 RuntimeException）
                if (attempts == 1) throw ExceptionInInitializerError(RuntimeException("UniFFI contract version mismatch"))
                fake
            },
            demoAllowed = false,
        )
        waitFor(hasText("无法加载核心库"))
        compose.onAllNodes(hasText("使用演示模式")).assertCountEquals(0)
        compose.onNode(hasText("contract version mismatch", substring = true)).assertIsDisplayed()
        compose.onNode(hasText("重试")).performClick()
        waitFor(hasText("最近运行"))
        assertEquals(2, attempts)
    }
}
