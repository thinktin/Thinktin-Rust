package cn.thinktin.app.ui.teams

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ErrorText
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.Team
import cn.thinktin.data.model.TeamMember
import cn.thinktin.data.model.TeamRole
import cn.thinktin.data.model.TeamTemplate
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

/** 团队最多几个成员（服务端 `routes/teams.rs` 的 MAX_MEMBERS）。 */
const val MAX_TEAM_MEMBERS = 12

/** 团队名最长几个字（服务端 1–64，按码点数）。 */
const val MAX_TEAM_NAME = 64

sealed interface TeamsEvent {
    data class Notice(val text: UiText) : TeamsEvent

    /** 领养了一个团队：去它的详情（逐个配模型）。 */
    data class OpenTeam(val teamId: String) : TeamsEvent
}

data class TeamsUiState(
    val loading: Boolean = true,
    val refreshing: Boolean = false,
    val teams: List<Team> = emptyList(),
    val templates: List<TeamTemplate> = emptyList(),
    /** 实例 id → 名字（不含已删除的）。 */
    val instances: Map<String, Instance> = emptyMap(),
    val loadError: UiText? = null,
    /** 正在领养 / 删除的模板。 */
    val busyTemplate: String? = null,
) {
    val isEmpty: Boolean get() = teams.isEmpty() && templates.isEmpty()
}

/**
 * 团队（13.7，路由 `teams`，抽屉“团队”）：我的团队（负责人、成员数）和团队模板（一键领养整个团队、删除）。
 * 领养是全成或全不成（服务端 11.9）：放不下报实例数上限；成功后去新团队的详情，逐个给成员配模型。
 */
class TeamsViewModel(private val service: ThinktinService) : ViewModel() {
    private val state = MutableStateFlow(TeamsUiState())
    val uiState: StateFlow<TeamsUiState> = state.asStateFlow()

    private val eventChannel = Channel<TeamsEvent>(Channel.BUFFERED)
    val events: Flow<TeamsEvent> = eventChannel.receiveAsFlow()

    private var shownOnce = false

    init {
        load(initial = true)
    }

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
        state.update { it.copy(loading = initial && it.isEmpty, refreshing = !initial, loadError = null) }
        viewModelScope.launch {
            try {
                val teams = service.teams()
                val templates = service.teamTemplates()
                val instances = service.instances().filter { it.state != InstanceState.Deleted }.associateBy { it.id }
                state.update {
                    it.copy(
                        loading = false, refreshing = false,
                        teams = teams.sortedByDescending { t -> t.createdAtMs },
                        templates = templates.sortedByDescending { t -> t.createdAtMs },
                        instances = instances,
                    )
                }
            } catch (e: ServiceError) {
                val text = ErrorText.of(e)
                if (!state.value.isEmpty) eventChannel.trySend(TeamsEvent.Notice(text))
                state.update { it.copy(loading = false, refreshing = false, loadError = if (it.isEmpty) text else null) }
            }
        }
    }

    /** 一键领养模板里的整个团队。 */
    fun adopt(template: TeamTemplate) {
        if (state.value.busyTemplate != null) return
        state.update { it.copy(busyTemplate = template.id) }
        viewModelScope.launch {
            try {
                val team = service.adoptTeamTemplate(template.id)
                state.update { it.copy(busyTemplate = null, teams = listOf(team) + it.teams) }
                eventChannel.trySend(TeamsEvent.OpenTeam(team.id))
            } catch (e: ServiceError) {
                state.update { it.copy(busyTemplate = null) }
                eventChannel.trySend(TeamsEvent.Notice(ErrorText.of(e)))
            }
        }
    }

    fun deleteTemplate(template: TeamTemplate) {
        if (state.value.busyTemplate != null) return
        state.update { it.copy(busyTemplate = template.id) }
        viewModelScope.launch {
            try {
                service.deleteTeamTemplate(template.id)
                state.update { s -> s.copy(busyTemplate = null, templates = s.templates.filterNot { it.id == template.id }) }
                eventChannel.trySend(TeamsEvent.Notice(UiText(R.string.team_template_deleted)))
            } catch (e: ServiceError) {
                state.update { it.copy(busyTemplate = null) }
                eventChannel.trySend(TeamsEvent.Notice(ErrorText.of(e)))
            }
        }
    }
}

sealed interface TeamDetailEvent {
    data class Notice(val text: UiText) : TeamDetailEvent

    /** 删掉了：退回去。 */
    data object Deleted : TeamDetailEvent
}

data class TeamDetailUiState(
    val loading: Boolean = true,
    val team: Team? = null,
    val instances: Map<String, Instance> = emptyMap(),
    val missing: Boolean = false,
    val loadError: UiText? = null,
    val busy: Boolean = false,
    /** 删除、存为模板的确认。 */
    val confirmDelete: Boolean = false,
    val savingTemplate: Boolean = false,
) {
    /** 成员按顺序，负责人在前。 */
    val members: List<TeamMember>
        get() = team?.members.orEmpty().sortedWith(compareBy<TeamMember> { it.role != TeamRole.Lead }.thenBy { it.position })
}

/**
 * 团队详情（13.7，路由 `team/{id}`）：负责人和成员（点进实例设置、配模型）；编辑、存为模板（同名）、删除（二次确认，实例不删）。
 */
class TeamDetailViewModel(private val service: ThinktinService, private val teamId: String) : ViewModel() {
    private val state = MutableStateFlow(TeamDetailUiState())
    val uiState: StateFlow<TeamDetailUiState> = state.asStateFlow()

    private val eventChannel = Channel<TeamDetailEvent>(Channel.BUFFERED)
    val events: Flow<TeamDetailEvent> = eventChannel.receiveAsFlow()

    init {
        load()
    }

    /** 每次显示时（从编辑页回来）重新取。 */
    fun load() {
        viewModelScope.launch {
            try {
                val team = service.team(teamId)
                val instances = service.instances().filter { it.state != InstanceState.Deleted }.associateBy { it.id }
                state.update { it.copy(loading = false, team = team, instances = instances, missing = false, loadError = null) }
            } catch (e: ServiceError) {
                val notFound = e is ServiceError.Api && (e.code == "not_found" || e.status == 404)
                state.update {
                    it.copy(loading = false, missing = notFound, loadError = if (notFound || it.team != null) null else ErrorText.of(e))
                }
                if (!notFound && state.value.team != null) eventChannel.trySend(TeamDetailEvent.Notice(ErrorText.of(e)))
            }
        }
    }

    fun askDelete() = state.update { it.copy(confirmDelete = true) }

    fun dismissDelete() = state.update { if (it.busy) it else it.copy(confirmDelete = false) }

    fun delete() {
        if (state.value.busy) return
        state.update { it.copy(busy = true) }
        viewModelScope.launch {
            try {
                service.deleteTeam(teamId)
                state.update { it.copy(busy = false, confirmDelete = false) }
                eventChannel.trySend(TeamDetailEvent.Deleted)
            } catch (e: ServiceError) {
                state.update { it.copy(busy = false, confirmDelete = false) }
                eventChannel.trySend(TeamDetailEvent.Notice(ErrorText.of(e)))
            }
        }
    }

    /** 存为模板（用团队的名字）：以后能一键领养一整套同样的 agent。 */
    fun saveAsTemplate() {
        val team = state.value.team ?: return
        if (state.value.savingTemplate) return
        state.update { it.copy(savingTemplate = true) }
        viewModelScope.launch {
            try {
                service.createTeamTemplateFromTeam(team.name, team.id)
                eventChannel.trySend(TeamDetailEvent.Notice(UiText(R.string.team_saved_as_template)))
            } catch (e: ServiceError) {
                eventChannel.trySend(TeamDetailEvent.Notice(ErrorText.of(e)))
            } finally {
                state.update { it.copy(savingTemplate = false) }
            }
        }
    }
}

/** 编辑团队表单的问题（保存前在本地拦下，和服务端的规则一样）。 */
enum class TeamFormProblem { NameEmpty, NameTooLong, NoMembers, TooManyMembers, NoLead }

data class TeamEditUiState(
    val loading: Boolean = true,
    val name: String = "",
    /** 选中的实例，按选的顺序。 */
    val selected: List<String> = emptyList(),
    val lead: String? = null,
    /** 可选的实例（不含已删除的），最近活跃的在前。 */
    val instances: List<Instance> = emptyList(),
    val saving: Boolean = false,
    val showProblems: Boolean = false,
    val loadError: UiText? = null,
) {
    val problems: Set<TeamFormProblem>
        get() = buildSet {
            val trimmed = name.trim()
            if (trimmed.isEmpty()) add(TeamFormProblem.NameEmpty)
            if (trimmed.codePointCount(0, trimmed.length) > MAX_TEAM_NAME) add(TeamFormProblem.NameTooLong)
            if (selected.isEmpty()) add(TeamFormProblem.NoMembers)
            if (selected.size > MAX_TEAM_MEMBERS) add(TeamFormProblem.TooManyMembers)
            if (selected.isNotEmpty() && lead !in selected) add(TeamFormProblem.NoLead)
        }

    /** 要提交的成员：负责人一个，其余是成员，按选的顺序编号。 */
    val members: List<TeamMember>
        get() = selected.mapIndexed { index, id -> TeamMember(id, if (id == lead) TeamRole.Lead else TeamRole.Member, index) }
}

sealed interface TeamEditEvent {
    data class Saved(val teamId: String) : TeamEditEvent

    data class Notice(val text: UiText) : TeamEditEvent
}

/**
 * 新建 / 编辑团队（13.7，路由 `teams/new`、`team/{id}/edit`）：名字（1–64 字）、成员（从实例里选，1–12 个）、负责人（一个）。
 * 第一个选中的默认当负责人；负责人取消选择时换成剩下的第一个。
 */
class TeamEditViewModel(private val service: ThinktinService, private val teamId: String?) : ViewModel() {
    private val state = MutableStateFlow(TeamEditUiState())
    val uiState: StateFlow<TeamEditUiState> = state.asStateFlow()

    private val eventChannel = Channel<TeamEditEvent>(Channel.BUFFERED)
    val events: Flow<TeamEditEvent> = eventChannel.receiveAsFlow()

    init {
        viewModelScope.launch {
            try {
                val instances = service.instances().filter { it.state != InstanceState.Deleted }
                    .sortedByDescending { it.lastActiveAtMs }
                val team = teamId?.let { service.team(it) }
                val ordered = team?.members.orEmpty().sortedBy { it.position }
                state.update {
                    it.copy(
                        loading = false,
                        instances = instances,
                        name = team?.name.orEmpty(),
                        selected = ordered.map { m -> m.instanceId }.filter { id -> instances.any { i -> i.id == id } },
                        lead = ordered.firstOrNull { m -> m.role == TeamRole.Lead }?.instanceId,
                    )
                }
            } catch (e: ServiceError) {
                state.update { it.copy(loading = false, loadError = ErrorText.of(e)) }
            }
        }
    }

    fun onNameChange(name: String) = state.update { it.copy(name = name) }

    fun toggle(instanceId: String) = state.update { s ->
        if (instanceId in s.selected) {
            val rest = s.selected - instanceId
            s.copy(selected = rest, lead = if (s.lead == instanceId) rest.firstOrNull() else s.lead)
        } else {
            s.copy(selected = s.selected + instanceId, lead = s.lead ?: instanceId)
        }
    }

    fun setLead(instanceId: String) = state.update { s ->
        if (instanceId in s.selected) s.copy(lead = instanceId) else s.copy(selected = s.selected + instanceId, lead = instanceId)
    }

    fun save() {
        val current = state.value
        if (current.saving) return
        if (current.problems.isNotEmpty()) {
            state.update { it.copy(showProblems = true) }
            return
        }
        state.update { it.copy(saving = true) }
        viewModelScope.launch {
            try {
                val name = current.name.trim()
                val team = if (teamId == null) {
                    service.createTeam(name, current.members)
                } else {
                    service.updateTeam(teamId, name = name, members = current.members)
                }
                eventChannel.trySend(TeamEditEvent.Saved(team.id))
            } catch (e: ServiceError) {
                eventChannel.trySend(TeamEditEvent.Notice(ErrorText.of(e)))
            } finally {
                state.update { it.copy(saving = false) }
            }
        }
    }
}
