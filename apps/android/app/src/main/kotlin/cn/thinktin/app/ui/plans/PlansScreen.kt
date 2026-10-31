package cn.thinktin.app.ui.plans

import androidx.compose.foundation.BorderStroke
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
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
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
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.resolve
import cn.thinktin.data.model.Plan
import cn.thinktin.design.component.AiGeneratedLabel
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinShapes
import cn.thinktin.design.theme.ThinktinSpacing
import cn.thinktin.design.theme.ThinktinTheme
import java.time.ZoneId

/** 测试用：计划行的 testTag 前缀（后接计划 id）。 */
const val PLAN_ROW_TEST_TAG = "plan-row-"

/**
 * 计划列表（13.6，第 4.6 节，路由 plans）：等确认的置顶（查看并确认、拒绝），其余分“在跑”“已暂停”，开关直接暂停 / 恢复。
 */
@Composable
fun PlansScreen(
    onBack: () -> Unit,
    onOpenPlan: (String) -> Unit,
    onNewPlan: () -> Unit,
    onOpenCatalog: () -> Unit,
) {
    val service = LocalThinktinService.current
    val zone = LocalAppContainer.current.clock.zone
    val viewModel: PlansViewModel = viewModel(
        key = "plans-${System.identityHashCode(service)}",
        factory = viewModelFactory { initializer { PlansViewModel(service) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    LaunchedEffect(viewModel) { viewModel.onShown() }
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is PlansEvent.Message -> snackbar.showSnackbar(event.text.resolve(context))
            }
        }
    }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_plans),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
                actions = {
                    if (state.hasInstances) {
                        IconButton(onClick = onNewPlan) {
                            Icon(Icons.Outlined.Add, contentDescription = stringResource(R.string.plans_new))
                        }
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
                state.loading -> {
                    val loading = stringResource(R.string.loading)
                    CircularProgressIndicator(
                        Modifier
                            .align(Alignment.Center)
                            .semantics { contentDescription = loading },
                    )
                }
                state.plans.isEmpty() && error != null -> EmptyState(
                    title = stringResource(R.string.plans_load_failed),
                    message = error.asString(),
                    actionLabel = stringResource(R.string.action_retry),
                    onAction = viewModel::load,
                    modifier = Modifier.padding(top = 48.dp),
                )
                state.plans.isEmpty() -> EmptyState(
                    title = stringResource(R.string.plans_empty_title),
                    message = stringResource(if (state.hasInstances) R.string.plans_empty_message else R.string.plans_empty_no_instance),
                    actionLabel = stringResource(if (state.hasInstances) R.string.plans_new else R.string.plans_adopt_first),
                    onAction = if (state.hasInstances) onNewPlan else onOpenCatalog,
                    modifier = Modifier.padding(top = 48.dp),
                )
                else -> LazyColumn(
                    contentPadding = PaddingValues(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    if (state.awaiting.isNotEmpty()) {
                        item(key = "awaiting-header") { SectionHeader(title = stringResource(R.string.plans_section_awaiting)) }
                        items(state.awaiting, key = { it.id }) { plan ->
                            AwaitingCard(
                                plan = plan,
                                instanceName = state.instances[plan.instanceId]?.name ?: plan.instanceId,
                                busy = state.busyPlanId == plan.id,
                                onOpen = { onOpenPlan(plan.id) },
                                onReject = { viewModel.askReject(plan) },
                            )
                        }
                    }
                    if (state.active.isNotEmpty()) {
                        item(key = "active-header") { SectionHeader(title = stringResource(R.string.plans_section_active)) }
                        items(state.active, key = { it.id }) { plan ->
                            PlanRow(plan, state.instances[plan.instanceId]?.name, zone, state.busyPlanId == plan.id, onOpenPlan, viewModel::setPaused)
                        }
                    }
                    if (state.paused.isNotEmpty()) {
                        item(key = "paused-header") { SectionHeader(title = stringResource(R.string.plans_section_paused)) }
                        items(state.paused, key = { it.id }) { plan ->
                            PlanRow(plan, state.instances[plan.instanceId]?.name, zone, state.busyPlanId == plan.id, onOpenPlan, viewModel::setPaused)
                        }
                    }
                }
            }
        }
    }
    state.rejecting?.let { plan ->
        ConfirmDialog(
            title = stringResource(R.string.plans_reject_title),
            text = stringResource(R.string.plans_reject_text, plan.title),
            confirm = stringResource(R.string.plans_reject),
            onConfirm = viewModel::confirmReject,
            onDismiss = viewModel::dismissReject,
            danger = true,
            busy = state.busyPlanId == plan.id,
        )
    }
}

/** agent 新建或修改、等确认的计划：标题（agent 写的）、实例；查看并确认、拒绝。 */
@Composable
private fun AwaitingCard(plan: Plan, instanceName: String, busy: Boolean, onOpen: () -> Unit, onReject: () -> Unit) {
    Surface(
        shape = ThinktinShapes.Card,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, ThinktinTheme.extendedColors.warning),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(PLAN_ROW_TEST_TAG + plan.id),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (plan.byAgent) AiGeneratedLabel()
            Text(plan.title, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(
                stringResource(R.string.plans_awaiting_hint, instanceName),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PrimaryButton(text = stringResource(R.string.plans_review), onClick = onOpen, enabled = !busy)
                SecondaryButton(text = stringResource(R.string.plans_reject), onClick = onReject, loading = busy)
            }
        }
    }
}

/** 一行：标题、实例 · 下一次触发（或“没有下一次”）、规则失效的提示；右边开关暂停 / 恢复。 */
@Composable
private fun PlanRow(
    plan: Plan,
    instanceName: String?,
    zone: ZoneId,
    busy: Boolean,
    onOpen: (String) -> Unit,
    onSetPaused: (Plan, Boolean) -> Unit,
) {
    val next = plan.nextFireAtMs?.let { stringResource(R.string.plan_next_fire, relativePlanTime(it, zone)) }
        ?: stringResource(if (plan.paused) R.string.plan_status_paused else R.string.plan_no_next_fire)
    val toggleLabel = stringResource(if (plan.paused) R.string.plan_resume else R.string.plan_pause)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clickable(role = Role.Button) { onOpen(plan.id) }
            .padding(vertical = 6.dp)
            .testTag(PLAN_ROW_TEST_TAG + plan.id),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (plan.byAgent) AiGeneratedLabel()
            Text(plan.title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                listOfNotNull(instanceName, next).joinToString(" · "),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (plan.invalidTriggers > 0) {
                Text(
                    stringResource(R.string.plan_invalid_triggers_short),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
        Switch(
            checked = !plan.paused,
            onCheckedChange = { on -> onSetPaused(plan, !on) },
            enabled = !busy,
            modifier = Modifier.semantics { contentDescription = toggleLabel },
        )
    }
}
