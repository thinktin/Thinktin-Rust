package cn.thinktin.app.ui.status

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Block
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.service.AuthState
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import cn.thinktin.data.service.logoutQuietly
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.theme.ThinktinSpacing
import cn.thinktin.design.theme.ThinktinTextStyles
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch

data class FrozenUiState(val checking: Boolean = false, val signingOut: Boolean = false)

/**
 * 已登录的账号被冻结（接口或事件流返回 AccountFrozen，[AuthState.Frozen]）：登录状态保留，提示联系客服；
 * “重新检查”取一次自己的资料，解冻了服务就回到已登录（主界面）；也可以退出登录。
 */
class FrozenViewModel(private val service: ThinktinService) : ViewModel() {
    private val state = MutableStateFlow(FrozenUiState())
    val uiState: StateFlow<FrozenUiState> = state.asStateFlow()

    private val messageChannel = Channel<UiText>(Channel.BUFFERED)
    val messages: Flow<UiText> = messageChannel.receiveAsFlow()

    fun checkAgain() {
        if (state.value.checking) return
        state.value = state.value.copy(checking = true)
        viewModelScope.launch {
            val message = try {
                service.me()
                if (service.authState.value == AuthState.Frozen) UiText(R.string.frozen_still) else null
            } catch (_: ServiceError.AccountFrozen) {
                UiText(R.string.frozen_still)
            } catch (e: ServiceError) {
                ErrorText.of(e)
            }
            state.value = state.value.copy(checking = false)
            message?.let { messageChannel.send(it) }
        }
    }

    fun signOut() {
        if (state.value.signingOut) return
        state.value = state.value.copy(signingOut = true)
        viewModelScope.launch {
            service.logoutQuietly()
            state.value = state.value.copy(signingOut = false)
        }
    }
}

/** 已登录时的冻结页（AppRoot 按 [AuthState.Frozen] 显示）。 */
@Composable
fun FrozenAccountScreen(service: ThinktinService) {
    val viewModel: FrozenViewModel = viewModel(
        key = "frozen-${System.identityHashCode(service)}",
        factory = viewModelFactory { initializer { FrozenViewModel(service) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.messages.collect { snackbar.showSnackbar(context.getString(it.resId, *it.args.toTypedArray())) }
    }
    FrozenScreen(
        message = stringResource(R.string.frozen_message),
        snackbar = snackbar,
        primaryLabel = stringResource(R.string.frozen_check_again),
        primaryLoading = state.checking,
        onPrimary = viewModel::checkAgain,
        secondaryLabel = stringResource(R.string.action_sign_out),
        onSecondary = viewModel::signOut,
    )
}

/**
 * 冻结说明（第 4.1 节、8.1 节）：图标、衬线标题、说明（联系客服）、主操作和次操作。
 * 已登录时是“重新检查 / 退出登录”，登录时被拒是“返回”（还没有登录态）。
 */
@Composable
fun FrozenScreen(
    message: String,
    primaryLabel: String,
    onPrimary: () -> Unit,
    modifier: Modifier = Modifier,
    snackbar: SnackbarHostState = remember { SnackbarHostState() },
    primaryLoading: Boolean = false,
    secondaryLabel: String? = null,
    onSecondary: () -> Unit = {},
) {
    Scaffold(
        modifier = modifier,
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(ThinktinSpacing.Page),
            verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(
                imageVector = Icons.Outlined.Block,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(bottom = 8.dp),
            )
            Text(
                text = stringResource(R.string.frozen_title),
                style = ThinktinTextStyles.Greeting,
                textAlign = TextAlign.Center,
                modifier = Modifier.semantics { heading() },
            )
            Text(
                text = message,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            Text(
                text = stringResource(R.string.frozen_contact),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            PrimaryButton(
                text = primaryLabel,
                onClick = onPrimary,
                loading = primaryLoading,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = ThinktinSpacing.Paragraph),
            )
            if (secondaryLabel != null) {
                OutlinedButton(onClick = onSecondary, modifier = Modifier.fillMaxWidth()) { Text(secondaryLabel) }
            }
        }
    }
}

/** 登录时服务端说账号被冻结（没有登录态）：说明 + 返回登录页。 */
@Composable
fun LoginFrozenScreen(onBack: () -> Unit) {
    FrozenScreen(
        message = stringResource(R.string.frozen_login_message),
        primaryLabel = stringResource(R.string.frozen_back_to_login),
        onPrimary = onBack,
    )
}
