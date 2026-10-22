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
import androidx.compose.material.icons.outlined.DeleteForever
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.DevicesOther
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.BuildConfig
import cn.thinktin.app.R
import cn.thinktin.app.settings.AppSettings
import cn.thinktin.app.settings.AppSettingsRepository
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.devices.AccountRow
import cn.thinktin.app.ui.devices.ConfirmDialog
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
 * 设置（13.2 的骨架升级；语言、通知、关于等完整版在 13.13）：账号（手机号、昵称）、安全（设备与账号、下线其他设备、
 * 全部停止）、外观、演示模式（仅调试版）、危险操作（退出登录、注销账号）。
 * 昵称、下线其他设备、全部停止、注销都在“设备与账号”页里做（[DevicesAction]），这里只是入口，退出登录直接在这里确认。
 */
class SettingsViewModel(
    private val repository: AppSettingsRepository,
    private val service: ThinktinService,
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
fun SettingsScreen(onBack: () -> Unit, onOpenDevices: (DevicesAction?) -> Unit = {}) {
    val container = LocalAppContainer.current
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
                    onClick = { onOpenDevices(DevicesAction.EditProfile) },
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
            Text(
                text = stringResource(R.string.settings_more_coming),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(ThinktinSpacing.Page),
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
                    onClick = { onOpenDevices(DevicesAction.DeleteAccount) },
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
            title = stringResource(R.string.action_sign_out),
            text = stringResource(R.string.devices_sign_out_message),
            confirm = stringResource(R.string.action_sign_out),
            busy = state.signingOut,
            onConfirm = viewModel::signOut,
            onDismiss = viewModel::dismissSignOut,
        )
    }
}

@Composable
private fun Section(title: Int) {
    SectionHeader(title = stringResource(title), modifier = Modifier.padding(horizontal = ThinktinSpacing.Page))
}
