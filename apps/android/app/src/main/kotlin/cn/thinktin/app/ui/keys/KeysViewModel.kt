package cn.thinktin.app.ui.keys

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.CredentialUpdate
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.VendorInfo
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** 一个实例的一个别名在用某把 key：[primary] 为真是主 key，否则在降级链里。 */
data class KeyUsage(val instanceId: String, val instanceName: String, val alias: String, val primary: Boolean)

/** 删除 key 的确认框：[usages] 非空时删除前会先把它从这些别名里拿掉。 */
data class DeleteKeyDialog(val credential: Credential, val usages: List<KeyUsage>)

data class KeysUiState(
    val loading: Boolean = true,
    val credentials: List<Credential> = emptyList(),
    /** 厂商 id → 厂商（拉不到时为空：只显示 id）。 */
    val vendors: Map<String, VendorInfo> = emptyMap(),
    val loadError: UiText? = null,
    val dialog: DeleteKeyDialog? = null,
    /** 删除进行中。 */
    val busy: Boolean = false,
    /** 正在查哪把 key 被哪些别名用着（删除前）。 */
    val checkingUsageFor: String? = null,
    /** 正在停用 / 启用的 key。 */
    val togglingId: String? = null,
)

sealed interface KeysEvent {
    data class Message(val text: UiText) : KeysEvent
}

/**
 * 模型 key 列表（13.4，路由 keys）：厂商、标签、后 4 位、每日限额、状态、协议；停用 / 启用、删除（先查哪些别名在用）。
 * 编辑、换 key、添加是单独的页面（有输入框）。
 */
class KeysViewModel(private val service: ThinktinService) : ViewModel() {
    private val state = MutableStateFlow(KeysUiState())
    val uiState: StateFlow<KeysUiState> = state.asStateFlow()

    private val eventChannel = Channel<KeysEvent>(Channel.BUFFERED)
    val events: Flow<KeysEvent> = eventChannel.receiveAsFlow()

    private var shownOnce = false

    init {
        load()
    }

    /** 页面每次显示时调（从添加、编辑页回来时重新取）；第一次已经在 init 里加载。 */
    fun onShown() {
        if (!shownOnce) {
            shownOnce = true
            return
        }
        load()
    }

    fun load() {
        state.update { it.copy(loading = it.credentials.isEmpty(), loadError = null) }
        viewModelScope.launch {
            try {
                coroutineScope {
                    // 厂商表拉不到不影响列表：只是显示厂商 id。
                    val vendors = async {
                        try {
                            service.vendors()
                        } catch (_: ServiceError) {
                            null
                        }
                    }
                    val credentials = service.credentials()
                    val vendorMap = vendors.await()?.associateBy { it.id }
                    state.update { s ->
                        s.copy(loading = false, credentials = credentials, vendors = vendorMap ?: s.vendors, loadError = null)
                    }
                }
            } catch (e: ServiceError) {
                state.update { it.copy(loading = false, loadError = ErrorText.of(e)) }
            }
        }
    }

    private fun message(text: UiText) {
        eventChannel.trySend(KeysEvent.Message(text))
    }

    /** 停用（运行用到它时会跳过它、换降级链里的下一把）或重新启用（等 key 的运行会接着跑）。 */
    fun setDisabled(credential: Credential, disabled: Boolean) {
        if (state.value.togglingId != null) return
        state.update { it.copy(togglingId = credential.id) }
        viewModelScope.launch {
            try {
                val updated = service.updateCredential(credential.id, CredentialUpdate(disabled = disabled))
                replace(updated)
                message(UiText(if (disabled) R.string.keys_disabled_done else R.string.keys_enabled_done, listOf(displayName(updated))))
            } catch (e: ServiceError) {
                message(ErrorText.of(e))
            } finally {
                state.update { it.copy(togglingId = null) }
            }
        }
    }

    private fun replace(updated: Credential) {
        state.update { s -> s.copy(credentials = s.credentials.map { if (it.id == updated.id) updated else it }) }
    }

    /** 先查所有实例的别名，找出用着这把 key 的，再开确认框；查不到就不让删（看不到影响范围）。 */
    fun askDelete(credential: Credential) {
        val s = state.value
        if (s.busy || s.checkingUsageFor != null) return
        state.update { it.copy(checkingUsageFor = credential.id) }
        viewModelScope.launch {
            try {
                val usages = findUsages(service, credential.id)
                state.update { it.copy(checkingUsageFor = null, dialog = DeleteKeyDialog(credential, usages)) }
            } catch (e: ServiceError) {
                state.update { it.copy(checkingUsageFor = null) }
                message(UiText(R.string.keys_usage_check_failed, listOf(ErrorText.of(e))))
            }
        }
    }

    fun dismissDialog() {
        if (state.value.busy) return
        state.update { it.copy(dialog = null) }
    }

    /**
     * 删除：有别名在用时先把它从这些实例的别名里拿掉（[KeyRules.detachCredential]，服务端在有别名用着时拒绝删除），再删。
     * 已经被删（404）当作成功。
     */
    fun confirmDelete() {
        val dialog = state.value.dialog ?: return
        if (state.value.busy) return
        state.update { it.copy(busy = true) }
        val id = dialog.credential.id
        viewModelScope.launch {
            try {
                for (instanceId in dialog.usages.map { it.instanceId }.distinct()) {
                    val routes = service.modelRoutes(instanceId)
                    val detached = KeyRules.detachCredential(routes, id)
                    if (detached != routes) service.setModelRoutes(instanceId, detached)
                }
                try {
                    service.deleteCredential(id)
                } catch (e: ServiceError.Api) {
                    if (e.code != "not_found" && e.status != 404) throw e
                }
                state.update { s -> s.copy(dialog = null, credentials = s.credentials.filterNot { it.id == id }) }
                message(UiText(R.string.keys_deleted, listOf(displayName(dialog.credential))))
            } catch (e: ServiceError) {
                state.update { it.copy(dialog = null) }
                val conflict = e is ServiceError.Api && (e.code == "conflict" || e.status == 409)
                message(if (conflict) UiText(R.string.keys_delete_in_use) else ErrorText.of(e))
                // 可能已经改了部分实例的别名：刷新列表。
                load()
            } finally {
                state.update { it.copy(busy = false) }
            }
        }
    }

    private fun displayName(credential: Credential): String = credential.label.ifBlank { credential.last4 }

    companion object {
        /** 所有（没删除的）实例里用着 [credentialId] 的别名。实例已经被删（404）就跳过。 */
        suspend fun findUsages(service: ThinktinService, credentialId: String): List<KeyUsage> = coroutineScope {
            val instances = service.instances().filter { it.state != InstanceState.Deleted }
            instances.map { instance ->
                async {
                    val routes = try {
                        service.modelRoutes(instance.id)
                    } catch (e: ServiceError.Api) {
                        if (e.code == "not_found" || e.status == 404) emptyList() else throw e
                    }
                    routes.flatMap { route ->
                        val primary = if (route.credentialId == credentialId) {
                            listOf(KeyUsage(instance.id, instance.name, route.alias, primary = true))
                        } else {
                            emptyList()
                        }
                        val fallback = if (route.fallbacks.any { it.credentialId == credentialId }) {
                            listOf(KeyUsage(instance.id, instance.name, route.alias, primary = false))
                        } else {
                            emptyList()
                        }
                        primary + fallback
                    }
                }
            }.awaitAll().flatten()
        }
    }
}
