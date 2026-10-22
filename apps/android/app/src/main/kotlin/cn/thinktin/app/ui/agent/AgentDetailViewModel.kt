package cn.thinktin.app.ui.agent

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.isInvalid
import cn.thinktin.app.ui.common.isRateLimited
import cn.thinktin.app.ui.common.retryAfterSeconds
import cn.thinktin.app.ui.keys.KeyRules
import cn.thinktin.data.model.AgentInfo
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.ModelRoute
import cn.thinktin.data.model.VendorInfo
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

/** 实例名的规则（服务端：去掉首尾空白后 1–64 个字）。 */
object InstanceNames {
    const val MAX_LENGTH: Int = 64

    /** 字数（按 Unicode 码点，和服务端一致）。 */
    fun length(name: String): Int = name.codePointCount(0, name.length)

    /** 本地校验：合规返回 null，否则返回字段下的提示。 */
    fun validate(name: String): UiText? {
        val trimmed = name.trim()
        return when {
            trimmed.isEmpty() -> UiText(R.string.instance_name_required)
            length(trimmed) > MAX_LENGTH -> UiText(R.string.instance_name_too_long, listOf(MAX_LENGTH))
            else -> null
        }
    }

    /** 截到上限（默认名“<agent 名> 的实例”可能超长）。 */
    fun clip(name: String): String {
        if (length(name) <= MAX_LENGTH) return name
        return name.substring(0, name.offsetByCodePoints(0, MAX_LENGTH))
    }
}

/** 领养表单（详情页底部）。 */
data class AdoptForm(
    val name: String,
    /** 选中的接入方式（默认 defaultHarness）。 */
    val harness: String,
    /**
     * 默认模型（别名 main）用哪把 key；null 表示跳过（领养后打开模型别名页再配）。
     * key 列表到了之后默认选第一把能用的（用户自己选过就不动）。
     */
    val credentialId: String? = null,
    /** main 的上游模型（选 key 时预填这家厂商推荐的第一个）。 */
    val model: String = "",
    /** 用户自己选过 key 或“跳过”。 */
    val keyChosen: Boolean = false,
    /** 用户自己改过模型名（换 key 时不再覆盖）。 */
    val modelEdited: Boolean = false,
    /** 名字下面的提示（本地校验、服务端的 invalid）。 */
    val nameError: UiText? = null,
    /** 模型名下面的提示。 */
    val modelError: UiText? = null,
    /** 表单级的错误（限频、已下架、网络……）。 */
    val error: UiText? = null,
    val submitting: Boolean = false,
)

/** 领养表单里选 key 用的数据（打开表单时取一次）。 */
data class AdoptKeys(
    val loading: Boolean = true,
    /** 取 key 列表失败（只能跳过，领养后到模型别名页配）。 */
    val failed: Boolean = false,
    /** 能给这个 agent 用的 key：没停用、支持它运行时用的协议。 */
    val usable: List<Credential> = emptyList(),
    val vendors: Map<String, VendorInfo> = emptyMap(),
)

data class AgentDetailUiState(
    val loading: Boolean = true,
    val agent: AgentInfo? = null,
    /** 拉取失败（显示错误和“重试”）。 */
    val loadError: UiText? = null,
    /** 目录里没有这个 agent（已下架或链接不对）。 */
    val notFound: Boolean = false,
    /** 领养表单打开时非空。 */
    val adopt: AdoptForm? = null,
    /** 领养表单里的 key 列表（第一次打开表单时取）。 */
    val keys: AdoptKeys = AdoptKeys(),
)

sealed interface AgentDetailEvent {
    /**
     * 领养成功：刷新抽屉的实例列表；[routesConfigured] 为真（选了 key 且 main 配好了）跳到对话页，
     * 否则（跳过、没有能用的 key、配 main 失败）打开模型别名页，免得第一次运行就卡在等 key。
     */
    data class Adopted(val instance: Instance, val routesConfigured: Boolean) : AgentDetailEvent
}

/**
 * Agent 详情与领养（13.3，路由 agent/{agentId}）。目录接口没有单个 agent 的查询，从 [ThinktinService.agents] 里找。
 */
class AgentDetailViewModel(
    private val service: ThinktinService,
    private val agentId: String,
) : ViewModel() {
    private val state = MutableStateFlow(AgentDetailUiState())
    val uiState: StateFlow<AgentDetailUiState> = state.asStateFlow()

    private val eventChannel = Channel<AgentDetailEvent>(Channel.BUFFERED)
    val events: Flow<AgentDetailEvent> = eventChannel.receiveAsFlow()

    /** 正在取领养表单的 key 列表。 */
    private var keysLoading = false

    init {
        load()
    }

    fun load() {
        state.update { it.copy(loading = true, loadError = null, notFound = false) }
        viewModelScope.launch {
            try {
                val agent = service.agents().firstOrNull { it.id == agentId }
                state.update { it.copy(loading = false, agent = agent, notFound = agent == null) }
            } catch (e: ServiceError) {
                state.update { it.copy(loading = false, loadError = ErrorText.of(e)) }
            }
        }
    }

    /** 打开领养表单；[defaultName] 是界面按语言拼好的“<agent 名> 的实例”。 */
    fun openAdopt(defaultName: String) {
        val agent = state.value.agent ?: return
        if (state.value.adopt != null) return
        val harness = agent.defaultHarness.takeIf { it in agent.harnesses } ?: agent.harnesses.firstOrNull() ?: agent.defaultHarness
        val form = preselectKey(AdoptForm(name = InstanceNames.clip(defaultName), harness = harness), state.value.keys)
        state.update { it.copy(adopt = form) }
        if (state.value.keys.loading || state.value.keys.failed) loadKeys(agent)
    }

    /** 取 key 列表和厂商表（厂商表拉不到只是不能预填模型）。 */
    private fun loadKeys(agent: AgentInfo) {
        if (keysLoading) return
        keysLoading = true
        state.update { it.copy(keys = it.keys.copy(loading = true, failed = false)) }
        viewModelScope.launch {
            val keys = try {
                coroutineScope {
                    val vendors = async {
                        try {
                            service.vendors().associateBy { it.id }
                        } catch (_: ServiceError) {
                            emptyMap()
                        }
                    }
                    val usable = service.credentials().filter { KeyRules.usable(it, agent.activeProtocol) }
                    AdoptKeys(loading = false, usable = usable, vendors = vendors.await())
                }
            } catch (_: ServiceError) {
                AdoptKeys(loading = false, failed = true)
            }
            keysLoading = false
            state.update { s -> s.copy(keys = keys, adopt = s.adopt?.let { preselectKey(it, keys) }) }
        }
    }

    /** 用户还没自己选时，默认选第一把能用的 key，预填厂商推荐的第一个模型。 */
    private fun preselectKey(form: AdoptForm, keys: AdoptKeys): AdoptForm {
        if (form.keyChosen || form.submitting || keys.loading) return form
        val first = keys.usable.firstOrNull()
        return form.copy(credentialId = first?.id, model = first?.let { firstModel(it.id, keys) }.orEmpty(), modelEdited = false)
    }

    private fun firstModel(credentialId: String, keys: AdoptKeys): String {
        val vendor = keys.usable.firstOrNull { it.id == credentialId }?.vendor ?: return ""
        return keys.vendors[vendor]?.models?.firstOrNull().orEmpty()
    }

    /** 选 main 用的 key；null 是“跳过”。模型名没改过时换成这家厂商推荐的第一个。 */
    fun onKeyChange(credentialId: String?) {
        val keys = state.value.keys
        if (credentialId != null && keys.usable.none { it.id == credentialId }) return
        updateForm { form ->
            val model = when {
                credentialId == null -> form.model
                form.modelEdited && form.model.isNotBlank() -> form.model
                else -> firstModel(credentialId, keys)
            }
            form.copy(credentialId = credentialId, model = model, keyChosen = true, modelError = null, error = null)
        }
    }

    fun onModelChange(model: String) {
        updateForm { it.copy(model = model, modelEdited = true, modelError = null, error = null) }
    }

    /** 收起表单（提交中不能收）。 */
    fun closeAdopt() {
        if (state.value.adopt?.submitting == true) return
        state.update { it.copy(adopt = null) }
    }

    fun onNameChange(name: String) {
        updateForm { it.copy(name = name, nameError = null, error = null) }
    }

    fun onHarnessChange(harness: String) {
        val agent = state.value.agent ?: return
        if (harness !in agent.harnesses) return
        updateForm { it.copy(harness = harness, error = null) }
    }

    private fun updateForm(change: (AdoptForm) -> AdoptForm) {
        state.update { s -> s.adopt?.takeIf { !it.submitting }?.let { s.copy(adopt = change(it)) } ?: s }
    }

    /**
     * 领养：本地查名字（选了 key 时也查模型名）→ adopt → 选了 key 时 setModelRoutes 配好 main。
     * 配 main 失败不算领养失败（实例已经有了）：照样发 Adopted，只是 routesConfigured 为假，界面打开模型别名页。
     */
    fun adopt() {
        val agent = state.value.agent ?: return
        val form = state.value.adopt ?: return
        if (form.submitting) return
        val nameError = InstanceNames.validate(form.name)
        val credentialId = form.credentialId?.takeIf { id -> state.value.keys.usable.any { it.id == id } }
        val model = form.model.trim()
        val modelError = credentialId?.let { KeyRules.checkModel(model) }
        if (nameError != null || modelError != null) {
            updateForm { it.copy(nameError = nameError, modelError = modelError) }
            return
        }
        // 只有一种接入方式时不传（服务端用默认的）。
        val harness = form.harness.takeIf { agent.harnesses.size > 1 }
        state.update { s -> s.copy(adopt = form.copy(submitting = true, nameError = null, modelError = null, error = null)) }
        viewModelScope.launch {
            try {
                val instance = service.adopt(agent.id, form.name.trim(), harness)
                val configured = credentialId != null && try {
                    service.setModelRoutes(instance.id, listOf(ModelRoute(KeyRules.MAIN_ALIAS, credentialId, model, emptyList())))
                    true
                } catch (_: ServiceError) {
                    false
                }
                state.update { it.copy(adopt = null) }
                eventChannel.send(AgentDetailEvent.Adopted(instance, routesConfigured = configured))
            } catch (e: ServiceError) {
                val (nameError, error) = adoptError(e)
                state.update { s ->
                    s.copy(adopt = s.adopt?.copy(submitting = false, nameError = nameError, error = error))
                }
            }
        }
    }

    companion object {
        /**
         * 领养失败 → （名字下的提示, 表单级错误）。服务端（control 的 adopt）目前只会返回：
         * - 404 not_found：agent 不在目录里（已下架）。
         * - 422 invalid：名字不对时提示在名字下；其余（版本下架、版本不存在、接入方式不对）是表单级。
         * 另外通用的限频（429）、网络错误照常处理。
         * 409 conflict 和 instance_limit / quota 这类数量上限服务端现在不返回（实例名没有唯一约束，也没有数量上限），
         * 分支留着防将来加上。
         */
        fun adoptError(e: ServiceError): Pair<UiText?, UiText?> {
            if (e !is ServiceError.Api) return null to ErrorText.of(e)
            return when {
                e.isRateLimited -> null to (
                    e.retryAfterSeconds?.let { UiText(R.string.adopt_rate_limited, listOf(it)) }
                        ?: UiText(R.string.adopt_rate_limited_plain)
                    )
                e.code.contains("limit") || e.code.startsWith("quota") ->
                    null to UiText(R.string.adopt_limit_reached)
                e.code == "conflict" || e.status == 409 -> UiText(R.string.adopt_conflict) to null
                e.code == "not_found" || e.status == 404 -> null to UiText(R.string.adopt_agent_gone)
                e.isInvalid && e.detail.contains("name", ignoreCase = true) ->
                    UiText(R.string.instance_name_too_long, listOf(InstanceNames.MAX_LENGTH)) to null
                e.isInvalid -> null to UiText(R.string.adopt_invalid)
                else -> null to ErrorText.of(e)
            }
        }
    }
}
