package cn.thinktin.app.ui.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Logout
import androidx.compose.material.icons.outlined.Badge
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.DeleteForever
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.DevicesOther
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Gavel
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Policy
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.Phone
import androidx.compose.material.icons.outlined.StopCircle
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.BuildConfig
import cn.thinktin.app.R
import cn.thinktin.app.push.hasNotificationPermission
import cn.thinktin.app.settings.AppLanguage
import cn.thinktin.app.settings.AppLocales
import cn.thinktin.app.settings.AppSettings
import cn.thinktin.app.settings.AppSettingsRepository
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.devices.AccountRow
import cn.thinktin.app.ui.common.ConfirmDialog
import cn.thinktin.app.ui.devices.DevicesAction
import cn.thinktin.data.model.User
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import cn.thinktin.data.service.logoutQuietly
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.Appearance
import cn.thinktin.design.theme.ThinktinSpacing
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class SettingsUiState(
    val settings: AppSettings? = null,
    val user: User? = null,
    val isDemo: Boolean = false,
    /** 退出登录的确认框开着。 */
    val confirmLogout: Boolean = false,
    val signingOut: Boolean = false,
)

/**
 * 设置（13.2 起，13.13 补全）：账号（手机号、昵称）、安全（设备与账号、下线其他设备、全部停止）、语言（跟随系统 / 中文 /
 * English）、外观、通知（是否允许，点了去系统设置）、演示模式（仅调试版）、模型、关于（隐私政策、用户协议、开源许可、版本）、
 * 危险操作（退出登录、注销账号）。
 * 下线其他设备、全部停止在“设备与账号”页里做（[DevicesAction]），改昵称、注销账号是单独的页面，这里只是入口；
 * 退出登录直接在这里确认。
 */
class SettingsViewModel(
    private val repository: AppSettingsRepository,
    private val service: ThinktinService,
    /** 把界面语言交给系统（[AppLocales.apply]，Activity 会重建）；测试里换成记录。 */
    private val applyLocales: (AppLanguage) -> Unit = AppLocales::apply,
) : ViewModel() {
    private val user = MutableStateFlow<User?>(null)
    private val local = MutableStateFlow(SettingsUiState(isDemo = service.isDemo))

    val uiState: StateFlow<SettingsUiState> = combine(repository.settings, user, local) { settings, me, ui ->
        ui.copy(settings = settings, user = me)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SettingsUiState(isDemo = service.isDemo))

    /** 取一次自己的资料（页面每次显示时调，从设备与账号页改完昵称回来也就刷新了）。失败不提示：账号区先不显示。 */
    fun refresh() {
        viewModelScope.launch {
            try {
                user.value = service.me()
            } catch (_: ServiceError) {
                // 冻结、登录失效由 authState 处理；断网时账号区先空着。
            }
        }
    }

    fun setAppearance(appearance: Appearance) {
        viewModelScope.launch { repository.setAppearance(appearance) }
    }

    /** 换界面语言（13.13）：先存（请求语言、服务端语言跟着变），再交给系统（界面重建成新语言）。 */
    fun setLanguage(language: AppLanguage) {
        viewModelScope.launch {
            repository.setLanguage(language)
            applyLocales(language)
        }
    }

    fun setDemoMode(enabled: Boolean) {
        viewModelScope.launch { repository.setDemoMode(enabled) }
    }

    fun askSignOut() = local.update { it.copy(confirmLogout = true) }

    fun dismissSignOut() = local.update { if (it.signingOut) it else it.copy(confirmLogout = false) }

    /** 只下线本设备（清缓存由 client-core 做）；服务端失败也已经在本地退出。 */
    fun signOut() {
        if (local.value.signingOut) return
        local.update { it.copy(signingOut = true) }
        viewModelScope.launch {
            service.logoutQuietly()
            local.update { it.copy(signingOut = false, confirmLogout = false) }
        }
    }
}

@Composable
fun SettingsScreen(
    onBack: () -> Unit,
    onOpenDevices: (DevicesAction?) -> Unit = {},
    onEditName: () -> Unit = {},
    onDeleteAccount: () -> Unit = {},
    onOpenKeys: () -> Unit = {},
    onOpenUsage: () -> Unit = {},
    onOpenLicenses: () -> Unit = {},
) {
    val container = LocalAppContainer.current
    val context = LocalContext.current
    // 通知权限：回到这页（从系统设置回来）时重新看一次。
    var notificationsOn by remember { mutableStateOf(hasNotificationPermission(context)) }
    LifecycleResumeEffect(Unit) {
        notificationsOn = hasNotificationPermission(context) &&
            androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled()
        onPauseOrDispose {}
    }
    val service = LocalThinktinService.current
    val viewModel: SettingsViewModel = viewModel(
        factory = viewModelFactory { initializer { SettingsViewModel(container.settingsRepository, service) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    LaunchedEffect(viewModel) { viewModel.refresh() }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_settings),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState()),
        ) {
            state.user?.let { user ->
                Section(R.string.settings_account)
                AccountRow(icon = Icons.Outlined.Phone, title = stringResource(R.string.profile_phone), value = user.phone)
                AccountRow(
                    icon = Icons.Outlined.Badge,
                    title = stringResource(R.string.profile_name),
                    value = user.displayName ?: stringResource(R.string.profile_name_unset),
                    onClick = onEditName,
                )
            }
            Section(R.string.settings_security)
            AccountRow(
                icon = Icons.Outlined.Devices,
                title = stringResource(R.string.page_devices),
                value = stringResource(R.string.settings_devices_summary),
                onClick = { onOpenDevices(null) },
            )
            AccountRow(
                icon = Icons.Outlined.DevicesOther,
                title = stringResource(R.string.devices_sign_out_others),
                value = stringResource(R.string.devices_sign_out_others_summary),
                onClick = { onOpenDevices(DevicesAction.SignOutOthers) },
            )
            AccountRow(
                icon = Icons.Outlined.StopCircle,
                title = stringResource(R.string.devices_stop_all),
                value = stringResource(R.string.devices_stop_all_summary),
                onClick = { onOpenDevices(DevicesAction.StopAll) },
                danger = true,
            )
            Section(R.string.settings_language)
            val language = state.settings?.language ?: AppLanguage.System
            Column(Modifier.selectableGroup()) {
                listOf(
                    AppLanguage.System to R.string.settings_language_system,
                    AppLanguage.Chinese to R.string.settings_language_chinese,
                    AppLanguage.English to R.string.settings_language_english,
                ).forEach { (option, label) ->
                    ListItem(
                        headlineContent = { Text(stringResource(label)) },
                        leadingContent = { RadioButton(selected = language == option, onClick = null) },
                        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
                        modifier = Modifier.selectable(
                            selected = language == option,
                            role = Role.RadioButton,
                            onClick = { if (language != option) viewModel.setLanguage(option) },
                        ),
                    )
                }
            }
            Text(
                text = stringResource(R.string.settings_language_summary),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = ThinktinSpacing.Page),
            )
            Section(R.string.settings_appearance)
            val current = state.settings?.appearance ?: Appearance.System
            Column(Modifier.selectableGroup()) {
                listOf(
                    Appearance.System to R.string.settings_appearance_system,
                    Appearance.Light to R.string.settings_appearance_light,
                    Appearance.Dark to R.string.settings_appearance_dark,
                ).forEach { (appearance, label) ->
                    ListItem(
                        headlineContent = { Text(stringResource(label)) },
                        leadingContent = { RadioButton(selected = current == appearance, onClick = null) },
                        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
                        modifier = Modifier.selectable(
                            selected = current == appearance,
                            role = Role.RadioButton,
                            onClick = { viewModel.setAppearance(appearance) },
                        ),
                    )
                }
            }
            Section(R.string.settings_notifications)
            AccountRow(
                icon = Icons.Outlined.Notifications,
                title = stringResource(R.string.settings_notifications),
                value = stringResource(
                    if (notificationsOn) R.string.settings_notifications_on else R.string.settings_notifications_off,
                ),
                onClick = { openNotificationSettings(context) },
            )
            // 演示模式开关只在 debug 包里有（第 7 节）。
            if (container.demoAllowed) {
                val demo = state.settings?.demoMode ?: state.isDemo
                ListItem(
                    headlineContent = { Text(stringResource(R.string.settings_demo_mode)) },
                    supportingContent = { Text(stringResource(R.string.settings_demo_mode_summary)) },
                    trailingContent = { Switch(checked = demo, onCheckedChange = null) },
                    colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
                    modifier = Modifier.toggleable(
                        value = demo,
                        role = Role.Switch,
                        onValueChange = viewModel::setDemoMode,
                    ),
                )
            }
            // 模型 key 与用量（13.4）：放在外观和演示模式之后。
            Section(R.string.settings_models)
            AccountRow(
                icon = Icons.Outlined.Key,
                title = stringResource(R.string.settings_keys),
                value = stringResource(R.string.settings_keys_summary),
                onClick = onOpenKeys,
            )
            AccountRow(
                icon = Icons.Outlined.BarChart,
                title = stringResource(R.string.page_usage),
                value = stringResource(R.string.settings_usage_summary),
                onClick = onOpenUsage,
            )
            Section(R.string.settings_about)
            AccountRow(
                icon = Icons.Outlined.Policy,
                title = stringResource(R.string.settings_privacy),
                value = PRIVACY_POLICY_URL,
                onClick = { openUrl(context, PRIVACY_POLICY_URL) },
            )
            AccountRow(
                icon = Icons.Outlined.Gavel,
                title = stringResource(R.string.settings_terms),
                value = TERMS_URL,
                onClick = { openUrl(context, TERMS_URL) },
            )
            AccountRow(
                icon = Icons.Outlined.Description,
                title = stringResource(R.string.page_licenses),
                value = stringResource(R.string.settings_licenses_summary),
                onClick = onOpenLicenses,
            )
            // 演示模式没有退出登录和注销：关掉演示模式就是“退出”。
            if (!state.isDemo) {
                Section(R.string.settings_danger)
                AccountRow(
                    icon = Icons.AutoMirrored.Outlined.Logout,
                    title = stringResource(R.string.action_sign_out),
                    value = stringResource(R.string.devices_sign_out_summary),
                    onClick = viewModel::askSignOut,
                )
                AccountRow(
                    icon = Icons.Outlined.DeleteForever,
                    title = stringResource(R.string.account_delete),
                    value = stringResource(R.string.account_delete_summary),
                    onClick = onDeleteAccount,
                    danger = true,
                )
            }
            Text(
                text = stringResource(R.string.settings_version, BuildConfig.VERSION_NAME, BuildConfig.DIST),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 24.dp),
            )
        }
    }
    if (state.confirmLogout) {
        ConfirmDialog(
            title = stringResource(R.string.devices_sign_out_title),
            text = stringResource(R.string.devices_sign_out_message),
            confirm = stringResource(R.string.action_sign_out),
            busy = state.signingOut,
            onConfirm = viewModel::signOut,
            onDismiss = viewModel::dismissSignOut,
        )
    }
}

/** 隐私政策、用户协议（和 iOS 一样的地址）。 */
const val PRIVACY_POLICY_URL = "https://thinktin.cn/legal/privacy"
const val TERMS_URL = "https://thinktin.cn/legal/terms"

private fun openUrl(context: android.content.Context, url: String) {
    runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))) }
}

/** 系统设置里这个 App 的通知页。 */
private fun openNotificationSettings(context: android.content.Context) {
    val intent = android.content.Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
        .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, context.packageName)
    runCatching { context.startActivity(intent) }
}

@Composable
private fun Section(title: Int) {
    SectionHeader(title = stringResource(title), modifier = Modifier.padding(horizontal = ThinktinSpacing.Page))
}
