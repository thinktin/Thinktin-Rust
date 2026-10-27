package cn.thinktin.app.ui.login

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.push.PushToken
import cn.thinktin.app.ui.common.Countdown
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.isInvalid
import cn.thinktin.app.ui.common.isRateLimited
import cn.thinktin.app.ui.common.isRetryable
import cn.thinktin.app.ui.common.retryAfterSeconds
import cn.thinktin.data.model.User
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class LoginUiState(
    val region: PhoneRegion = PhoneRegion.Default,
    /** 输入框里的号码（原样，可能带空格）。 */
    val phone: String = "",
    /** 手机号的字段级提示（格式不对、服务端说不合法）。 */
    val phoneError: UiText? = null,
    /** 验证码发到了哪个号码（E.164）；没发过为 null。 */
    val sentTo: String? = null,
    /** 页面上显示的号码（+86 13800138000）。 */
    val sentToDisplay: String = "",
    val code: String = "",
    /** 验证码的字段级提示（错误或过期、注册限频）。 */
    val codeError: UiText? = null,
    val sending: Boolean = false,
    val verifying: Boolean = false,
    /** 倒计时剩余秒数：发码成功后 60 秒内不能重发，限频时是服务端给的剩余秒数。 */
    val cooldownSecs: Int = 0,
    /** 倒计时对哪个号码（E.164）生效：限频按号码算，换了号码可以马上发。 */
    val cooldownPhone: String? = null,
    /** 倒计时是因为限频（显示“请 N 秒后再试”），不是正常的重发间隔。 */
    val rateLimited: Boolean = false,
) {
    val phoneValid: Boolean get() = region.isValid(phone)

    /** 倒计时对输入框里这个号码生效。 */
    val coolingDown: Boolean get() = cooldownSecs > 0 && cooldownPhone == region.e164(phone)

    /** 手机号页的“获取验证码”可以点（同一个号码还在正常的重发间隔里也能点：直接回到验证码页，不再发）。 */
    val canRequestCode: Boolean get() = !sending && !(coolingDown && rateLimited)

    /** 验证码页可以重发。 */
    val canResend: Boolean get() = !sending && !verifying && cooldownSecs == 0 && sentTo != null
}

/** 一次性事件。 */
sealed interface LoginEvent {
    /** 验证码发出去了（或同一号码还在重发间隔里）：进验证码页。 */
    data object ShowCodeStep : LoginEvent

    /** 账号被冻结：进冻结说明页。 */
    data object Frozen : LoginEvent

    /** Snackbar；[retry] 不为空时带“重试”。 */
    data class Message(val text: UiText, val retry: (() -> Unit)? = null) : LoginEvent
}

/**
 * 登录流（login → login/code）共用的 ViewModel：两步共用号码、倒计时，所以整个登录流一个，不按页面拆。
 *
 * 错误映射（第 4.1 节）：rate_limited 显示剩余秒数（发码时倒计时）；account_frozen 进冻结页；网络错误用 Snackbar 并可重试；
 * invalid 按当前步骤做字段级提示（手机号页是号码不对，验证码页是验证码错误或过期——服务端两者都报 invalid，不区分）。
 *
 * 登录成功后 [ThinktinService.authState] 变成已登录，界面由 AppRoot 换成主界面（暂存的深链在那里处理）；
 * [onSignedIn] 再同步服务端语言（App 级的作用域，见 AppContainer.syncServerLocale）。
 */
class LoginViewModel(
    private val service: ThinktinService,
    private val onSignedIn: (User) -> Unit = {},
    /** 登录时带上的推送令牌（13.8，推送 SDK 给的；还没有就登录后再报）。 */
    private val pushToken: () -> PushToken? = { null },
) : ViewModel() {
    private val state = MutableStateFlow(LoginUiState())
    val uiState: StateFlow<LoginUiState> = state.asStateFlow()

    private val eventChannel = Channel<LoginEvent>(Channel.BUFFERED)
    val events: Flow<LoginEvent> = eventChannel.receiveAsFlow()

    private val countdown = Countdown(viewModelScope) { left ->
        state.update { it.copy(cooldownSecs = left, rateLimited = it.rateLimited && left > 0) }
    }

    /**
     * 回到初始状态（新的一次登录流）。这个 ViewModel 挂在 Activity 上（旋转屏幕不丢号码和倒计时，登录成功后
     * 界面切走也不会把还没跑完的 [onSignedIn] 取消掉），所以每次重新进登录流时由界面调一次。
     */
    fun reset() {
        countdown.cancel()
        state.value = LoginUiState()
    }

    fun onRegionChange(region: PhoneRegion) {
        state.update { it.copy(region = region, phoneError = null) }
    }

    /** 只收数字、空格和横线，最多 [PhoneRegion.MAX_INPUT_DIGITS] 位数字。 */
    fun onPhoneChange(input: String) {
        val cleaned = input.filter { it.isDigit() || it == ' ' || it == '-' }
        if (cleaned.count(Char::isDigit) > PhoneRegion.MAX_INPUT_DIGITS) return
        state.update { it.copy(phone = cleaned, phoneError = null) }
    }

    /** 手机号页的“获取验证码”。 */
    fun requestCode() {
        val current = state.value
        if (!current.phoneValid) {
            state.update { it.copy(phoneError = UiText(R.string.login_phone_invalid)) }
            return
        }
        if (!current.canRequestCode) return
        val phone = current.region.e164(current.phone)
        // 同一个号码刚发过、还在重发间隔里：直接回验证码页，不再发（服务端也会限频）。
        if (current.coolingDown && phone == current.sentTo) {
            eventChannel.trySend(LoginEvent.ShowCodeStep)
            return
        }
        send(phone, current.region.display(current.phone), Op.SendFromPhone)
    }

    /** 验证码页的“重新获取”。 */
    fun resend() {
        val current = state.value
        val phone = current.sentTo ?: return
        if (!current.canResend) return
        send(phone, current.sentToDisplay, Op.Resend)
    }

    private fun send(phone: String, display: String, op: Op) {
        state.update { it.copy(sending = true, phoneError = null) }
        viewModelScope.launch {
            try {
                service.sendCode(phone)
                state.update {
                    it.copy(
                        sending = false,
                        sentTo = phone,
                        sentToDisplay = display,
                        code = if (op == Op.SendFromPhone || it.sentTo != phone) "" else it.code,
                        codeError = null,
                        cooldownPhone = phone,
                        rateLimited = false,
                    )
                }
                countdown.start(RESEND_SECONDS)
                if (op == Op.SendFromPhone) {
                    eventChannel.send(LoginEvent.ShowCodeStep)
                } else {
                    eventChannel.send(LoginEvent.Message(UiText(R.string.login_code_resent)))
                }
            } catch (e: ServiceError) {
                state.update { it.copy(sending = false) }
                fail(e, op, phone) { send(phone, display, op) }
            }
        }
    }

    /** 只收数字，最多 6 位；满 6 位自动提交。 */
    fun onCodeChange(input: String) {
        val digits = input.filter(Char::isDigit).take(CODE_LENGTH)
        if (state.value.verifying) return
        state.update { it.copy(code = digits, codeError = null) }
        if (digits.length == CODE_LENGTH) submit()
    }

    /** 提交验证码登录（带上推送令牌，13.8）。 */
    fun submit() {
        val current = state.value
        val phone = current.sentTo ?: return
        if (current.verifying || current.code.length != CODE_LENGTH) return
        val code = current.code
        state.update { it.copy(verifying = true, codeError = null) }
        viewModelScope.launch {
            try {
                val push = pushToken()
                val result = service.login(phone, code, pushChannel = push?.channel, pushToken = push?.token)
                countdown.cancel()
                state.update { it.copy(verifying = false) }
                onSignedIn(result.user)
            } catch (e: ServiceError) {
                state.update { it.copy(verifying = false) }
                fail(e, Op.Login, phone) { submit() }
            }
        }
    }

    /** 出错的是哪个操作：决定字段级提示落在哪个输入框。 */
    private enum class Op { SendFromPhone, Resend, Login }

    private suspend fun fail(error: ServiceError, op: Op, phone: String, retry: () -> Unit) {
        when {
            error is ServiceError.AccountFrozen -> eventChannel.send(LoginEvent.Frozen)
            error is ServiceError.Api && error.isRateLimited -> rateLimited(error, op, phone)
            error is ServiceError.Api && error.isInvalid && op == Op.SendFromPhone ->
                state.update { it.copy(phoneError = UiText(R.string.login_phone_invalid)) }
            // 验证码错误或过期：清空重输（输入框保持焦点）。
            error is ServiceError.Api && error.isInvalid && op == Op.Login ->
                state.update { it.copy(code = "", codeError = UiText(R.string.login_code_invalid)) }
            else -> eventChannel.send(
                LoginEvent.Message(ErrorText.of(error), retry = if (error.isRetryable) retry else null),
            )
        }
    }

    private fun rateLimited(error: ServiceError.Api, op: Op, phone: String) {
        val secs = error.retryAfterSeconds
        when {
            // 登录时限频（同一网络新注册太多）：提示剩余秒数，验证码保留，过一会儿再点登录。
            op == Op.Login -> state.update { it.copy(codeError = ErrorText.of(error)) }
            // 发码限频：倒计时到能再发，界面上的剩余秒数跟着走。
            secs != null -> {
                state.update { it.copy(cooldownPhone = phone, rateLimited = true) }
                countdown.start(secs)
            }
            // 服务端没给秒数：只提示“稍后再试”。
            op == Op.SendFromPhone -> state.update { it.copy(phoneError = ErrorText.of(error)) }
            else -> state.update { it.copy(codeError = ErrorText.of(error)) }
        }
    }

    companion object {
        const val CODE_LENGTH: Int = 6

        /** 重发验证码的间隔（和服务端的 code_resend_interval 一致）。 */
        const val RESEND_SECONDS: Int = 60
    }
}
