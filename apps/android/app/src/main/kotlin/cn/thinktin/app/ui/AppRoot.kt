package cn.thinktin.app.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import cn.thinktin.app.AppContainer
import cn.thinktin.app.navigation.MainNavigation
import cn.thinktin.app.settings.AppSettings
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.login.LoginFlow
import cn.thinktin.app.ui.status.CoreUnavailableScreen
import cn.thinktin.app.ui.status.FrozenScreen
import cn.thinktin.data.service.AuthState
import kotlinx.coroutines.launch

/**
 * 根界面：按设置选服务（演示 / 真实），按登录状态显示登录流、冻结页或主界面。
 * 切换演示模式会换服务，主界面整个重建（新的 NavController 和 ViewModel）。
 */
@Composable
fun AppRoot(container: AppContainer, settings: AppSettings?) {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        // 设置还没读出来：只显示背景（和窗口背景同色），通常只有一帧。
        if (settings == null) return@Surface
        val scope = rememberCoroutineScope()
        val service = remember(settings.demoMode) { container.service(settings.demoMode) }
        if (service == null) {
            CoreUnavailableScreen(onUseDemo = { scope.launch { container.settingsRepository.setDemoMode(true) } })
            return@Surface
        }
        val auth by service.authState.collectAsStateWithLifecycle()
        CompositionLocalProvider(LocalAppContainer provides container, LocalThinktinService provides service) {
            key(service) {
                when {
                    auth == AuthState.Frozen -> FrozenScreen(onSignOut = { scope.launch { runCatching { service.logout() } } })
                    auth == AuthState.SignedOut && !service.isDemo -> LoginFlow()
                    else -> MainNavigation()
                }
            }
        }
    }
}
