package cn.thinktin.app.ui.teams

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ConfirmDialog
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.resolve
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.Team
import cn.thinktin.data.model.TeamRole
import cn.thinktin.data.model.TeamTemplate
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing

const val TEAM_ROW_TEST_TAG = "team-row-"
const val TEMPLATE_ROW_TEST_TAG = "template-row-"
const val TEAM_MEMBER_TEST_TAG = "team-member-"
const val TEAM_SAVE_TEST_TAG = "team-save"

/**
 * 团队（13.7，第 3 节路由 `teams`、第 4.7 节）：我的团队（负责人、成员数，点进详情）、团队模板（一键领养整个团队、删除），
 * 右上角新建团队。下拉刷新。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TeamsScreen(
    onBack: () -> Unit,
    onOpenTeam: (String) -> Unit,
    onNewTeam: () -> Unit,
) {
    val service = LocalThinktinService.current
    val viewModel: TeamsViewModel = viewModel(factory = viewModelFactory { initializer { TeamsViewModel(service) } })
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    var deleting by remember { mutableStateOf<TeamTemplate?>(null) }
    LaunchedEffect(viewModel) { viewModel.onShown() }
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is TeamsEvent.Notice -> snackbar.showSnackbar(event.text.resolve(context))
                is TeamsEvent.OpenTeam -> onOpenTeam(event.teamId)
            }
        }
    }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_teams),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
                actions = {
                    IconButton(onClick = onNewTeam) {
                        Icon(Icons.Outlined.Add, contentDescription = stringResource(R.string.team_new))
                    }
                },
            )
        },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = state.refreshing,
            onRefresh = viewModel::refresh,
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            val error = state.loadError
            when {
                state.loading && state.isEmpty -> Loading()
                error != null && state.isEmpty -> LazyColumn(Modifier.fillMaxSize()) {
                    item {
                        EmptyState(
                            title = stringResource(R.string.teams_load_failed),
                            message = error.resolve(context),
                            actionLabel = stringResource(R.string.action_retry),
                            onAction = viewModel::retry,
                            modifier = Modifier.padding(top = 48.dp),
                        )
                    }
                }
                else -> LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
                ) {
                    item(key = "intro") {
                        Text(
                            stringResource(R.string.teams_intro),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    item(key = "teams-header") {
                        SectionHeader(title = stringResource(R.string.teams_section_mine), modifier = Modifier.padding(top = 12.dp))
                    }
                    if (state.teams.isEmpty()) {
                        item(key = "teams-empty") {
                            Column(Modifier.padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(stringResource(R.string.teams_empty), style = MaterialTheme.typography.bodyMedium)
                                SecondaryButton(text = stringResource(R.string.team_new), onClick = onNewTeam)
                            }
                        }
                    }
                    items(state.teams, key = { "team-" + it.id }) { team ->
                        TeamRow(team, state.instances, onClick = { onOpenTeam(team.id) })
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    }
                    item(key = "templates-header") {
                        SectionHeader(title = stringResource(R.string.teams_section_templates), modifier = Modifier.padding(top = 20.dp))
                    }
                    if (state.templates.isEmpty()) {
                        item(key = "templates-empty") {
                            Text(
                                stringResource(R.string.team_templates_empty),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(vertical = 8.dp),
                            )
                        }
                    }
                    items(state.templates, key = { "tpl-" + it.id }) { template ->
                        TemplateRow(
                            template = template,
                            busy = state.busyTemplate == template.id,
                            enabled = state.busyTemplate == null,
                            onAdopt = { viewModel.adopt(template) },
                            onDelete = { deleting = template },
                        )
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    }
                }
            }
        }
    }
    deleting?.let { template ->
        ConfirmDialog(
            title = stringResource(R.string.team_template_delete_title, template.name),
            text = stringResource(R.string.team_template_delete_message),
            confirm = stringResource(R.string.action_delete),
            danger = true,
            onConfirm = {
                deleting = null
                viewModel.deleteTemplate(template)
            },
            onDismiss = { deleting = null },
        )
    }
}

@Composable
private fun TeamRow(team: Team, instances: Map<String, Instance>, onClick: () -> Unit) {
    val lead = team.members.firstOrNull { it.role == TeamRole.Lead }?.let { instances[it.instanceId]?.name }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(vertical = 10.dp)
            .testTag(TEAM_ROW_TEST_TAG + team.id),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(team.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(
            listOfNotNull(
                lead?.let { stringResource(R.string.team_lead_is, it) },
                pluralStringResource(R.plurals.team_member_count, team.members.size, team.members.size),
            ).joinToString(" · "),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun TemplateRow(
    template: TeamTemplate,
    busy: Boolean,
    enabled: Boolean,
    onAdopt: () -> Unit,
    onDelete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    val leadLabel = stringResource(R.string.team_role_lead)
    val context = LocalContext.current
    val separator = stringResource(R.string.plan_list_separator)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 10.dp)
            .testTag(TEMPLATE_ROW_TEST_TAG + template.id),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(template.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                template.members.joinToString(separator) { m ->
                    if (m.role == TeamRole.Lead) context.getString(R.string.team_member_with_role, m.name, leadLabel) else m.name
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (busy) {
            CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
        } else {
            TextButton(onClick = onAdopt, enabled = enabled) { Text(stringResource(R.string.team_template_adopt)) }
            Box {
                IconButton(onClick = { menu = true }, enabled = enabled) {
                    Icon(Icons.Outlined.MoreVert, contentDescription = stringResource(R.string.team_more_actions, template.name))
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.action_delete), color = MaterialTheme.colorScheme.error) },
                        onClick = {
                            menu = false
                            onDelete()
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun Loading() {
    val label = stringResource(R.string.loading)
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(Modifier.semantics { contentDescription = label })
    }
}

/**
 * 团队详情（13.7，路由 `team/{id}`）：负责人和成员（点进实例设置；“配模型”去实例的模型别名，领养来的团队逐个配）；
 * 编辑、存为模板、用这个团队建流水线、删除（二次确认，实例不删）。
 */
@Composable
fun TeamDetailScreen(
    teamId: String,
    onBack: () -> Unit,
    onEdit: () -> Unit,
    onOpenInstance: (String) -> Unit,
    onOpenRoutes: (String) -> Unit,
    onNewPipeline: (Team) -> Unit,
) {
    val service = LocalThinktinService.current
    val viewModel: TeamDetailViewModel = viewModel(
        key = "team-$teamId",
        factory = viewModelFactory { initializer { TeamDetailViewModel(service, teamId) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) { viewModel.onShown() }
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is TeamDetailEvent.Notice -> snackbar.showSnackbar(event.text.resolve(context))
                TeamDetailEvent.Deleted -> onBack()
            }
        }
    }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = state.team?.name ?: stringResource(R.string.page_team),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
                actions = {
                    if (state.team != null) TextButton(onClick = onEdit) { Text(stringResource(R.string.action_edit)) }
                },
            )
        },
    ) { padding ->
        val team = state.team
        val error = state.loadError
        when {
            state.missing -> EmptyState(
                title = stringResource(R.string.team_not_found_title),
                message = stringResource(R.string.team_not_found_message),
                modifier = Modifier.padding(padding).padding(top = 48.dp),
            )
            team == null && error != null -> EmptyState(
                title = stringResource(R.string.teams_load_failed),
                message = error.resolve(context),
                actionLabel = stringResource(R.string.action_retry),
                onAction = viewModel::load,
                modifier = Modifier.padding(padding).padding(top = 48.dp),
            )
            team == null -> Box(Modifier.padding(padding)) { Loading() }
            else -> Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                SectionHeader(title = pluralStringResource(R.plurals.team_member_count, team.members.size, team.members.size))
                for (member in state.members) {
                    val instance = state.instances[member.instanceId]
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 56.dp)
                            .clickable(role = Role.Button) { onOpenInstance(member.instanceId) }
                            .padding(vertical = 8.dp)
                            .testTag(TEAM_MEMBER_TEST_TAG + member.instanceId),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(instance?.name ?: member.instanceId, style = MaterialTheme.typography.bodyLarge)
                            if (member.instanceId in state.missingModel) {
                                Text(stringResource(R.string.routes_main_missing), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                            }
                            Text(
                                stringResource(if (member.role == TeamRole.Lead) R.string.team_role_lead else R.string.team_role_member),
                                style = MaterialTheme.typography.bodySmall,
                                color = if (member.role == TeamRole.Lead) {
                                    MaterialTheme.colorScheme.primary
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                },
                            )
                        }
                        TextButton(onClick = { onOpenRoutes(member.instanceId) }) { Text(stringResource(R.string.team_member_routes)) }
                    }
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                }
                if (state.missingModel.isNotEmpty()) Text(
                    stringResource(R.string.team_routes_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 8.dp),
                )
                PrimaryButton(
                    text = stringResource(R.string.team_new_pipeline),
                    onClick = { onNewPipeline(team) },
                    modifier = Modifier.fillMaxWidth(),
                )
                SecondaryButton(
                    text = stringResource(R.string.team_save_as_template),
                    onClick = viewModel::saveAsTemplate,
                    loading = state.savingTemplate,
                    modifier = Modifier.fillMaxWidth(),
                )
                TextButton(onClick = viewModel::askDelete, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.team_delete), color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
    if (state.confirmDelete) {
        ConfirmDialog(
            title = stringResource(R.string.team_delete_title, state.team?.name.orEmpty()),
            text = stringResource(R.string.team_delete_message),
            confirm = stringResource(R.string.action_delete),
            danger = true,
            busy = state.busy,
            onConfirm = viewModel::delete,
            onDismiss = viewModel::dismissDelete,
        )
    }
}

/** 新建 / 编辑团队（13.7，路由 `teams/new`、`team/{id}/edit`）：名字、成员（勾选实例）、负责人（单选）。 */
@Composable
fun TeamEditScreen(teamId: String?, onClose: () -> Unit, onSaved: (String) -> Unit) {
    val service = LocalThinktinService.current
    val viewModel: TeamEditViewModel = viewModel(
        key = "team-edit-${teamId ?: "new"}",
        factory = viewModelFactory { initializer { TeamEditViewModel(service, teamId) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is TeamEditEvent.Saved -> onSaved(event.teamId)
                is TeamEditEvent.Notice -> snackbar.showSnackbar(event.text.resolve(context))
            }
        }
    }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = stringResource(if (teamId == null) R.string.team_new else R.string.team_edit),
                navigationIcon = TopBarIcons.Close,
                navigationContentDescription = stringResource(R.string.action_close),
                onNavigationClick = onClose,
                actions = {
                    if (state.saving) {
                        CircularProgressIndicator(Modifier.padding(12.dp).size(24.dp), strokeWidth = 2.dp)
                    } else {
                        TextButton(
                            onClick = viewModel::save,
                            enabled = !state.loading && state.loadError == null,
                            modifier = Modifier.testTag(TEAM_SAVE_TEST_TAG),
                        ) { Text(stringResource(R.string.action_save)) }
                    }
                },
            )
        },
    ) { padding ->
        if (state.loading) {
            Box(Modifier.padding(padding)) { Loading() }
            return@Scaffold
        }
        val loadError = state.loadError
        if (loadError != null) {
            EmptyState(
                title = stringResource(R.string.teams_load_failed),
                message = loadError.resolve(context),
                actionLabel = stringResource(R.string.action_retry),
                onAction = viewModel::load,
                modifier = Modifier.padding(padding).padding(top = 48.dp),
            )
            return@Scaffold
        }
        val problems = if (state.showProblems) state.problems else emptySet()
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
        ) {
            item(key = "name") {
                val nameError = when {
                    TeamFormProblem.NameEmpty in problems -> stringResource(R.string.team_name_empty)
                    TeamFormProblem.NameTooLong in problems -> stringResource(R.string.team_name_too_long, MAX_TEAM_NAME)
                    else -> null
                }
                OutlinedTextField(
                    value = state.name,
                    onValueChange = viewModel::onNameChange,
                    label = { Text(stringResource(R.string.team_name)) },
                    singleLine = true,
                    isError = nameError != null,
                    supportingText = nameError?.let { { Text(it) } },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item(key = "members-header") {
                SectionHeader(
                    title = stringResource(R.string.team_members_pick, MAX_TEAM_MEMBERS),
                    modifier = Modifier.padding(top = 16.dp),
                )
                val memberError = when {
                    TeamFormProblem.NoMembers in problems -> stringResource(R.string.team_no_members)
                    TeamFormProblem.TooManyMembers in problems -> stringResource(R.string.team_too_many_members, MAX_TEAM_MEMBERS)
                    TeamFormProblem.NoLead in problems -> stringResource(R.string.team_no_lead)
                    else -> null
                }
                memberError?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                }
                if (state.instances.isEmpty()) {
                    Text(stringResource(R.string.team_no_instances), style = MaterialTheme.typography.bodyMedium)
                }
            }
            items(state.instances, key = { it.id }) { instance ->
                val selected = instance.id in state.selected
                val lead = state.lead == instance.id
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 56.dp)
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    val pickLabel = stringResource(R.string.team_pick_member, instance.name)
                    Checkbox(
                        checked = selected,
                        onCheckedChange = { viewModel.toggle(instance.id) },
                        modifier = Modifier.semantics { contentDescription = pickLabel },
                    )
                    Text(instance.name, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                    if (selected) {
                        val leadLabel = stringResource(R.string.team_make_lead, instance.name)
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            RadioButton(
                                selected = lead,
                                onClick = { viewModel.setLead(instance.id) },
                                modifier = Modifier.semantics { contentDescription = leadLabel },
                            )
                            Text(stringResource(R.string.team_role_lead), style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        }
    }
}
