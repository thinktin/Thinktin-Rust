package cn.thinktin.app.ui.vault

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.NewVaultItem
import cn.thinktin.data.model.VaultItem
import cn.thinktin.data.model.VaultItemDetail
import cn.thinktin.data.model.VaultItemUpdate
import cn.thinktin.data.model.VaultRequest
import cn.thinktin.data.model.VaultRequestStatus
import cn.thinktin.data.model.VaultRules
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
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

private val ServiceError.isConflict: Boolean get() = this is ServiceError.Api && (status == 409 || code == "conflict")
private val ServiceError.isNotFound: Boolean get() = this is ServiceError.Api && (status == 404 || code == "not_found")

/** 请求现在的状态：过了期限还显示“等你填写”的按过期算（服务端定时清理前）。 */
fun VaultRequest.effectiveStatus(nowMs: Long): VaultRequestStatus =
    if (status == VaultRequestStatus.Pending && expiresAtMs <= nowMs) VaultRequestStatus.Expired else status

/** 新建、修改条目和填写请求的表单问题（点保存后标出来）。 */
sealed interface VaultFormProblem {
    data object NameEmpty : VaultFormProblem
    data object NameInvalid : VaultFormProblem
    data object PurposeTooLong : VaultFormProblem
    data object UsernameTooLong : VaultFormProblem

    /** 用途、账号里有换行、制表符这些。 */
    data object PurposeControl : VaultFormProblem
    data object ControlCharacters : VaultFormProblem
    data class Password(val problem: VaultRules.PasswordProblem) : VaultFormProblem
    data object NoInstances : VaultFormProblem
    data object TooManyInstances : VaultFormProblem

    /** 已经存满 200 条（新建时）。 */
    data object Full : VaultFormProblem
}

sealed interface VaultEvent {
    data class Notice(val text: UiText) : VaultEvent

    /** 删掉了：退回去。 */
    data object Deleted : VaultEvent

    /** 存好了：退回去。 */
    data class Saved(val item: VaultItem) : VaultEvent
}

data class VaultUiState(
    val loading: Boolean = true,
    val refreshing: Boolean = false,
    val items: List<VaultItem> = emptyList(),
    /** 全部请求（`vaultRequests(all = true)`），新的在前。 */
    val requests: List<VaultRequest> = emptyList(),
    /** 实例 id → 实例（不含已删除的）。 */
    val instances: Map<String, Instance> = emptyMap(),
    val loadError: UiText? = null,
    val deleting: Set<String> = emptySet(),
    val loaded: Boolean = false,
) {
    val isFull: Boolean get() = items.size >= VaultRules.MAX_ITEMS

    fun pending(nowMs: Long): List<VaultRequest> = requests.filter { it.effectiveStatus(nowMs) == VaultRequestStatus.Pending }

    fun past(nowMs: Long): List<VaultRequest> = requests.filter { it.effectiveStatus(nowMs) != VaultRequestStatus.Pending }
}

/**
 * 密码保险箱（13.14，路由 `vault`，设置 → 密码保险箱）：条目（按名字排，用途、能用的实例；没有密码）、等你填写的请求、
 * 处理过的请求（过了期限的算过期）。最多 200 条，满了不能新建。
 */
class VaultViewModel(private val service: ThinktinService) : ViewModel() {
    private val state = MutableStateFlow(VaultUiState())
    val uiState: StateFlow<VaultUiState> = state.asStateFlow()

    private val eventChannel = Channel<VaultEvent>(Channel.BUFFERED)
    val events: Flow<VaultEvent> = eventChannel.receiveAsFlow()

    private var shownOnce = false

    init {
        load(initial = true)
    }

    /** 每次回到这页（从条目、请求页回来）重新拉。 */
    fun onShown() {
        if (!shownOnce) {
            shownOnce = true
            return
        }
        load(initial = false)
    }

    fun refresh() = load(initial = false)

    fun retry() = load(initial = true)

    private fun load(initial: Boolean) {
        state.update { it.copy(loading = initial && !it.loaded, refreshing = !initial, loadError = null) }
        viewModelScope.launch {
            try {
                val (items, requests) = coroutineScope {
                    val items = async { service.vaultItems() }
                    val requests = async { service.vaultRequests(all = true) }
                    items.await() to requests.await()
                }
                val instances = try {
                    service.instances().filter { it.state != InstanceState.Deleted }.associateBy { it.id }
                } catch (_: ServiceError) {
                    state.value.instances
                }
                state.update {
                    it.copy(
                        loading = false, refreshing = false, loaded = true,
                        items = items.sortedBy { item -> item.name },
                        requests = requests.sortedByDescending { r -> r.createdAtMs },
                        instances = instances,
                    )
                }
            } catch (e: ServiceError) {
                val text = ErrorText.of(e)
                if (state.value.loaded) eventChannel.trySend(VaultEvent.Notice(text))
                state.update { it.copy(loading = false, refreshing = false, loadError = if (it.loaded) null else text) }
            }
        }
    }

    fun delete(item: VaultItem) {
        if (item.id in state.value.deleting) return
        state.update { it.copy(deleting = it.deleting + item.id) }
        viewModelScope.launch {
            try {
                service.deleteVaultItem(item.id)
                removed(item)
                eventChannel.trySend(VaultEvent.Notice(UiText(R.string.vault_item_deleted, listOf(item.name))))
            } catch (e: ServiceError) {
                if (e.isNotFound) {
                    removed(item)
                } else {
                    state.update { it.copy(deleting = it.deleting - item.id) }
                    eventChannel.trySend(VaultEvent.Notice(ErrorText.of(e)))
                }
            }
        }
    }

    private fun removed(item: VaultItem) {
        state.update { s -> s.copy(deleting = s.deleting - item.id, items = s.items.filterNot { it.id == item.id }) }
    }
}

data class VaultItemUiState(
    val loading: Boolean = true,
    val detail: VaultItemDetail? = null,
    val instances: Map<String, Instance> = emptyMap(),
    val loadError: UiText? = null,
    val missing: Boolean = false,
    val deleting: Boolean = false,
    val confirmDelete: Boolean = false,
)

/** 一个条目（`vault/item/{id}`）：引用（可以复制）、用途、账号（服务端解密后返回；密码永远不返回）、能用的实例、时间；修改、删除。 */
class VaultItemViewModel(private val service: ThinktinService, private val itemId: String) : ViewModel() {
    private val state = MutableStateFlow(VaultItemUiState())
    val uiState: StateFlow<VaultItemUiState> = state.asStateFlow()

    private val eventChannel = Channel<VaultEvent>(Channel.BUFFERED)
    val events: Flow<VaultEvent> = eventChannel.receiveAsFlow()

    private var shownOnce = false

    init {
        load()
    }

    /** 从修改页回来：账号、用途可能变了。 */
    fun onShown() {
        if (!shownOnce) {
            shownOnce = true
            return
        }
        load()
    }

    fun load() {
        state.update { it.copy(loading = it.detail == null, loadError = null) }
        viewModelScope.launch {
            try {
                val detail = service.vaultItem(itemId)
                val instances = try {
                    service.instances().filter { it.state != InstanceState.Deleted }.associateBy { it.id }
                } catch (_: ServiceError) {
                    state.value.instances
                }
                state.update { it.copy(loading = false, detail = detail, instances = instances, missing = false) }
            } catch (e: ServiceError) {
                state.update {
                    if (e.isNotFound) it.copy(loading = false, missing = true) else it.copy(loading = false, loadError = ErrorText.of(e))
                }
            }
        }
    }

    fun askDelete() = state.update { it.copy(confirmDelete = true) }

    fun dismissDelete() = state.update { if (it.deleting) it else it.copy(confirmDelete = false) }

    fun delete() {
        if (state.value.deleting) return
        state.update { it.copy(deleting = true) }
        viewModelScope.launch {
            try {
                service.deleteVaultItem(itemId)
                state.update { it.copy(deleting = false, confirmDelete = false) }
                eventChannel.trySend(VaultEvent.Deleted)
            } catch (e: ServiceError) {
                state.update { it.copy(deleting = false, confirmDelete = false) }
                if (e.isNotFound) eventChannel.trySend(VaultEvent.Deleted) else eventChannel.trySend(VaultEvent.Notice(ErrorText.of(e)))
            }
        }
    }
}

data class VaultEditorUiState(
    val loading: Boolean = true,
    val loadError: UiText? = null,
    val editing: Boolean = false,
    val name: String = "",
    val purpose: String = "",
    val username: String = "",
    val password: String = "",
    val allInstances: Boolean = true,
    val selected: Set<String> = emptySet(),
    /** 能选的实例（不含已删除的），最近活跃的在前。 */
    val instances: List<Instance> = emptyList(),
    val original: VaultItemDetail? = null,
    val itemCount: Int = 0,
    val takenNames: List<String> = emptyList(),
    val saving: Boolean = false,
    val showProblems: Boolean = false,
    /** 名字被占用、换成了这个（提示一句，用户可以再改）。 */
    val renamedTo: String? = null,
) {
    val instanceIds: List<String> get() = if (allInstances) emptyList() else selected.sorted()

    val problems: List<VaultFormProblem>
        get() = buildList {
            if (!editing) {
                if (itemCount >= VaultRules.MAX_ITEMS) add(VaultFormProblem.Full)
                when {
                    name.isEmpty() -> add(VaultFormProblem.NameEmpty)
                    !VaultRules.isValidName(name) -> add(VaultFormProblem.NameInvalid)
                }
            }
            val purpose = purpose.trim()
            if (VaultRules.length(purpose) > VaultRules.MAX_PURPOSE) add(VaultFormProblem.PurposeTooLong)
            if (VaultRules.length(username) > VaultRules.MAX_USERNAME) add(VaultFormProblem.UsernameTooLong)
            if (VaultRules.hasControlCharacters(purpose)) add(VaultFormProblem.PurposeControl)
            if (VaultRules.hasControlCharacters(username)) add(VaultFormProblem.ControlCharacters)
            if (!editing || password.isNotEmpty()) VaultRules.passwordProblem(password)?.let { add(VaultFormProblem.Password(it)) }
            if (!allInstances) {
                if (selected.isEmpty()) add(VaultFormProblem.NoInstances)
                if (selected.size > VaultRules.MAX_INSTANCES) add(VaultFormProblem.TooManyInstances)
            }
        }

    val visibleProblems: List<VaultFormProblem> get() = if (showProblems) problems else emptyList()

    val hasChanges: Boolean
        get() {
            val original = original ?: return name.isNotEmpty() || purpose.isNotEmpty() || username.isNotEmpty() || password.isNotEmpty()
            return purpose.trim() != original.item.purpose || username != original.username || password.isNotEmpty() ||
                instanceIds != original.item.instanceIds.sorted()
        }
}

/**
 * 新建（`vault/new`）/ 修改（`vault/item/{id}/edit`）条目：名字（新建时；1–64 个小写字母、数字、`-`、`_`）、用途、账号、
 * 密码（修改时不填就不改）、能用的实例（所有，或者选几个，最多 50 个）。重名时换一个不重复的名字（`github` → `github_2`），
 * 提示一句、等用户再点保存；满 200 条不能新建。
 */
class VaultEditorViewModel(private val service: ThinktinService, private val itemId: String?) : ViewModel() {
    private val state = MutableStateFlow(VaultEditorUiState(editing = itemId != null))
    val uiState: StateFlow<VaultEditorUiState> = state.asStateFlow()

    private val eventChannel = Channel<VaultEvent>(Channel.BUFFERED)
    val events: Flow<VaultEvent> = eventChannel.receiveAsFlow()

    init {
        load()
    }

    fun load() {
        state.update { it.copy(loading = true, loadError = null) }
        viewModelScope.launch {
            try {
                val instances = service.instances().filter { it.state != InstanceState.Deleted }.sortedByDescending { it.lastActiveAtMs }
                val items = service.vaultItems()
                val detail = itemId?.let { service.vaultItem(it) }
                state.update {
                    val base = it.copy(
                        loading = false, instances = instances, itemCount = items.size, takenNames = items.map { i -> i.name },
                    )
                    if (detail == null || it.original != null) {
                        base
                    } else {
                        base.copy(
                            original = detail,
                            name = detail.item.name,
                            purpose = detail.item.purpose,
                            username = detail.username,
                            allInstances = detail.item.instanceIds.isEmpty(),
                            selected = detail.item.instanceIds.intersect(instances.map { instance -> instance.id }.toSet()),
                        )
                    }
                }
            } catch (e: ServiceError) {
                state.update { it.copy(loading = false, loadError = ErrorText.of(e)) }
            }
        }
    }

    fun onName(raw: String) = state.update { it.copy(name = VaultRules.cleanName(raw), renamedTo = null) }

    fun onPurpose(value: String) = state.update { it.copy(purpose = value) }

    fun onUsername(value: String) = state.update { it.copy(username = value) }

    fun onPassword(value: String) = state.update { it.copy(password = value) }

    fun setAllInstances(all: Boolean) = state.update { it.copy(allInstances = all) }

    fun toggle(instanceId: String) = state.update {
        it.copy(selected = if (instanceId in it.selected) it.selected - instanceId else it.selected + instanceId)
    }

    fun save() {
        val current = state.value
        if (current.saving || current.loading || current.loadError != null) return
        if (!current.editing && current.name in current.takenNames) {
            rename(current.takenNames)
            return
        }
        if (current.problems.isNotEmpty()) {
            state.update { it.copy(showProblems = true) }
            return
        }
        state.update { it.copy(saving = true) }
        viewModelScope.launch {
            try {
                val purpose = current.purpose.trim()
                val original = current.original
                val saved = if (itemId != null && original != null) {
                    service.updateVaultItem(
                        itemId,
                        VaultItemUpdate(
                            purpose = purpose.takeIf { it != original.item.purpose },
                            username = current.username.takeIf { it != original.username },
                            password = current.password.ifEmpty { null },
                            instanceIds = current.instanceIds.takeIf { it != original.item.instanceIds.sorted() },
                        ),
                    )
                } else {
                    service.createVaultItem(
                        NewVaultItem(current.name, purpose, current.username, current.password, current.instanceIds),
                    )
                }
                state.update { it.copy(saving = false, password = "") }
                eventChannel.trySend(VaultEvent.Saved(saved))
            } catch (e: ServiceError) {
                state.update { it.copy(saving = false) }
                // 别处刚建了同名的：换个名字让用户确认。
                val names = if (e.isConflict && itemId == null) {
                    try {
                        service.vaultItems().map { it.name }
                    } catch (_: ServiceError) {
                        null
                    }
                } else {
                    null
                }
                if (names != null) {
                    state.update { it.copy(takenNames = names, itemCount = names.size) }
                    rename(names)
                } else {
                    eventChannel.trySend(VaultEvent.Notice(ErrorText.of(e)))
                }
            }
        }
    }

    private fun rename(taken: List<String>) {
        val suggestion = service.uniqueVaultName(state.value.name, taken)
        state.update { it.copy(name = suggestion, renamedTo = suggestion) }
    }
}

data class VaultRequestUiState(
    val loading: Boolean = true,
    val request: VaultRequest? = null,
    /** 同名的已有条目（填好会更新它）。 */
    val existing: VaultItem? = null,
    val instanceName: String? = null,
    val loadError: UiText? = null,
    val missing: Boolean = false,
    val username: String = "",
    val password: String = "",
    val busy: Boolean = false,
    val showProblems: Boolean = false,
) {
    val problems: List<VaultFormProblem>
        get() = buildList {
            if (VaultRules.length(username) > VaultRules.MAX_USERNAME) add(VaultFormProblem.UsernameTooLong)
            if (VaultRules.hasControlCharacters(username)) add(VaultFormProblem.ControlCharacters)
            VaultRules.passwordProblem(password)?.let { add(VaultFormProblem.Password(it)) }
        }

    val visibleProblems: List<VaultFormProblem> get() = if (showProblems) problems else emptyList()
}

/**
 * 填写请求（`vault?requestId=`：推送、收件箱、深链 `thinktin://vault/request/{id}`、保险箱里的列表进来）：agent 要的账号密码，
 * 填好只进保险箱（agent 只拿到名字）。已经有同名条目的，填好会换掉它的账号密码（服务端就是这样），先提示。也可以拒绝。
 * 别处已处理、过期了（409）时重新拉、显示结果，不算出错。
 */
class VaultRequestViewModel(
    private val service: ThinktinService,
    private val requestId: String,
    private val clock: () -> Long,
) : ViewModel() {
    private val state = MutableStateFlow(VaultRequestUiState())
    val uiState: StateFlow<VaultRequestUiState> = state.asStateFlow()

    private val eventChannel = Channel<VaultEvent>(Channel.BUFFERED)
    val events: Flow<VaultEvent> = eventChannel.receiveAsFlow()

    init {
        load()
    }

    /** 现在的状态（过了期限的按过期算）。 */
    fun status(): VaultRequestStatus? = state.value.request?.effectiveStatus(clock())

    fun load() {
        state.update { it.copy(loading = it.request == null, loadError = null) }
        viewModelScope.launch {
            try {
                val request = service.vaultRequests(all = true).firstOrNull { it.id == requestId }
                val existing = request?.let { r -> service.vaultItems().firstOrNull { it.name == r.name } }
                val instanceName = request?.let { r ->
                    try {
                        service.instances().firstOrNull { it.id == r.instanceId && it.state != InstanceState.Deleted }?.name
                    } catch (_: ServiceError) {
                        null
                    }
                }
                state.update {
                    it.copy(
                        loading = false, request = request, existing = existing, instanceName = instanceName,
                        missing = request == null,
                    )
                }
            } catch (e: ServiceError) {
                state.update { it.copy(loading = false, loadError = ErrorText.of(e)) }
            }
        }
    }

    fun onUsername(value: String) = state.update { it.copy(username = value) }

    fun onPassword(value: String) = state.update { it.copy(password = value) }

    fun fulfill() {
        val current = state.value
        if (current.busy || status() != VaultRequestStatus.Pending) return
        if (current.problems.isNotEmpty()) {
            state.update { it.copy(showProblems = true) }
            return
        }
        run(R.string.chat_vault_fulfilled) {
            service.fulfillVaultRequest(requestId, current.username.trim(), current.password)
        }
    }

    fun decline() {
        if (state.value.busy || status() != VaultRequestStatus.Pending) return
        run(R.string.chat_vault_declined) { service.declineVaultRequest(requestId) }
    }

    private fun run(done: Int, action: suspend () -> VaultRequest) {
        state.update { it.copy(busy = true) }
        viewModelScope.launch {
            try {
                val request = action()
                state.update { it.copy(busy = false, request = request, password = "") }
                eventChannel.trySend(VaultEvent.Notice(UiText(done, listOf(request.name))))
            } catch (e: ServiceError) {
                state.update { it.copy(busy = false) }
                if (e.isConflict || e.isNotFound) {
                    eventChannel.trySend(VaultEvent.Notice(UiText(R.string.chat_vault_already_handled)))
                    load()
                } else {
                    eventChannel.trySend(VaultEvent.Notice(ErrorText.of(e)))
                }
            }
        }
    }
}
