package cn.thinktin.app.ui.agent

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.isInvalid
import cn.thinktin.app.ui.common.isRateLimited
import cn.thinktin.app.ui.common.retryAfterSeconds
import cn.thinktin.data.model.AgentInfo
import cn.thinktin.data.model.Instance
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
    /** 名字下面的提示（本地校验、服务端的 invalid / conflict）。 */
    val nameError: UiText? = null,
    /** 表单级的错误（限频、数量上限、已下架、网络……）。 */
    val error: UiText? = null,
    val submitting: Boolean = false,
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
)

sealed interface AgentDetailEvent {
    /** 领养成功：跳到对话页，并刷新抽屉的实例列表。 */
    data class Adopted(val instance: Instance) : AgentDetailEvent
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
        state.update { it.copy(adopt = AdoptForm(name = InstanceNames.clip(defaultName), harness = harness)) }
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

    fun adopt() {
        val agent = state.value.agent ?: return
        val form = state.value.adopt ?: return
        if (form.submitting) return
        InstanceNames.validate(form.name)?.let { error ->
            updateForm { it.copy(nameError = error) }
            return
        }
        // 只有一种接入方式时不传（服务端用默认的）。
        val harness = form.harness.takeIf { agent.harnesses.size > 1 }
        state.update { s -> s.copy(adopt = form.copy(submitting = true, nameError = null, error = null)) }
        viewModelScope.launch {
            try {
                val instance = service.adopt(agent.id, form.name.trim(), harness)
                state.update { it.copy(adopt = null) }
                eventChannel.send(AgentDetailEvent.Adopted(instance))
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
         * 领养失败 → （名字下的提示, 表单级错误）。
         * - invalid：服务端说名字不对时提示在名字下；其余（接入方式停用、版本下架）是表单级。
         * - conflict：和现有实例冲突（重名、并发），提示在名字下，换个名字再试。
         * - 限频 / 数量上限 / 额度：表单级，带剩余秒数。
         * - not_found：agent 已下架。
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
