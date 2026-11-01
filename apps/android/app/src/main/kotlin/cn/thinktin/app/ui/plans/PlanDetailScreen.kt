package cn.thinktin.app.ui.plans

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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.semantics.heading
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
import cn.thinktin.app.ui.common.StatusDot
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.formatTokens
import cn.thinktin.app.ui.common.labelRes
import cn.thinktin.app.ui.common.resolve
import cn.thinktin.data.model.Plan
import cn.thinktin.data.model.PlanPolicy
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.Trigger
import cn.thinktin.data.model.TriggerDisabledReason
import cn.thinktin.design.component.AiGeneratedLabel
import cn.thinktin.design.component.BannerTone
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.component.WarningBanner
import cn.thinktin.design.theme.ThinktinSpacing
import java.time.ZoneId

const val PLAN_DETAIL_TEST_TAG = "plan-detail"
const val PLAN_RUN_ROW_TEST_TAG = "plan-run-"

/** 计划详情的跳转。 */
data class PlanDetailNavigation(
    val onBack: () -> Unit,
    val onEdit: (String) -> Unit,
    val onOpenRun: (String) -> Unit,
    val onDeleted: () -> Unit,
)

/**
 * 计划详情（13.6，第 4.6 节）：状态、目标、触发规则、策略、补跑方式、流水线步骤、运行历史；暂停 / 恢复、编辑、删除；
 * agent 新建或修改的计划在这里确认（“修改”进编辑页，保存后回来按新版本确认）。
 */
@Composable
fun PlanDetailScreen(planId: String, navigation: PlanDetailNavigation) {
    val service = LocalThinktinService.current
    val zone = LocalAppContainer.current.clock.zone
    val viewModel: PlanDetailViewModel = viewModel(
        key = "plan-$planId-${System.identityHashCode(service)}",
        factory = viewModelFactory { initializer { PlanDetailViewModel(service, planId) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    LaunchedEffect(viewModel) { viewModel.onShown() }
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is PlanDetailEvent.Message -> snackbar.showSnackbar(event.text.resolve(context))
                PlanDetailEvent.Deleted -> navigation.onDeleted()
            }
        }
    }
    var menu by remember { mutableStateOf(false) }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_plan),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = navigation.onBack,
                actions = {
                    if (state.plan != null) {
                        IconButton(onClick = { navigation.onEdit(planId) }, enabled = !state.busy) {
                            Icon(Icons.Outlined.Edit, contentDescription = stringResource(R.string.plan_edit))
                        }
                        Box {
                            IconButton(onClick = { menu = true }) {
                                Icon(Icons.Outlined.MoreVert, contentDescription = stringResource(R.string.action_more))
                            }
                            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.plan_delete), color = MaterialTheme.colorScheme.error) },
                                    onClick = {
                                        menu = false
                                        viewModel.askDelete()
                                    },
                                )
                            }
                        }
                    }
                },
            )
        },
        bottomBar = {
            state.plan?.let { plan ->
                PlanActions(plan, state, onConfirm = viewModel::confirm, onEdit = { navigation.onEdit(planId) }, onSetPaused = viewModel::setPaused)
            }
        },
    ) { padding ->
        Box(
            Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            val plan = state.plan
            val error = state.loadError
            when {
                state.notFound -> EmptyState(
                    title = stringResource(R.string.plan_not_found_title),
                    message = stringResource(R.string.plan_not_found_message),
                    actionLabel = stringResource(R.string.action_back),
                    onAction = navigation.onBack,
                    modifier = Modifier.padding(top = 48.dp),
                )
                plan == null && error != null -> EmptyState(
                    title = stringResource(R.string.plans_load_failed),
                    message = error.asString(),
                    actionLabel = stringResource(R.string.action_retry),
                    onAction = viewModel::load,
                    modifier = Modifier.padding(top = 48.dp),
                )
                plan == null -> {
                    val loading = stringResource(R.string.loading)
                    CircularProgressIndicator(
                        Modifier
                            .align(Alignment.Center)
                            .semantics { contentDescription = loading },
                    )
                }
                else -> PlanContent(plan, state, zone, navigation.onOpenRun, onMoreRuns = { viewModel.loadRuns() })
            }
        }
    }
    if (state.confirmDelete) {
        ConfirmDialog(
            title = stringResource(R.string.plan_delete_title),
            text = stringResource(R.string.plan_delete_text, state.plan?.title.orEmpty()),
            confirm = stringResource(R.string.plan_delete),
            onConfirm = viewModel::delete,
            onDismiss = viewModel::dismissDelete,
            danger = true,
            busy = state.deleting,
        )
    }
}

@Composable
private fun PlanActions(
    plan: Plan,
    state: PlanDetailUiState,
    onConfirm: () -> Unit,
    onEdit: () -> Unit,
    onSetPaused: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = ThinktinSpacing.Page, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (plan.awaitingConfirmation) {
            PrimaryButton(
                text = stringResource(R.string.plan_confirm),
                onClick = onConfirm,
                loading = state.confirming,
                enabled = !state.busy && state.blockedSteps.isEmpty(),
                modifier = Modifier.weight(1f),
            )
            SecondaryButton(text = stringResource(R.string.plan_edit_then_confirm), onClick = onEdit, enabled = !state.busy)
        } else {
            SecondaryButton(
                text = stringResource(if (plan.paused) R.string.plan_resume else R.string.plan_pause),
                onClick = { onSetPaused(!plan.paused) },
                loading = state.pausing,
                enabled = !state.busy,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun PlanContent(plan: Plan, state: PlanDetailUiState, zone: ZoneId, onOpenRun: (String) -> Unit, onMoreRuns: () -> Unit) {
    LazyColumn(
        contentPadding = PaddingValues(horizontal = ThinktinSpacing.Page, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxSize()
            .testTag(PLAN_DETAIL_TEST_TAG),
    ) {
        if (plan.awaitingConfirmation) {
            item(key = "awaiting") { WarningBanner(text = stringResource(R.string.plan_awaiting_banner)) }
        }
        if (state.changedSinceShown) {
            item(key = "changed") { WarningBanner(text = stringResource(R.string.plan_changed_since_shown), tone = BannerTone.Error) }
        }
        if (state.blockedSteps.isNotEmpty()) {
            item(key = "blocked") {
                WarningBanner(
                    text = stringResource(R.string.plan_blocked_steps_detail, state.blockedSteps.joinToString(stringResource(R.string.plan_list_separator)) { it.key }),
                    tone = BannerTone.Error,
                )
            }
        }
        if (plan.invalidTriggers > 0) {
            item(key = "invalid") {
                WarningBanner(
                    text = pluralStringResource(R.plurals.plan_invalid_triggers, plan.invalidTriggers, plan.invalidTriggers),
                    tone = BannerTone.Error,
                )
            }
        }
        item(key = "head") { PlanHead(plan, state, zone) }
        item(key = "triggers-header") { SectionHeader(title = stringResource(R.string.plan_section_triggers)) }
        items(plan.triggers, key = { "trigger-${it.id}" }) { TriggerRow(it, zone) }
        item(key = "policy") { PolicySection(plan.policy, plan) }
        if (plan.steps.isNotEmpty()) {
            item(key = "steps-header") { SectionHeader(title = stringResource(R.string.plan_section_steps)) }
            items(plan.steps, key = { "step-${it.key}" }) { step ->
                Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    Text(
                        listOf(step.key, state.instances[step.instanceId]?.name ?: step.instanceId).joinToString(" · "),
                        style = MaterialTheme.typography.labelLarge,
                    )
                    if (step.dependsOn.isNotEmpty()) {
                        Text(
                            stringResource(R.string.plan_step_depends, step.dependsOn.joinToString(stringResource(R.string.plan_list_separator))),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Text(step.prompt, style = MaterialTheme.typography.bodySmall, maxLines = 3, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        item(key = "runs-header") { SectionHeader(title = stringResource(R.string.plan_section_runs)) }
        if (state.runs.isEmpty() && !state.runsLoading) {
            item(key = "runs-empty") {
                Text(
                    state.runsError?.asString() ?: stringResource(R.string.plan_runs_empty),
                    style = MaterialTheme.typography.bodySmall,
                    color = if (state.runsError != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        items(state.runs, key = { "run-${it.id}" }) { run -> RunRow(run, zone, onOpenRun) }
        if (state.runsLoading) {
            item(key = "runs-loading") {
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(Modifier.padding(8.dp))
                }
            }
        } else if (state.hasMoreRuns) {
            item(key = "runs-more") {
                TextButton(onClick = onMoreRuns, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.plan_runs_more)) }
            }
        }
    }
}

@Composable
private fun PlanHead(plan: Plan, state: PlanDetailUiState, zone: ZoneId) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (plan.byAgent) AiGeneratedLabel()
        Text(plan.title, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.semantics { heading() })
        val status = stringResource(plan.status.labelRes())
        val next = plan.nextFireAtMs?.let { stringResource(R.string.plan_next_fire, relativePlanTime(it, zone)) }
        Text(
            listOfNotNull(status, state.instances[plan.instanceId]?.name ?: plan.instanceId, next).joinToString(" · "),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        SectionHeader(title = stringResource(R.string.plan_section_goal))
        if (plan.byAgent) AiGeneratedLabel()
        Text(plan.goal, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun TriggerRow(trigger: Trigger, zone: ZoneId) {
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(scheduleSummary(trigger.schedule, zone), style = MaterialTheme.typography.bodyLarge)
        val detail = when {
            trigger.disabledReason == TriggerDisabledReason.InvalidRule -> stringResource(R.string.plan_trigger_invalid)
            !trigger.enabled -> stringResource(R.string.plan_trigger_disabled)
            trigger.nextFireAtMs != null -> stringResource(R.string.plan_next_fire, relativePlanTime(trigger.nextFireAtMs!!, zone))
            else -> null
        }
        val last = trigger.lastFireAtMs?.let { stringResource(R.string.plan_last_fire, relativePlanTime(it, zone)) }
        val line = listOfNotNull(detail, last).joinToString(" · ")
        if (line.isNotEmpty()) {
            Text(
                line,
                style = MaterialTheme.typography.bodySmall,
                color = if (trigger.disabledReason != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun PolicySection(policy: PlanPolicy, plan: Plan) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        SectionHeader(title = stringResource(R.string.plan_section_policy))
        PolicyLine(
            stringResource(R.string.plan_policy_approval_timeout),
            stringResource(
                R.string.plan_policy_timeout_then,
                PlanPolicyDraft.hours(policy.approvalTimeoutSecs),
                stringResource(policy.onApprovalTimeout.labelRes()),
            ),
        )
        PolicyLine(stringResource(R.string.plan_policy_wait_timeout), stringResource(R.string.plan_hours, PlanPolicyDraft.hours(policy.waitTimeoutSecs)))
        PolicyLine(stringResource(R.string.plan_policy_max_duration), stringResource(R.string.plan_hours, PlanPolicyDraft.hours(policy.maxDurationSecs)))
        val unlimited = stringResource(R.string.plan_policy_unlimited)
        PolicyLine(stringResource(R.string.plan_policy_max_tokens), policy.maxTokens?.let { formatTokens(it) } ?: unlimited)
        PolicyLine(stringResource(R.string.plan_policy_max_steps), policy.maxSteps?.toString() ?: unlimited)
        PolicyLine(stringResource(R.string.plan_policy_daily_tokens), policy.dailyTokenLimit?.let { formatTokens(it) } ?: unlimited)
        val tools = policy.preauthorizedTools.map { kind -> toolKindLabelRes(kind)?.let { stringResource(it) } ?: kind }
        PolicyLine(
            stringResource(R.string.plan_policy_preauthorized),
            tools.joinToString(stringResource(R.string.plan_list_separator)).ifEmpty { stringResource(R.string.plan_policy_none) },
        )
        PolicyLine(stringResource(R.string.plan_catch_up), stringResource(plan.catchUp.labelRes()))
    }
}

@Composable
private fun PolicyLine(label: String, value: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.semantics(mergeDescendants = true) {}) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(0.45f))
        Text(value, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(0.55f))
    }
}

@Composable
private fun RunRow(run: Run, zone: ZoneId, onOpenRun: (String) -> Unit) {
    val state = stringResource(run.state.labelRes())
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(role = Role.Button) { onOpenRun(run.id) }
            .padding(vertical = 4.dp)
            .testTag(PLAN_RUN_ROW_TEST_TAG + run.id),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        StatusDot(run.state, contentDescription = state)
        Column(Modifier.weight(1f)) {
            Text(listOfNotNull(relativePlanTime(run.createdAtMs, zone), state, run.durationMs(LocalAppContainer.current.clock.millis())?.let { cn.thinktin.app.ui.chat.durationText(it) }).joinToString(" · "), style = MaterialTheme.typography.bodyMedium)
            val summary = run.summary ?: run.error
            if (summary != null) {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    // 摘要是 agent 写的；失败原因是平台诊断，不标（第 8.4 节）。
                    if (run.summary != null) AiGeneratedLabel()
                    Text(summary, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}
