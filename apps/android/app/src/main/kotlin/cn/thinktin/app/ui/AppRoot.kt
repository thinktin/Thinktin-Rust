package cn.thinktin.app.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import cn.thinktin.app.AppContainer
import cn.thinktin.app.ServiceState
import cn.thinktin.app.navigation.DeepLinkInbox
import cn.thinktin.app.navigation.LocalDeepLinks
import cn.thinktin.app.navigation.MainNavigation
import cn.thinktin.app.push.FlavorPush
import cn.thinktin.app.push.PushNotifier
import cn.thinktin.app.settings.AppSettings
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.login.LoginFlow
import cn.thinktin.app.ui.status.CoreUnavailableScreen
import cn.thinktin.app.ui.status.FrozenAccountScreen
import cn.thinktin.app.ui.status.LoadingScreen
import cn.thinktin.app.ui.status.UpgradeRequiredScreen
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * 根界面：按设置选服务（演示 / 真实），按登录状态显示登录流、冻结页或主界面；
 * 服务端说版本太老（[ThinktinService.upgradeState]）时什么都不显示，只有升级页。
 * 真实服务在后台创建：创建中显示加载，失败显示“核心库不可用”页。
 * 切换演示模式会换服务，主界面整个重建（新的 NavController 和 ViewModel）。
 */
@Composable
fun AppRoot(container: AppContainer, settings: AppSettings?, deepLinks: DeepLinkInbox = remember { DeepLinkInbox() }) {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        // 设置还没读出来：只显示背景（和窗口背景同色），通常只有一帧。
        if (settings == null) return@Surface
        val scope = rememberCoroutineScope()
        val serviceFlow: StateFlow<ServiceState> = remember(settings.demoMode) {
            if (settings.demoMode) MutableStateFlow(ServiceState.Ready(container.demoService())) else container.coreService()
        }
        val serviceState by serviceFlow.collectAsStateWithLifecycle()
        when (val current = serviceState) {
            ServiceState.Loading -> LoadingScreen()
            is ServiceState.Failed -> CoreUnavailableScreen(
                error = current.error,
                onRetry = container::retryCore,
                onUseDemo = if (container.demoAllowed) {
                    { scope.launch { container.settingsRepository.setDemoMode(true) } }
                } else {
                    null
                },
            )
            is ServiceState.Ready -> ServiceContent(container, current.service, deepLinks)
        }
    }
}

@Composable
private fun ServiceContent(container: AppContainer, service: ThinktinService, deepLinks: DeepLinkInbox) {
    val auth by service.authState.collectAsStateWithLifecycle()
    val upgradeRequired by service.upgradeState.collectAsStateWithLifecycle()
    PushSync(container, service, auth)
    CompositionLocalProvider(
        LocalAppContainer provides container,
        LocalThinktinService provides service,
        LocalDeepLinks provides deepLinks,
    ) {
        key(service) {
            when {
                upgradeRequired -> UpgradeRequiredScreen()
                auth == AuthState.Frozen -> FrozenAccountScreen(service)
                auth == AuthState.SignedOut && !service.isDemo -> LoginFlow()
                else -> MainNavigation()
            }
        }
    }
}

/**
 * 推送（13.8）：真实服务登录后（同意了隐私政策）才启动推送 SDK，拿到的令牌交给 [AppContainer.push]；登录着时把令牌
 * 报给服务端、点开过的通知标已读（令牌、待标已读变了再来一次）；从登录变成退出登录时清掉通知栏里的（推送里没有用户 id，
 * 不能留着上一个账号的）。演示模式不接推送。
 */
@Composable
private fun PushSync(container: AppContainer, service: ThinktinService, auth: AuthState) {
    val context = LocalContext.current
    var wasSignedIn by remember(service) { mutableStateOf(false) }
    LaunchedEffect(service, auth) {
        if (auth == AuthState.SignedIn) {
            wasSignedIn = true
            if (!service.isDemo) {
                FlavorPush.start(context.applicationContext) { token -> container.push.onNewToken(FlavorPush.channel, token) }
            }
            combine(container.push.token, container.push.pendingReads) { _, _ -> }
                .collect { container.push.sync(service) }
        } else {
            if (wasSignedIn && auth == AuthState.SignedOut) PushNotifier.cancelAll(context)
            if (auth == AuthState.SignedOut) wasSignedIn = false
            container.push.sync(service)
        }
    }
}
