package cn.thinktin.app.ui.run

import androidx.compose.material3.Switch
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.StopCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
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
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.approval.rememberNowMs
import cn.thinktin.app.ui.chat.durationText
import cn.thinktin.app.ui.chat.formatSize
import cn.thinktin.app.ui.chat.labelRes
import cn.thinktin.app.ui.common.ConfirmDialog
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.StatusDot
import cn.thinktin.app.ui.common.TokenFormat
import cn.thinktin.app.ui.common.WaitText
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.formatTokens
import cn.thinktin.app.ui.common.labelRes
import cn.thinktin.app.ui.common.resolve
import cn.thinktin.data.model.Run
import cn.thinktin.data.model.RunSource
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.RunTreeNode
import cn.thinktin.design.component.AiGeneratedLabel
import cn.thinktin.design.component.DangerButton
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.component.WarningBanner
import cn.thinktin.design.theme.ThinktinSpacing
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

const val RUN_NODE_TEST_TAG = "run-node-"
const val RUN_DETAIL_TEST_TAG = "run-detail"

/**
 * 运行页（13.5，路由 run/{runId}）：选中运行的详情 + 整棵运行树（缩进、状态点、实例名、耗时；单个停止、停止整棵树）。
 * 子孙里卡在等 key / 等电脑 / 等审批的冒泡到顶部横幅（第 8.6 节）。
 */
@Composable
fun RunScreen(
    runId: String,
    onBack: () -> Unit,
    onOpenChat: (instanceId: String, runId: String) -> Unit,
    onOpenModelRoutes: (String) -> Unit,
) {
    val service = LocalThinktinService.current
    val container = LocalAppContainer.current
    val viewModel: RunViewModel = viewModel(
        key = "run-$runId-${System.identityHashCode(service)}",
        factory = viewModelFactory { initializer { RunViewModel(service, runId) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    val now by rememberNowMs(container.clock)
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is RunEvent.Message -> snackbar.showSnackbar(event.text.resolve(context))
            }
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_run),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
            )
        },
    ) { padding ->
        Box(
            Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            val selected = state.selected
            val error = state.loadError
            when {
                state.loading && state.nodes.isEmpty() -> {
                    val loading = stringResource(R.string.loading)
                    CircularProgressIndicator(
                        Modifier
                            .align(Alignment.Center)
                            .semantics { contentDescription = loading },
                    )
                }
                state.notFound -> EmptyState(
                    title = stringResource(R.string.run_not_found_title),
                    message = stringResource(R.string.run_not_found_message),
                    modifier = Modifier.padding(top = 48.dp),
                )
                selected == null && error != null -> EmptyState(
                    title = stringResource(R.string.run_load_failed),
                    message = error.asString(),
                    actionLabel = stringResource(R.string.action_retry),
                    onAction = viewModel::load,
                    modifier = Modifier.padding(top = 48.dp),
                )
                selected != null -> RunContent(
                    state = state,
                    selected = selected,
                    nowMs = now,
                    onSelect = viewModel::select,
                    onStop = viewModel::stop,
                    onStopTree = viewModel::askStopTree,
                    onOpenChat = onOpenChat,
                    onOpenModelRoutes = onOpenModelRoutes,
                )
            }
        }
    }
    if (state.confirmStopTree) {
        ConfirmDialog(
            title = stringResource(R.string.run_tree_stop_confirm_title),
            text = stringResource(R.string.run_tree_stop_confirm_text),
            confirm = stringResource(R.string.run_tree_stop_all),
            onConfirm = viewModel::stopTree,
            onDismiss = viewModel::dismissStopTree,
            danger = true,
        )
    }
}

@Composable
private fun RunContent(
    state: RunUiState,
    selected: Run,
    nowMs: Long,
    onSelect: (String) -> Unit,
    onStop: (String) -> Unit,
    onStopTree: () -> Unit,
    onOpenChat: (String, String) -> Unit,
    onOpenModelRoutes: (String) -> Unit,
) {
    val listState = rememberLazyListState()
    // 深链指向子运行：树上的那个节点滚到可见。节点前面还有详情、（可能有的）横幅和树的标题三行。
    LaunchedEffect(state.nodes.size) {
        val index = state.nodes.indexOfFirst { it.run.id == state.selectedId }
        val rowsBefore = 2 + if (state.rootAttention != null) 1 else 0
        if (index > 0) listState.scrollToItem(index + rowsBefore)
    }
    LazyColumn(
        state = listState,
        contentPadding = PaddingValues(ThinktinSpacing.Page),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxSize(),
    ) {
        item(key = "detail") {
            RunDetail(state, selected, nowMs, onOpenChat)
        }
        state.rootAttention?.let { attention ->
            item(key = "attention") {
                val who = state.instanceNames[attention.run.instanceId] ?: attention.run.instanceId
                val what = WaitText.of(attention.waitCode)?.asString() ?: stringResource(attention.state.labelRes())
                WarningBanner(
                    text = stringResource(R.string.run_tree_child_waiting, who, what),
                    actionLabel = if (attention.state == RunState.WaitingQuota) stringResource(R.string.chat_banner_go_routes) else null,
                    onAction = { onOpenModelRoutes(attention.run.instanceId) },
                )
            }
        }
        item(key = "tree-header") {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionHeader(title = stringResource(R.string.run_tree_title), modifier = Modifier.weight(1f))
                if (state.hasActive && state.nodes.size > 1) {
                    DangerButton(
                        text = stringResource(R.string.run_tree_stop_all),
                        onClick = onStopTree,
                        loading = state.stopping == state.root?.run?.id,
                    )
                }
            }
        }
        items(state.nodes, key = { it.run.id }) { node ->
            TreeRow(
                node = node,
                name = state.instanceNames[node.run.instanceId] ?: node.run.instanceId,
                selected = node.run.id == state.selectedId,
                nowMs = nowMs,
                stopping = state.stopping == node.run.id,
                onClick = { onSelect(node.run.id) },
                onStop = { onStop(node.run.id) },
            )
        }
    }
}

@Composable
private fun RunDetail(state: RunUiState, run: Run, nowMs: Long, onOpenChat: (String, String) -> Unit) {
    Column(
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.testTag(RUN_DETAIL_TEST_TAG),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StatusDot(run.state)
            Text(
                stringResource(run.state.labelRes()),
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.semantics { heading() },
            )
        }
        // 委派子运行的 prompt 是负责人 agent 写的（第 8.4 节）。
        if (run.source == RunSource.Delegate || run.source == RunSource.Pipeline) AiGeneratedLabel()
        Text(run.prompt, style = MaterialTheme.typography.bodyLarge)
        val zone = LocalAppContainer.current.clock.zone
        InfoRow(stringResource(R.string.run_detail_instance), state.instanceNames[run.instanceId] ?: run.instanceId)
        InfoRow(stringResource(R.string.run_detail_source), stringResource(run.source.labelRes()))
        InfoRow(stringResource(R.string.run_detail_attempt), run.attempt.toString())
        InfoRow(
            stringResource(R.string.run_detail_created),
            DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
                .format(Instant.ofEpochMilli(run.createdAtMs).atZone(zone)),
        )
        run.durationMs(nowMs)?.let { InfoRow(stringResource(R.string.run_detail_duration), durationText(it)) }
        val usage = state.usage
        val tokens = stringResource(R.string.chat_block_tokens, formatTokens(run.tokensUsed))
        InfoRow(
            stringResource(R.string.run_detail_tokens),
            if (usage == null) {
                tokens
            } else {
                tokens + " · " + stringResource(
                    R.string.run_detail_usage_io,
                    usage.inputTokens?.let { TokenFormat.grouped(it) } ?: "—",
                    usage.outputTokens?.let { TokenFormat.grouped(it) } ?: "—",
                )
            },
        )
        WaitText.of(run)?.takeIf { run.state.needsAttention }?.let { Text(it.asString(), color = MaterialTheme.colorScheme.error) }
        run.summary?.let { summary ->
            SectionHeader(title = stringResource(R.string.run_detail_summary))
            AiGeneratedLabel()
            Text(summary, style = MaterialTheme.typography.bodyMedium)
        }
        run.error?.let { error ->
            // 失败原因是平台诊断，不标 AI 生成（第 8.4 节）。
            SectionHeader(title = stringResource(R.string.run_detail_error))
            Text(error, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
        }
        SectionHeader(title = stringResource(R.string.run_detail_artifacts))
        if (state.artifacts.isEmpty()) {
            Text(
                stringResource(R.string.run_detail_no_artifacts),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        state.artifacts.forEach { artifact ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Outlined.Description, contentDescription = null, modifier = Modifier.size(18.dp))
                Column(Modifier.weight(1f)) {
                    AiGeneratedLabel()
                    Text(artifact.name, style = MaterialTheme.typography.bodyMedium)
                    Text(
                        stringResource(R.string.chat_artifact_meta, formatSize(artifact.size), artifact.version),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        // 根运行没结束时可以在通知栏显示进度（13.10）。
        if (run.state.isActive && run.parentRunId == null) {
            ProgressToggle(run, state.instanceNames[run.instanceId] ?: stringResource(R.string.app_name))
        }
        SecondaryButton(
            text = stringResource(R.string.run_detail_open_chat),
            onClick = { onOpenChat(run.instanceId, run.id) },
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}

/** “在通知栏显示进度”开关：开了发常驻通知并跟着事件流更新，关了撤掉。 */
@Composable
private fun ProgressToggle(run: Run, title: String) {
    val container = LocalAppContainer.current
    val service = LocalThinktinService.current
    val tracked by container.progress.tracked.collectAsStateWithLifecycle()
    val on = run.id in tracked
    val context = LocalContext.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .toggleable(value = on, role = Role.Switch) { enable ->
                if (!enable) container.progress.stop(run.id)
                else if (cn.thinktin.app.progress.SystemProgressNotifier.isEnabled(context)) container.progress.track(service, run, title)
                else android.widget.Toast.makeText(context, R.string.run_progress_blocked, android.widget.Toast.LENGTH_LONG).show()
            }
            .padding(vertical = 4.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(stringResource(R.string.run_progress_toggle), style = MaterialTheme.typography.bodyMedium)
            Text(
                stringResource(R.string.run_progress_toggle_summary),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Switch(checked = on, onCheckedChange = null)
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.semantics(mergeDescendants = true) {}) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
    }
}

/** 树上的一行：缩进、状态点、实例名、耗时；还在进行的可以单独停止。选中的高亮。 */
@Composable
private fun TreeRow(
    node: RunTreeNode,
    name: String,
    selected: Boolean,
    nowMs: Long,
    stopping: Boolean,
    onClick: () -> Unit,
    onStop: () -> Unit,
) {
    val run = node.run
    val stateLabel = stringResource(run.state.labelRes())
    val duration = run.durationMs(nowMs)?.let { durationText(it) }
    val current = stringResource(R.string.run_tree_current)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .background(
                if (selected) MaterialTheme.colorScheme.surfaceVariant else MaterialTheme.colorScheme.background,
                MaterialTheme.shapes.small,
            )
            .clickable(role = Role.Button, onClick = onClick)
            .padding(start = (8 + node.depth * 20).dp, end = 4.dp, top = 4.dp, bottom = 4.dp)
            .testTag(RUN_NODE_TEST_TAG + run.id)
            .semantics { this.selected = selected },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        StatusDot(run.state, contentDescription = stateLabel)
        Column(Modifier.weight(1f)) {
            Text(
                listOfNotNull(name, run.stepKey).joinToString(" · "),
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                listOfNotNull(stateLabel, duration, current.takeIf { selected }).joinToString(" · "),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (run.state.isActive) {
            if (stopping) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                IconButton(onClick = onStop) {
                    Icon(Icons.Outlined.StopCircle, contentDescription = stringResource(R.string.run_tree_stop, name))
                }
            }
        }
    }
}
