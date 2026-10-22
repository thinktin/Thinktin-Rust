package cn.thinktin.app.ui.placeholder

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** 还没做的页面（13.2–13.14 逐个替换成真页面）。 */
enum class Page(@StringRes val titleRes: Int) {
    Chat(R.string.page_chat),
    Run(R.string.page_run),
    ModelRoutes(R.string.page_model_routes),
    Plans(R.string.page_plans),
    Plan(R.string.page_plan),
    Teams(R.string.page_teams),
    Team(R.string.page_team),
    Inbox(R.string.page_inbox),
    Approvals(R.string.page_approvals),
    Approval(R.string.page_approval),
    Keys(R.string.page_keys),
    Vault(R.string.page_vault),
}

data class ComingSoonUiState(val page: Page, val argument: String?)

/** 骨架页的 ViewModel：每个页面一个实例，真页面做出来后换成各自的 ViewModel。 */
class ComingSoonViewModel(page: Page, argument: String?) : ViewModel() {
    private val state = MutableStateFlow(ComingSoonUiState(page, argument))
    val uiState: StateFlow<ComingSoonUiState> = state.asStateFlow()
}

/** 骨架页：顶栏（返回）+ 标题 + “即将推出”。[actions] 是顶栏右侧的按钮（对话页的“实例设置”）。 */
@Composable
fun ComingSoonScreen(
    page: Page,
    argument: String?,
    onBack: () -> Unit,
    actions: @Composable RowScope.() -> Unit = {},
    viewModel: ComingSoonViewModel = viewModel(
        key = "coming-soon-${page.name}-$argument",
        factory = viewModelFactory { initializer { ComingSoonViewModel(page, argument) } },
    ),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            ThinktinTopBar(
                title = stringResource(state.page.titleRes),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
                actions = actions,
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(ThinktinSpacing.Page),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            EmptyState(
                title = stringResource(R.string.coming_soon_title),
                message = stringResource(R.string.coming_soon_message),
            )
            state.argument?.let {
                Text(
                    text = stringResource(R.string.coming_soon_argument, it),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
