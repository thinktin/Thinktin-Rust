package cn.thinktin.app.ui.imchannels

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.PasswordVisualTransformation
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
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.resolve
import cn.thinktin.data.model.ImChannel
import cn.thinktin.data.model.ImChannelRules
import cn.thinktin.data.model.ImEvents
import cn.thinktin.data.model.ImVendors
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing
import cn.thinktin.design.theme.ThinktinTheme

const val IM_CHANNEL_ROW_TEST_TAG = "im-channel-"

@Composable
fun imVendorName(vendor: String): String = when (vendor) {
    ImVendors.FEISHU -> stringResource(R.string.im_vendor_feishu)
    ImVendors.LARK -> stringResource(R.string.im_vendor_lark)
    ImVendors.WECOM -> stringResource(R.string.im_vendor_wecom)
    ImVendors.DINGTALK -> stringResource(R.string.im_vendor_dingtalk)
    else -> vendor
}

@Composable
fun imEventName(event: String): String = when (event) {
    ImEvents.RUN_FINISHED -> stringResource(R.string.im_event_run_finished)
    ImEvents.RUN_FAILED -> stringResource(R.string.im_event_run_failed)
    ImEvents.APPROVAL -> stringResource(R.string.im_event_approval)
    else -> event
}

/** 列表里的名字：备注，没有时“飞书群机器人 …x7k2”。 */
@Composable
fun imChannelTitle(channel: ImChannel): String =
    channel.label.trim().ifEmpty { stringResource(R.string.im_title_unnamed, imVendorName(channel.vendor), channel.hint) }

@Composable
private fun ImChannelRules.Problem.text(): String = when (this) {
    ImChannelRules.Problem.UnknownAddress -> stringResource(R.string.im_problem_unknown_address)
    ImChannelRules.Problem.BadToken -> stringResource(R.string.im_problem_bad_token)
    ImChannelRules.Problem.SecretNotSupported -> stringResource(R.string.im_problem_secret_not_supported)
    ImChannelRules.Problem.BadSecret -> stringResource(R.string.im_problem_bad_secret)
    ImChannelRules.Problem.BadLabel -> stringResource(R.string.im_problem_bad_label, ImChannelRules.MAX_LABEL)
    ImChannelRules.Problem.NoEvents -> stringResource(R.string.im_problem_no_events)
}

/**
 * 最近一次发送失败的原因（服务端记的是英文诊断，见 crates/notify/src/im.rs）：认得出的换成怎么处理，认不出的给原文。
 * 和 iOS 的 `ImChannelText.lastError` 一样的顺序（“security check”里也有“custom keywords”，先看它）。
 */
fun imLastErrorRes(error: String): Int? {
    val text = error.lowercase()
    return when {
        "security check" in text -> R.string.im_error_security
        "custom keyword" in text -> R.string.im_error_keywords
        "signature" in text || "signing secret" in text -> R.string.im_error_signature
        "ip address" in text || "ip list" in text -> R.string.im_error_ip
        listOf("invalid", "removed", "is gone", "disabled").any { it in text } -> R.string.im_error_invalid
        "rate limited" in text || "throttled" in text -> R.string.im_error_rate_limited
        "does not allow bot" in text -> R.string.im_error_group
        else -> null
    }
}

@Composable
private fun lastErrorText(error: String): String =
    imLastErrorRes(error)?.let { stringResource(it) } ?: stringResource(R.string.im_error_other, error)

@Composable
private fun ScreenScaffold(
    title: String,
    onBack: () -> Unit,
    snackbar: SnackbarHostState,
    actions: @Composable () -> Unit = {},
    content: @Composable (PaddingValues) -> Unit,
) {
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = title,
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
                actions = { actions() },
            )
        },
        content = content,
    )
}

/**
 * IM 渠道（13.15，路由 `im-channels`）：说明、每个群一行（名字、平台和提示、订阅的事件、上次发送，右边开关），下面“发测试消息”
 * “修改”“删除”；发送失败时一句怎么处理。右上角绑定新的（最多 20 个），下拉刷新。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImChannelsScreen(onBack: () -> Unit, onNew: () -> Unit, onEdit: (String) -> Unit) {
    val service = LocalThinktinService.current
    val clock = LocalAppContainer.current.clock
    val viewModel: ImChannelsViewModel = viewModel(factory = viewModelFactory { initializer { ImChannelsViewModel(service) } })
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    var deleting by remember { mutableStateOf<ImChannel?>(null) }
    LaunchedEffect(viewModel) { viewModel.onShown() }
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            if (event is ImChannelEvent.Notice) snackbar.showSnackbar(event.text.resolve(context))
        }
    }
    val now = clock.millis()
    ScreenScaffold(
        title = stringResource(R.string.page_im_channels),
        onBack = onBack,
        snackbar = snackbar,
        actions = {
            IconButton(onClick = onNew, enabled = state.loaded && state.canAdd) {
                Icon(Icons.Outlined.Add, contentDescription = stringResource(R.string.im_new))
            }
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
                state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                error != null -> LazyColumn(Modifier.fillMaxSize()) {
                    item {
                        EmptyState(
                            title = stringResource(R.string.im_load_failed),
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
                            stringResource(R.string.im_intro),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (!state.canAdd) {
                        item(key = "limit") {
                            Text(
                                stringResource(R.string.im_limit, ImChannelRules.MAX_CHANNELS),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.error,
                                modifier = Modifier.padding(vertical = 8.dp),
                            )
                        }
                    }
                    if (state.channels.isEmpty()) {
                        item(key = "empty") {
                            Text(
                                stringResource(R.string.im_empty),
                                style = MaterialTheme.typography.bodyMedium,
                                modifier = Modifier.padding(vertical = 16.dp),
                            )
                        }
                    }
                    items(state.channels, key = { it.id }) { channel ->
                        ChannelRow(
                            channel = channel,
                            busy = channel.id in state.busy,
                            lastSent = channel.lastSentAtMs?.let { RelativeTime.of(it, now, clock.zone).asString() },
                            onToggle = { viewModel.setEnabled(channel, it) },
                            onTest = { viewModel.sendTest(channel) },
                            onEdit = { onEdit(channel.id) },
                            onDelete = { deleting = channel },
                        )
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    }
                }
            }
        }
    }
    deleting?.let { channel ->
        val title = imChannelTitle(channel)
        ConfirmDialog(
            title = stringResource(R.string.im_delete_title, title),
            text = stringResource(R.string.im_delete_message),
            confirm = stringResource(R.string.im_delete_action),
            danger = true,
            onConfirm = {
                deleting = null
                viewModel.delete(channel)
            },
            onDismiss = { deleting = null },
        )
    }
}

@Composable
private fun ChannelRow(
    channel: ImChannel,
    busy: Boolean,
    lastSent: String?,
    onToggle: (Boolean) -> Unit,
    onTest: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val title = imChannelTitle(channel)
    val separator = stringResource(R.string.im_list_separator)
    val detail = listOfNotNull(
        "${imVendorName(channel.vendor)} ${channel.hint}",
        channel.events.map { imEventName(it) }.joinToString(separator),
        lastSent?.let { stringResource(R.string.im_last_sent, it) },
    ).joinToString(" · ")
    val switchLabel = stringResource(R.string.im_enabled_named, title)
    Column(Modifier.testTag(IM_CHANNEL_ROW_TEST_TAG + channel.id)) {
        ListItem(
            headlineContent = { Text(title) },
            supportingContent = { Text(detail) },
            leadingContent = { Icon(Icons.Outlined.Forum, contentDescription = null) },
            trailingContent = {
                Switch(
                    checked = channel.enabled,
                    onCheckedChange = onToggle,
                    enabled = !busy,
                    modifier = Modifier.semantics { contentDescription = switchLabel },
                )
            },
            colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
        )
        channel.lastError?.let { error ->
            Text(
                lastErrorText(error),
                style = MaterialTheme.typography.bodyMedium,
                color = ThinktinTheme.extendedColors.warning,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(horizontal = 4.dp)) {
            TextButton(onClick = onTest, enabled = !busy) { Text(stringResource(R.string.im_send_test)) }
            TextButton(onClick = onEdit) { Text(stringResource(R.string.im_edit_action)) }
            TextButton(onClick = onDelete, enabled = !busy) {
                Text(stringResource(R.string.im_delete_action), color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

/**
 * 绑定（`im-channels/new`）/ 修改（`im-channels/{id}/edit`）群机器人：地址（边粘边认出平台）、签名密钥（企业微信没有）、
 * 备注、事件。修改时“换地址”打开才填新地址。保存后退回去。
 */
@Composable
fun ImChannelEditorScreen(channelId: String?, onBack: () -> Unit, onSaved: (ImChannel) -> Unit) {
    val service = LocalThinktinService.current
    val viewModel: ImChannelEditorViewModel = viewModel(
        key = "im-editor-${channelId ?: "new"}",
        factory = viewModelFactory { initializer { ImChannelEditorViewModel(service, channelId) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is ImChannelEvent.Saved -> onSaved(event.channel)
                is ImChannelEvent.Notice -> snackbar.showSnackbar(event.text.resolve(context))
            }
        }
    }
    ScreenScaffold(
        title = stringResource(if (state.editing) R.string.im_edit else R.string.im_new),
        onBack = onBack,
        snackbar = snackbar,
        actions = {
            TextButton(
                onClick = viewModel::save,
                enabled = !state.saving && !state.loading && state.loadError == null && state.hasChanges,
            ) { Text(stringResource(if (state.saving) R.string.im_saving else R.string.action_save)) }
        },
    ) { padding ->
        val error = state.loadError
        when {
            state.loading -> Box(Modifier.padding(padding).fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            error != null -> Box(Modifier.padding(padding)) {
                EmptyState(
                    title = stringResource(R.string.im_load_failed),
                    message = error.resolve(context),
                    actionLabel = stringResource(R.string.action_retry),
                    onAction = viewModel::load,
                    modifier = Modifier.padding(top = 48.dp),
                )
            }
            else -> EditorForm(state, viewModel, Modifier.padding(padding))
        }
    }
}

@Composable
private fun EditorForm(state: ImChannelEditorUiState, viewModel: ImChannelEditorViewModel, modifier: Modifier) {
    val shows = state.attempted
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(ThinktinSpacing.Page),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        val original = state.original
        if (original == null) {
            Text(
                stringResource(R.string.im_setup_hint),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            val replaceLabel = stringResource(R.string.im_replace_webhook)
            ListItem(
                headlineContent = { Text("${imVendorName(original.vendor)} ${original.hint}") },
                supportingContent = if (original.hasSecret) {
                    { Text(stringResource(R.string.im_has_secret)) }
                } else {
                    null
                },
                trailingContent = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(replaceLabel, style = MaterialTheme.typography.bodyMedium)
                        Switch(
                            checked = state.replacingWebhook,
                            onCheckedChange = viewModel::setReplacingWebhook,
                            modifier = Modifier
                                .padding(start = 8.dp)
                                .semantics { contentDescription = replaceLabel },
                        )
                    }
                },
                colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
            )
        }
        if (state.editsWebhook) {
            val webhookLabel = stringResource(R.string.im_webhook)
            val webhookProblem = state.webhookProblem.takeIf { shows }
            OutlinedTextField(
                value = state.webhookUrl,
                onValueChange = viewModel::onWebhookUrl,
                label = { Text(webhookLabel) },
                placeholder = { Text("https://…") },
                singleLine = true,
                isError = webhookProblem != null,
                supportingText = (webhookProblem?.text() ?: state.vendor?.let {
                    stringResource(R.string.im_webhook_recognized, imVendorName(it))
                })?.let { { Text(it) } },
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { contentDescription = webhookLabel },
            )
            if (state.supportsSecret) {
                val secretLabel = stringResource(R.string.im_secret)
                val secretProblem = state.secretProblem.takeIf { shows }
                OutlinedTextField(
                    value = state.secret,
                    onValueChange = viewModel::onSecret,
                    label = { Text(secretLabel) },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    isError = secretProblem != null,
                    supportingText = { Text(secretProblem?.text() ?: stringResource(R.string.im_secret_hint)) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = secretLabel },
                )
            }
        }
        val labelLabel = stringResource(R.string.im_label)
        val labelProblem = state.labelProblem.takeIf { shows }
        OutlinedTextField(
            value = state.label,
            onValueChange = viewModel::onLabel,
            label = { Text(labelLabel) },
            singleLine = true,
            isError = labelProblem != null,
            supportingText = {
                Text(labelProblem?.text() ?: "${state.label.trim().codePointCount(0, state.label.trim().length)}/${ImChannelRules.MAX_LABEL}")
            },
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = labelLabel },
        )
        SectionHeader(title = stringResource(R.string.im_events))
        for (event in ImEvents.ALL) {
            val name = imEventName(event)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(role = Role.Checkbox) { viewModel.toggle(event) },
            ) {
                Checkbox(checked = event in state.events, onCheckedChange = null)
                Text(name, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(start = 8.dp))
            }
        }
        state.eventsProblem.takeIf { shows }?.let {
            Text(it.text(), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
        }
    }
}
