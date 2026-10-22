package cn.thinktin.app.ui.instance

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.AgentInfo
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.Plan
import cn.thinktin.data.model.Team
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
import java.time.Clock

/**
 * 删除实例会影响到的东西（第 8.6 节）。服务端删实例只是软删除（state = deleted）：团队读取时不再列出它；
 * 其他计划里引用它的流水线步骤和它的模型别名都还留着（步骤之后运行会失败）。确认框照样列出来，让用户知道去改哪些计划。
 * 设计规范 8.6 写的“级联删除”和后端实现不一致，待 backend-core 确认以哪边为准。
 */
data class DeleteImpact(
    /** 这个实例自己的计划（实例删了就不会再运行）。 */
    val ownPlans: List<Plan> = emptyList(),
    /** 别的计划里有步骤用到它：这些步骤之后运行会失败（服务端不会自动删掉）。 */
    val pipelinePlans: List<Plan> = emptyList(),
    /** 它是成员的团队：会从团队里移除。 */
    val teams: List<Team> = emptyList(),
) {
    val isEmpty: Boolean get() = ownPlans.isEmpty() && pipelinePlans.isEmpty() && teams.isEmpty()

    /** [plan] 里引用这个实例的步骤数。 */
    fun removedSteps(plan: Plan, instanceId: String): Int = plan.steps.count { it.instanceId == instanceId }

    companion object {
        /** 从全部计划和团队里找出引用 [instanceId] 的。 */
        fun of(instanceId: String, plans: List<Plan>, teams: List<Team>): DeleteImpact {
            val own = plans.filter { it.instanceId == instanceId }
            val pipelines = plans.filter { plan -> plan.instanceId != instanceId && plan.steps.any { it.instanceId == instanceId } }
            val memberOf = teams.filter { team -> team.members.any { it.instanceId == instanceId } }
            return DeleteImpact(own, pipelines, memberOf)
        }
    }
}

/** 可以切换到的一个版本。 */
data class VersionOption(
    val version: String,
    /** 比当前版本旧（回滚）；否则是升级到比当前新、但不是最新的版本。 */
    val older: Boolean,
)

/** 页面上同时只开一个对话框。 */
sealed interface InstanceDialog {
    /** 换版本：[version] 为 null 表示升级到最新（[target] 是最新版本号）。 */
    data class ChangeVersion(val version: String?, val target: String, val older: Boolean) : InstanceDialog

    /** 删除第一步：列出受影响的计划和团队。 */
    data class DeleteImpactNotice(val impact: DeleteImpact) : InstanceDialog

    /** 删除第二步：最后确认。 */
    data class DeleteConfirm(val impact: DeleteImpact) : InstanceDialog
}

data class InstanceSettingsUiState(
    val loading: Boolean = true,
    val instance: Instance? = null,
    /** 这个实例的 agent（目录拉取失败时为 null：只显示 id，没有版本选项）。 */
    val agent: AgentInfo? = null,
    val loadError: UiText? = null,
    val dialog: InstanceDialog? = null,
    /** 对话框里的操作进行中。 */
    val busy: Boolean = false,
    /** 正在查删除会影响的计划和团队。 */
    val checkingImpact: Boolean = false,
    val nowMs: Long = 0,
) {
    /** 目录里的最新版本。 */
    val latestVersion: String? get() = agent?.version

    /** 当前不是最新版本：显示“升级到最新”。 */
    val canUpgrade: Boolean
        get() {
            val inst = instance ?: return false
            val latest = latestVersion ?: return false
            return inst.agentVersion != latest
        }

    /** 除了当前和最新之外能切换的版本（目录里的顺序：新的在前）。 */
    val otherVersions: List<VersionOption>
        get() {
            val inst = instance ?: return emptyList()
            val agent = agent ?: return emptyList()
            val versions = agent.versions.ifEmpty { listOf(agent.version) }
            val current = versions.indexOf(inst.agentVersion)
            return versions.withIndex()
                .filter { it.value != inst.agentVersion && it.value != agent.version }
                .map { VersionOption(it.value, older = current < 0 || it.index > current) }
        }
}

sealed interface InstanceSettingsEvent {
    /** 删掉了：回首页，刷新抽屉。 */
    data object Deleted : InstanceSettingsEvent

    /** 实例变了（换了版本）：刷新抽屉。 */
    data object Changed : InstanceSettingsEvent

    data class Message(val text: UiText) : InstanceSettingsEvent
}

/**
 * 实例设置（13.3，路由 instance/{instanceId}）：名字、agent 与版本（升级 / 回滚）、状态、最后活跃、模型别名入口、删除。
 * 先用缓存的实例渲染，再联网。
 */
class InstanceSettingsViewModel(
    private val service: ThinktinService,
    private val instanceId: String,
    private val clock: Clock,
) : ViewModel() {
    private val state = MutableStateFlow(InstanceSettingsUiState(nowMs = clock.millis()))
    val uiState: StateFlow<InstanceSettingsUiState> = state.asStateFlow()

    private val eventChannel = Channel<InstanceSettingsEvent>(Channel.BUFFERED)
    val events: Flow<InstanceSettingsEvent> = eventChannel.receiveAsFlow()

    private var shownOnce = false

    init {
        load()
    }

    /** 页面每次显示时调：第一次已经在 init 里加载；之后（比如改完名字回来）重新取。 */
    fun onShown() {
        if (!shownOnce) {
            shownOnce = true
            return
        }
        load()
    }

    fun load() {
        state.update { it.copy(loading = it.instance == null, loadError = null, nowMs = clock.millis()) }
        viewModelScope.launch {
            if (state.value.instance == null) {
                service.cachedInstances().firstOrNull { it.id == instanceId && it.state != InstanceState.Deleted }
                    ?.let { cached -> state.update { it.copy(instance = cached, loading = false) } }
            }
            try {
                val instance = coroutineScope {
                    val instance = async { service.instance(instanceId) }
                    // 目录拉不到不影响这一页：只是没有 agent 名和版本选项。
                    val agents = async {
                        try {
                            service.agents()
                        } catch (_: ServiceError) {
                            null
                        }
                    }
                    val loaded = instance.await()
                    val agent = agents.await()?.firstOrNull { it.id == loaded.agentId }
                    state.update { s -> s.copy(agent = agent ?: s.agent) }
                    loaded
                }
                state.update { it.copy(loading = false, instance = instance, loadError = null) }
            } catch (e: ServiceError) {
                state.update { it.copy(loading = false, loadError = ErrorText.of(e)) }
            }
        }
    }

    fun dismissDialog() {
        if (state.value.busy) return
        state.update { it.copy(dialog = null) }
    }

    private fun message(text: UiText) {
        eventChannel.trySend(InstanceSettingsEvent.Message(text))
    }

    // ---- 版本 ----

    /** 升级到最新（setInstanceVersion(null)）。 */
    fun askUpgrade() {
        val s = state.value
        val latest = s.latestVersion ?: return
        if (!s.canUpgrade) return
        state.update { it.copy(dialog = InstanceDialog.ChangeVersion(version = null, target = latest, older = false)) }
    }

    /** 切到 [option] 这个版本（回滚或换到中间版本）。 */
    fun askVersion(option: VersionOption) {
        state.update { it.copy(dialog = InstanceDialog.ChangeVersion(option.version, option.version, option.older)) }
    }

    fun confirmVersion() {
        val dialog = state.value.dialog as? InstanceDialog.ChangeVersion ?: return
        runDialogAction {
            val updated = service.setInstanceVersion(instanceId, dialog.version)
            state.update { it.copy(dialog = null, instance = updated) }
            eventChannel.send(InstanceSettingsEvent.Changed)
            message(UiText(R.string.instance_version_changed, listOf(updated.agentVersion)))
        }
    }

    // ---- 删除 ----

    /** 先查 plans() 和 teams() 算出受影响的计划和团队，再开确认框。查不到就不让删（看不到影响范围）。 */
    fun askDelete() {
        val s = state.value
        if (s.checkingImpact || s.busy || s.instance == null) return
        state.update { it.copy(checkingImpact = true) }
        viewModelScope.launch {
            try {
                val impact = coroutineScope {
                    val plans = async { service.plans() }
                    val teams = async { service.teams() }
                    DeleteImpact.of(instanceId, plans.await(), teams.await())
                }
                state.update { it.copy(checkingImpact = false, dialog = InstanceDialog.DeleteImpactNotice(impact)) }
            } catch (e: ServiceError) {
                state.update { it.copy(checkingImpact = false) }
                val reason = ErrorText.of(e)
                message(UiText(R.string.instance_delete_impact_failed, listOf(reason)))
            }
        }
    }

    /** 第一步“继续” → 第二次确认。 */
    fun continueDelete() {
        val dialog = state.value.dialog as? InstanceDialog.DeleteImpactNotice ?: return
        state.update { it.copy(dialog = InstanceDialog.DeleteConfirm(dialog.impact)) }
    }

    fun confirmDelete() {
        if (state.value.dialog !is InstanceDialog.DeleteConfirm) return
        runDialogAction {
            try {
                service.deleteInstance(instanceId)
            } catch (e: ServiceError.Api) {
                // 已经删掉了（别的设备删的）：当作成功。
                if (e.code != "not_found" && e.status != 404) throw e
            }
            state.update { it.copy(dialog = null) }
            eventChannel.send(InstanceSettingsEvent.Deleted)
        }
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
}
