package cn.thinktin.app.ui.account

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.Countdown
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.isInvalid
import cn.thinktin.app.ui.common.isRateLimited
import cn.thinktin.app.ui.common.retryAfterSeconds
import cn.thinktin.data.model.SelfCodePurpose
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import cn.thinktin.design.component.DangerButton
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** 注销账号的三步（16.4）：说明后果 → 输入发到本人手机的验证码 → 最后确认。 */
enum class DeleteStep { Explain, Code, Confirm }

data class DeleteAccountUiState(
    val step: DeleteStep = DeleteStep.Explain,
    val code: String = "",
    val error: UiText? = null,
    val busy: Boolean = false,
    /** 重发验证码的倒计时（限频时是服务端给的剩余秒数）。 */
    val resendInSecs: Int = 0,
    /** 演示模式不能注销（关掉演示模式即可）。 */
    val isDemo: Boolean = false,
)

/**
 * 注销账号（13.2，路由 account/delete）：三步确认，说明不可恢复、保险箱的加密密钥（DEK）一并销毁。
 * 成功后服务变成未登录（client-core 清掉本地登录态和缓存），AppRoot 回登录页，这里不用管跳转。
 */
class DeleteAccountViewModel(private val service: ThinktinService) : ViewModel() {
    private val state = MutableStateFlow(DeleteAccountUiState(isDemo = service.isDemo))
    val uiState: StateFlow<DeleteAccountUiState> = state.asStateFlow()

    private val countdown = Countdown(viewModelScope) { left -> state.update { it.copy(resendInSecs = left) } }

    /** 第一步“发送验证码”，也是第二步的“重新获取”。 */
    fun sendCode() {
        val current = state.value
        if (current.isDemo || current.busy || current.resendInSecs > 0) return
        state.update { it.copy(busy = true, error = null) }
        viewModelScope.launch {
            try {
                service.sendSelfCode(SelfCodePurpose.DeleteAccount)
                state.update { it.copy(busy = false, step = DeleteStep.Code) }
                countdown.start(RESEND_SECONDS)
            } catch (e: ServiceError) {
                val secs = (e as? ServiceError.Api)?.takeIf { it.isRateLimited }?.retryAfterSeconds
                // 限频：可能已经发过（比如刚才发了又退出来），进第二步填码，倒计时到能再发。
                state.update {
                    it.copy(
                        busy = false,
                        step = if (secs != null) DeleteStep.Code else it.step,
                        error = ErrorText.of(e),
                    )
                }
                if (secs != null) countdown.start(secs)
            }
        }
    }

    fun onCodeChange(input: String) {
        state.update { it.copy(code = input.filter(Char::isDigit).take(CODE_LENGTH), error = null) }
    }

    /** 第二步“下一步”：验证码满 6 位才进最后确认。 */
    fun next() {
        val current = state.value
        if (current.step != DeleteStep.Code) return
        if (current.code.length != CODE_LENGTH) {
            state.update { it.copy(error = UiText(R.string.login_code_incomplete)) }
            return
        }
        state.update { it.copy(step = DeleteStep.Confirm, error = null) }
    }

    /** 第三步回到第二步。 */
    fun back() {
        state.update { if (it.step == DeleteStep.Confirm && !it.busy) it.copy(step = DeleteStep.Code) else it }
    }

    /**
     * 第三步“永久注销”。只有验证码不对（invalid）才回到第二步清空重填；断网、超时、5xx、限频时验证码多半
     * 仍然有效，留在这一步、保留验证码，用户可以再点一次重试。
     */
    fun confirm() {
        val current = state.value
        if (current.step != DeleteStep.Confirm || current.busy) return
        state.update { it.copy(busy = true, error = null) }
        viewModelScope.launch {
            try {
                service.deleteAccount(current.code)
                countdown.cancel()
                state.update { it.copy(busy = false) }
            } catch (e: ServiceError) {
                if (e is ServiceError.Api && e.isInvalid) {
                    state.update {
                        it.copy(busy = false, step = DeleteStep.Code, code = "", error = UiText(R.string.login_code_invalid))
                    }
                } else {
                    state.update { it.copy(busy = false, error = ErrorText.of(e)) }
                }
            }
        }
    }

    companion object {
        const val CODE_LENGTH: Int = 6
        const val RESEND_SECONDS: Int = 60
    }
}

@Composable
fun DeleteAccountScreen(onBack: () -> Unit) {
    val service = LocalThinktinService.current
    val viewModel: DeleteAccountViewModel = viewModel(
        factory = viewModelFactory { initializer { DeleteAccountViewModel(service) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.account_delete),
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
                // Scaffold 的 padding 已经含导航栏：先记为已消费，键盘弹起时 imePadding 只补差值。
                .consumeWindowInsets(padding)
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(ThinktinSpacing.Page),
            verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
        ) {
            val (title, message) = when (state.step) {
                DeleteStep.Explain -> R.string.account_delete_step1_title to R.string.account_delete_step1_message
                DeleteStep.Code -> R.string.account_delete_step2_title to R.string.account_delete_step2_message
                DeleteStep.Confirm -> R.string.account_delete_step3_title to R.string.account_delete_step3_message
            }
            Text(
                text = stringResource(title),
                // 衬线只用于 28–34sp：headlineMedium 是衬线 28sp。
                style = MaterialTheme.typography.headlineMedium,
                modifier = Modifier.semantics { heading() },
            )
            Text(stringResource(message), style = MaterialTheme.typography.bodyLarge)
            if (state.isDemo) {
                Text(
                    stringResource(R.string.account_delete_demo),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium,
                )
                return@Column
            }
            if (state.step == DeleteStep.Code) {
                val label = stringResource(R.string.login_code_label)
                OutlinedTextField(
                    value = state.code,
                    onValueChange = viewModel::onCodeChange,
                    label = { Text(label) },
                    singleLine = true,
                    isError = state.error != null,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Next),
                    keyboardActions = KeyboardActions(onNext = { viewModel.next() }),
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = label },
                )
                TextButton(onClick = viewModel::sendCode, enabled = !state.busy && state.resendInSecs == 0) {
                    Text(
                        if (state.resendInSecs > 0) {
                            stringResource(R.string.login_resend_in, state.resendInSecs)
                        } else {
                            stringResource(R.string.login_resend)
                        },
                    )
                }
            }
            state.error?.let { error ->
                Text(
                    text = error.asString(),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
            val (action, onAction) = when (state.step) {
                DeleteStep.Explain -> R.string.account_delete_send_code to viewModel::sendCode
                DeleteStep.Code -> R.string.action_next to viewModel::next
                DeleteStep.Confirm -> R.string.account_delete_confirm to viewModel::confirm
            }
            DangerButton(
                text = stringResource(action),
                onClick = onAction,
                loading = state.busy,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp),
            )
            SecondaryButton(
                text = stringResource(if (state.step == DeleteStep.Confirm) R.string.action_previous else R.string.action_cancel),
                onClick = if (state.step == DeleteStep.Confirm) viewModel::back else onBack,
                enabled = !state.busy,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
