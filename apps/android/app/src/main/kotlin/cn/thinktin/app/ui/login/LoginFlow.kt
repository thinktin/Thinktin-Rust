package cn.thinktin.app.ui.login

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDropDown
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import cn.thinktin.app.R
import cn.thinktin.app.navigation.Routes
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.status.LoginFrozenScreen
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing
import cn.thinktin.design.theme.ThinktinTextStyles
import kotlinx.coroutines.launch

/**
 * 未登录时替换整个主区的独立导航图（第 3 节）：login（手机号）→ login/code（验证码），
 * 账号被冻结时 → login/frozen。两步共用一个 [LoginViewModel]。
 */
@Composable
fun LoginFlow() {
    val container = LocalAppContainer.current
    val service = LocalThinktinService.current
    // 挂在 Activity 上（不是导航项上）：两页共用，旋转不丢；每次新进登录流 reset 一次。
    val viewModel: LoginViewModel = viewModel(
        key = "login-${System.identityHashCode(service)}",
        factory = viewModelFactory {
            initializer { LoginViewModel(service, onSignedIn = { user -> container.syncServerLocale(service, user) }) }
        },
    )
    // 新进登录流（不是旋转后恢复）时清掉上一次的号码和倒计时：rememberSaveable 的初始化只在没有保存的状态时跑。
    rememberSaveable(viewModel) {
        viewModel.reset()
        true
    }
    val navController = rememberNavController()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    val retryLabel = stringResource(R.string.action_retry)
    LaunchedEffect(viewModel, navController) {
        viewModel.events.collect { event ->
            when (event) {
                LoginEvent.ShowCodeStep -> navController.navigateOnce(Routes.LOGIN_CODE)
                LoginEvent.Frozen -> navController.navigateOnce(Routes.LOGIN_FROZEN)
                is LoginEvent.Message -> launch {
                    val result = snackbar.showSnackbar(
                        message = context.getString(event.text.resId, *event.text.args.toTypedArray()),
                        actionLabel = if (event.retry != null) retryLabel else null,
                        duration = if (event.retry != null) SnackbarDuration.Long else SnackbarDuration.Short,
                    )
                    if (result == SnackbarResult.ActionPerformed) event.retry?.invoke()
                }
            }
        }
    }
    NavHost(navController = navController, startDestination = Routes.LOGIN) {
        composable(Routes.LOGIN) {
            PhoneScreen(
                viewModel = viewModel,
                snackbar = snackbar,
                demoAllowed = container.demoAllowed,
                onUseDemo = { container.launchSetDemoMode(true) },
            )
        }
        composable(Routes.LOGIN_CODE) {
            CodeScreen(viewModel = viewModel, snackbar = snackbar, onBack = { navController.popBackStack() })
        }
        composable(Routes.LOGIN_FROZEN) {
            LoginFrozenScreen(onBack = { navController.popBackStack(Routes.LOGIN, inclusive = false) })
        }
    }
}

private fun NavHostController.navigateOnce(route: String) {
    if (currentDestination?.route == route) return
    navigate(route) { launchSingleTop = true }
}

/** 第一步：手机号（第 4.1 节）。 */
@Composable
private fun PhoneScreen(
    viewModel: LoginViewModel,
    snackbar: SnackbarHostState,
    demoAllowed: Boolean,
    onUseDemo: () -> Unit,
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = { ThinktinTopBar(title = stringResource(R.string.page_login)) },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                // Scaffold 的 padding 已经含导航栏：先记为已消费，键盘弹起时 imePadding 只补差值。
                .consumeWindowInsets(padding)
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(ThinktinSpacing.Page),
            verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
        ) {
            Text(
                text = stringResource(R.string.login_welcome),
                style = ThinktinTextStyles.Greeting,
                modifier = Modifier
                    .padding(top = 32.dp)
                    .semantics { heading() },
            )
            Text(
                text = stringResource(R.string.login_subtitle),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(top = 16.dp),
            ) {
                RegionPicker(region = state.region, onSelect = viewModel::onRegionChange)
                val phoneLabel = stringResource(R.string.login_phone_label)
                val error = state.phoneError ?: if (state.coolingDown && state.rateLimited) {
                    UiText(R.string.error_rate_limited, listOf(state.cooldownSecs))
                } else {
                    null
                }
                OutlinedTextField(
                    value = state.phone,
                    onValueChange = viewModel::onPhoneChange,
                    label = { Text(phoneLabel) },
                    singleLine = true,
                    isError = error != null,
                    supportingText = error?.let { text ->
                        {
                            Text(
                                text = text.asString(),
                                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                            )
                        }
                    },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone, imeAction = ImeAction.Next),
                    keyboardActions = KeyboardActions(onNext = { viewModel.requestCode() }),
                    modifier = Modifier
                        .weight(1f)
                        .semantics { contentDescription = phoneLabel },
                )
            }
            PrimaryButton(
                text = stringResource(R.string.login_get_code),
                onClick = viewModel::requestCode,
                enabled = state.canRequestCode,
                loading = state.sending,
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                text = stringResource(R.string.login_agreement),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp),
            )
            // 演示模式只在 debug 包里提供（第 7 节）：release 进去了就回不到真实账号。
            if (demoAllowed) {
                TextButton(onClick = onUseDemo, modifier = Modifier.align(Alignment.CenterHorizontally)) {
                    Text(stringResource(R.string.login_use_demo))
                }
            }
        }
    }
}

/** 国家 / 地区码选择（默认 +86）。 */
@Composable
private fun RegionPicker(region: PhoneRegion, onSelect: (PhoneRegion) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val description = stringResource(R.string.login_region_description, stringResource(region.labelRes), region.dialCode)
    Box(modifier = Modifier.padding(top = 8.dp)) {
        OutlinedButton(
            onClick = { expanded = true },
            modifier = Modifier.semantics { contentDescription = description },
        ) {
            Text("+${region.dialCode}")
            Icon(Icons.Outlined.ArrowDropDown, contentDescription = null)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            PhoneRegion.entries.forEach { option ->
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.login_region_option, stringResource(option.labelRes), option.dialCode)) },
                    onClick = {
                        expanded = false
                        onSelect(option)
                    },
                )
            }
        }
    }
}

/** 第二步：6 位验证码，自动聚焦，满 6 位自动提交，60 秒倒计时重发，可以改号码。 */
@Composable
private fun CodeScreen(viewModel: LoginViewModel, snackbar: SnackbarHostState, onBack: () -> Unit) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_login_code),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.login_change_phone),
                onNavigationClick = onBack,
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                // Scaffold 的 padding 已经含导航栏：先记为已消费，键盘弹起时 imePadding 只补差值。
                .consumeWindowInsets(padding)
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(ThinktinSpacing.Page),
            verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
        ) {
            Text(
                text = stringResource(R.string.login_code_title),
                style = ThinktinTextStyles.Greeting,
                modifier = Modifier
                    .padding(top = 32.dp)
                    .semantics { heading() },
            )
            Text(
                text = stringResource(R.string.login_code_sent_to, state.sentToDisplay),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            val codeLabel = stringResource(R.string.login_code_label)
            val error = state.codeError ?: if (state.rateLimited && state.cooldownSecs > 0) {
                UiText(R.string.error_rate_limited, listOf(state.cooldownSecs))
            } else {
                null
            }
            OutlinedTextField(
                value = state.code,
                onValueChange = viewModel::onCodeChange,
                label = { Text(codeLabel) },
                singleLine = true,
                enabled = !state.verifying,
                isError = error != null,
                supportingText = error?.let { text ->
                    {
                        Text(
                            text = text.asString(),
                            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                        )
                    }
                },
                textStyle = TextStyle(fontSize = 24.sp, letterSpacing = 8.sp),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { viewModel.submit() }),
                modifier = Modifier
                    .fillMaxWidth()
                    .focusRequester(focus)
                    .semantics { contentDescription = codeLabel },
            )
            if (state.verifying) {
                val verifying = stringResource(R.string.login_verifying)
                LinearProgressIndicator(
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = verifying },
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                TextButton(onClick = viewModel::resend, enabled = state.canResend) {
                    Text(
                        if (state.cooldownSecs > 0) {
                            stringResource(R.string.login_resend_in, state.cooldownSecs)
                        } else {
                            stringResource(R.string.login_resend)
                        },
                    )
                }
                Box(Modifier.weight(1f))
                TextButton(onClick = onBack) { Text(stringResource(R.string.login_change_phone)) }
            }
        }
    }
}
