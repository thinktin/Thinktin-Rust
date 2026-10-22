package cn.thinktin.app.ui.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import cn.thinktin.data.service.ThinktinService
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.Appearance
import cn.thinktin.design.theme.ThinktinSpacing
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

data class SettingsUiState(
    val settings: AppSettings? = null,
    val userName: String? = null,
    val isDemo: Boolean = false,
)

/** 设置（13.13 做完整版）：现在有外观、演示模式（仅调试版）、退出登录。 */
class SettingsViewModel(
    private val repository: AppSettingsRepository,
    private val service: ThinktinService,
) : ViewModel() {
    private val user = flow {
        emit(null)
        emit(runCatching { service.me() }.getOrNull())
    }

    val uiState: StateFlow<SettingsUiState> = combine(repository.settings, user) { settings, me ->
        SettingsUiState(settings = settings, userName = me?.displayName ?: me?.phone, isDemo = service.isDemo)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SettingsUiState(isDemo = service.isDemo))

    fun setAppearance(appearance: Appearance) {
        viewModelScope.launch { repository.setAppearance(appearance) }
    }

    fun setDemoMode(enabled: Boolean) {
        viewModelScope.launch { repository.setDemoMode(enabled) }
    }

    fun signOut() {
        viewModelScope.launch { runCatching { service.logout() } }
    }
}

@Composable
fun SettingsScreen(onBack: () -> Unit) {
    val container = LocalAppContainer.current
    val service = LocalThinktinService.current
    val viewModel: SettingsViewModel = viewModel(
        factory = viewModelFactory { initializer { SettingsViewModel(container.settingsRepository, service) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
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
            state.userName?.let { name ->
                SectionHeader(
                    title = stringResource(R.string.settings_account),
                    modifier = Modifier.padding(horizontal = ThinktinSpacing.Page),
                )
                ListItem(
                    headlineContent = { Text(name) },
                    colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
                )
            }
            SectionHeader(
                title = stringResource(R.string.settings_appearance),
                modifier = Modifier.padding(horizontal = ThinktinSpacing.Page),
            )
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
            if (BuildConfig.DEBUG) {
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
            if (!state.isDemo) {
                OutlinedButton(
                    onClick = viewModel::signOut,
                    modifier = Modifier.padding(horizontal = ThinktinSpacing.Page),
                ) {
                    Text(stringResource(R.string.action_sign_out))
                }
            }
            Text(
                text = stringResource(R.string.settings_version, BuildConfig.VERSION_NAME, BuildConfig.DIST),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 24.dp),
            )
        }
    }
}
