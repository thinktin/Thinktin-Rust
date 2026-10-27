package cn.thinktin.app.ui.approval

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
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.labelRes
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * 审批详情（13.16，路由 approval/{id}）：卡片（原始请求默认展开）+ 所在实例、运行、第几次尝试、请求和到期时间。
 * 已处理 / 过期 / 取消 / 作废的显示结果；不存在的显示“找不到”。
 */
@Composable
fun ApprovalDetailScreen(
    approvalId: String,
    onBack: () -> Unit,
    onOpenRun: (String) -> Unit,
    onOpenChat: (String) -> Unit,
) {
    val container = LocalAppContainer.current
    val service = LocalThinktinService.current
    val viewModel: ApprovalDetailViewModel = viewModel(
        key = "approval-$approvalId",
        factory = viewModelFactory {
            initializer { ApprovalDetailViewModel(service, container.approvalGate, approvalId) }
        },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val actionState by viewModel.actions.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    ApprovalMessages(viewModel.actions, snackbar)
    val now by rememberNowMs(container.clock)

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_approval),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
            )
        },
    ) { padding ->
        val card = state.card
        val error = state.loadError
        Box(
            Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            when {
                state.loading && card == null -> {
                    val label = stringResource(R.string.loading)
                    CircularProgressIndicator(
                        Modifier
                            .align(Alignment.Center)
                            .semantics { contentDescription = label },
                    )
                }
                state.notFound -> EmptyState(
                    title = stringResource(R.string.approval_not_found_title),
                    message = stringResource(R.string.approval_not_found_message),
                    modifier = Modifier.padding(top = 48.dp),
                )
                card == null && error != null -> EmptyState(
                    title = stringResource(R.string.approvals_load_failed),
                    message = error.asString(),
                    actionLabel = stringResource(R.string.action_retry),
                    onAction = viewModel::load,
                    modifier = Modifier.padding(top = 48.dp),
                )
                card != null -> Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(ThinktinSpacing.Page),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    ApprovalCardItem(
                        card = card,
                        nowMs = now,
                        clock = container.clock,
                        actionState = actionState,
                        actions = viewModel.actions,
                        source = state.instanceName,
                        initiallyExpanded = true,
                    )
                    SectionHeader(title = stringResource(R.string.approval_detail_section))
                    val zone = container.clock.zone
                    card.instanceId?.let { instanceId ->
                        InfoRow(
                            label = stringResource(R.string.approval_detail_instance),
                            value = state.instanceName ?: stringResource(R.string.approvals_instance_unknown),
                            onClick = if (state.instanceName != null) ({ onOpenChat(instanceId) }) else null,
                        )
                    }
                    val run = state.run
                    InfoRow(
                        label = stringResource(R.string.approval_detail_run),
                        value = run?.let { stringResource(it.state.labelRes()) } ?: stringResource(R.string.approval_open_run),
                        onClick = { onOpenRun(card.key.runId) },
                    )
                    if (card.key.attempt > 0) {
                        InfoRow(
                            label = stringResource(R.string.approval_detail_attempt),
                            value = if (run != null && run.attempt > card.key.attempt) {
                                stringResource(R.string.approval_detail_attempt_superseded, card.key.attempt, run.attempt)
                            } else {
                                stringResource(R.string.approval_detail_attempt_value, card.key.attempt)
                            },
                        )
                    }
                    card.createdAtMs?.let {
                        InfoRow(label = stringResource(R.string.approval_detail_requested), value = formatTime(it, zone))
                    }
                    card.expiresAtMs?.let {
                        InfoRow(label = stringResource(R.string.approval_detail_expires), value = formatTime(it, zone))
                    }
                    card.decidedAtMs?.let {
                        InfoRow(label = stringResource(R.string.approval_detail_decided), value = formatTime(it, zone))
                    }
                }
            }
        }
    }
    ApprovalDialogs(actionState, viewModel.actions)
}

@Composable
private fun InfoRow(label: String, value: String, onClick: (() -> Unit)? = null) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        if (onClick != null) {
            Icon(
                Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

private fun formatTime(ms: Long, zone: ZoneId): String =
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
        .format(Instant.ofEpochMilli(ms).atZone(zone))
