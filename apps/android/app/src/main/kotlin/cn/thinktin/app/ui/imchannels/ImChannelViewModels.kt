package cn.thinktin.app.ui.imchannels

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.ImChannel
import cn.thinktin.data.model.ImChannelRules
import cn.thinktin.data.model.ImChannelUpdate
import cn.thinktin.data.model.ImEvents
import cn.thinktin.data.model.NewImChannel
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

private val ServiceError.isNotFound: Boolean get() = this is ServiceError.Api && (status == 404 || code == "not_found")
private val ServiceError.isRateLimited: Boolean get() = this is ServiceError.Api && (status == 429 || code == "rate_limited")

sealed interface ImChannelEvent {
    data class Notice(val text: UiText) : ImChannelEvent

    /** 存好了：退回去。 */
    data class Saved(val channel: ImChannel) : ImChannelEvent
}

data class ImChannelsUiState(
    val loading: Boolean = true,
    val refreshing: Boolean = false,
    val loaded: Boolean = false,
    val channels: List<ImChannel> = emptyList(),
    val loadError: UiText? = null,
    /** 正在开关、测试、删除的渠道。 */
    val busy: Set<String> = emptySet(),
) {
    /** 还能再绑（最多 20 个）。 */
    val canAdd: Boolean get() = channels.size < ImChannelRules.MAX_CHANNELS
}

/**
 * IM 渠道（13.15，路由 `im-channels`，设置 → IM 渠道）：绑定的群机器人，开关、发测试消息（关着的先提示打开，每小时 10 条）、
 * 删除（别处删了照样拿掉）；新建、修改在 [ImChannelEditorViewModel]。和 iOS 12.14 同一套规则。
 */
class ImChannelsViewModel(private val service: ThinktinService) : ViewModel() {
    private val state = MutableStateFlow(ImChannelsUiState())
    val uiState: StateFlow<ImChannelsUiState> = state.asStateFlow()

    private val eventChannel = Channel<ImChannelEvent>(Channel.BUFFERED)
    val events: Flow<ImChannelEvent> = eventChannel.receiveAsFlow()

    private var shownOnce = false

    init {
        load(initial = true)
    }

    /** 每次回到这页（从编辑页回来）重新拉。 */
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
                val channels = service.imChannels()
                state.update { it.copy(loading = false, refreshing = false, loaded = true, channels = channels) }
            } catch (e: ServiceError) {
                val text = ErrorText.of(e)
                if (state.value.loaded) eventChannel.trySend(ImChannelEvent.Notice(text))
                state.update { it.copy(loading = false, refreshing = false, loadError = if (it.loaded) null else text) }
            }
        }
    }

    fun setEnabled(channel: ImChannel, enabled: Boolean) = perform(channel) {
        val updated = service.updateImChannel(channel.id, ImChannelUpdate(enabled = enabled))
        replace(updated)
    }

    /** 发一条测试消息（经服务端的出箱，几秒内到群里；结果写回渠道的上次发送时间、错误）。 */
    fun sendTest(channel: ImChannel) {
        if (!channel.enabled) {
            eventChannel.trySend(ImChannelEvent.Notice(UiText(R.string.im_turn_on_first)))
            return
        }
        perform(channel) {
            try {
                service.testImChannel(channel.id)
                eventChannel.trySend(ImChannelEvent.Notice(UiText(R.string.im_test_queued)))
            } catch (e: ServiceError) {
                if (!e.isRateLimited) throw e
                eventChannel.trySend(
                    ImChannelEvent.Notice(UiText(R.string.im_test_rate_limited, listOf(ImChannelRules.TESTS_PER_HOUR))),
                )
            }
        }
    }

    fun delete(channel: ImChannel) = perform(channel) {
        service.deleteImChannel(channel.id)
        remove(channel.id)
    }

    private fun perform(channel: ImChannel, body: suspend () -> Unit) {
        if (channel.id in state.value.busy) return
        state.update { it.copy(busy = it.busy + channel.id) }
        viewModelScope.launch {
            try {
                body()
            } catch (e: ServiceError) {
                if (e.isNotFound) remove(channel.id) else eventChannel.trySend(ImChannelEvent.Notice(ErrorText.of(e)))
            } finally {
                state.update { it.copy(busy = it.busy - channel.id) }
            }
        }
    }

    private fun replace(channel: ImChannel) = state.update { s ->
        s.copy(channels = s.channels.map { if (it.id == channel.id) channel else it })
    }

    private fun remove(id: String) = state.update { s -> s.copy(channels = s.channels.filterNot { it.id == id }) }
}

data class ImChannelEditorUiState(
    val editing: Boolean,
    val loading: Boolean = editing,
    val loadError: UiText? = null,
    /** 修改的渠道（存过一部分后换成存好的，再点保存只做剩下的）。 */
    val original: ImChannel? = null,
    val webhookUrl: String = "",
    val secret: String = "",
    val label: String = "",
    val events: List<String> = ImEvents.ALL,
    /** 修改时：要不要换地址。 */
    val replacingWebhook: Boolean = false,
    val saving: Boolean = false,
    /** 点过保存（之后问题才标出来）。 */
    val attempted: Boolean = false,
) {
    /** 要填地址（新建，或者修改时打开了“换地址”）。 */
    val editsWebhook: Boolean get() = !editing || replacingWebhook

    /** 粘贴的地址是哪家的（还没粘完整也认得出）；修改时没换地址就是原来的。 */
    val vendor: String? get() = if (editsWebhook) ImChannelRules.vendorOf(webhookUrl) else original?.vendor

    val supportsSecret: Boolean get() = vendor?.let(ImChannelRules::supportsSecret) ?: true

    val webhookProblem: ImChannelRules.Problem? get() = if (editsWebhook) ImChannelRules.webhookProblem(webhookUrl) else null

    val secretProblem: ImChannelRules.Problem?
        get() = if (editsWebhook) vendor?.let { ImChannelRules.secretProblem(secret, it) } else null

    val labelProblem: ImChannelRules.Problem? get() = ImChannelRules.labelProblem(label.trim())
    val eventsProblem: ImChannelRules.Problem? get() = ImChannelRules.eventsProblem(events)

    val hasProblems: Boolean
        get() = webhookProblem != null || secretProblem != null || labelProblem != null || eventsProblem != null

    /** 修改时有没有改动。 */
    val hasChanges: Boolean
        get() = original == null || replacingWebhook || label.trim() != original.label ||
            events.toSet() != original.events.toSet()
}

/**
 * 绑定（`im-channels/new`）/ 修改（`im-channels/{id}/edit`）群机器人：地址（边粘边认出平台）、签名密钥（企业微信没有）、
 * 备注（64 字）、事件（至少一种）。修改时“换地址”打开才填新地址；先改备注和事件再换地址，换失败了再点只换地址。
 */
class ImChannelEditorViewModel(private val service: ThinktinService, private val channelId: String?) : ViewModel() {
    private val state = MutableStateFlow(ImChannelEditorUiState(editing = channelId != null))
    val uiState: StateFlow<ImChannelEditorUiState> = state.asStateFlow()

    private val eventChannel = Channel<ImChannelEvent>(Channel.BUFFERED)
    val events: Flow<ImChannelEvent> = eventChannel.receiveAsFlow()

    init {
        if (channelId != null) load()
    }

    fun load() {
        val id = channelId ?: return
        state.update { it.copy(loading = true, loadError = null) }
        viewModelScope.launch {
            try {
                val channel = service.imChannels().firstOrNull { it.id == id }
                state.update {
                    when {
                        channel == null -> it.copy(loading = false, loadError = UiText(R.string.im_missing))
                        it.original != null -> it.copy(loading = false)
                        else -> it.copy(
                            loading = false, original = channel, label = channel.label,
                            events = ImEvents.ALL.filter { e -> e in channel.events },
                        )
                    }
                }
            } catch (e: ServiceError) {
                state.update { it.copy(loading = false, loadError = ErrorText.of(e)) }
            }
        }
    }

    fun onWebhookUrl(value: String) = state.update { it.copy(webhookUrl = value) }

    fun onSecret(value: String) = state.update { it.copy(secret = value) }

    fun onLabel(value: String) = state.update { it.copy(label = value) }

    fun setReplacingWebhook(on: Boolean) = state.update { it.copy(replacingWebhook = on) }

    /** 勾选、取消一种事件；按固定顺序发。 */
    fun toggle(event: String) = state.update { s ->
        val chosen = if (event in s.events) s.events - event else s.events + event
        s.copy(events = ImEvents.ALL.filter { it in chosen })
    }

    fun save() {
        val current = state.value
        if (current.saving || current.loading || current.loadError != null) return
        state.update { it.copy(attempted = true) }
        if (current.hasProblems) return
        state.update { it.copy(saving = true) }
        val url = current.webhookUrl.trim()
        val secret = current.secret.trim().ifEmpty { null }
        val label = current.label.trim()
        viewModelScope.launch {
            try {
                val original = current.original
                val saved = if (original == null) {
                    service.addImChannel(NewImChannel(webhookUrl = url, secret = secret, label = label, events = current.events))
                } else {
                    var saved = original
                    val labelChanged = label != original.label
                    val eventsChanged = current.events.toSet() != original.events.toSet()
                    if (labelChanged || eventsChanged) {
                        saved = service.updateImChannel(
                            original.id,
                            ImChannelUpdate(
                                label = label.takeIf { labelChanged },
                                events = current.events.takeIf { eventsChanged },
                            ),
                        )
                        state.update { it.copy(original = saved) }
                    }
                    if (current.replacingWebhook) saved = service.replaceImWebhook(original.id, url, secret)
                    saved
                }
                state.update { it.copy(saving = false) }
                eventChannel.trySend(ImChannelEvent.Saved(saved))
            } catch (e: ServiceError) {
                state.update { it.copy(saving = false) }
                eventChannel.trySend(ImChannelEvent.Notice(ErrorText.of(e)))
            }
        }
    }
}
