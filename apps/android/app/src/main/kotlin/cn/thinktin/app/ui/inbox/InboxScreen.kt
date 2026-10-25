package cn.thinktin.app.ui.inbox

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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.DoneAll
import androidx.compose.material.icons.outlined.EditCalendar
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.navigation.targetRoute
import cn.thinktin.app.ui.approval.rememberNowMs
import cn.thinktin.app.ui.chat.BottomPanel
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.RelativeTime
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.resolve
import cn.thinktin.app.ui.plans.dateTimeText
import cn.thinktin.data.model.InboxItem
import cn.thinktin.data.model.InboxKind
import cn.thinktin.design.component.AiGeneratedLabel
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

const val INBOX_LIST_TEST_TAG = "inbox-list"
const val INBOX_ROW_TEST_TAG = "inbox-row-"
const val INBOX_ITEM_PANEL_TEST_TAG = "inbox-item-panel"

/**
 * 收件箱（13.8，第 3 节路由 `inbox?itemId=`、第 4.8 节）：按天分组，未读的加粗、带圆点，种类图标；点一条去对应的页面
 * （没有就在面板里打开）；每行的“更多”里标已读 / 未读、删除；顶栏“全部已读”；下拉同步，滚到底加载更早的。
 * 带 [itemId]（推送、深链 `thinktin://inbox/{id}`）时打开那一条。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InboxScreen(itemId: String?, onBack: () -> Unit, onNavigate: (String) -> Unit) {
    val container = LocalAppContainer.current
    val service = LocalThinktinService.current
    val viewModel: InboxViewModel = viewModel(
        factory = viewModelFactory { initializer { InboxViewModel(service, initialItemId = itemId) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) { viewModel.onShown() }
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is InboxEvent.Navigate -> onNavigate(event.route)
                is InboxEvent.Notice -> snackbar.showSnackbar(event.text.resolve(context))
            }
        }
    }
    val zone = container.clock.zone
    val now by rememberNowMs(container.clock, intervalMs = 60_000)
    val anyUnread = state.unread > 0 || state.items.any { !it.read }

    Box(Modifier.fillMaxSize()) {
        Scaffold(
            containerColor = MaterialTheme.colorScheme.background,
            snackbarHost = { SnackbarHost(snackbar) },
            topBar = {
                ThinktinTopBar(
                    title = stringResource(R.string.page_inbox),
                    navigationIcon = TopBarIcons.Back,
                    navigationContentDescription = stringResource(R.string.action_back),
                    onNavigationClick = onBack,
                    actions = {
                        IconButton(onClick = viewModel::markAllRead, enabled = anyUnread && !state.isEmpty) {
                            Icon(Icons.Outlined.DoneAll, contentDescription = stringResource(R.string.inbox_mark_all_read))
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
                    state.loading && state.isEmpty -> {
                        val label = stringResource(R.string.loading)
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(Modifier.semantics { contentDescription = label })
                        }
                    }
                    // 空状态和错误也放在可滚动的列表里：下拉刷新要靠嵌套滚动触发。
                    error != null && state.isEmpty -> LazyColumn(Modifier.fillMaxSize()) {
                        item {
                            EmptyState(
                                title = stringResource(R.string.inbox_load_failed),
                                message = error.resolve(context),
                                actionLabel = stringResource(R.string.action_retry),
                                onAction = viewModel::retry,
                                modifier = Modifier.padding(top = 48.dp),
                            )
                        }
                    }
                    state.isEmpty -> LazyColumn(Modifier.fillMaxSize()) {
                        item {
                            EmptyState(
                                title = stringResource(R.string.inbox_empty_title),
                                message = stringResource(R.string.inbox_empty_message),
                                modifier = Modifier.padding(top = 48.dp),
                            )
                        }
                    }
                    else -> InboxList(state, zone, now, viewModel)
                }
            }
        }
        val opened = state.opened
        if (opened != null || state.openedMissing) {
            InboxItemPanel(
                item = opened,
                zone = zone,
                onOpenTarget = viewModel::openTarget,
                onMarkUnread = { opened?.let(viewModel::markUnread) },
                onDelete = { opened?.let(viewModel::delete) },
                onDismiss = viewModel::closeOpened,
            )
        }
    }
}

@Composable
private fun InboxList(state: InboxUiState, zone: ZoneId, nowMs: Long, viewModel: InboxViewModel) {
    val listState = rememberLazyListState()
    // 滚到最后几行时加载更早的。
    val nearEnd by remember {
        derivedStateOf {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()?.index ?: 0
            info.totalItemsCount > 0 && last >= info.totalItemsCount - 3
        }
    }
    LaunchedEffect(nearEnd, state.items.size) {
        if (nearEnd) viewModel.loadMore()
    }
    val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
    LazyColumn(
        state = listState,
        modifier = Modifier
            .fillMaxSize()
            .testTag(INBOX_LIST_TEST_TAG),
        contentPadding = PaddingValues(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
    ) {
        item(key = "unread") {
            Text(
                if (state.unread > 0) {
                    pluralStringResource(R.plurals.inbox_unread_count, state.unread.toInt(), state.unread.toInt())
                } else {
                    stringResource(R.string.inbox_all_read)
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 4.dp),
            )
        }
        for (day in state.items.groupByDay(zone)) {
            item(key = "day-${day.day}") {
                SectionHeader(title = dayLabel(day.day, today), modifier = Modifier.padding(top = 12.dp))
            }
            items(day.items, key = { it.id }) { item ->
                InboxRow(
                    item = item,
                    nowMs = nowMs,
                    zone = zone,
                    busy = item.id in state.busy,
                    onOpen = { viewModel.open(item) },
                    onToggleRead = { if (item.read) viewModel.markUnread(item) else viewModel.markRead(item) },
                    onDelete = { viewModel.delete(item) },
                )
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            }
        }
        if (state.loadingMore) {
            item(key = "more") {
                val label = stringResource(R.string.inbox_loading_more)
                Box(
                    Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(Modifier.semantics { contentDescription = label })
                }
            }
        }
    }
}

@Composable
private fun dayLabel(day: LocalDate, today: LocalDate): String = when (day) {
    today -> stringResource(R.string.inbox_today)
    today.minusDays(1) -> stringResource(R.string.inbox_yesterday)
    else -> day.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))
}

/** 一行：种类图标、未读圆点、标题（未读加粗）、正文前两行、种类 · 时间（AI 生成标识）；右边“更多”。 */
@Composable
fun InboxRow(
    item: InboxItem,
    nowMs: Long,
    zone: ZoneId,
    busy: Boolean,
    onOpen: () -> Unit,
    onToggleRead: () -> Unit,
    onDelete: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val unreadLabel = stringResource(R.string.inbox_unread)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp)
            .clickable(role = Role.Button, onClick = onOpen)
            .padding(vertical = 10.dp)
            .testTag(INBOX_ROW_TEST_TAG + item.id),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        KindIcon(item.kind)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (!item.read) {
                    Box(
                        Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.primary)
                            .semantics { contentDescription = unreadLabel },
                    )
                }
                Text(
                    item.title,
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = if (item.read) FontWeight.Normal else FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (item.body.isNotBlank()) {
                Text(
                    item.body,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "${stringResource(item.kind.labelRes())} · ${RelativeTime.of(item.createdAtMs, nowMs, zone).asString()}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (item.aiGenerated) AiGeneratedLabel()
            }
        }
        Box {
            if (busy) {
                CircularProgressIndicator(Modifier.size(24.dp).padding(2.dp), strokeWidth = 2.dp)
            } else {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(
                        Icons.Outlined.MoreVert,
                        contentDescription = stringResource(R.string.inbox_more_actions, item.title),
                    )
                }
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                    text = { Text(stringResource(if (item.read) R.string.inbox_mark_unread else R.string.inbox_mark_read)) },
                    onClick = {
                        menuOpen = false
                        onToggleRead()
                    },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.inbox_delete), color = MaterialTheme.colorScheme.error) },
                    onClick = {
                        menuOpen = false
                        onDelete()
                    },
                )
            }
        }
    }
}

/** 打开着的一条：全文、时间；有对应的页面时“查看”；标回未读、删除。找不到时说一声。 */
@Composable
private fun InboxItemPanel(
    item: InboxItem?,
    zone: ZoneId,
    onOpenTarget: () -> Unit,
    onMarkUnread: () -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit,
) {
    val title = item?.title ?: stringResource(R.string.inbox_item_missing_title)
    BottomPanel(title = title, onDismiss = onDismiss, testTag = INBOX_ITEM_PANEL_TEST_TAG) {
        if (item == null) {
            Text(
                stringResource(R.string.inbox_item_missing_message),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            return@BottomPanel
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            KindIcon(item.kind)
            Column {
                Text(stringResource(item.kind.labelRes()), style = MaterialTheme.typography.bodyMedium)
                Text(
                    dateTimeText(item.createdAtMs, zone),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        if (item.body.isNotBlank()) Text(item.body, style = MaterialTheme.typography.bodyLarge)
        if (item.aiGenerated) AiGeneratedLabel()
        if (item.targetRoute() != null) {
            PrimaryButton(text = stringResource(R.string.inbox_open_target), onClick = onOpenTarget, modifier = Modifier.fillMaxWidth())
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (item.read) {
                androidx.compose.material3.TextButton(onClick = onMarkUnread) { Text(stringResource(R.string.inbox_mark_unread)) }
            }
            androidx.compose.material3.TextButton(onClick = onDelete) {
                Text(stringResource(R.string.inbox_delete), color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

@Composable
private fun KindIcon(kind: InboxKind) {
    val tint = kind.tint()
    Box(
        Modifier
            .size(36.dp)
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.12f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(kind.icon(), contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
    }
}

fun InboxKind.labelRes(): Int = when (this) {
    InboxKind.RunFinished -> R.string.inbox_kind_run_finished
    InboxKind.RunFailed -> R.string.inbox_kind_run_failed
    InboxKind.Approval -> R.string.inbox_kind_approval
    InboxKind.ComputerApproval -> R.string.inbox_kind_computer_approval
    InboxKind.VaultRequest -> R.string.inbox_kind_vault_request
    InboxKind.PlanConfirm -> R.string.inbox_kind_plan_confirm
    InboxKind.Info -> R.string.inbox_kind_info
}

private fun InboxKind.icon(): ImageVector = when (this) {
    InboxKind.RunFinished -> Icons.Outlined.CheckCircle
    InboxKind.RunFailed -> Icons.Outlined.ErrorOutline
    InboxKind.Approval -> Icons.Outlined.PanTool
    InboxKind.ComputerApproval -> Icons.Outlined.Computer
    InboxKind.VaultRequest -> Icons.Outlined.Key
    InboxKind.PlanConfirm -> Icons.Outlined.EditCalendar
    InboxKind.Info -> Icons.Outlined.Notifications
}

@Composable
private fun InboxKind.tint(): Color = when (this) {
    InboxKind.RunFinished -> MaterialTheme.colorScheme.tertiary
    InboxKind.RunFailed -> MaterialTheme.colorScheme.error
    InboxKind.Approval, InboxKind.ComputerApproval, InboxKind.VaultRequest, InboxKind.PlanConfirm ->
        MaterialTheme.colorScheme.primary
    InboxKind.Info -> MaterialTheme.colorScheme.onSurfaceVariant
}
