package cn.thinktin.app.ui.privacy

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import cn.thinktin.app.R
import cn.thinktin.app.settings.AppSettingsRepository
import cn.thinktin.app.ui.common.ConfirmDialog
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.data.service.ThinktinService
import cn.thinktin.data.service.logoutQuietly
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class PrivacyInfoUiState(val confirmWithdraw: Boolean = false, val withdrawing: Boolean = false)

/** 撤回同意（13.11）：真实账号先退出登录（client-core 清掉登录态和缓存），再记下没同意，根界面换回隐私政策页。 */
class PrivacyInfoViewModel(
    private val repository: AppSettingsRepository,
    private val service: ThinktinService,
) : ViewModel() {
    private val state = MutableStateFlow(PrivacyInfoUiState())
    val uiState: StateFlow<PrivacyInfoUiState> = state.asStateFlow()

    fun askWithdraw() = state.update { it.copy(confirmWithdraw = true) }

    fun dismissWithdraw() = state.update { if (it.withdrawing) it else it.copy(confirmWithdraw = false) }

    fun withdraw() {
        if (state.value.withdrawing) return
        state.update { it.copy(withdrawing = true) }
        viewModelScope.launch {
            if (!service.isDemo) service.logoutQuietly()
            repository.withdrawPrivacy()
            state.update { it.copy(withdrawing = false, confirmWithdraw = false) }
        }
    }
}

/**
 * 个人信息与权限（13.11，设置 → 关于）：收集的个人信息、和第三方共享的、App 里的第三方 SDK、系统权限（要允许的显示现在
 * 允没允许，点了去系统设置）、撤回同意。
 */
@Composable
fun PrivacyInfoScreen(onBack: () -> Unit) {
    val container = LocalAppContainer.current
    val service = LocalThinktinService.current
    val context = LocalContext.current
    val viewModel: PrivacyInfoViewModel = viewModel(
        factory = viewModelFactory { initializer { PrivacyInfoViewModel(container.settingsRepository, service) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    // 从系统设置回来时重新看一遍权限。
    var resumes by remember { mutableIntStateOf(0) }
    LifecycleResumeEffect(Unit) {
        resumes++
        onPauseOrDispose {}
    }
    val permissions = remember(resumes) {
        PrivacyInfo.permissions(PrivacyInfo.requestedPermissions(context), context.packageName)
            .map { (permission, info) -> Triple(permission, info, PrivacyInfo.isGranted(context, permission)) }
    }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_privacy_info),
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
                .verticalScroll(rememberScrollState())
                .padding(bottom = 24.dp),
        ) {
            PrivacyListsContent()
            PrivacySection(R.string.privacy_section_permissions)
            permissions.forEach { (permission, info, granted) ->
                val status = when (granted) {
                    null -> stringResource(R.string.privacy_permission_install_time)
                    true -> stringResource(R.string.privacy_permission_granted)
                    false -> stringResource(R.string.privacy_permission_denied)
                }
                PrivacyItem(
                    title = info?.let { stringResource(it.name) } ?: permission,
                    lines = listOf(
                        stringResource(
                            R.string.privacy_item_purpose,
                            info?.let { stringResource(it.purpose) } ?: stringResource(R.string.privacy_perm_other_purpose),
                        ),
                        status,
                    ),
                    trailing = if (granted != null) {
                        { SystemSettingsButton { openAppSettings(context) } }
                    } else {
                        null
                    },
                )
            }
            PrivacySection(R.string.privacy_section_consent)
            ListItem(
                headlineContent = { Text(stringResource(R.string.privacy_withdraw), color = MaterialTheme.colorScheme.error) },
                supportingContent = { Text(stringResource(R.string.privacy_withdraw_summary)) },
                colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
                modifier = Modifier.clickable(role = Role.Button, onClick = viewModel::askWithdraw),
            )
            Text(
                text = stringResource(R.string.privacy_delete_hint),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
    }
    if (state.confirmWithdraw) {
        ConfirmDialog(
            title = stringResource(R.string.privacy_withdraw_title),
            text = stringResource(R.string.privacy_withdraw_message),
            confirm = stringResource(R.string.privacy_withdraw_confirm),
            onConfirm = viewModel::withdraw,
            onDismiss = viewModel::dismissWithdraw,
            danger = true,
            busy = state.withdrawing,
        )
    }
}

/** 系统设置里这个 App 的详情页（权限、通知都在里面）。 */
private fun openAppSettings(context: Context) {
    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    runCatching { context.startActivity(intent) }
}
