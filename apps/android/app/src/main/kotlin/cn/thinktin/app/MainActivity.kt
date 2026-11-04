package cn.thinktin.app

import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import cn.thinktin.app.navigation.DeepLinkInbox
import cn.thinktin.app.push.PushMessage
import cn.thinktin.app.settings.AppLocales
import cn.thinktin.app.ui.AppRoot
import cn.thinktin.design.theme.Appearance
import cn.thinktin.design.theme.ThinktinTheme

/**
 * 唯一的 Activity（singleTask）。深链（第 3 节）不让 NavController 自己从 Activity 的 intent 里读
 * （主界面的 NavController 不绑 Activity，见 rememberAppNavController）：冷启动（onCreate）和 App 已在运行时
 * （onNewIntent）都放进 [deepLinks]，由主界面统一处理，见 [DeepLinkInbox]。
 *
 * 点开推送（13.8）：FCM 在后台时系统发的通知、[cn.thinktin.app.push.PushNotifier] 发的、极光转过来的，Intent 里都带
 * `tt_*`（[PushMessage]）：换成它的深链交给 [deepLinks]，那条收件箱通知交给 [AppContainer.push] 等登录着时标已读。
 *
 * 是 AppCompatActivity（FragmentActivity 的子类）：批准审批前的 BiometricPrompt 要 FragmentActivity（13.16，见 ApprovalGate），
 * 设置里换界面语言（13.13，[cn.thinktin.app.settings.AppLocales]）在 Android 13 以前靠 AppCompat。
 */
class MainActivity : AppCompatActivity() {
    internal val deepLinks = DeepLinkInbox()

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) {
            if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY == 0) receive(intent)
        } else {
            // 重建（旋转、进程被杀后恢复）：intent 还是当初那条，已经处理过；只恢复还没处理的。
            deepLinks.restore(savedInstanceState.getString(KEY_PENDING_DEEP_LINK)?.let(Uri::parse))
        }
        val container = (application as ThinktinApp).container
        container.attachActivity(this)
        // 系统设置里改过“应用语言”的话，以系统的为准（请求语言、服务端语言跟着变）。
        container.followSystemAppLanguage(AppLocales.current())
        setContent {
            val settings by container.settings.collectAsStateWithLifecycle(initialValue = null)
            val appearance = settings?.appearance ?: Appearance.System
            ThinktinTheme(appearance = appearance) {
                SystemBarsFor(appearance)
                AppRoot(container = container, settings = settings, deepLinks = deepLinks)
            }
        }
    }

    override fun onDestroy() {
        (application as ThinktinApp).container.detachActivity(this)
        super.onDestroy()
    }

    /** App 已在运行时点推送或外部链接（singleTask）。public 是为了测试能直接投递。 */
    public override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        receive(intent)
    }

    /** 推送点开的换成深链；其余照常交给 [deepLinks]。 */
    private fun receive(intent: Intent?) {
        val push = PushMessage.fromIntent(intent)
        if (push == null) {
            deepLinks.offer(intent)
            return
        }
        (application as ThinktinApp).container.push.onOpened(push)
        deepLinks.offer(Intent(Intent.ACTION_VIEW, push.deepLink()))
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        deepLinks.current.value?.let { outState.putString(KEY_PENDING_DEEP_LINK, it.toString()) }
    }

    /** 状态栏、导航栏图标的深浅跟着 App 的外观设置走（不只是系统的）。 */
    @Composable
    private fun SystemBarsFor(appearance: Appearance) {
        val dark = when (appearance) {
            Appearance.System -> isSystemInDarkTheme()
            Appearance.Light -> false
            Appearance.Dark -> true
        }
        DisposableEffect(dark) {
            val style = if (dark) {
                SystemBarStyle.dark(Color.TRANSPARENT)
            } else {
                SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
            }
            enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
            onDispose {}
        }
    }

    private companion object {
        const val KEY_PENDING_DEEP_LINK = "pending_deep_link"
    }
}
