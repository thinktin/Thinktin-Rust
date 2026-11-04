package cn.thinktin.app.ui.plans

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.ConfirmDialog
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.asString
import cn.thinktin.data.model.ApprovalTimeoutAction
import cn.thinktin.data.model.CatchUp
import cn.thinktin.data.model.Plan
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing
import java.time.ZoneId

const val PLAN_EDIT_TEST_TAG = "plan-edit"
const val PLAN_SAVE_TEST_TAG = "plan-save"
const val PLAN_TRIGGER_ROW_TEST_TAG = "plan-trigger-"

/**
 * 新建、编辑计划（13.6，第 4.6 节；路由 plans/new?instanceId=…、plan/{id}/edit）：实例、标题、目标、触发规则（面板里编）、
 * 策略、补跑方式；流水线的步骤只读。有改动时返回先问一句。
 */
@Composable
fun PlanEditScreen(mode: PlanEditMode, onClose: () -> Unit, onSaved: (Plan, Boolean) -> Unit) {
    val service = LocalThinktinService.current
    val clock = LocalAppContainer.current.clock
    val key = when (mode) {
        is PlanEditMode.Create -> "plan-new-${mode.instanceId}"
        is PlanEditMode.Edit -> "plan-edit-${mode.planId}"
    }
    val viewModel: PlanEditViewModel = viewModel(
        key = "$key-${System.identityHashCode(service)}",
        factory = viewModelFactory { initializer { PlanEditViewModel(service, clock, mode) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is PlanEditEvent.Saved -> onSaved(event.plan, event.created)
                PlanEditEvent.Closed -> onClose()
            }
        }
    }
    BackHandler(onBack = viewModel::requestClose)
    val zone = clock.zone
    Box(Modifier.fillMaxSize()) {
        Scaffold(
            containerColor = MaterialTheme.colorScheme.background,
            topBar = {
                ThinktinTopBar(
                    title = stringResource(if (state.isEditing) R.string.plan_edit_title else R.string.plan_new_title),
                    navigationIcon = TopBarIcons.Close,
                    navigationContentDescription = stringResource(R.string.action_close),
                    onNavigationClick = viewModel::requestClose,
                    navigationEnabled = !state.saving,
                    actions = {
                        if (state.saving) {
                            val saving = stringResource(R.string.loading)
                            CircularProgressIndicator(
                                Modifier
                                    .padding(12.dp)
                                    .semantics { contentDescription = saving },
                                strokeWidth = 2.dp,
                            )
                        } else {
                            TextButton(
                                onClick = viewModel::save,
                                enabled = state.canSave,
                                modifier = Modifier.testTag(PLAN_SAVE_TEST_TAG),
                            ) { Text(stringResource(R.string.action_save)) }
                        }
                    },
                )
            },
        ) { padding ->
            Box(
                Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                val error = state.loadError
                when {
                    state.notFound -> EmptyState(
                        title = stringResource(R.string.plan_not_found_title),
                        message = stringResource(R.string.plan_not_found_message),
                        modifier = Modifier.padding(top = 48.dp),
                    )
                    state.needsLoad && error != null -> EmptyState(
                        title = stringResource(R.string.plans_load_failed),
                        message = error.asString(),
                        actionLabel = stringResource(R.string.action_retry),
                        onAction = viewModel::load,
                        modifier = Modifier.padding(top = 48.dp),
                    )
                    state.needsLoad -> {
                        val loading = stringResource(R.string.loading)
                        CircularProgressIndicator(
                            Modifier
                                .align(Alignment.Center)
                                .semantics { contentDescription = loading },
                        )
                    }
                    else -> PlanForm(state, viewModel, zone)
                }
            }
        }
        state.editing?.let { editing ->
            TriggerEditorSheet(
                editing = editing,
                deviceZone = zone,
                nowMs = clock.millis(),
                actions = TriggerEditorActions(
                    onKind = viewModel::setDraftKind,
                    onChange = viewModel::updateDraft,
                    onApply = viewModel::applyTrigger,
                    onDismiss = viewModel::dismissTrigger,
                ),
            )
        }
    }
    if (state.confirmDiscard) {
        ConfirmDialog(
            title = stringResource(R.string.plan_discard_title),
            text = stringResource(R.string.plan_discard_text),
            confirm = stringResource(R.string.plan_discard),
            onConfirm = viewModel::discard,
            onDismiss = viewModel::dismissDiscard,
            danger = true,
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun PlanForm(state: PlanEditUiState, viewModel: PlanEditViewModel, zone: ZoneId) {
    val problems = state.problems
    Column(
        modifier = Modifier
            .fillMaxSize()
            .imePadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = ThinktinSpacing.Page, vertical = 12.dp)
            .testTag(PLAN_EDIT_TEST_TAG),
        verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
    ) {
        if (!state.isEditing) {
            SectionHeader(title = stringResource(R.string.plan_field_instance))
            if (state.instances.isEmpty()) {
                Text(stringResource(R.string.plans_empty_no_instance), style = MaterialTheme.typography.bodyMedium)
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                state.instances.forEach { instance ->
                    FilterChip(
                        selected = state.instanceId == instance.id,
                        onClick = { viewModel.setInstance(instance.id) },
                        label = { Text(instance.name) },
                    )
                }
            }
        }
        val titleProblem = problems.filterIsInstance<PlanFormProblem.Title>().firstOrNull()
        OutlinedTextField(
            value = state.title,
            onValueChange = viewModel::setTitle,
            label = { Text(stringResource(R.string.plan_field_title)) },
            singleLine = true,
            isError = titleProblem?.problem == TextProblem.TooLong,
            supportingText = {
                Text(
                    if (titleProblem?.problem == TextProblem.TooLong) titleProblem.message() else "${PlanText.length(state.title)}/${PlanLimits.MAX_TITLE}",
                )
            },
            modifier = Modifier.fillMaxWidth(),
        )
        val goalProblem = problems.filterIsInstance<PlanFormProblem.Goal>().firstOrNull()
        OutlinedTextField(
            value = state.goal,
            onValueChange = viewModel::setGoal,
            label = { Text(stringResource(R.string.plan_field_goal)) },
            placeholder = { Text(stringResource(R.string.plan_field_goal_hint)) },
            minLines = 3,
            isError = goalProblem?.problem == TextProblem.TooLong,
            supportingText = {
                Text(if (goalProblem?.problem == TextProblem.TooLong) goalProblem.message() else "${PlanText.length(state.goal)}/${PlanLimits.MAX_GOAL}")
            },
            modifier = Modifier.fillMaxWidth(),
        )

        SectionHeader(
            title = stringResource(R.string.plan_section_triggers),
            actionLabel = stringResource(R.string.trigger_add).takeIf { state.canAddTrigger },
            onAction = viewModel::addTrigger,
        )
        if (state.triggers.isEmpty()) {
            Text(stringResource(R.string.plan_problem_no_triggers), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        state.triggers.forEach { item ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(PLAN_TRIGGER_ROW_TEST_TAG + item.id),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(scheduleSummary(item.schedule, zone), style = MaterialTheme.typography.bodyLarge)
                    val next = item.trigger?.nextFireAtMs ?: cn.thinktin.data.schedule.ScheduleForecast
                        .nextFires(item.schedule, LocalAppContainer.current.clock.millis(), 1)?.firstOrNull()
                    if (next != null) {
                        Text(
                            stringResource(R.string.plan_next_fire, dateTimeText(next, zone)),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (item.trigger?.disabledReason != null) {
                        Text(stringResource(R.string.plan_trigger_invalid), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                    }
                }
                IconButton(onClick = { viewModel.editTrigger(item.id) }) {
                    Icon(Icons.Outlined.Edit, contentDescription = stringResource(R.string.trigger_edit_title))
                }
                IconButton(onClick = { viewModel.removeTrigger(item.id) }) {
                    Icon(Icons.Outlined.Delete, contentDescription = stringResource(R.string.trigger_remove))
                }
            }
        }
        if (state.triggers.isEmpty()) {
            SecondaryButton(text = stringResource(R.string.trigger_add), onClick = viewModel::addTrigger)
        }

        PolicyForm(state.policy, viewModel)

        SectionHeader(title = stringResource(R.string.plan_catch_up))
        CatchUp.entries.filter { it != CatchUp.Unknown }.forEach { option ->
            FilterChip(
                selected = state.catchUp == option,
                onClick = { viewModel.setCatchUp(option) },
                label = {
                    Column(Modifier.padding(vertical = 4.dp)) {
                        Text(stringResource(option.labelRes()))
                        Text(stringResource(option.detailRes()), style = MaterialTheme.typography.bodySmall)
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )
        }

        PipelineStepsEditor(state, viewModel)

        if (state.partiallySaved) {
            Text(stringResource(R.string.plan_partially_saved), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
        }
        state.saveError?.let { error ->
            Text(
                error.asString(),
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
        // 保存按钮灰着的原因（标题、目标、规则这些不在当前位置提示的）。
        problems.filter { it !is PlanFormProblem.Title && it !is PlanFormProblem.Goal }.firstOrNull()?.let { problem ->
            Text(problem.message(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun PolicyForm(policy: PlanPolicyDraft, viewModel: PlanEditViewModel) {
    val problems = policy.problems
    SectionHeader(title = stringResource(R.string.plan_section_policy))
    NumberField(
        label = stringResource(R.string.plan_policy_approval_timeout_hours),
        value = policy.approvalTimeoutHours,
        error = PolicyProblem.ApprovalTimeout in problems,
        decimal = true,
    ) { v -> viewModel.updatePolicy { it.copy(approvalTimeoutHours = v) } }
    if (PolicyProblem.ApprovalAction in problems) {
        Text(stringResource(R.string.plan_choose_timeout_action), color = MaterialTheme.colorScheme.error)
    }
    Text(stringResource(R.string.plan_policy_on_timeout), style = MaterialTheme.typography.labelLarge)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        listOf(ApprovalTimeoutAction.PausePlan, ApprovalTimeoutAction.Skip, ApprovalTimeoutAction.Fail).forEach { action ->
            FilterChip(
                selected = policy.onApprovalTimeout == action,
                onClick = { viewModel.updatePolicy { it.copy(onApprovalTimeout = action) } },
                label = { Text(stringResource(action.labelRes())) },
            )
        }
    }
    NumberField(
        label = stringResource(R.string.plan_policy_wait_timeout_hours),
        value = policy.waitTimeoutHours,
        error = PolicyProblem.WaitTimeout in problems,
        decimal = true,
    ) { v -> viewModel.updatePolicy { it.copy(waitTimeoutHours = v) } }
    NumberField(
        label = stringResource(R.string.plan_policy_max_duration_hours),
        value = policy.maxDurationHours,
        error = PolicyProblem.MaxDuration in problems,
        decimal = true,
    ) { v -> viewModel.updatePolicy { it.copy(maxDurationHours = v) } }
    NumberField(
        label = stringResource(R.string.plan_policy_max_tokens),
        value = policy.maxTokens,
        error = PolicyProblem.MaxTokens in problems,
        placeholder = stringResource(R.string.plan_policy_unlimited),
    ) { v -> viewModel.updatePolicy { it.copy(maxTokens = v) } }
    NumberField(
        label = stringResource(R.string.plan_policy_max_steps),
        value = policy.maxSteps,
        error = PolicyProblem.MaxSteps in problems,
        placeholder = stringResource(R.string.plan_policy_unlimited),
    ) { v -> viewModel.updatePolicy { it.copy(maxSteps = v) } }
    NumberField(
        label = stringResource(R.string.plan_policy_daily_tokens),
        value = policy.dailyTokenLimit,
        error = PolicyProblem.DailyTokenLimit in problems,
        placeholder = stringResource(R.string.plan_policy_unlimited),
    ) { v -> viewModel.updatePolicy { it.copy(dailyTokenLimit = v) } }
    Text(stringResource(R.string.plan_policy_preauthorized), style = MaterialTheme.typography.labelLarge)
    Text(stringResource(R.string.plan_policy_preauthorized_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        PREAUTHORIZABLE_TOOLS.forEach { kind ->
            val selected = kind in policy.preauthorizedTools
            FilterChip(
                selected = selected,
                onClick = {
                    viewModel.updatePolicy {
                        it.copy(preauthorizedTools = if (selected) it.preauthorizedTools - kind else it.preauthorizedTools + kind)
                    }
                },
                label = { Text(toolKindLabelRes(kind)?.let { res -> stringResource(res) } ?: kind) },
            )
        }
    }
}

@Composable
private fun NumberField(
    label: String,
    value: String,
    error: Boolean,
    decimal: Boolean = false,
    placeholder: String? = null,
    onChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        placeholder = placeholder?.let { { Text(it) } },
        singleLine = true,
        isError = error,
        keyboardOptions = KeyboardOptions(keyboardType = if (decimal) KeyboardType.Decimal else KeyboardType.Number),
        modifier = Modifier.fillMaxWidth(),
    )
}
