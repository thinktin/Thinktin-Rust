package cn.thinktin.app.ui.devices

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.DeviceInfo
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

/** 从设置页直接打开的操作（路由 `devices?action=…`）。改昵称、注销账号是单独的页面（有输入框）。 */
enum class DevicesAction(val wire: String) {
    SignOutOthers("sign_out_others"),
    StopAll("stop_all"),
    ;

    companion object {
        fun fromWire(value: String?): DevicesAction? = entries.firstOrNull { it.wire == value }
    }
}

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
 * 设备与账号（13.2，路由 devices）：资料、设备列表、远程下线、下线其他设备（可选同时停止全部 agent）、全部停止、
 * 退出登录；改昵称、注销账号是单独的页面（account/name、account/delete）。结果和错误用 Snackbar（[messages]）。
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

    init {
        when (initialAction) {
            DevicesAction.SignOutOthers -> askSignOutOthers()
            DevicesAction.StopAll -> askStopAll()
            null -> Unit
        }
        refresh()
    }

    private var shownOnce = false

    /** 页面每次显示时调：第一次已经在 init 里加载了；之后（比如改完昵称回来）重新取资料。 */
    fun onShown() {
        if (!shownOnce) {
            shownOnce = true
            return
        }
        viewModelScope.launch {
            try {
                val user = service.me()
                state.update { it.copy(user = user) }
            } catch (_: ServiceError) {
                // 资料没刷新不影响这一页。
            }
        }
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
            } catch (e: ServiceError) {
                state.update { it.copy(loading = false, loadError = ErrorText.of(e)) }
            }
        }
    }

    fun dismissDialog() {
        if (state.value.busy) return
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
}
