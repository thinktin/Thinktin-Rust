package cn.thinktin.app.ui.devices

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.Countdown
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.isInvalid
import cn.thinktin.app.ui.common.isRateLimited
import cn.thinktin.data.model.DeviceInfo
import cn.thinktin.data.model.SelfCodePurpose
import cn.thinktin.data.model.StopAllResult
import cn.thinktin.data.model.User
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import cn.thinktin.data.service.logoutQuietly
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** 从设置页直接打开的操作（路由 `devices?action=…`）。 */
enum class DevicesAction(val wire: String) {
    EditProfile("edit_profile"),
    SignOutOthers("sign_out_others"),
    StopAll("stop_all"),
    DeleteAccount("delete_account"),
    ;

    companion object {
        fun fromWire(value: String?): DevicesAction? = entries.firstOrNull { it.wire == value }
    }
}

/** 注销账号的三步（16.4）：说明后果 → 输入发到本人手机的验证码 → 最后确认。 */
enum class DeleteStep { Explain, Code, Confirm }

/** 页面上同时只开一个对话框。 */
sealed interface DevicesDialog {
    /** 远程下线某台设备。 */
    data class Revoke(val device: DeviceInfo) : DevicesDialog

    /** 下线其他设备：先选要不要同时停止全部 agent，[confirming] 是第二次确认。 */
    data class SignOutOthers(val stopAgents: Boolean = false, val confirming: Boolean = false) : DevicesDialog

    /** 全部停止（危险操作）：[confirming] 是第二次确认。 */
    data class StopAll(val confirming: Boolean = false) : DevicesDialog

    /** 全部停止的结果（取消的运行、吊销的授权、暂停的计划）。 */
    data class StopAllDone(val result: StopAllResult) : DevicesDialog

    /** 退出登录（只下线本设备）。 */
    data object Logout : DevicesDialog

    /** 改昵称。 */
    data class EditName(val name: String, val error: UiText? = null) : DevicesDialog

    /** 注销账号。 */
    data class DeleteAccount(
        val step: DeleteStep = DeleteStep.Explain,
        val code: String = "",
        val error: UiText? = null,
        /** 重发验证码的倒计时。 */
        val resendInSecs: Int = 0,
    ) : DevicesDialog
}

data class DevicesUiState(
    val loading: Boolean = true,
    val user: User? = null,
    val devices: List<DeviceInfo> = emptyList(),
    /** 列表加载失败（页面上显示，带重试）。 */
    val loadError: UiText? = null,
    val dialog: DevicesDialog? = null,
    /** 对话框里的操作进行中（按钮转圈、不可重复点）。 */
    val busy: Boolean = false,
    /** 演示模式：没有退出登录和注销（关掉演示模式即可）。 */
    val isDemo: Boolean = false,
)

/**
 * 设备与账号（13.2，路由 devices）：设备列表、远程下线、下线其他设备（可选同时停止全部 agent）、全部停止、
 * 退出登录、注销账号、改昵称。结果和错误用 Snackbar（[messages]）。
 *
 * 下线本机、退出登录、注销成功后服务的登录状态变成未登录，AppRoot 换成登录流，这里不用管跳转。
 */
class DevicesViewModel(
    private val service: ThinktinService,
    initialAction: DevicesAction? = null,
) : ViewModel() {
    private val state = MutableStateFlow(DevicesUiState(isDemo = service.isDemo))
    val uiState: StateFlow<DevicesUiState> = state.asStateFlow()

    private val messageChannel = Channel<UiText>(Channel.BUFFERED)
    val messages: Flow<UiText> = messageChannel.receiveAsFlow()

    private val resendCountdown = Countdown(viewModelScope) { left ->
        state.update { s ->
            val dialog = s.dialog as? DevicesDialog.DeleteAccount ?: return@update s
            s.copy(dialog = dialog.copy(resendInSecs = left))
        }
    }

    /** 从设置页点“昵称”进来：等资料取到再开改昵称的对话框（要预填现在的昵称），见 [refresh]。 */
    private var pendingEditProfile = initialAction == DevicesAction.EditProfile

    init {
        when (initialAction) {
            DevicesAction.SignOutOthers -> askSignOutOthers()
            DevicesAction.StopAll -> askStopAll()
            DevicesAction.DeleteAccount -> startDeleteAccount()
            DevicesAction.EditProfile, null -> Unit
        }
        refresh()
    }

    fun refresh() {
        state.update { it.copy(loading = true, loadError = null) }
        viewModelScope.launch {
            try {
                // coroutineScope：一个失败时另一个跟着取消，异常在这里抛出（不会越过 try 交给 viewModelScope）。
                val (user, devices) = coroutineScope {
                    val user = async { service.me() }
                    val devices = async { service.devices() }
                    user.await() to devices.await()
                }
                state.update { it.copy(loading = false, user = user, devices = devices) }
                if (pendingEditProfile) {
                    pendingEditProfile = false
                    editName()
                }
            } catch (e: ServiceError) {
                state.update { it.copy(loading = false, loadError = ErrorText.of(e)) }
            }
        }
    }

    fun dismissDialog() {
        if (state.value.busy) return
        resendCountdown.cancel()
        state.update { it.copy(dialog = null) }
    }

    private fun open(dialog: DevicesDialog) {
        state.update { it.copy(dialog = dialog) }
    }

    private fun message(text: UiText) {
        messageChannel.trySend(text)
    }

    /** 跑一个对话框里的操作：busy 期间不能重复点、不能关；失败用 Snackbar 并关掉对话框。 */
    private fun runDialogAction(block: suspend () -> Unit) {
        if (state.value.busy) return
        state.update { it.copy(busy = true) }
        viewModelScope.launch {
            try {
                block()
            } catch (e: ServiceError) {
                state.update { it.copy(dialog = null) }
                message(ErrorText.of(e))
            } finally {
                state.update { it.copy(busy = false) }
            }
        }
    }

    // ---- 远程下线一台 ----

    fun askRevoke(device: DeviceInfo) = open(DevicesDialog.Revoke(device))

    fun confirmRevoke() {
        val dialog = state.value.dialog as? DevicesDialog.Revoke ?: return
        runDialogAction {
            service.revokeDevice(dialog.device.id)
            state.update { s -> s.copy(dialog = null, devices = s.devices.filterNot { it.id == dialog.device.id }) }
            message(UiText(R.string.devices_revoked, listOf(dialog.device.name)))
        }
    }

    // ---- 下线其他设备 ----

    fun askSignOutOthers() = open(DevicesDialog.SignOutOthers())

    fun setStopAgents(stop: Boolean) {
        state.update { s ->
            val dialog = s.dialog as? DevicesDialog.SignOutOthers ?: return@update s
            s.copy(dialog = dialog.copy(stopAgents = stop))
        }
    }

    /** 第一步“下线其他设备” → 第二次确认；第二次确认 → 执行。 */
    fun confirmSignOutOthers() {
        val dialog = state.value.dialog as? DevicesDialog.SignOutOthers ?: return
        if (!dialog.confirming) {
            open(dialog.copy(confirming = true))
            return
        }
        runDialogAction {
            val result = service.signOutOtherDevices(dialog.stopAgents)
            state.update { s -> s.copy(dialog = null, devices = s.devices.filter { it.current }) }
            val stopped = result.stopped
            message(
                if (stopped == null) {
                    UiText(R.string.devices_signed_out_others, listOf(result.devicesSignedOut))
                } else {
                    UiText(
                        R.string.devices_signed_out_others_and_stopped,
                        listOf(result.devicesSignedOut, stopped.runsCancelled, stopped.grantsRevoked, stopped.plansPaused),
                    )
                },
            )
            reloadDevices()
        }
    }

    private suspend fun reloadDevices() {
        try {
            val devices = service.devices()
            state.update { it.copy(devices = devices) }
        } catch (_: ServiceError) {
            // 列表已经按结果更新过了，刷新失败不提示。
        }
    }

    // ---- 全部停止 ----

    fun askStopAll() = open(DevicesDialog.StopAll())

    fun confirmStopAll() {
        val dialog = state.value.dialog as? DevicesDialog.StopAll ?: return
        if (!dialog.confirming) {
            open(dialog.copy(confirming = true))
            return
        }
        runDialogAction {
            val result = service.stopAll()
            open(DevicesDialog.StopAllDone(result))
        }
    }

    // ---- 退出登录 ----

    fun askLogout() = open(DevicesDialog.Logout)

    fun confirmLogout() {
        if (state.value.dialog != DevicesDialog.Logout) return
        runDialogAction {
            // 只下线本设备；本地缓存由 client-core 清。服务端失败（断网）也已经在本地退出。
            service.logoutQuietly()
            state.update { it.copy(dialog = null) }
        }
    }

    // ---- 昵称 ----

    fun editName() = open(DevicesDialog.EditName(state.value.user?.displayName.orEmpty()))

    fun onNameChange(name: String) {
        state.update { s ->
            val dialog = s.dialog as? DevicesDialog.EditName ?: return@update s
            s.copy(dialog = dialog.copy(name = name, error = null))
        }
    }

    fun saveName() {
        val dialog = state.value.dialog as? DevicesDialog.EditName ?: return
        val name = dialog.name.trim()
        if (name.codePointCount(0, name.length) > MAX_NAME_LENGTH) {
            open(dialog.copy(error = UiText(R.string.profile_name_too_long, listOf(MAX_NAME_LENGTH))))
            return
        }
        runDialogAction {
            // 清空 = 去掉昵称（服务端传 null）。
            val user = service.updateProfile(name.ifEmpty { null })
            state.update { it.copy(user = user, dialog = null) }
            message(UiText(R.string.profile_name_saved))
        }
    }

    // ---- 注销账号（三步） ----

    fun startDeleteAccount() {
        if (service.isDemo) return
        open(DevicesDialog.DeleteAccount())
    }

    /** 第一步“继续”：给本人手机号发验证码，进第二步。也用于第二步的重发。 */
    fun sendDeleteCode() {
        val dialog = state.value.dialog as? DevicesDialog.DeleteAccount ?: return
        if (state.value.busy || dialog.resendInSecs > 0) return
        state.update { it.copy(busy = true) }
        viewModelScope.launch {
            try {
                service.sendSelfCode(SelfCodePurpose.DeleteAccount)
                updateDelete { it.copy(step = DeleteStep.Code, error = null) }
                resendCountdown.start(RESEND_SECONDS)
            } catch (e: ServiceError) {
                if (e is ServiceError.Api && e.isRateLimited) {
                    updateDelete { it.copy(step = DeleteStep.Code, error = ErrorText.of(e)) }
                    e.retryAfterSecs?.let { resendCountdown.start(it.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()) }
                } else {
                    updateDelete { it.copy(error = ErrorText.of(e)) }
                }
            } finally {
                state.update { it.copy(busy = false) }
            }
        }
    }

    fun onDeleteCodeChange(input: String) {
        updateDelete { it.copy(code = input.filter(Char::isDigit).take(CODE_LENGTH), error = null) }
    }

    /** 第二步“下一步”：验证码满 6 位才进最后确认。 */
    fun deleteCodeNext() {
        val dialog = state.value.dialog as? DevicesDialog.DeleteAccount ?: return
        if (dialog.code.length != CODE_LENGTH) {
            updateDelete { it.copy(error = UiText(R.string.login_code_incomplete)) }
            return
        }
        updateDelete { it.copy(step = DeleteStep.Confirm, error = null) }
    }

    /** 第三步“永久注销”。验证码不对时回到第二步重填。 */
    fun confirmDeleteAccount() {
        val dialog = state.value.dialog as? DevicesDialog.DeleteAccount ?: return
        if (dialog.step != DeleteStep.Confirm || state.value.busy) return
        state.update { it.copy(busy = true) }
        viewModelScope.launch {
            try {
                service.deleteAccount(dialog.code)
                resendCountdown.cancel()
                // 成功后服务变成未登录，AppRoot 回登录页。
                state.update { it.copy(dialog = null) }
            } catch (e: ServiceError) {
                val text = if (e is ServiceError.Api && e.isInvalid) UiText(R.string.login_code_invalid) else ErrorText.of(e)
                updateDelete { it.copy(step = DeleteStep.Code, code = "", error = text) }
            } finally {
                state.update { it.copy(busy = false) }
            }
        }
    }

    /** 回到上一步（第三步 → 第二步）。 */
    fun deleteBack() {
        updateDelete { if (it.step == DeleteStep.Confirm) it.copy(step = DeleteStep.Code) else it }
    }

    private fun updateDelete(change: (DevicesDialog.DeleteAccount) -> DevicesDialog.DeleteAccount) {
        state.update { s ->
            val dialog = s.dialog as? DevicesDialog.DeleteAccount ?: return@update s
            s.copy(dialog = change(dialog))
        }
    }

    companion object {
        /** 昵称上限（服务端 1–64 个字符）。 */
        const val MAX_NAME_LENGTH: Int = 64
        const val CODE_LENGTH: Int = 6
        const val RESEND_SECONDS: Int = 60
    }
}
