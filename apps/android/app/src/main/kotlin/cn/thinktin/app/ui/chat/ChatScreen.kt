package cn.thinktin.app.ui.chat

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SmallFloatingActionButton
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
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
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.approval.ApprovalCardItem
import cn.thinktin.app.ui.approval.ApprovalDialogs
import cn.thinktin.app.ui.approval.ApprovalMessages
import cn.thinktin.app.ui.approval.rememberNowMs
import cn.thinktin.app.ui.common.ConfirmDialog
import cn.thinktin.app.ui.common.LocalAppContainer
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.StatusDot
import cn.thinktin.app.ui.common.WaitText
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.labelRes
import cn.thinktin.app.ui.common.resolve
import cn.thinktin.data.model.RunBlock
import cn.thinktin.data.model.RunState
import cn.thinktin.data.model.StreamState
import cn.thinktin.data.model.TimelineItem
import cn.thinktin.data.model.WaitCode
import cn.thinktin.design.component.BannerTone
import cn.thinktin.design.component.Composer
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.WarningBanner
import cn.thinktin.design.theme.ThinktinSpacing
import kotlinx.coroutines.launch
import java.io.File

const val CHAT_SCREEN_TEST_TAG = "chat-screen-"
const val CHAT_LIST_TEST_TAG = "chat-list"

/** 对话页的跳转（由 MainNavigation 接到路由上）。 */
data class ChatNavigation(
    val onBack: () -> Unit,
    val onOpenInstanceSettings: (String) -> Unit,
    val onOpenRun: (String) -> Unit,
    val onOpenPlan: (String) -> Unit,
    val onOpenApprovals: () -> Unit,
    val onOpenApproval: (String) -> Unit,
    val onOpenKeys: () -> Unit,
    val onOpenModelRoutes: (String) -> Unit,
    val onOpenDevices: () -> Unit,
    /** 实例没了（404）：回实例列表（首页）。 */
    val onInstanceGone: () -> Unit,
)

/**
 * 对话页（13.5，第 4.3 节）：顶栏实例名（点进实例设置）+ 状态点 + 更多（运行树、实例设置）；按运行分组的时间线
 * （倒序锚定底部：新内容自动滚到底，用户往上翻时不抢）；底部输入框（运行中变停止）；等待类横幅；
 * 密码拦截和 agent 的填写请求是盖在页面上的底部面板。
 */
@Composable
fun ChatScreen(instanceId: String, focusRunId: String?, navigation: ChatNavigation) {
    val container = LocalAppContainer.current
    val service = LocalThinktinService.current
    val viewModel: ChatViewModel = viewModel(
        key = "chat-$instanceId-${System.identityHashCode(service)}",
        factory = viewModelFactory {
            initializer {
                ChatViewModel(
                    service = service,
                    gate = container.approvalGate,
                    clock = container.clock,
                    instanceId = instanceId,
                    focusRunId = focusRunId,
                    artifactFiles = container.artifactFiles,
                    initialDraft = container.draftHandoff.take(instanceId),
                )
            }
        },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val actionState by viewModel.actions.state.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val listState = rememberLazyListState()
    val now by rememberNowMs(container.clock)
    val rows = remember(state.conversation) { ChatRows.of(state.conversation) }
    // reverseLayout：第 0 项在最底下（最新的）。
    val reversed = remember(rows) { rows.asReversed() }
    ApprovalMessages(viewModel.actions, snackbar)
    val copied = stringResource(R.string.chat_copied)
    val onCopied: () -> Unit = { scope.launch { snackbar.showSnackbar(copied) } }

    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is ChatEvent.Message -> {
                    val result = snackbar.showSnackbar(
                        message = event.text.resolve(context),
                        actionLabel = event.retry?.let { context.getString(R.string.action_retry) },
                        duration = if (event.retry != null) SnackbarDuration.Long else SnackbarDuration.Short,
                    )
                    if (result == SnackbarResult.ActionPerformed) event.retry?.invoke()
                }
                is ChatEvent.OpenFile -> if (!openFile(context, event.file, event.name, event.share)) {
                    snackbar.showSnackbar(context.getString(R.string.chat_artifact_no_app))
                }
                ChatEvent.ScrollToBottom -> listState.animateScrollToItem(0)
                is ChatEvent.ScrollToRun -> {
                    val rowsNow = ChatRows.of(viewModel.uiState.value.conversation)
                    val index = ChatRows.lastRowOf(rowsNow, event.runId)
                    if (index >= 0) listState.scrollToItem(rowsNow.size - 1 - index)
                }
                is ChatEvent.ScrollToItem -> {
                    val rowsNow = ChatRows.of(viewModel.uiState.value.conversation)
                    val index = rowsNow.indexOfFirst { it.key == event.key }
                    if (index >= 0) listState.animateScrollToItem(rowsNow.size - 1 - index)
                }
                ChatEvent.InstanceGone -> {
                    snackbar.showSnackbar(context.getString(R.string.chat_instance_gone))
                    navigation.onInstanceGone()
                }
            }
        }
    }

    // 新内容：用户在最底下（或差一项）时跟着滚到底；往上翻着的时候不动。
    val newestKey = rows.lastOrNull()?.key
    val newestSize = (rows.lastOrNull() as? ChatRow.Item)?.item?.let { (it as? TimelineItem.AgentText)?.text?.length }
    LaunchedEffect(newestKey, newestSize) {
        if (listState.firstVisibleItemIndex <= 1) listState.scrollToItem(0)
    }
    // 上拉到顶：加载更早的运行（列表短得一屏放得下时也会接着翻，直到翻完）。
    val nearTop by remember {
        derivedStateOf {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()?.index ?: 0
            info.totalItemsCount == 0 || last >= info.totalItemsCount - 2
        }
    }
    LaunchedEffect(nearTop, state.loadingOlder, state.hasOlder, rows.size) {
        if (nearTop && state.hasOlder && !state.loadingOlder && !state.loading) viewModel.loadOlder()
    }
    val atBottom by remember { derivedStateOf { listState.firstVisibleItemIndex <= 1 } }

    BackHandler(enabled = state.secretForm != null || state.vaultForm != null) {
        viewModel.dismissSecretForm()
        viewModel.dismissVaultForm()
    }

    Box(
        Modifier
            .fillMaxSize()
            .testTag(CHAT_SCREEN_TEST_TAG + instanceId),
    ) {
        Scaffold(
            containerColor = MaterialTheme.colorScheme.background,
            snackbarHost = { SnackbarHost(snackbar) },
            topBar = {
                ChatTopBar(
                    state = state,
                    onBack = navigation.onBack,
                    onOpenSettings = { navigation.onOpenInstanceSettings(instanceId) },
                    onOpenRunTree = {
                        val target = state.conversation.activeBlock ?: state.conversation.blocks.lastOrNull()
                        target?.let { navigation.onOpenRun(it.runId) }
                    },
                )
            },
            bottomBar = {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .imePadding()
                        .padding(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    state.conversation.attentionBlock?.let { block ->
                        AttentionBanner(
                            block = block,
                            onApprove = { if (!viewModel.scrollToPendingApproval()) navigation.onOpenApprovals() },
                            onOpenKeys = navigation.onOpenKeys,
                            onOpenRoutes = { navigation.onOpenModelRoutes(instanceId) },
                            onOpenDevices = navigation.onOpenDevices,
                        )
                    }
                    val name = state.instance?.name ?: stringResource(R.string.page_chat)
                    Composer(
                        value = state.draft,
                        onValueChange = viewModel::onDraftChange,
                        onSend = viewModel::send,
                        running = state.activeRun != null && state.draft.isBlank(),
                        onStop = viewModel::stop,
                        enabled = !state.sending && !state.notFound,
                        placeholder = stringResource(R.string.home_composer_placeholder, name),
                    )
                }
            },
        ) { padding ->
            Column(
                Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                StreamBanner(state, onReconnect = viewModel::subscribe)
                if (state.activeRun != null) {
                    val running = stringResource(R.string.run_state_running)
                    LinearProgressIndicator(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(2.dp)
                            .semantics { contentDescription = running },
                    )
                }
                Box(
                    Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                ) {
                    when {
                        state.loading && rows.isEmpty() -> {
                            val loading = stringResource(R.string.loading)
                            CircularProgressIndicator(
                                Modifier
                                    .align(Alignment.Center)
                                    .semantics { contentDescription = loading },
                            )
                        }
                        rows.isEmpty() -> EmptyState(
                            title = stringResource(R.string.chat_empty_title),
                            message = stringResource(R.string.chat_empty_message, state.instance?.name ?: ""),
                            modifier = Modifier.align(Alignment.Center),
                        )
                        else -> LazyColumn(
                            state = listState,
                            reverseLayout = true,
                            contentPadding = PaddingValues(horizontal = ThinktinSpacing.Page, vertical = 12.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                            modifier = Modifier
                                .fillMaxSize()
                                .testTag(CHAT_LIST_TEST_TAG),
                        ) {
                            items(reversed, key = { it.key }, contentType = { it::class.simpleName }) { row ->
                                ChatRowView(
                                    row = row,
                                    state = state,
                                    nowMs = now,
                                    viewModel = viewModel,
                                    actionState = actionState,
                                    navigation = navigation,
                                    onCopied = onCopied,
                                )
                            }
                            item(key = "older") { OlderRow(state, onLoad = viewModel::loadOlder) }
                        }
                    }
                    if (!atBottom && rows.isNotEmpty()) {
                        SmallFloatingActionButton(
                            onClick = { scope.launch { listState.animateScrollToItem(0) } },
                            modifier = Modifier
                                .align(Alignment.BottomEnd)
                                .padding(16.dp),
                        ) {
                            Icon(Icons.Outlined.KeyboardArrowDown, contentDescription = stringResource(R.string.chat_scroll_bottom))
                        }
                    }
                }
            }
        }
        state.secretForm?.let { form ->
            SecretSheet(
                form = form,
                onChange = viewModel::onSecretFormChange,
                onSave = viewModel::saveSecret,
                onSendAnyway = viewModel::askSendAnyway,
                onDismiss = viewModel::dismissSecretForm,
            )
        }
        state.vaultForm?.let { form ->
            VaultFillSheet(
                form = form,
                onChange = viewModel::onVaultFormChange,
                onSubmit = viewModel::submitVaultForm,
                onDecline = { viewModel.declineVaultRequest(form.requestId) },
                onDismiss = viewModel::dismissVaultForm,
            )
        }
    }
    ApprovalDialogs(actionState, viewModel.actions)
    when (val dialog = state.dialog) {
        null -> Unit
        is ChatDialog.SendAnyway -> ConfirmDialog(
            title = stringResource(R.string.chat_send_anyway_title),
            text = stringResource(R.string.chat_send_anyway_text, dialog.count),
            confirm = stringResource(R.string.chat_secret_send_anyway),
            onConfirm = viewModel::confirmSendAnyway,
            onDismiss = viewModel::dismissDialog,
            danger = true,
        )
        ChatDialog.PrivateKey -> ConfirmDialog(
            title = stringResource(R.string.chat_private_key_title),
            text = stringResource(R.string.chat_private_key_text),
            confirm = stringResource(R.string.action_ok),
            onConfirm = viewModel::dismissDialog,
            onDismiss = viewModel::dismissDialog,
        )
    }
}

@Composable
private fun ChatRowView(
    row: ChatRow,
    state: ChatUiState,
    nowMs: Long,
    viewModel: ChatViewModel,
    actionState: cn.thinktin.app.ui.approval.ApprovalActionState,
    navigation: ChatNavigation,
    onCopied: () -> Unit,
) {
    val container = LocalAppContainer.current
    when (row) {
        is ChatRow.Header -> RunHeaderRow(row.block, nowMs, navigation.onOpenRun)
        is ChatRow.Gap -> GapRow(row.gap)
        is ChatRow.Outcome -> OutcomeRow(row.block)
        is ChatRow.Item -> when (val item = row.item) {
            is TimelineItem.Prompt -> PromptRow(item)
            is TimelineItem.AgentText -> {
                val block = row.runId?.let { state.conversation.block(it) }
                val streaming = block?.streaming == true && block.items.lastOrNull()?.key == item.key
                AgentTextRow(item, streaming, onCopied)
            }
            is TimelineItem.Thought -> ThoughtRow(item)
            is TimelineItem.ToolCall -> ToolCallRow(item)
            is TimelineItem.PlatformToolCall -> PlatformToolCallRow(item)
            is TimelineItem.AgentPlan -> AgentPlanRow(item)
            is TimelineItem.ApprovalCard -> ApprovalCardItem(
                card = item.card,
                nowMs = nowMs,
                clock = container.clock,
                actionState = actionState,
                actions = viewModel.actions,
                onOpen = item.card.approvalId?.let { id -> { navigation.onOpenApproval(id) } },
            )
            is TimelineItem.VaultRequestCard -> VaultRequestRow(
                item = item,
                onFill = { viewModel.openVaultForm(item) },
                onDecline = { viewModel.declineVaultRequest(item.requestId) },
            )
            is TimelineItem.VaultUsed -> VaultUsedRow(item)
            is TimelineItem.Artifact -> ArtifactRow(
                item = item,
                downloading = state.downloadingArtifactId == item.artifactId,
                onOpen = { viewModel.openArtifact(item) },
                onShare = { viewModel.openArtifact(item, share = true) },
            )
            is TimelineItem.ChildRun -> ChildRunRow(item, navigation.onOpenRun)
            is TimelineItem.RunStateLine -> RunStateRow(item)
            is TimelineItem.PlanCard -> PlanCardRow(item, navigation.onOpenPlan)
            is TimelineItem.System -> SystemRow(item.line)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChatTopBar(state: ChatUiState, onBack: () -> Unit, onOpenSettings: () -> Unit, onOpenRunTree: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val instance = state.instance
    val name = instance?.name ?: stringResource(R.string.page_chat)
    CenterAlignedTopAppBar(
        title = {
            val stateLabel = instance?.let { stringResource(it.state.labelRes()) }.orEmpty()
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .clickable(role = Role.Button, onClickLabel = stringResource(R.string.home_instance_settings), onClick = onOpenSettings)
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            ) {
                if (instance != null) StatusDot(instance.state, contentDescription = stateLabel)
                Text(name, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        },
        navigationIcon = {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = stringResource(R.string.action_back))
            }
        },
        actions = {
            Box {
                IconButton(onClick = { menu = true }) {
                    Icon(Icons.Outlined.MoreVert, contentDescription = stringResource(R.string.action_more))
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.chat_menu_run_tree)) },
                        enabled = state.conversation.blocks.isNotEmpty(),
                        onClick = {
                            menu = false
                            onOpenRunTree()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.home_instance_settings)) },
                        onClick = {
                            menu = false
                            onOpenSettings()
                        },
                    )
                }
            }
        },
        colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
            containerColor = MaterialTheme.colorScheme.background,
            scrolledContainerColor = MaterialTheme.colorScheme.background,
        ),
    )
}

/** 顶部细条：连接中 / 重连中；断开时给“重新连接”；联网失败时说显示的是缓存。 */
@Composable
private fun StreamBanner(state: ChatUiState, onReconnect: () -> Unit) {
    val text = when {
        state.streamFailed -> stringResource(R.string.chat_status_stopped)
        state.stream == StreamState.Connecting -> stringResource(R.string.chat_status_connecting)
        state.stream is StreamState.Reconnecting -> stringResource(R.string.chat_status_reconnecting)
        state.offline -> stringResource(R.string.home_offline_banner)
        else -> null
    } ?: return
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = ThinktinSpacing.Page, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        if (state.streamFailed) {
            TextButton(onClick = onReconnect) { Text(stringResource(R.string.chat_reconnect)) }
        }
    }
}

/** 等待类横幅（警告色）：等审批 → 去审批；等 key → 去配 key / 去配模型；等电脑 → 查看设备。 */
@Composable
private fun AttentionBanner(
    block: RunBlock,
    onApprove: () -> Unit,
    onOpenKeys: () -> Unit,
    onOpenRoutes: () -> Unit,
    onOpenDevices: () -> Unit,
) {
    val code = block.waitCode
    when (block.state) {
        RunState.WaitingApproval -> WarningBanner(
            text = stringResource(R.string.chat_banner_approval),
            actionLabel = stringResource(R.string.chat_banner_go_approve),
            onAction = onApprove,
        )
        RunState.WaitingQuota -> {
            val text = WaitText.of(code)?.asString() ?: stringResource(R.string.chat_banner_quota)
            when (code) {
                WaitCode.RateLimited, WaitCode.Overloaded -> WarningBanner(text = text, tone = BannerTone.Info)
                WaitCode.Invalid, WaitCode.NoBalance, WaitCode.Unavailable -> WarningBanner(
                    text = text,
                    actionLabel = stringResource(R.string.chat_banner_go_keys),
                    onAction = onOpenKeys,
                )
                else -> WarningBanner(
                    text = text,
                    actionLabel = stringResource(R.string.chat_banner_go_routes),
                    onAction = onOpenRoutes,
                )
            }
        }
        RunState.WaitingDevice -> WarningBanner(
            text = WaitText.of(code)?.asString() ?: stringResource(R.string.wait_device_offline),
            actionLabel = stringResource(R.string.chat_banner_go_devices),
            onAction = onOpenDevices,
        )
        else -> Unit
    }
}

/** 列表最上面：加载更早的运行（滚到这里自动加载；也能点）。 */
@Composable
private fun OlderRow(state: ChatUiState, onLoad: () -> Unit) {
    Box(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        when {
            state.loadingOlder -> {
                val loading = stringResource(R.string.loading)
                CircularProgressIndicator(
                    Modifier
                        .height(24.dp)
                        .semantics { contentDescription = loading },
                    strokeWidth = 2.dp,
                )
            }
            state.hasOlder -> TextButton(onClick = onLoad) { Text(stringResource(R.string.chat_load_older)) }
            else -> Text(
                stringResource(R.string.chat_no_older),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
    Spacer(Modifier.height(4.dp))
}

/** 用 FileProvider 交给系统打开（ACTION_VIEW）或分享（ACTION_SEND）。没有能处理的应用时返回 false。 */
fun openFile(context: Context, file: File, name: String, share: Boolean): Boolean {
    val uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
    val extension = name.substringAfterLast('.', "").lowercase()
    val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
        ?: if (extension in setOf("md", "txt", "log", "csv", "json")) "text/plain" else "application/octet-stream"
    val intent = if (share) {
        Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_STREAM, uri)
    } else {
        Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
    }.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    return try {
        context.startActivity(Intent.createChooser(intent, name).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (_: ActivityNotFoundException) {
        false
    }
}
