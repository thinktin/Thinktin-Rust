package cn.thinktin.app.ui.devices

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Logout
import androidx.compose.material.icons.outlined.Badge
import androidx.compose.material.icons.outlined.DeleteForever
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.DevicesOther
import androidx.compose.material.icons.outlined.Laptop
import androidx.compose.material.icons.outlined.Phone
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.PhoneIphone
import androidx.compose.material.icons.outlined.StopCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.RelativeTime
import cn.thinktin.app.ui.common.asString
import cn.thinktin.data.model.DeviceInfo
import cn.thinktin.data.model.DevicePlatform
import cn.thinktin.data.model.StopAllResult
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing
import cn.thinktin.design.theme.ThinktinTheme

/** 设备与账号（13.2，第 4.9 节“安全”）。[action] 是从设置页直接要打开的操作。 */
@Composable
fun DevicesScreen(
    action: DevicesAction?,
    onBack: () -> Unit,
    onEditName: () -> Unit,
    onDeleteAccount: () -> Unit,
) {
    val container = LocalAppContainer.current
    val service = LocalThinktinService.current
    val viewModel: DevicesViewModel = viewModel(
        factory = viewModelFactory { initializer { DevicesViewModel(service, action) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    LaunchedEffect(viewModel) { viewModel.onShown() }
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.messages.collect {
            snackbar.showSnackbar(context.getString(it.resId, *it.args.toTypedArray()), duration = SnackbarDuration.Long)
        }
    }
    val now = container.clock.millis()
    val zone = container.clock.zone
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_devices),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            item { Section(R.string.devices_section_profile) }
            item {
                AccountRow(
                    icon = Icons.Outlined.Phone,
                    title = stringResource(R.string.profile_phone),
                    value = state.user?.phone ?: stringResource(R.string.loading_short),
                )
            }
            item {
                AccountRow(
                    icon = Icons.Outlined.Badge,
                    title = stringResource(R.string.profile_name),
                    value = state.user?.displayName ?: stringResource(R.string.profile_name_unset),
                    onClick = if (state.user != null) onEditName else null,
                )
            }
            item { Section(R.string.devices_section_devices) }
            when {
                state.loading && state.devices.isEmpty() -> item {
                    val label = stringResource(R.string.loading)
                    Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(Modifier.semantics { contentDescription = label })
                    }
                }
                state.loadError != null && state.devices.isEmpty() -> item {
                    EmptyState(
                        title = stringResource(R.string.devices_load_failed),
                        message = state.loadError!!.asString(),
                        actionLabel = stringResource(R.string.action_retry),
                        onAction = viewModel::refresh,
                        modifier = Modifier.padding(ThinktinSpacing.Page),
                    )
                }
                else -> items(state.devices, key = { it.id }) { device ->
                    DeviceRow(device = device, nowMs = now, zone = zone, onRevoke = { viewModel.askRevoke(device) })
                }
            }
            item { Section(R.string.devices_section_security) }
            item {
                AccountRow(
                    icon = Icons.Outlined.DevicesOther,
                    title = stringResource(R.string.devices_sign_out_others),
                    value = stringResource(R.string.devices_sign_out_others_summary),
                    onClick = viewModel::askSignOutOthers,
                )
            }
            item {
                AccountRow(
                    icon = Icons.Outlined.StopCircle,
                    title = stringResource(R.string.devices_stop_all),
                    value = stringResource(R.string.devices_stop_all_summary),
                    onClick = viewModel::askStopAll,
                    danger = true,
                )
            }
            // 演示模式没有退出登录和注销（第 7 节：关掉演示模式就是“退出”）。
            if (!state.isDemo) {
                item { Section(R.string.settings_danger) }
                item {
                    AccountRow(
                        icon = Icons.AutoMirrored.Outlined.Logout,
                        title = stringResource(R.string.action_sign_out),
                        value = stringResource(R.string.devices_sign_out_summary),
                        onClick = viewModel::askLogout,
                    )
                }
                item {
                    AccountRow(
                        icon = Icons.Outlined.DeleteForever,
                        title = stringResource(R.string.account_delete),
                        value = stringResource(R.string.account_delete_summary),
                        onClick = onDeleteAccount,
                        danger = true,
                    )
                }
            }
            item { Box(Modifier.padding(bottom = 24.dp)) }
        }
    }
    state.dialog?.let { dialog ->
        DevicesDialogs(dialog = dialog, busy = state.busy, viewModel = viewModel)
    }
}

@Composable
private fun Section(title: Int) {
    SectionHeader(title = stringResource(title), modifier = Modifier.padding(horizontal = ThinktinSpacing.Page))
}

@Composable
internal fun AccountRow(
    icon: ImageVector,
    title: String,
    value: String?,
    onClick: (() -> Unit)? = null,
    danger: Boolean = false,
) {
    val tint = if (danger) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface
    ListItem(
        headlineContent = { Text(title, color = tint) },
        supportingContent = value?.let { { Text(it) } },
        leadingContent = { Icon(icon, contentDescription = null, tint = tint) },
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
        modifier = if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier,
    )
}

/** 一台设备：平台图标、名字、本机标记、在线状态（电脑）、最后活跃；别的设备右侧是“下线”。 */
@Composable
private fun DeviceRow(device: DeviceInfo, nowMs: Long, zone: java.time.ZoneId, onRevoke: () -> Unit) {
    val platform = stringResource(platformLabel(device.platform))
    val lastSeen = stringResource(R.string.devices_last_seen, RelativeTime.of(device.lastSeenAtMs, nowMs, zone).asString())
    val online = device.platform == DevicePlatform.Macos
    ListItem(
        headlineContent = {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(device.name)
                if (device.current) Badge(stringResource(R.string.devices_this_device), ThinktinTheme.colors.primary)
            }
        },
        supportingContent = {
            Column {
                Text(stringResource(R.string.devices_platform_and_seen, platform, lastSeen))
                if (online) {
                    val (label, color) = if (device.online) {
                        R.string.devices_online to ThinktinTheme.extendedColors.success
                    } else {
                        R.string.devices_offline to MaterialTheme.colorScheme.onSurfaceVariant
                    }
                    Text(stringResource(label), color = color, style = MaterialTheme.typography.labelMedium)
                }
            }
        },
        leadingContent = { Icon(platformIcon(device.platform), contentDescription = platform) },
        trailingContent = if (device.current) {
            null
        } else {
            {
                IconButton(onClick = onRevoke) {
                    Icon(
                        Icons.AutoMirrored.Outlined.Logout,
                        contentDescription = stringResource(R.string.devices_revoke_description, device.name),
                    )
                }
            }
        },
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
    )
}

@Composable
private fun Badge(text: String, color: Color) {
    Surface(color = color.copy(alpha = 0.12f), contentColor = color, shape = RoundedCornerShape(8.dp)) {
        Text(text, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp))
    }
}

private fun platformIcon(platform: DevicePlatform): ImageVector = when (platform) {
    DevicePlatform.Android -> Icons.Outlined.PhoneAndroid
    DevicePlatform.Ios -> Icons.Outlined.PhoneIphone
    DevicePlatform.Macos -> Icons.Outlined.Laptop
    DevicePlatform.Unknown -> Icons.Outlined.Devices
}

private fun platformLabel(platform: DevicePlatform): Int = when (platform) {
    DevicePlatform.Android -> R.string.platform_android
    DevicePlatform.Ios -> R.string.platform_ios
    DevicePlatform.Macos -> R.string.platform_macos
    DevicePlatform.Unknown -> R.string.platform_unknown
}

@Composable
private fun DevicesDialogs(dialog: DevicesDialog, busy: Boolean, viewModel: DevicesViewModel) {
    when (dialog) {
        is DevicesDialog.Revoke -> ConfirmDialog(
            title = stringResource(R.string.devices_revoke_title, dialog.device.name),
            text = stringResource(R.string.devices_revoke_message),
            confirm = stringResource(R.string.devices_revoke_confirm),
            danger = true,
            busy = busy,
            onConfirm = viewModel::confirmRevoke,
            onDismiss = viewModel::dismissDialog,
        )
        is DevicesDialog.SignOutOthers -> if (!dialog.confirming) {
            ConfirmDialog(
                title = stringResource(R.string.devices_sign_out_others),
                text = stringResource(R.string.devices_sign_out_others_message),
                confirm = stringResource(R.string.devices_sign_out_others),
                busy = busy,
                onConfirm = viewModel::confirmSignOutOthers,
                onDismiss = viewModel::dismissDialog,
            ) {
                val label = stringResource(R.string.devices_also_stop_agents)
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 8.dp)
                        .toggleable(value = dialog.stopAgents, role = Role.Checkbox, onValueChange = viewModel::setStopAgents),
                ) {
                    Checkbox(checked = dialog.stopAgents, onCheckedChange = null)
                    Text(label, modifier = Modifier.padding(start = 8.dp))
                }
            }
        } else {
            ConfirmDialog(
                title = stringResource(R.string.devices_sign_out_others_confirm_title),
                text = stringResource(
                    if (dialog.stopAgents) R.string.devices_sign_out_others_confirm_stop else R.string.devices_sign_out_others_confirm,
                ),
                confirm = stringResource(R.string.devices_sign_out_others_confirm_action),
                danger = true,
                busy = busy,
                onConfirm = viewModel::confirmSignOutOthers,
                onDismiss = viewModel::dismissDialog,
            )
        }
        is DevicesDialog.StopAll -> if (!dialog.confirming) {
            ConfirmDialog(
                title = stringResource(R.string.devices_stop_all),
                text = stringResource(R.string.devices_stop_all_message),
                confirm = stringResource(R.string.action_continue),
                busy = busy,
                onConfirm = viewModel::confirmStopAll,
                onDismiss = viewModel::dismissDialog,
            )
        } else {
            ConfirmDialog(
                title = stringResource(R.string.devices_stop_all_confirm_title),
                text = stringResource(R.string.devices_stop_all_confirm),
                confirm = stringResource(R.string.devices_stop_all_confirm_action),
                danger = true,
                busy = busy,
                onConfirm = viewModel::confirmStopAll,
                onDismiss = viewModel::dismissDialog,
            )
        }
        is DevicesDialog.StopAllDone -> StopAllDoneDialog(dialog.result, onDismiss = viewModel::dismissDialog)
        DevicesDialog.Logout -> ConfirmDialog(
            title = stringResource(R.string.devices_sign_out_title),
            text = stringResource(R.string.devices_sign_out_message),
            confirm = stringResource(R.string.action_sign_out),
            busy = busy,
            onConfirm = viewModel::confirmLogout,
            onDismiss = viewModel::dismissDialog,
        )
    }
}

/** 通用确认框：危险操作的确认按钮用错误色；[busy] 时转圈、不可关。 */
@Composable
internal fun ConfirmDialog(
    title: String,
    text: String,
    confirm: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    danger: Boolean = false,
    busy: Boolean = false,
    confirmEnabled: Boolean = true,
    dismiss: String? = null,
    onDismissButton: (() -> Unit)? = null,
    extra: (@Composable () -> Unit)? = null,
) {
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(text)
                extra?.invoke()
            }
        },
        confirmButton = {
            TextButton(onClick = onConfirm, enabled = !busy && confirmEnabled) {
                if (busy) {
                    val label = stringResource(R.string.loading)
                    CircularProgressIndicator(
                        strokeWidth = 2.dp,
                        modifier = Modifier
                            .size(18.dp)
                            .semantics { contentDescription = label },
                    )
                } else {
                    Text(confirm, color = if (danger) MaterialTheme.colorScheme.error else Color.Unspecified)
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismissButton ?: onDismiss, enabled = !busy) {
                Text(dismiss ?: stringResource(R.string.action_cancel))
            }
        },
    )
}

@Composable
private fun StopAllDoneDialog(result: StopAllResult, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.devices_stop_all_done_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(stringResource(R.string.devices_stop_all_done_runs, result.runsCancelled))
                Text(stringResource(R.string.devices_stop_all_done_grants, result.grantsRevoked))
                Text(stringResource(R.string.devices_stop_all_done_plans, result.plansPaused))
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_ok)) } },
    )
}
