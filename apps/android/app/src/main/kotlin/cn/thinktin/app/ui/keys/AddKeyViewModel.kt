package cn.thinktin.app.ui.keys

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.isInvalid
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.NewCredential
import cn.thinktin.data.model.VendorInfo
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
import java.net.URI

/** 添加 key 的两步：选厂商 → 填 key。 */
enum class AddKeyStep {
    Vendor,
    Details,
}

/** 表单里能挂错误提示的字段。 */
enum class AddKeyField {
    Label,
    AnthropicBase,
    OpenaiBase,
    ResponsesBase,
    Protocols,
    DailyLimit,
}

data class AddKeyUiState(
    val loading: Boolean = true,
    val vendors: List<VendorInfo> = emptyList(),
    val loadError: UiText? = null,
    val step: AddKeyStep = AddKeyStep.Vendor,
    /** 选中的预置厂商；自定义接口时为 null 且 [custom] 为真。 */
    val vendor: VendorInfo? = null,
    val custom: Boolean = false,
    val key: KeyInput = KeyInput(),
    val label: String = "",
    /** 自定义接口提供哪些协议（每种一个地址）。 */
    val customProtocols: Set<String> = setOf("chat"),
    val anthropicBase: String = "",
    val openaiBase: String = "",
    val responsesBase: String = "",
    val dailyLimit: String = "",
    val errors: Map<AddKeyField, UiText> = emptyMap(),
    /** 不属于某个字段的错误（厂商不认识、服务端其他的 invalid）。 */
    val formError: UiText? = null,
    val submitting: Boolean = false,
    /** 已经加好（等页面退出）：不能再提交，key 明文已经清掉。 */
    val done: Boolean = false,
) {
    /** 表单能不能改、能不能提交。 */
    val editable: Boolean get() = !submitting && !done

    /** 第一步的分组（自定义接口在界面上单独放最后）。 */
    val groups: List<KeyRules.VendorGroup> get() = KeyRules.groupVendors(vendors)

    /** 厂商 id（提交用）。 */
    val vendorId: String get() = if (custom) KeyRules.CUSTOM_VENDOR else vendor?.id.orEmpty()

    /** 有订阅类 key 前缀要拒绝的厂商：输入框下提示“只接按量付费 key”。 */
    val refusesSubscriptionKeys: Boolean get() = KeyRules.SUBSCRIPTION_PREFIXES.containsKey(vendorId)
}

sealed interface AddKeyEvent {
    data class Added(val credential: Credential) : AddKeyEvent

    data class Message(val text: UiText) : AddKeyEvent
}

/**
 * 添加 key（13.4，路由 keys/new）：第一步选厂商（vendors()，按协议分组，最后是自定义接口），第二步填 key（密码输入、
 * 粘贴整理）、标签（默认厂商名）、自定义接口的地址（按协议，本地查 https 和公网主机）、可选每日 token 限额。
 * 本地先按服务端的规则查一遍；服务端返回的 invalid 按说的字段挂到字段下。成功后回列表。
 */
class AddKeyViewModel(private val service: ThinktinService) : ViewModel() {
    private val state = MutableStateFlow(AddKeyUiState())
    val uiState: StateFlow<AddKeyUiState> = state.asStateFlow()

    private val eventChannel = Channel<AddKeyEvent>(Channel.BUFFERED)
    val events: Flow<AddKeyEvent> = eventChannel.receiveAsFlow()

    init {
        load()
    }

    fun load() {
        state.update { it.copy(loading = true, loadError = null) }
        viewModelScope.launch {
            try {
                val vendors = service.vendors()
                state.update { it.copy(loading = false, vendors = vendors) }
            } catch (e: ServiceError) {
                state.update { it.copy(loading = false, loadError = ErrorText.of(e)) }
            }
        }
    }

    fun selectVendor(vendor: VendorInfo) {
        state.update { s ->
            // 标签默认是厂商名；用户在上一次选的厂商下改过标签就保留。
            val keepLabel = s.label.isNotBlank() && s.label != s.vendor?.name
            s.copy(
                step = AddKeyStep.Details,
                vendor = vendor,
                custom = false,
                label = if (keepLabel) s.label else vendor.name,
                errors = emptyMap(),
                formError = null,
                key = s.key.copy(error = s.key.value.takeIf { it.isNotEmpty() }?.let { KeyRules.checkKey(vendor.id, it) }),
            )
        }
    }

    fun selectCustom() {
        state.update { s ->
            val keepLabel = s.label.isNotBlank() && s.label != s.vendor?.name
            s.copy(
                step = AddKeyStep.Details,
                vendor = null,
                custom = true,
                label = if (keepLabel) s.label else "",
                errors = emptyMap(),
                formError = null,
                key = s.key.copy(error = null),
            )
        }
    }

    /** 第二步按返回：回到选厂商（已经填的保留）。返回真表示处理了。 */
    fun backToVendors(): Boolean {
        if (state.value.step != AddKeyStep.Details || !state.value.editable) return false
        state.update { it.copy(step = AddKeyStep.Vendor, formError = null) }
        return true
    }

    fun onKeyChange(raw: String) {
        state.update { s -> s.copy(key = s.key.change(raw, s.vendorId), formError = null) }
    }

    fun toggleKeyVisible() {
        state.update { s -> s.copy(key = s.key.copy(visible = !s.key.visible)) }
    }

    fun onLabelChange(label: String) = updateField(AddKeyField.Label) { it.copy(label = label) }

    fun onDailyLimitChange(text: String) = updateField(AddKeyField.DailyLimit) { it.copy(dailyLimit = text) }

    fun onBaseChange(protocol: String, url: String) = when (protocol) {
        "anthropic" -> updateField(AddKeyField.AnthropicBase) { it.copy(anthropicBase = url) }
        "chat" -> updateField(AddKeyField.OpenaiBase) { it.copy(openaiBase = url) }
        "responses" -> updateField(AddKeyField.ResponsesBase) { it.copy(responsesBase = url) }
        else -> Unit
    }

    /** 自定义接口：勾选 / 取消一种协议（每种协议一个地址）。 */
    fun toggleProtocol(protocol: String) {
        if (protocol !in KeyRules.PROTOCOLS) return
        updateField(AddKeyField.Protocols) { s ->
            val next = if (protocol in s.customProtocols) s.customProtocols - protocol else s.customProtocols + protocol
            s.copy(customProtocols = next, errors = s.errors - fieldOf(protocol))
        }
    }

    private fun updateField(field: AddKeyField, change: (AddKeyUiState) -> AddKeyUiState) {
        state.update { s -> change(s).let { it.copy(errors = it.errors - field, formError = null) } }
    }

    /** 本地校验 + 提交。 */
    fun submit() {
        val s = state.value
        if (!s.editable || s.step != AddKeyStep.Details) return
        val vendorId = s.vendorId
        val key = s.key.value.trim()
        val keyError = KeyRules.checkKey(vendorId, key)
        val errors = mutableMapOf<AddKeyField, UiText>()
        val label = s.label.trim()
        KeyRules.checkLabel(label)?.let { errors[AddKeyField.Label] = it }
        val limit = when (val parsed = KeyRules.parseDailyLimit(s.dailyLimit)) {
            KeyRules.DailyLimit.None -> null
            is KeyRules.DailyLimit.Value -> parsed.tokens
            is KeyRules.DailyLimit.Invalid -> {
                errors[AddKeyField.DailyLimit] = parsed.error
                null
            }
        }
        var anthropic: String? = null
        var openai: String? = null
        var responses: String? = null
        if (s.custom) {
            if (s.customProtocols.isEmpty()) errors[AddKeyField.Protocols] = UiText(R.string.key_error_protocols_empty)
            for (protocol in KeyRules.PROTOCOLS.filter { it in s.customProtocols }) {
                val url = baseOf(s, protocol).trim().trimEnd('/')
                val error = KeyRules.checkBase(url)
                if (error != null) {
                    errors[fieldOf(protocol)] = error
                } else {
                    when (protocol) {
                        "anthropic" -> anthropic = url
                        "chat" -> openai = url
                        "responses" -> responses = url
                    }
                }
            }
        }
        if (keyError != null || errors.isNotEmpty()) {
            state.update { it.copy(key = it.key.copy(error = keyError), errors = errors, formError = null) }
            return
        }
        val request = NewCredential(
            vendor = vendorId,
            // 自定义接口没填标签时用地址的主机名。
            label = label.ifEmpty { if (s.custom) defaultCustomLabel(anthropic ?: openai ?: responses) else s.vendor?.name.orEmpty() },
            apiKey = key,
            anthropicBase = anthropic,
            openaiBase = openai,
            responsesBase = responses,
            dailyTokenLimit = limit,
        )
        state.update { it.copy(submitting = true, key = it.key.copy(error = null), errors = emptyMap(), formError = null) }
        viewModelScope.launch {
            try {
                val created = service.addCredential(request)
                // 页面退出动画期间还能点到按钮：标成已完成，不再提交；key 明文不留在内存里。
                state.update { it.copy(submitting = false, done = true, key = KeyInput()) }
                eventChannel.send(AddKeyEvent.Added(created))
            } catch (e: ServiceError) {
                state.update { it.copy(submitting = false) }
                if (e is ServiceError.Api && e.isInvalid) {
                    applyServerError(e)
                } else {
                    eventChannel.send(AddKeyEvent.Message(ErrorText.of(e)))
                }
            }
        }
    }

    /** 服务端的 invalid 按 detail 里说的字段挂到字段下（detail 只用来定位字段，显示的是本地文案）。 */
    private fun applyServerError(e: ServiceError.Api) {
        val detail = e.detail.lowercase()
        state.update { s ->
            when {
                // 地址的错误先认（套餐地址的说明里也有 subscription 这个词）。
                "anthropic_base" in detail -> s.copy(errors = s.errors + (AddKeyField.AnthropicBase to baseRejected(detail)))
                "responses_base" in detail -> s.copy(errors = s.errors + (AddKeyField.ResponsesBase to baseRejected(detail)))
                "openai_base" in detail -> s.copy(errors = s.errors + (AddKeyField.OpenaiBase to baseRejected(detail)))
                "api_key" in detail || "subscription" in detail || "api key" in detail ->
                    s.copy(key = s.key.copy(error = serverKeyError(e)))
                // 服务端的“unknown vendor: …, or custom with your own base URLs”里也有 base url，先认厂商。
                "unknown vendor" in detail -> s.copy(formError = UiText(R.string.key_error_vendor))
                "base url" in detail -> s.copy(formError = UiText(R.string.key_error_base_rejected))
                "label" in detail -> s.copy(errors = s.errors + (AddKeyField.Label to UiText(R.string.key_error_label_long, listOf(KeyRules.MAX_LABEL_LENGTH))))
                "daily_token_limit" in detail -> s.copy(errors = s.errors + (AddKeyField.DailyLimit to UiText(R.string.key_error_limit_positive)))
                "vendor" in detail -> s.copy(formError = UiText(R.string.key_error_vendor))
                else -> s.copy(formError = UiText(R.string.key_error_rejected))
            }
        }
    }

    private fun baseRejected(detail: String): UiText =
        if ("plan" in detail) UiText(R.string.key_error_base_plan_server) else UiText(R.string.key_error_base_rejected)

    companion object {
        fun fieldOf(protocol: String): AddKeyField = when (protocol) {
            "anthropic" -> AddKeyField.AnthropicBase
            "responses" -> AddKeyField.ResponsesBase
            else -> AddKeyField.OpenaiBase
        }

        fun baseOf(s: AddKeyUiState, protocol: String): String = when (protocol) {
            "anthropic" -> s.anthropicBase
            "responses" -> s.responsesBase
            else -> s.openaiBase
        }

        /** 自定义接口的默认标签：地址的主机名（按码点截到标签上限）。 */
        fun defaultCustomLabel(url: String?): String {
            val host = url?.let { runCatching { URI(it).host }.getOrNull() }.orEmpty()
            return KeyRules.clip(host, KeyRules.MAX_LABEL_LENGTH)
        }
    }
}
