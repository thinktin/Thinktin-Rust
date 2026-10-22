package cn.thinktin.app.ui.login

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import cn.thinktin.app.R
import cn.thinktin.app.navigation.Routes
import cn.thinktin.app.settings.AppSettingsRepository
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing
import cn.thinktin.design.theme.ThinktinTextStyles
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class LoginUiState(val step: LoginStep)

enum class LoginStep { Phone, Code }

/** 登录流的 ViewModel（13.2 接手机号与验证码）。现在只能切到演示模式。 */
class LoginViewModel(step: LoginStep, private val settings: AppSettingsRepository) : ViewModel() {
    private val state = MutableStateFlow(LoginUiState(step))
    val uiState: StateFlow<LoginUiState> = state.asStateFlow()

    fun useDemo() {
        viewModelScope.launch { settings.setDemoMode(true) }
    }
}

/** 未登录时替换整个主区的独立导航图：login → login/code。 */
@Composable
fun LoginFlow() {
    val navController = rememberNavController()
    NavHost(navController = navController, startDestination = Routes.LOGIN) {
        composable(Routes.LOGIN) {
            LoginScreen(step = LoginStep.Phone, onNext = { navController.navigate(Routes.LOGIN_CODE) }, onBack = null)
        }
        composable(Routes.LOGIN_CODE) {
            LoginScreen(step = LoginStep.Code, onNext = {}, onBack = { navController.popBackStack() })
        }
    }
}

@Composable
private fun LoginScreen(step: LoginStep, onNext: () -> Unit, onBack: (() -> Unit)?) {
    val container = LocalAppContainer.current
    val viewModel: LoginViewModel = viewModel(
        key = "login-${step.name}",
        factory = viewModelFactory { initializer { LoginViewModel(step, container.settingsRepository) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            ThinktinTopBar(
                title = stringResource(if (state.step == LoginStep.Phone) R.string.page_login else R.string.page_login_code),
                navigationIcon = if (onBack != null) TopBarIcons.Back else null,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = { onBack?.invoke() },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(ThinktinSpacing.Page),
            verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = stringResource(R.string.login_welcome),
                style = ThinktinTextStyles.Greeting,
                textAlign = TextAlign.Center,
                modifier = Modifier.semantics { heading() },
            )
            Text(
                text = stringResource(if (container.demoAllowed) R.string.login_coming_soon else R.string.login_coming_soon_plain),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            if (state.step == LoginStep.Phone) {
                OutlinedButton(onClick = onNext) { Text(stringResource(R.string.login_next)) }
            }
            // 演示模式只在 debug 包里提供（第 7 节）：release 进去了就回不到真实账号。
            if (container.demoAllowed) {
                PrimaryButton(text = stringResource(R.string.login_use_demo), onClick = viewModel::useDemo)
            }
        }
    }
}
