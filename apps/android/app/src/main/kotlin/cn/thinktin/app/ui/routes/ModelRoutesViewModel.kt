package cn.thinktin.app.ui.routes

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.isInvalid
import cn.thinktin.app.ui.keys.KeyRules
import cn.thinktin.data.model.AgentInfo
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.ModelRoute
import cn.thinktin.data.model.RouteFallback
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

/** 降级链里的一项（编辑中）：[credentialId] 为 null 表示还没选 key。 */
data class FallbackDraft(val credentialId: String?, val model: String)

/** 一个别名（编辑中）。[id] 只在本地用来区分行（改别名不会换行）。 */
data class RouteDraft(
    val id: Long,
    val alias: String,
    val credentialId: String?,
    val model: String,
    val fallbacks: List<FallbackDraft> = emptyList(),
)

/** 一行的错误：别名、主 key、主模型；[fallbacks] 是降级链每一项的（key 错误, 模型错误）。 */
data class RouteErrors(
    val alias: UiText? = null,
    val credential: UiText? = null,
    val model: UiText? = null,
    val fallbacks: Map<Int, Pair<UiText?, UiText?>> = emptyMap(),
) {
    val isEmpty: Boolean get() = alias == null && credential == null && model == null && fallbacks.isEmpty()
}

data class ModelRoutesUiState(
    val loading: Boolean = true,
    val loadError: UiText? = null,
    val instance: Instance? = null,
    /** 实例的 agent（目录拉不到时为 null：不按协议过滤 key）。 */
    val agent: AgentInfo? = null,
    val credentials: List<Credential> = emptyList(),
    val vendors: Map<String, VendorInfo> = emptyMap(),
    val drafts: List<RouteDraft> = emptyList(),
    /** 服务端现在的别名（保存后更新）：顶部警告看它。 */
    val saved: List<ModelRoute> = emptyList(),
    val errors: Map<Long, RouteErrors> = emptyMap(),
    val formError: UiText? = null,
    val saving: Boolean = false,
) {
    /** agent 运行时用的协议：选的 key 都要支持它。 */
    val activeProtocol: String? get() = agent?.activeProtocol

    /** 服务端还没有 main：运行会等 key（顶部警告）。 */
    val mainMissing: Boolean get() = !loading && instance != null && saved.none { it.alias == KeyRules.MAIN_ALIAS }

    /** 可以选的 key：没停用、支持 agent 的协议。 */
    val usableCredentials: List<Credential> get() = credentials.filter { KeyRules.usable(it, activeProtocol) }

    /**
     * 实例原来就用着的 key（服务端现在的别名里的主 key 和降级项）：停用了也可以留着（11.9），保存时服务端只拒绝
     * 新引用的停用 key。
     */
    val keptCredentialIds: Set<String>
        get() = saved.flatMap { route -> listOf(route.credentialId) + route.fallbacks.map { it.credentialId } }.toSet()

    /** 选的 key 已停用、但实例原来就用着：不算错，只提示运行时会跳过它。 */
    fun keyWarning(credentialId: String?): UiText? {
        val credential = credentials.firstOrNull { it.id == credentialId } ?: return null
        return if (credential.disabled && credential.id in keptCredentialIds) UiText(R.string.routes_warning_key_disabled) else null
    }

    val canAddRoute: Boolean get() = drafts.size < KeyRules.MAX_ALIASES

    /** 和服务端的不一样（有没保存的改动）。 */
    val dirty: Boolean get() = ModelRoutesViewModel.toRoutes(drafts).sortedBy { it.alias } != saved.sortedBy { it.alias }
}

sealed interface ModelRoutesEvent {
    data class Message(val text: UiText) : ModelRoutesEvent
}

/**
 * 按实例的模型别名（13.4，路由 instance/{instanceId}/routes）：别名 → key + 上游模型，每个别名最多 3 个降级项（可排序）；
 * 默认别名 main 必填；保存调 setModelRoutes（整表替换）。key 按 agent 的协议过滤；停用的不能新选（服务端也拒绝），
 * 实例原来就用着的停用 key 可以留着（11.9，只提示运行时会跳过它）。
 */
class ModelRoutesViewModel(
    private val service: ThinktinService,
    private val instanceId: String,
) : ViewModel() {
    private val state = MutableStateFlow(ModelRoutesUiState())
    val uiState: StateFlow<ModelRoutesUiState> = state.asStateFlow()

    private val eventChannel = Channel<ModelRoutesEvent>(Channel.BUFFERED)
    val events: Flow<ModelRoutesEvent> = eventChannel.receiveAsFlow()

    private var nextId = 1L
    private var shownOnce = false

    init {
        load()
    }

    /** 从 key 列表、添加 key 页回来时重新取 key（不动正在编辑的别名）。 */
    fun onShown() {
        if (!shownOnce) {
            shownOnce = true
            return
        }
        refreshCredentials()
    }

    fun load() {
        state.update { it.copy(loading = true, loadError = null) }
        viewModelScope.launch {
            try {
                coroutineScope {
                    val instance = async { service.instance(instanceId) }
                    val routes = async { service.modelRoutes(instanceId) }
                    val credentials = async { service.credentials() }
                    val vendors = async { optional { service.vendors() } }
                    val agents = async { optional { service.agents() } }
                    val loaded = instance.await()
                    val saved = routes.await()
                    state.update { s ->
                        s.copy(
                            loading = false,
                            instance = loaded,
                            agent = agents.await()?.firstOrNull { it.id == loaded.agentId },
                            credentials = credentials.await(),
                            vendors = vendors.await()?.associateBy { it.id } ?: s.vendors,
                            saved = saved,
                            drafts = draftsOf(saved),
                            errors = emptyMap(),
                            formError = null,
                        )
                    }
                }
            } catch (e: ServiceError) {
                state.update { it.copy(loading = false, loadError = ErrorText.of(e)) }
            }
        }
    }

    private fun refreshCredentials() {
        viewModelScope.launch {
            try {
                val credentials = service.credentials()
                state.update { it.copy(credentials = credentials) }
            } catch (_: ServiceError) {
                // 刷新失败就用之前的。
            }
        }
    }

    private suspend fun <T> optional(block: suspend () -> T): T? = try {
        block()
    } catch (_: ServiceError) {
        null
    }

    /** 服务端的别名 → 编辑行；main 排第一；一个都没有时给一行空的 main。 */
    private fun draftsOf(routes: List<ModelRoute>): List<RouteDraft> {
        val sorted = routes.sortedBy { if (it.alias == KeyRules.MAIN_ALIAS) 0 else 1 }
        val drafts = sorted.map { route ->
            RouteDraft(
                id = nextId++,
                alias = route.alias,
                credentialId = route.credentialId,
                model = route.upstreamModel,
                fallbacks = route.fallbacks.map { FallbackDraft(it.credentialId, it.upstreamModel) },
            )
        }
        return drafts.ifEmpty { listOf(RouteDraft(nextId++, KeyRules.MAIN_ALIAS, null, "")) }
    }

    // ---- 编辑 ----

    fun addRoute() {
        if (!state.value.canAddRoute) return
        val alias = if (state.value.drafts.none { it.alias == KeyRules.MAIN_ALIAS }) KeyRules.MAIN_ALIAS else ""
        edit { drafts -> drafts + RouteDraft(nextId++, alias, null, "") }
    }

    fun removeRoute(id: Long) = edit { drafts -> drafts.filterNot { it.id == id } }

    fun onAliasChange(id: Long, alias: String) = editRoute(id) { it.copy(alias = alias.trim().lowercase()) }

    /** 选了 key：模型还空着时填上这家厂商推荐的第一个模型。 */
    fun onCredentialChange(id: Long, credentialId: String) = editRoute(id) { route ->
        route.copy(credentialId = credentialId, model = route.model.ifBlank { firstModel(credentialId) })
    }

    fun onModelChange(id: Long, model: String) = editRoute(id) { it.copy(model = model) }

    fun addFallback(id: Long) = editRoute(id) { route ->
        if (route.fallbacks.size >= KeyRules.MAX_FALLBACKS) route else route.copy(fallbacks = route.fallbacks + FallbackDraft(null, ""))
    }

    fun removeFallback(id: Long, index: Int) = editRoute(id) { route ->
        route.copy(fallbacks = route.fallbacks.filterIndexed { i, _ -> i != index })
    }

    /** 降级项上移（[up]）或下移一位。 */
    fun moveFallback(id: Long, index: Int, up: Boolean) = editRoute(id) { route ->
        val target = if (up) index - 1 else index + 1
        if (index !in route.fallbacks.indices || target !in route.fallbacks.indices) {
            route
        } else {
            val list = route.fallbacks.toMutableList()
            list[index] = list[target].also { list[target] = list[index] }
            route.copy(fallbacks = list)
        }
    }

    fun onFallbackCredentialChange(id: Long, index: Int, credentialId: String) = editFallback(id, index) { fallback ->
        fallback.copy(credentialId = credentialId, model = fallback.model.ifBlank { firstModel(credentialId) })
    }

    fun onFallbackModelChange(id: Long, index: Int, model: String) = editFallback(id, index) { it.copy(model = model) }

    /** 放弃没保存的改动。 */
    fun reset() {
        state.update { it.copy(drafts = draftsOf(it.saved), errors = emptyMap(), formError = null) }
    }

    private fun firstModel(credentialId: String): String {
        val s = state.value
        val vendor = s.credentials.firstOrNull { it.id == credentialId }?.vendor ?: return ""
        return s.vendors[vendor]?.models?.firstOrNull().orEmpty()
    }

    private fun edit(change: (List<RouteDraft>) -> List<RouteDraft>) {
        if (state.value.saving) return
        state.update { it.copy(drafts = change(it.drafts), errors = emptyMap(), formError = null) }
    }

    private fun editRoute(id: Long, change: (RouteDraft) -> RouteDraft) = edit { drafts ->
        drafts.map { if (it.id == id) change(it) else it }
    }

    private fun editFallback(id: Long, index: Int, change: (FallbackDraft) -> FallbackDraft) = editRoute(id) { route ->
        route.copy(fallbacks = route.fallbacks.mapIndexed { i, f -> if (i == index) change(f) else f })
    }

    // ---- 保存 ----

    /** 本地校验（main 必填、别名格式与重复、key 可用、模型 1–128 字）→ setModelRoutes（整表替换）→ 重新取。 */
    fun save() {
        val s = state.value
        if (s.saving || s.instance == null) return
        val (errors, formError) = validate(s)
        if (errors.isNotEmpty() || formError != null) {
            state.update { it.copy(errors = errors, formError = formError) }
            return
        }
        val routes = toRoutes(s.drafts)
        state.update { it.copy(saving = true, errors = emptyMap(), formError = null) }
        viewModelScope.launch {
            try {
                service.setModelRoutes(instanceId, routes)
                val saved = try {
                    service.modelRoutes(instanceId)
                } catch (_: ServiceError) {
                    routes
                }
                state.update { it.copy(saving = false, saved = saved, drafts = draftsOf(saved)) }
                eventChannel.send(ModelRoutesEvent.Message(UiText(R.string.routes_saved)))
            } catch (e: ServiceError) {
                state.update { it.copy(saving = false) }
                if (e is ServiceError.Api && e.isInvalid) {
                    // 多半是 key 刚被停用或删除：刷新 key 列表，提示重选。
                    state.update { it.copy(formError = UiText(R.string.routes_error_rejected)) }
                    refreshCredentials()
                } else {
                    eventChannel.send(ModelRoutesEvent.Message(ErrorText.of(e)))
                }
            }
        }
    }

    companion object {
        /** 编辑行 → 服务端的别名（main 在前）。 */
        fun toRoutes(drafts: List<RouteDraft>): List<ModelRoute> = drafts
            .sortedBy { if (it.alias == KeyRules.MAIN_ALIAS) 0 else 1 }
            .map { draft ->
                ModelRoute(
                    alias = draft.alias.trim(),
                    credentialId = draft.credentialId.orEmpty(),
                    upstreamModel = draft.model.trim(),
                    fallbacks = draft.fallbacks.map { RouteFallback(it.credentialId.orEmpty(), it.model.trim()) },
                )
            }

        /** 校验全部别名：返回每行的错误和表单级错误（没配 main、别名太多）。 */
        fun validate(s: ModelRoutesUiState): Pair<Map<Long, RouteErrors>, UiText?> {
            val errors = mutableMapOf<Long, RouteErrors>()
            val seen = mutableSetOf<String>()
            for (draft in s.drafts) {
                val alias = draft.alias.trim()
                val aliasError = KeyRules.checkAlias(alias)
                    ?: if (!seen.add(alias)) UiText(R.string.routes_error_alias_duplicate) else null
                val fallbackErrors = draft.fallbacks.mapIndexedNotNull { i, fallback ->
                    val keyError = credentialError(s, fallback.credentialId)
                        ?: if (fallback.credentialId == draft.credentialId && fallback.model.trim() == draft.model.trim()) {
                            UiText(R.string.routes_error_fallback_same)
                        } else {
                            null
                        }
                    val modelError = KeyRules.checkModel(fallback.model.trim())
                    if (keyError == null && modelError == null) null else i to (keyError to modelError)
                }.toMap()
                val rowErrors = RouteErrors(
                    alias = aliasError,
                    credential = credentialError(s, draft.credentialId),
                    model = KeyRules.checkModel(draft.model.trim()),
                    fallbacks = fallbackErrors,
                )
                if (!rowErrors.isEmpty) errors[draft.id] = rowErrors
            }
            val formError = when {
                s.drafts.none { it.alias.trim() == KeyRules.MAIN_ALIAS } -> UiText(R.string.routes_error_main_required)
                s.drafts.size > KeyRules.MAX_ALIASES -> UiText(R.string.routes_error_too_many, listOf(KeyRules.MAX_ALIASES))
                else -> null
            }
            return errors to formError
        }

        /** 协议名的文案（UiText 参数里可以再套 UiText）；不认识的原样。 */
        fun protocolText(protocol: String): Any = when (protocol) {
            "anthropic" -> UiText(R.string.protocol_anthropic)
            "chat" -> UiText(R.string.protocol_chat)
            "responses" -> UiText(R.string.protocol_responses)
            else -> protocol
        }

        private fun credentialError(s: ModelRoutesUiState, credentialId: String?): UiText? {
            if (credentialId == null) return UiText(R.string.routes_error_key_empty)
            val credential = s.credentials.firstOrNull { it.id == credentialId } ?: return UiText(R.string.routes_error_key_missing)
            return when {
                // 实例原来就用着的停用 key 可以留着（服务端 11.9 起也不拒）；新选的不行。
                credential.disabled && credential.id !in s.keptCredentialIds -> UiText(R.string.routes_error_key_disabled)
                !KeyRules.supports(credential, s.activeProtocol) ->
                    UiText(R.string.routes_error_key_protocol, listOf(protocolText(s.activeProtocol.orEmpty())))
                else -> null
            }
        }
    }
}
