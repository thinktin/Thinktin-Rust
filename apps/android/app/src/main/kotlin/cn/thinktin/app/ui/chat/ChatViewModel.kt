package cn.thinktin.app.ui.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.approval.ApprovalActions
import cn.thinktin.app.ui.approval.ApprovalDecider
import cn.thinktin.app.ui.approval.ApprovalGate
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.isRetryable
import cn.thinktin.data.model.Approval
import cn.thinktin.data.model.ApprovalState
import cn.thinktin.data.model.Conversation
import cn.thinktin.data.model.ConversationBuilder
import cn.thinktin.data.model.DetectedSecret
import cn.thinktin.data.model.EventKinds
import cn.thinktin.data.model.EventStreamItem
import cn.thinktin.data.model.HistoryWindow
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceEvent
import cn.thinktin.data.model.NewVaultItem
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.StreamState
import cn.thinktin.data.model.TimelineItem
import cn.thinktin.data.model.VaultRequest
import cn.thinktin.data.model.string
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File
import java.time.Clock
import java.util.TreeMap

/** 发送前拦下的密码：存进保险箱的表单（第 4.3 节、docs/vault.md 第 7 节）。不是对话框：盖在页面上的底部面板。 */
data class SecretForm(
    /** 拦下时的消息原文（存好后换成引用的就是它）。 */
    val message: String,
    val secret: DetectedSecret,
    /** 这条消息里还有几处要处理（存完这一处再弹下一处）。 */
    val remaining: Int,
    val name: String,
    val purpose: String = "",
    val username: String = "",
    val password: String,
    /** 用户改过名字：之后算出的不重名建议不再覆盖。 */
    val nameEdited: Boolean = false,
    val nameError: UiText? = null,
    val error: UiText? = null,
    val saving: Boolean = false,
)

/** agent 的账号密码填写请求（vault.requested）的表单。[agentPurpose] 是 agent 写的用途（标 AI 生成）。 */
data class VaultFillForm(
    val requestId: String,
    val name: String,
    val agentPurpose: String?,
    val fields: List<String>,
    val username: String = "",
    val password: String = "",
    /** 用户自己写的用途；空的话服务端用 agent 写的。 */
    val purpose: String = "",
    val submitting: Boolean = false,
    val error: UiText? = null,
) {
    /** 要不要账号（agent 没说要哪几项时两项都要）。 */
    val wantsUsername: Boolean get() = fields.isEmpty() || "username" in fields
    val wantsPassword: Boolean get() = fields.isEmpty() || "password" in fields
}

/** 对话页上的对话框（里面都没有输入框）。 */
sealed interface ChatDialog {
    /** “仍然发送”的二次确认：消息里有 [count] 处像密码的内容，发出去 agent 会看到。 */
    data class SendAnyway(val text: String, val count: Int) : ChatDialog

    /** 私钥（存不进保险箱）：只提示，不发。 */
    data object PrivateKey : ChatDialog
}

data class ChatUiState(
    val instanceId: String,
    val instance: Instance? = null,
    /** 缓存也没有、网络也还没回来。 */
    val loading: Boolean = true,
    val conversation: Conversation = Conversation(),
    /** 事件流的连接状态（null：还没订阅）。 */
    val stream: StreamState? = null,
    /** 订阅失败或事件流意外停了：顶部提示 + 重连。 */
    val streamFailed: Boolean = false,
    /** 联网刷新失败：显示的是缓存。 */
    val offline: Boolean = false,
    val loadingOlder: Boolean = false,
    val hasOlder: Boolean = true,
    val draft: String = "",
    val sending: Boolean = false,
    val stopping: Boolean = false,
    val secretForm: SecretForm? = null,
    val vaultForm: VaultFillForm? = null,
    val dialog: ChatDialog? = null,
    val downloadingArtifactId: String? = null,
    /** 实例不存在了（404 / 事件流 NotFound）：页面回实例列表。 */
    val notFound: Boolean = false,
) {
    /** 正在进行的运行（发送键变停止）。 */
    val activeRun: String? get() = conversation.activeBlock?.runId
}

sealed interface ChatEvent {
    data class Message(val text: UiText, val retry: (() -> Unit)? = null) : ChatEvent

    /** 产出物下好了：用系统的打开 / 分享。 */
    data class OpenFile(val file: File, val name: String, val share: Boolean) : ChatEvent

    /** 新内容（自己发的消息）：滚到底。 */
    data object ScrollToBottom : ChatEvent

    /** 定位到某个运行（首页“最近运行”点进来）。 */
    data class ScrollToRun(val runId: String) : ChatEvent

    /** 定位到某一条（等待审批横幅的“去审批”）。 */
    data class ScrollToItem(val key: String) : ChatEvent

    /** 实例没了：回实例列表。 */
    data object InstanceGone : ChatEvent
}

/** 产出物下载到哪（App 的缓存目录；测试里换成临时目录）。 */
fun interface ArtifactFiles {
    suspend fun save(artifactId: String, name: String, bytes: ByteArray): File
}

/**
 * 对话页（13.5，路由 chat/{instanceId}?runId=…）：
 * - 打开：先 cachedRuns + cachedEventsBefore（最后一屏）渲染 → events(instanceId) 实时追加；同时联网刷新实例、运行、
 *   待处理的审批和保险箱请求。补发的事件按批归并（[scheduleRebuild]）。
 * - 上拉：cachedEventsBefore 往前翻 + olderRuns。
 * - on_reset：清掉事件、保留运行并重新 runs()；比 oldest_seq 早的运行只显示 prompt / summary / error。
 * - 发送：detectSecrets 有命中 → 保险箱表单；“仍然发送”二次确认后 allowSecrets；发出后新运行马上进时间线。
 * - 停止、审批（13.16 的 [ApprovalActions]）、agent 的填写请求、产出物下载。
 */
class ChatViewModel(
    private val service: ThinktinService,
    gate: ApprovalGate,
    private val clock: Clock,
    private val instanceId: String,
    /** 首页“最近运行”点进来时要定位到的运行。 */
    private val focusRunId: String? = null,
    private val artifactFiles: ArtifactFiles = ArtifactFiles { _, _, _ -> error("no artifact storage") },
    /** 首页拦下密码后转过来的消息（打开时直接走拦截流程）。 */
    initialDraft: String? = null,
    /** 发出去了、有了运行（常驻通知跟它，13.10）。 */
    private val onRunStarted: (Run) -> Unit = {},
) : ViewModel() {
    private val state = MutableStateFlow(ChatUiState(instanceId = instanceId))
    val uiState: StateFlow<ChatUiState> = state.asStateFlow()

    private val eventChannel = Channel<ChatEvent>(Channel.BUFFERED)
    val events: Flow<ChatEvent> = eventChannel.receiveAsFlow()

    val actions = ApprovalActions(
        scope = viewModelScope,
        decider = ApprovalDecider(service, gate),
        onUpdated = { approval ->
            approvals[approval.id] = approval
            rebuild()
        },
        onGone = { id ->
            approvals.remove(id)
            rebuild()
        },
    )

    // 归并的原料（只在主线程上改）。
    private val runs = LinkedHashMap<String, Run>()
    private val eventsBySeq = TreeMap<Long, InstanceEvent>()
    private val approvals = LinkedHashMap<String, Approval>()
    private val vaultRecords = LinkedHashMap<String, VaultRequest>()
    private var window = HistoryWindow()
    private var olderRunsDone = false
    private val fetchingRuns = mutableSetOf<String>()
    private var rebuildPending = false
    private var streamJob: Job? = null
    private var focusPending = focusRunId
    private var focusPages = 0
    private var vaultNames: List<String>? = null

    init {
        if (!initialDraft.isNullOrBlank()) state.update { it.copy(draft = initialDraft) }
        viewModelScope.launch {
            openFromCache()
            subscribe()
            refresh()
            if (!initialDraft.isNullOrBlank()) send()
        }
    }

    // ---- 加载 ----

    private suspend fun openFromCache() {
        val instance = service.cachedInstances().firstOrNull { it.id == instanceId }
        val cachedRuns = service.cachedRuns(instanceId, ThinktinService.DEFAULT_PAGE)
        val cachedEvents = service.cachedEventsBefore(instanceId, null, ThinktinService.DEFAULT_SCREEN)
        cachedRuns.forEach { runs[it.id] = it }
        cachedEvents.forEach { eventsBySeq.putIfAbsent(it.seq, it) }
        if (cachedEvents.size < ThinktinService.DEFAULT_SCREEN) window = window.copy(exhausted = true)
        state.update {
            it.copy(
                instance = instance ?: it.instance,
                loading = cachedRuns.isEmpty() && cachedEvents.isEmpty(),
            )
        }
        rebuild()
        // 缓存里就有要定位的运行：马上滚过去（不在的话等联网之后再往前翻）。
        if (focusPending?.let { state.value.conversation.block(it) } != null) ensureFocus()
    }

    /** 联网刷新：实例、最近的运行、待处理的审批、保险箱请求。 */
    fun refresh() {
        viewModelScope.launch { refreshNow() }
    }

    private suspend fun refreshNow() {
        try {
            val instance = service.instance(instanceId)
            state.update { it.copy(instance = instance) }
            service.runs(instanceId, ThinktinService.DEFAULT_PAGE).forEach { runs[it.id] = it }
            if (runs.size < ThinktinService.DEFAULT_PAGE) olderRunsDone = true
            state.update { it.copy(offline = false, loading = false) }
        } catch (e: ServiceError) {
            if (e.isNotFound) {
                markGone()
                return
            }
            state.update { it.copy(offline = true, loading = false) }
        }
        // 审批和保险箱请求是附带的：拉不到只是卡片不能操作。
        try {
            val pending = service.approvals().filter { it.instanceId == instanceId }
            approvals.values.removeAll { it.state == ApprovalState.Pending && pending.none { p -> p.id == it.id } }
            pending.forEach { approvals[it.id] = it }
        } catch (_: ServiceError) {
        }
        try {
            service.vaultRequests(all = true).filter { it.instanceId == instanceId }.forEach { vaultRecords[it.id] = it }
        } catch (_: ServiceError) {
        }
        rebuild()
        ensureFocus()
    }

    private fun markGone() {
        if (state.value.notFound) return
        state.update { it.copy(notFound = true, loading = false) }
        eventChannel.trySend(ChatEvent.InstanceGone)
    }

    // ---- 事件流 ----

    /** 订阅事件流（断了以后“重新连接”也走这里）。 */
    fun subscribe() {
        streamJob?.cancel()
        state.update { it.copy(streamFailed = false) }
        streamJob = viewModelScope.launch {
            try {
                service.events(instanceId).collect { item -> onStreamItem(item) }
            } catch (e: CancellationException) {
                throw e
            } catch (_: ServiceError) {
                state.update { it.copy(streamFailed = true) }
            }
        }
    }

    private fun onStreamItem(item: EventStreamItem) {
        when (item) {
            is EventStreamItem.Event -> onEvent(item.event)
            is EventStreamItem.Reset -> onReset(item.oldestSeq)
            is EventStreamItem.Status -> {
                val s = item.state
                state.update { it.copy(stream = s, streamFailed = s == StreamState.Stopped) }
                // SignedOut、AccountFrozen、UpgradeRequired 由服务的 authState / upgradeState 换整个界面（AppRoot）。
                if (s == StreamState.NotFound) markGone()
            }
        }
    }

    private fun onEvent(event: InstanceEvent) {
        if (event.instanceId != instanceId || eventsBySeq.containsKey(event.seq)) return
        eventsBySeq[event.seq] = event
        val runId = event.runId
        if (runId != null) {
            when {
                runId !in runs -> fetchRun(runId)
                event.kind == EventKinds.RUN_STATE &&
                    RunState.fromWire(event.payload.string("state").orEmpty()).isTerminal -> fetchRun(runId)
            }
        }
        scheduleRebuild()
    }

    /** 续传位置过了保留期：本地事件作废，服务端会把保留期内的补发过来。运行记录留着并重新取。 */
    private fun onReset(oldestSeq: Long) {
        eventsBySeq.clear()
        window = HistoryWindow(exhausted = true, resetOldestSeq = oldestSeq)
        rebuild()
        viewModelScope.launch {
            try {
                service.runs(instanceId, ThinktinService.DEFAULT_PAGE).forEach { runs[it.id] = it }
                rebuild()
            } catch (_: ServiceError) {
                state.update { it.copy(offline = true) }
            }
        }
    }

    /** 事件里提到、列表里还没有的运行（别的设备发的、刚建的），或刚结束的运行（取 summary、用量）。 */
    private fun fetchRun(runId: String) {
        if (!fetchingRuns.add(runId)) return
        viewModelScope.launch {
            try {
                val run = service.getRun(runId)
                if (run.instanceId == instanceId) {
                    runs[run.id] = run
                    scheduleRebuild()
                }
            } catch (_: ServiceError) {
            } finally {
                fetchingRuns.remove(runId)
            }
        }
    }

    /**
     * 补发的事件会一次涌进很多：按批归并。归并排在主线程队列的后面（`Dispatchers.Main` 总是排队，不像
     * `Main.immediate` 当场执行），收集方先把缓冲里已经到的事件都收完，再归并一次。
     */
    private fun scheduleRebuild() {
        if (rebuildPending) return
        rebuildPending = true
        viewModelScope.launch(Dispatchers.Main) {
            rebuildPending = false
            rebuild()
        }
    }

    private fun rebuild() {
        val conversation = ConversationBuilder.build(
            runs = runs.values,
            events = eventsBySeq.values,
            approvals = approvals.values.toList(),
            vaultRequests = vaultRecords.values.toList(),
            window = window,
        )
        state.update {
            it.copy(
                conversation = conversation,
                hasOlder = !(window.exhausted && olderRunsDone),
                loading = it.loading && conversation.isEmpty,
            )
        }
    }

    /** 首页点进某个运行：它在已加载的里就定位，不在就往前翻几页找。 */
    private fun ensureFocus() {
        val target = focusPending ?: return
        if (state.value.conversation.block(target) != null) {
            focusPending = null
            eventChannel.trySend(ChatEvent.ScrollToRun(target))
            return
        }
        if (focusPages >= MAX_FOCUS_PAGES || !state.value.hasOlder) {
            // 找不到也发一次：界面据此恢复“新内容自动滚到底”（列表里没有它就不动）。
            focusPending = null
            eventChannel.trySend(ChatEvent.ScrollToRun(target))
            return
        }
        focusPages++
        loadOlder()
    }

    // ---- 翻页 ----

    /** 上拉到顶：缓存往前翻一屏事件 + 更早的一页运行。 */
    fun loadOlder() {
        val current = state.value
        if (current.loadingOlder || !current.hasOlder) return
        state.update { it.copy(loadingOlder = true) }
        viewModelScope.launch {
            if (!window.exhausted) {
                val before = eventsBySeq.firstEntry()?.key
                val older = service.cachedEventsBefore(instanceId, before, ThinktinService.DEFAULT_SCREEN)
                older.forEach { eventsBySeq.putIfAbsent(it.seq, it) }
                if (older.size < ThinktinService.DEFAULT_SCREEN) window = window.copy(exhausted = true)
            }
            var error: ServiceError? = null
            if (!olderRunsDone) {
                val oldest = runs.values.minByOrNull { it.createdAtMs }
                if (oldest == null) {
                    olderRunsDone = true
                } else {
                    try {
                        val older = service.olderRuns(instanceId, oldest.id, ThinktinService.DEFAULT_PAGE)
                        older.forEach { runs.putIfAbsent(it.id, it) }
                        if (older.size < ThinktinService.DEFAULT_PAGE) olderRunsDone = true
                    } catch (e: ServiceError) {
                        error = e
                    }
                }
            }
            state.update { it.copy(loadingOlder = false) }
            rebuild()
            if (error != null) {
                // 联网翻不了：本机缓存的照样显示，别反复重试。
                olderRunsDone = true
                rebuild()
                message(ErrorText.of(error))
            }
            ensureFocus()
        }
    }

    // ---- 输入与发送 ----

    fun onDraftChange(text: String) {
        state.update { it.copy(draft = text) }
    }

    fun send() {
        val current = state.value
        val text = current.draft.trim()
        if (text.isEmpty() || current.sending || current.secretForm != null) return
        val hits = detect(text)
        if (hits.isNotEmpty()) {
            intercept(text, hits)
            return
        }
        doSend(text, allowSecrets = false)
    }

    private fun detect(text: String): List<DetectedSecret> = try {
        service.detectSecrets(text)
    } catch (_: ServiceError) {
        // 本地识别失败：交给 sendMessage 自己的检查（有命中会抛 ContainsSecrets）。
        emptyList()
    }

    /** 有像密码的内容：私钥只提示（存不进保险箱）；其余弹保险箱表单（一处一处来）。 */
    private fun intercept(text: String, hits: List<DetectedSecret>) {
        if (hits.any { !it.storable }) {
            state.update { it.copy(dialog = ChatDialog.PrivateKey) }
            return
        }
        openSecretForm(text, hits)
    }

    private fun openSecretForm(text: String, hits: List<DetectedSecret>) {
        val secret = hits.first()
        val suggested = service.uniqueVaultName(secret.suggestedName, vaultNames.orEmpty())
        state.update {
            it.copy(
                secretForm = SecretForm(
                    message = text,
                    secret = secret,
                    remaining = hits.size - 1,
                    name = suggested,
                    password = secret.value,
                ),
            )
        }
        if (vaultNames == null) {
            viewModelScope.launch {
                val names = loadVaultNames() ?: return@launch
                state.update { s ->
                    val form = s.secretForm ?: return@update s
                    if (form.nameEdited) s else s.copy(secretForm = form.copy(name = service.uniqueVaultName(form.secret.suggestedName, names)))
                }
            }
        }
    }

    private suspend fun loadVaultNames(): List<String>? = try {
        service.vaultItems().map { it.name }.also { vaultNames = it }
    } catch (_: ServiceError) {
        null
    }

    fun onSecretFormChange(transform: (SecretForm) -> SecretForm) {
        state.update { s ->
            val form = s.secretForm ?: return@update s
            if (form.saving) return@update s
            val next = transform(form)
            s.copy(
                secretForm = next.copy(
                    nameEdited = form.nameEdited || next.name != form.name,
                    nameError = if (next.name != form.name) null else next.nameError,
                    error = null,
                ),
            )
        }
    }

    fun dismissSecretForm() {
        state.update { if (it.secretForm?.saving == true) it else it.copy(secretForm = null) }
    }

    /** 存进保险箱，把输入框里的那段换成 `[vault:名字]`。还有别的命中就接着弹。 */
    fun saveSecret() {
        val form = state.value.secretForm ?: return
        if (form.saving) return
        val name = form.name.trim()
        if (name.isEmpty()) {
            state.update { it.copy(secretForm = form.copy(nameError = UiText(R.string.chat_secret_name_required))) }
            return
        }
        if (form.password.isEmpty()) {
            state.update { it.copy(secretForm = form.copy(error = UiText(R.string.chat_secret_password_required))) }
            return
        }
        state.update { it.copy(secretForm = form.copy(saving = true)) }
        viewModelScope.launch {
            try {
                val saved = service.saveSecretFromMessage(
                    message = form.message,
                    value = form.secret.value,
                    item = NewVaultItem(
                        name = name,
                        purpose = form.purpose.trim(),
                        username = form.username.trim(),
                        password = form.password,
                        instanceIds = listOf(instanceId),
                    ),
                )
                vaultNames = vaultNames.orEmpty() + saved.item.name
                state.update { it.copy(secretForm = null, draft = saved.message) }
                message(UiText(R.string.chat_secret_saved, listOf(saved.item.name)))
                val more = detect(saved.message)
                if (more.isNotEmpty()) intercept(saved.message, more)
            } catch (e: ServiceError) {
                if (e is ServiceError.Api && (e.status == 409 || e.code == "conflict")) {
                    val names = loadVaultNames().orEmpty()
                    state.update { s ->
                        val f = s.secretForm ?: return@update s
                        s.copy(
                            secretForm = f.copy(
                                saving = false,
                                name = service.uniqueVaultName(name, names + name),
                                nameEdited = false,
                                nameError = UiText(R.string.chat_secret_name_taken, listOf(name)),
                            ),
                        )
                    }
                } else {
                    state.update { s -> s.copy(secretForm = s.secretForm?.copy(saving = false, error = ErrorText.of(e))) }
                }
            }
        }
    }

    /** 表单里的“仍然发送”：先二次确认。 */
    fun askSendAnyway() {
        val form = state.value.secretForm ?: return
        val count = detect(form.message).size.coerceAtLeast(1)
        state.update { it.copy(secretForm = null, dialog = ChatDialog.SendAnyway(form.message, count)) }
    }

    fun confirmSendAnyway() {
        val dialog = state.value.dialog as? ChatDialog.SendAnyway ?: return
        state.update { it.copy(dialog = null) }
        doSend(dialog.text, allowSecrets = true)
    }

    fun dismissDialog() {
        state.update { it.copy(dialog = null) }
    }

    private fun doSend(text: String, allowSecrets: Boolean) {
        if (state.value.sending) return
        state.update { it.copy(sending = true, draft = "") }
        viewModelScope.launch {
            try {
                val run = service.sendMessage(instanceId, text, allowSecrets)
                onRunStarted(run)
                // 乐观：新运行马上进时间线（事件流的 run.state 随后到）。
                runs[run.id] = run
                rebuild()
                eventChannel.trySend(ChatEvent.ScrollToBottom)
            } catch (e: ServiceError) {
                state.update { if (it.draft.isEmpty()) it.copy(draft = text) else it }
                if (e is ServiceError.ContainsSecrets) {
                    val hits = detect(text)
                    if (hits.isEmpty()) {
                        state.update { it.copy(dialog = ChatDialog.SendAnyway(text, e.count)) }
                    } else {
                        intercept(text, hits)
                    }
                } else {
                    message(ErrorText.of(e), if (e.isRetryable) ({ retrySend(text, allowSecrets) }) else null)
                }
            } finally {
                state.update { it.copy(sending = false) }
            }
        }
    }

    private fun retrySend(text: String, allowSecrets: Boolean) {
        if (state.value.draft.trim() == text) doSend(text, allowSecrets)
    }

    /** 停止正在进行的运行（连同它委派出去的子任务）。 */
    fun stop() {
        val runId = state.value.activeRun ?: return
        if (state.value.stopping) return
        state.update { it.copy(stopping = true) }
        viewModelScope.launch {
            try {
                val run = service.cancelRun(runId, wholeTree = true)
                runs[run.id] = run
                rebuild()
                message(UiText(R.string.chat_stopped))
            } catch (e: ServiceError) {
                message(ErrorText.of(e))
            } finally {
                state.update { it.copy(stopping = false) }
            }
        }
    }

    // ---- agent 的填写请求 ----

    fun openVaultForm(item: TimelineItem.VaultRequestCard) {
        state.update {
            it.copy(
                vaultForm = VaultFillForm(
                    requestId = item.requestId,
                    name = item.name,
                    agentPurpose = item.purpose,
                    fields = item.fields,
                ),
            )
        }
    }

    fun onVaultFormChange(transform: (VaultFillForm) -> VaultFillForm) {
        state.update { s ->
            val form = s.vaultForm ?: return@update s
            if (form.submitting) s else s.copy(vaultForm = transform(form).copy(error = null))
        }
    }

    fun dismissVaultForm() {
        state.update { if (it.vaultForm?.submitting == true) it else it.copy(vaultForm = null) }
    }

    fun submitVaultForm() {
        val form = state.value.vaultForm ?: return
        if (form.submitting) return
        if (form.wantsPassword && form.password.isEmpty()) {
            state.update { it.copy(vaultForm = form.copy(error = UiText(R.string.chat_secret_password_required))) }
            return
        }
        state.update { it.copy(vaultForm = form.copy(submitting = true)) }
        viewModelScope.launch {
            try {
                val done = service.fulfillVaultRequest(
                    requestId = form.requestId,
                    username = form.username.trim(),
                    password = form.password,
                    purpose = form.purpose.trim().ifEmpty { null },
                )
                vaultRecords[done.id] = done
                state.update { it.copy(vaultForm = null) }
                rebuild()
                message(UiText(R.string.chat_vault_fulfilled, listOf(form.name)))
            } catch (e: ServiceError) {
                if (e.isAlreadyHandled) {
                    state.update { it.copy(vaultForm = null) }
                    refreshVaultRequest(form.requestId)
                    message(UiText(R.string.chat_vault_already_handled))
                } else {
                    state.update { s -> s.copy(vaultForm = s.vaultForm?.copy(submitting = false, error = ErrorText.of(e))) }
                }
            }
        }
    }

    /** 拒绝 agent 的填写请求（直接发）。 */
    fun declineVaultRequest(requestId: String) {
        viewModelScope.launch {
            try {
                val done = service.declineVaultRequest(requestId)
                vaultRecords[done.id] = done
                state.update { if (it.vaultForm?.requestId == requestId) it.copy(vaultForm = null) else it }
                rebuild()
                message(UiText(R.string.chat_vault_declined))
            } catch (e: ServiceError) {
                if (e.isAlreadyHandled) {
                    refreshVaultRequest(requestId)
                    message(UiText(R.string.chat_vault_already_handled))
                } else {
                    message(ErrorText.of(e))
                }
            }
        }
    }

    private suspend fun refreshVaultRequest(requestId: String) {
        try {
            service.vaultRequests(all = true).firstOrNull { it.id == requestId }?.let { vaultRecords[it.id] = it }
            rebuild()
        } catch (_: ServiceError) {
        }
    }

    // ---- 产出物 ----

    /** 下载产出物到缓存目录再交给系统打开 / 分享（一次返回整个文件，最多 20 MiB；只转圈）。 */
    fun openArtifact(item: TimelineItem.Artifact, share: Boolean = false) {
        if (state.value.downloadingArtifactId != null) return
        if ((item.size ?: 0) > MAX_ARTIFACT_BYTES) {
            message(UiText(R.string.chat_artifact_too_large))
            return
        }
        state.update { it.copy(downloadingArtifactId = item.artifactId) }
        viewModelScope.launch {
            try {
                val bytes = service.artifactContent(item.artifactId)
                if (bytes.size > MAX_ARTIFACT_BYTES) {
                    message(UiText(R.string.chat_artifact_too_large))
                    return@launch
                }
                val file = artifactFiles.save(item.artifactId, item.name, bytes)
                eventChannel.trySend(ChatEvent.OpenFile(file, item.name, share))
            } catch (e: ServiceError) {
                message(ErrorText.of(e), if (e.isRetryable) ({ openArtifact(item, share) }) else null)
            } catch (e: java.io.IOException) {
                message(UiText(R.string.chat_artifact_save_failed))
            } finally {
                state.update { it.copy(downloadingArtifactId = null) }
            }
        }
    }

    // ---- 横幅的“去审批” ----

    /** 等待审批横幅：本页有能点的卡片就滚过去，返回 true；没有返回 false（去审批中心）。 */
    fun scrollToPendingApproval(): Boolean {
        val conversation = state.value.conversation
        for (section in conversation.sections) {
            val items = (section as? cn.thinktin.data.model.ConversationSection.RunSection)?.block?.items ?: continue
            val item = items.lastOrNull { it is TimelineItem.ApprovalCard && it.card.canDecide } ?: continue
            eventChannel.trySend(ChatEvent.ScrollToItem(item.key))
            return true
        }
        return false
    }

    fun nowMs(): Long = clock.millis()

    private fun message(text: UiText, retry: (() -> Unit)? = null) {
        eventChannel.trySend(ChatEvent.Message(text, retry))
    }

    companion object {
        /** artifact_content 的上限（服务端一次返回整个文件）。 */
        const val MAX_ARTIFACT_BYTES = 20L * 1024 * 1024

        /** 首页点进来的运行不在已加载的范围里时，最多往前翻几页去找。 */
        const val MAX_FOCUS_PAGES = 5

        private val ServiceError.isNotFound: Boolean
            get() = this is ServiceError.Api && (status == 404 || code == "not_found")

        /** 填写请求已经处理过 / 过期 / 不存在。 */
        private val ServiceError.isAlreadyHandled: Boolean
            get() = this is ServiceError.Api && (status == 404 || status == 409 || status == 410 || code == "conflict")
    }
}
