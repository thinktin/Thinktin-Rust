package cn.thinktin.app.ui.keys

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.isInvalid
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.CredentialUpdate
import cn.thinktin.data.model.VendorInfo
import cn.thinktin.data.service.ServiceError
import cn.thinktin.data.service.ThinktinService
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch

/** 编辑、换 key 页面的结果。 */
sealed interface KeyFormEvent {
    data class Saved(val credential: Credential) : KeyFormEvent

    data class Message(val text: UiText) : KeyFormEvent
}

/** 从 credentials() 里找出一把 key（没有单个查询的接口），顺便取厂商表（拉不到不影响）。 */
internal suspend fun loadCredential(
    service: ThinktinService,
    credentialId: String,
): Pair<Credential?, Map<String, VendorInfo>> {
    val credential = service.credentials().firstOrNull { it.id == credentialId }
    val vendors = try {
        service.vendors().associateBy { it.id }
    } catch (_: ServiceError) {
        emptyMap()
    }
    return credential to vendors
}

data class KeyEditUiState(
    val loading: Boolean = true,
    val credential: Credential? = null,
    val vendors: Map<String, VendorInfo> = emptyMap(),
    /** 找不到这把 key（已删除）。 */
    val missing: Boolean = false,
    val loadError: UiText? = null,
    val label: String = "",
    val disabled: Boolean = false,
    /** 每日 token 上限（输入框里的文字）：空表示不限。 */
    val dailyLimit: String = "",
    val labelError: UiText? = null,
    val dailyLimitError: UiText? = null,
    val saving: Boolean = false,
    /** 已经发出 Saved（等页面退出）：不再保存，免得退出动画期间再点一次多弹一层返回栈。 */
    val finished: Boolean = false,
) {
    val editable: Boolean get() = credential != null && !saving && !finished
}

/**
 * 编辑 key（路由 keys/{credentialId}/edit）：标签、停用 / 启用（updateCredential，给了才改）、每日 token 上限
 * （setCredentialDailyLimit，11.9：清空就是取消上限）。两个接口分开调，只调改了的；前一个成功、后一个失败时，
 * 页面上的 key 换成前一个的结果，再点保存只重试没成功的那个。
 */
class KeyEditViewModel(
    private val service: ThinktinService,
    private val credentialId: String,
) : ViewModel() {
    private val state = MutableStateFlow(KeyEditUiState())
    val uiState: StateFlow<KeyEditUiState> = state.asStateFlow()

    private val eventChannel = Channel<KeyFormEvent>(Channel.BUFFERED)
    val events: Flow<KeyFormEvent> = eventChannel.receiveAsFlow()

    init {
        load()
    }

    fun load() {
        state.value = state.value.copy(loading = state.value.credential == null, loadError = null)
        viewModelScope.launch {
            try {
                val (credential, vendors) = loadCredential(service, credentialId)
                val s = state.value
                state.value = if (credential == null) {
                    s.copy(loading = false, missing = true)
                } else {
                    // 用户已经改过的不覆盖。
                    val untouched = s.credential == null
                    s.copy(
                        loading = false,
                        credential = credential,
                        vendors = vendors,
                        missing = false,
                        label = if (untouched) credential.label else s.label,
                        disabled = if (untouched) credential.disabled else s.disabled,
                        dailyLimit = if (untouched) limitText(credential.dailyTokenLimit) else s.dailyLimit,
                    )
                }
            } catch (e: ServiceError) {
                state.value = state.value.copy(loading = false, loadError = ErrorText.of(e))
            }
        }
    }

    fun onLabelChange(label: String) {
        state.value = state.value.copy(label = label, labelError = null)
    }

    fun onDisabledChange(disabled: Boolean) {
        state.value = state.value.copy(disabled = disabled)
    }

    fun onDailyLimitChange(text: String) {
        state.value = state.value.copy(dailyLimit = text, dailyLimitError = null)
    }

    fun save() {
        val s = state.value
        val credential = s.credential ?: return
        if (s.saving || s.finished) return
        val label = s.label.trim()
        val labelError = KeyRules.checkLabel(label)
        val limit = when (val parsed = KeyRules.parseDailyLimit(s.dailyLimit)) {
            KeyRules.DailyLimit.None -> null
            is KeyRules.DailyLimit.Value -> parsed.tokens
            is KeyRules.DailyLimit.Invalid -> {
                state.value = s.copy(labelError = labelError, dailyLimitError = parsed.error)
                return
            }
        }
        if (labelError != null) {
            state.value = s.copy(labelError = labelError)
            return
        }
        val update = CredentialUpdate(
            label = label.takeIf { it != credential.label },
            disabled = s.disabled.takeIf { it != credential.disabled },
        )
        val updateNeeded = update.label != null || update.disabled != null
        val limitChanged = limit != credential.dailyTokenLimit
        if (!updateNeeded && !limitChanged) {
            state.value = s.copy(finished = true)
            eventChannel.trySend(KeyFormEvent.Saved(credential))
            return
        }
        state.value = s.copy(saving = true, labelError = null, dailyLimitError = null)
        viewModelScope.launch {
            var current = credential
            // 标签、停用保存好了（或者不用改）：之后的 invalid 只能是每日上限的。
            var updateDone = !updateNeeded
            try {
                if (updateNeeded) {
                    current = service.updateCredential(credentialId, update)
                    updateDone = true
                    state.value = state.value.copy(credential = current)
                }
                if (limitChanged) {
                    current = service.setCredentialDailyLimit(credentialId, limit)
                }
                state.value = state.value.copy(
                    saving = false,
                    finished = true,
                    credential = current,
                    label = current.label,
                    disabled = current.disabled,
                    dailyLimit = limitText(current.dailyTokenLimit),
                )
                eventChannel.send(KeyFormEvent.Saved(current))
            } catch (e: ServiceError) {
                state.value = state.value.copy(saving = false)
                when {
                    e is ServiceError.Api && e.isInvalid && updateDone ->
                        state.value = state.value.copy(dailyLimitError = UiText(R.string.key_error_limit_positive))
                    e is ServiceError.Api && e.isInvalid ->
                        state.value = state.value.copy(
                            labelError = UiText(R.string.key_error_label_long, listOf(KeyRules.MAX_LABEL_LENGTH)),
                        )
                    else -> eventChannel.send(KeyFormEvent.Message(ErrorText.of(e)))
                }
            }
        }
    }

    companion object {
        /** 上限 → 输入框里的文字（不带千分位，免得编辑时光标乱跳）；不限是空的。 */
        fun limitText(limit: Long?): String = limit?.toString().orEmpty()
    }
}

data class KeySecretUiState(
    val loading: Boolean = true,
    val credential: Credential? = null,
    val vendors: Map<String, VendorInfo> = emptyMap(),
    val missing: Boolean = false,
    val loadError: UiText? = null,
    val key: KeyInput = KeyInput(),
    val saving: Boolean = false,
    /** 已经换好（等页面退出）：不再保存。 */
    val finished: Boolean = false,
)

/**
 * 输入 key 的状态（添加和换 key 共用）：[value] 是去掉粘贴带进来的空白、引号等之后的值，[pasted] 表示刚才是粘贴的
 * （一次进来很多字符），[cleaned] 表示粘贴的内容被整理过。[visible] 是“显示 key”。
 */
data class KeyInput(
    val value: String = "",
    val visible: Boolean = false,
    val pasted: Boolean = false,
    val cleaned: Boolean = false,
    val error: UiText? = null,
) {
    /**
     * 输入框的值变了：一次多出 [PASTE_THRESHOLD] 个以上字符当作粘贴，整理一下并马上检查（订阅类 key 按 [vendor] 的
     * 前缀当场提示；自定义接口、厂商表拉不到时为 null，不查前缀）；手打的不打扰，提交时再查。
     */
    fun change(raw: String, vendor: VendorInfo?): KeyInput {
        val pastedNow = raw.length - value.length >= PASTE_THRESHOLD
        if (!pastedNow) return copy(value = raw, pasted = false, cleaned = false, error = null)
        val cleanedValue = KeyRules.cleanPastedKey(raw)
        return copy(
            value = cleanedValue,
            pasted = true,
            cleaned = cleanedValue != raw,
            error = KeyRules.checkKey(vendor, cleanedValue),
        )
    }

    companion object {
        const val PASTE_THRESHOLD = 8
    }
}

/** 服务端说 key 不对（invalid）：订阅类 key 有专门的提示，其余按格式不对。 */
internal fun serverKeyError(e: ServiceError.Api): UiText =
    if (e.detail.contains("subscription", ignoreCase = true)) {
        UiText(R.string.key_error_subscription_server)
    } else {
        UiText(R.string.key_error_key_rejected)
    }

/**
 * 换 key（路由 keys/{credentialId}/secret）：同一个厂商、同一条记录，模型别名不用改；等 key 的运行会接着跑。
 */
class KeySecretViewModel(
    private val service: ThinktinService,
    private val credentialId: String,
) : ViewModel() {
    private val state = MutableStateFlow(KeySecretUiState())
    val uiState: StateFlow<KeySecretUiState> = state.asStateFlow()

    private val eventChannel = Channel<KeyFormEvent>(Channel.BUFFERED)
    val events: Flow<KeyFormEvent> = eventChannel.receiveAsFlow()

    init {
        load()
    }

    fun load() {
        state.value = state.value.copy(loading = state.value.credential == null, loadError = null)
        viewModelScope.launch {
            try {
                val (credential, vendors) = loadCredential(service, credentialId)
                state.value = state.value.copy(
                    loading = false,
                    credential = credential ?: state.value.credential,
                    vendors = vendors,
                    missing = credential == null,
                )
            } catch (e: ServiceError) {
                state.value = state.value.copy(loading = false, loadError = ErrorText.of(e))
            }
        }
    }

    fun onKeyChange(raw: String) {
        val credential = state.value.credential ?: return
        state.value = state.value.copy(key = state.value.key.change(raw, state.value.vendors[credential.vendor]))
    }

    fun toggleVisible() {
        state.value = state.value.copy(key = state.value.key.copy(visible = !state.value.key.visible))
    }

    fun save() {
        val s = state.value
        val credential = s.credential ?: return
        if (s.saving || s.finished) return
        val key = s.key.value.trim()
        KeyRules.checkKey(s.vendors[credential.vendor], key)?.let { error ->
            state.value = s.copy(key = s.key.copy(error = error))
            return
        }
        state.value = s.copy(saving = true, key = s.key.copy(error = null))
        viewModelScope.launch {
            try {
                val updated = service.replaceCredentialSecret(credentialId, key)
                state.value = state.value.copy(saving = false, finished = true, credential = updated, key = KeyInput())
                eventChannel.send(KeyFormEvent.Saved(updated))
            } catch (e: ServiceError) {
                state.value = state.value.copy(saving = false)
                if (e is ServiceError.Api && e.isInvalid) {
                    state.value = state.value.copy(key = state.value.key.copy(error = serverKeyError(e)))
                } else {
                    eventChannel.send(KeyFormEvent.Message(ErrorText.of(e)))
                }
            }
        }
    }
}
