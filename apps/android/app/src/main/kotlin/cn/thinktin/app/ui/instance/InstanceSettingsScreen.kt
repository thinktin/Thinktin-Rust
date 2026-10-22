package cn.thinktin.app.ui.instance

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ConfirmDialog
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.RelativeTime
import cn.thinktin.app.ui.common.StatusDot
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.labelRes
import cn.thinktin.app.ui.common.resolve
import cn.thinktin.data.model.Instance
import cn.thinktin.design.component.AiGeneratedLabel
import cn.thinktin.design.component.DangerButton
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing

/**
 * 实例设置（第 4.4 节，路由 instance/{instanceId}）。入口：对话页顶栏、首页溢出菜单、抽屉里长按 / 更多、深链。
 */
@Composable
fun InstanceSettingsScreen(
    instanceId: String,
    onBack: () -> Unit,
    onRename: () -> Unit,
    onOpenAgent: (String) -> Unit,
    onOpenModelRoutes: () -> Unit,
    onDeleted: () -> Unit,
    onChanged: () -> Unit = {},
    onOpenKeys: () -> Unit = {},
) {
    val service = LocalThinktinService.current
    val container = LocalAppContainer.current
    val viewModel: InstanceSettingsViewModel = viewModel(
        key = "instance-$instanceId",
        factory = viewModelFactory { initializer { InstanceSettingsViewModel(service, instanceId, container.clock) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    LaunchedEffect(viewModel) { viewModel.onShown() }
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                InstanceSettingsEvent.Deleted -> onDeleted()
                InstanceSettingsEvent.Changed -> onChanged()
                is InstanceSettingsEvent.Message ->
                    snackbar.showSnackbar(event.text.resolve(context), duration = SnackbarDuration.Long)
            }
        }
    }
    val instance = state.instance
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_instance),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            when {
                instance != null -> InstanceSettingsContent(
                    state = state,
                    instance = instance,
                    onRename = onRename,
                    onOpenAgent = onOpenAgent,
                    onOpenModelRoutes = onOpenModelRoutes,
                    onOpenKeys = onOpenKeys,
                    viewModel = viewModel,
                )
                state.loading -> {
                    val loading = stringResource(R.string.loading)
                    CircularProgressIndicator(
                        modifier = Modifier
                            .align(Alignment.Center)
                            .semantics { contentDescription = loading },
                    )
                }
                else -> Column(
                    modifier = Modifier
                        .align(Alignment.Center)
                        .padding(ThinktinSpacing.Page),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
                ) {
                    Text(
                        text = state.loadError?.asString().orEmpty(),
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                    )
                    SecondaryButton(text = stringResource(R.string.action_retry), onClick = viewModel::load)
                }
            }
        }
    }
    state.dialog?.let { dialog ->
        InstanceDialogs(dialog = dialog, instance = instance, busy = state.busy, viewModel = viewModel)
    }
}

@Composable
private fun InstanceSettingsContent(
    state: InstanceSettingsUiState,
    instance: Instance,
    onRename: () -> Unit,
    onOpenAgent: (String) -> Unit,
    onOpenModelRoutes: () -> Unit,
    onOpenKeys: () -> Unit,
    viewModel: InstanceSettingsViewModel,
) {
    val zone = LocalAppContainer.current.clock.zone
    val stateLabel = stringResource(instance.state.labelRes())
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(bottom = 24.dp),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            StatusDot(instance.state, contentDescription = stateLabel)
            // 实例名是用户起的，不标 AI 生成。
            Text(
                text = instance.name,
                style = MaterialTheme.typography.headlineMedium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.semantics { heading() },
            )
        }
        state.loadError?.let { error ->
            // 刷新失败但有缓存：显示缓存 + 一行错误。
            Row(
                modifier = Modifier.padding(horizontal = ThinktinSpacing.Page),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = error.asString(),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = viewModel::load) { Text(stringResource(R.string.action_retry)) }
            }
        }

        Section(R.string.instance_section_basic)
        InfoRow(
            title = stringResource(R.string.instance_name),
            value = instance.name,
            onClick = onRename,
            clickLabel = stringResource(R.string.instance_rename),
        )
        val agent = state.agent
        InfoRow(
            title = stringResource(R.string.instance_agent),
            value = stringResource(R.string.instance_agent_value, agent?.name ?: instance.agentId, instance.harness),
            onClick = { onOpenAgent(instance.agentId) },
            clickLabel = stringResource(R.string.catalog_open_agent),
        )
        InfoRow(title = stringResource(R.string.instance_status), value = stateLabel) {
            StatusDot(instance.state)
        }
        if (instance.lastActiveAtMs > 0) {
            InfoRow(
                title = stringResource(R.string.instance_last_active),
                value = RelativeTime.of(instance.lastActiveAtMs, state.nowMs, zone).asString(),
            )
        }

        Section(R.string.instance_section_version)
        InfoRow(
            title = stringResource(R.string.instance_current_version),
            value = when {
                state.latestVersion == null -> instance.agentVersion
                state.canUpgrade -> stringResource(R.string.instance_version_upgradable, instance.agentVersion, state.latestVersion!!)
                else -> stringResource(R.string.instance_version_latest, instance.agentVersion)
            },
        )
        if (state.canUpgrade) {
            SecondaryButton(
                text = stringResource(R.string.instance_upgrade),
                onClick = viewModel::askUpgrade,
                modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 4.dp),
            )
        }
        state.otherVersions.forEach { option ->
            val action = stringResource(if (option.older) R.string.instance_rollback else R.string.instance_switch)
            val actionLabel = stringResource(R.string.instance_version_action_a11y, action, option.version)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = ThinktinSpacing.ListItemMinHeight)
                    .padding(horizontal = ThinktinSpacing.Page),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = stringResource(R.string.instance_version_option, option.version),
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                )
                TextButton(
                    onClick = { viewModel.askVersion(option) },
                    modifier = Modifier.semantics {
                        contentDescription = actionLabel
                    },
                ) { Text(action) }
            }
        }
        Text(
            text = stringResource(R.string.instance_version_hint),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 4.dp),
        )

        Section(R.string.instance_section_model)
        InfoRow(
            title = stringResource(R.string.instance_model_routes),
            value = stringResource(R.string.instance_model_routes_summary),
            onClick = onOpenModelRoutes,
            clickLabel = stringResource(R.string.instance_model_routes),
        )
        InfoRow(
            title = stringResource(R.string.settings_keys),
            value = stringResource(R.string.instance_keys_summary),
            onClick = onOpenKeys,
            clickLabel = stringResource(R.string.settings_keys),
        )

        Section(R.string.instance_section_danger)
        Text(
            text = stringResource(R.string.instance_delete_summary),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 4.dp),
        )
        DangerButton(
            text = stringResource(R.string.instance_delete),
            onClick = viewModel::askDelete,
            loading = state.checkingImpact,
            enabled = !state.busy,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
        )
    }
}

@Composable
private fun Section(title: Int) {
    SectionHeader(
        title = stringResource(title),
        modifier = Modifier.padding(start = ThinktinSpacing.Page, end = ThinktinSpacing.Page, top = 16.dp),
    )
}

/** 一行：标题 + 值；能点时右侧有箭头。[leading] 放在值前面（状态点）。 */
@Composable
private fun InfoRow(
    title: String,
    value: String,
    onClick: (() -> Unit)? = null,
    clickLabel: String? = null,
    leading: (@Composable () -> Unit)? = null,
) {
    Column {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = ThinktinSpacing.ListItemMinHeight)
                .then(
                    if (onClick != null) {
                        Modifier.clickable(role = Role.Button, onClickLabel = clickLabel, onClick = onClick)
                    } else {
                        Modifier
                    },
                )
                .padding(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.weight(0.4f),
            )
            Row(
                modifier = Modifier.weight(0.6f),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.End),
            ) {
                leading?.invoke()
                Text(
                    text = value,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                if (onClick != null) {
                    Icon(
                        Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        HorizontalDivider(
            modifier = Modifier.padding(horizontal = ThinktinSpacing.Page),
            color = MaterialTheme.colorScheme.outline,
        )
    }
}

@Composable
private fun InstanceDialogs(
    dialog: InstanceDialog,
    instance: Instance?,
    busy: Boolean,
    viewModel: InstanceSettingsViewModel,
) {
    val name = instance?.name.orEmpty()
    when (dialog) {
        is InstanceDialog.ChangeVersion -> ConfirmDialog(
            title = stringResource(
                when {
                    dialog.version == null -> R.string.instance_upgrade_title
                    dialog.older -> R.string.instance_rollback_title
                    else -> R.string.instance_switch_title
                },
                dialog.target,
            ),
            text = stringResource(R.string.instance_version_confirm_message),
            confirm = stringResource(R.string.instance_version_confirm),
            busy = busy,
            onConfirm = viewModel::confirmVersion,
            onDismiss = viewModel::dismissDialog,
        )
        is InstanceDialog.DeleteImpactNotice -> ConfirmDialog(
            title = stringResource(R.string.instance_delete_title, name),
            text = stringResource(
                if (dialog.impact.isEmpty) R.string.instance_delete_no_impact else R.string.instance_delete_impact,
            ),
            confirm = stringResource(R.string.action_continue),
            danger = true,
            busy = busy,
            onConfirm = viewModel::continueDelete,
            onDismiss = viewModel::dismissDialog,
        ) {
            if (!dialog.impact.isEmpty) ImpactList(dialog.impact, instance?.id.orEmpty())
        }
        is InstanceDialog.DeleteConfirm -> ConfirmDialog(
            title = stringResource(R.string.instance_delete_confirm_title, name),
            text = stringResource(R.string.instance_delete_confirm_message),
            confirm = stringResource(R.string.instance_delete),
            danger = true,
            busy = busy,
            onConfirm = viewModel::confirmDelete,
            onDismiss = viewModel::dismissDialog,
        )
    }
}

/** 删除确认框里列出受影响的计划和团队（第 8.6 节）。 */
@Composable
private fun ImpactList(impact: DeleteImpact, instanceId: String) {
    Column(
        modifier = Modifier
            .heightIn(max = 280.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (impact.ownPlans.isNotEmpty()) {
            ImpactHeader(stringResource(R.string.instance_impact_own_plans))
            impact.ownPlans.forEach { plan -> PlanLine(plan.title, plan.createdBy == "agent", null) }
        }
        if (impact.pipelinePlans.isNotEmpty()) {
            ImpactHeader(stringResource(R.string.instance_impact_pipeline_plans))
            impact.pipelinePlans.forEach { plan ->
                val steps = impact.removedSteps(plan, instanceId)
                PlanLine(
                    plan.title,
                    plan.createdBy == "agent",
                    pluralStringResource(R.plurals.instance_impact_steps, steps, steps),
                )
            }
        }
        if (impact.teams.isNotEmpty()) {
            ImpactHeader(stringResource(R.string.instance_impact_teams))
            // 团队名是用户起的，不标。
            impact.teams.forEach { team ->
                Text(text = stringResource(R.string.instance_impact_item, team.name), style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

@Composable
private fun ImpactHeader(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelLarge,
        modifier = Modifier
            .padding(top = 4.dp)
            .semantics { heading() },
    )
}

/** 计划标题：agent 建的计划标题是 agent 写的，标 AI 生成（第 8.4 节）。 */
@Composable
private fun PlanLine(title: String, aiGenerated: Boolean, detail: String?) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(text = stringResource(R.string.instance_impact_bullet), style = MaterialTheme.typography.bodyMedium)
        if (aiGenerated) AiGeneratedLabel()
        Text(
            text = if (detail == null) title else stringResource(R.string.instance_impact_plan_detail, title, detail),
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}
