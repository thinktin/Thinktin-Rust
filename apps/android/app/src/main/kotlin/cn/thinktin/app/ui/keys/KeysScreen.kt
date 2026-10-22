package cn.thinktin.app.ui.keys

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
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
import cn.thinktin.app.ui.catalog.Tag
import cn.thinktin.app.ui.catalog.protocolLabel
import cn.thinktin.app.ui.common.ConfirmDialog
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.formatTokens
import cn.thinktin.app.ui.common.resolve
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.VendorInfo
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing
import cn.thinktin.design.theme.ThinktinTheme

/** 测试用：key 行的 testTag 前缀（后接 key 的 id）。 */
const val KEY_ROW_TEST_TAG = "key-row-"

/**
 * 模型 key 列表（第 4.5 节，路由 keys）。入口：设置页“模型 key”、实例设置里模型别名旁、模型别名页顶栏。
 * 每行：厂商、标签、后 4 位、每日限额、状态、协议；点行进编辑，“更多”里有编辑、换 key、停用 / 启用、删除。
 */
@Composable
fun KeysScreen(
    onBack: () -> Unit,
    onAdd: () -> Unit,
    onEdit: (String) -> Unit,
    onReplaceSecret: (String) -> Unit,
    onOpenUsage: () -> Unit,
) {
    val service = LocalThinktinService.current
    val viewModel: KeysViewModel = viewModel(factory = viewModelFactory { initializer { KeysViewModel(service) } })
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    LaunchedEffect(viewModel) { viewModel.onShown() }
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is KeysEvent.Message -> snackbar.showSnackbar(event.text.resolve(context), duration = SnackbarDuration.Long)
            }
        }
    }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_keys),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
                actions = {
                    IconButton(onClick = onOpenUsage) {
                        Icon(Icons.Outlined.BarChart, contentDescription = stringResource(R.string.page_usage))
                    }
                },
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            when {
                state.credentials.isNotEmpty() -> LazyColumn(modifier = Modifier.fillMaxSize()) {
                    item {
                        Text(
                            text = stringResource(R.string.keys_intro),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
                        )
                    }
                    state.loadError?.let { error ->
                        item {
                            Text(
                                text = error.asString(),
                                color = MaterialTheme.colorScheme.error,
                                style = MaterialTheme.typography.bodyMedium,
                                modifier = Modifier.padding(horizontal = ThinktinSpacing.Page),
                            )
                        }
                    }
                    items(state.credentials, key = { it.id }) { credential ->
                        KeyRow(
                            credential = credential,
                            vendors = state.vendors,
                            checking = state.checkingUsageFor == credential.id,
                            toggling = state.togglingId == credential.id,
                            onEdit = { onEdit(credential.id) },
                            onReplaceSecret = { onReplaceSecret(credential.id) },
                            onToggle = { viewModel.setDisabled(credential, !credential.disabled) },
                            onDelete = { viewModel.askDelete(credential) },
                        )
                    }
                    item {
                        PrimaryButton(
                            text = stringResource(R.string.keys_add),
                            onClick = onAdd,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(ThinktinSpacing.Page),
                        )
                    }
                }
                state.loading -> {
                    val loading = stringResource(R.string.loading)
                    CircularProgressIndicator(
                        modifier = Modifier
                            .align(Alignment.Center)
                            .semantics { contentDescription = loading },
                    )
                }
                state.loadError != null -> EmptyState(
                    title = stringResource(R.string.keys_load_failed),
                    message = state.loadError!!.asString(),
                    actionLabel = stringResource(R.string.action_retry),
                    onAction = viewModel::load,
                    modifier = Modifier.align(Alignment.Center),
                )
                else -> Column(
                    modifier = Modifier
                        .align(Alignment.Center)
                        .verticalScroll(rememberScrollState()),
                ) {
                    EmptyState(
                        title = stringResource(R.string.keys_empty_title),
                        message = stringResource(R.string.keys_empty_message),
                        actionLabel = stringResource(R.string.keys_add),
                        onAction = onAdd,
                    )
                }
            }
        }
    }
    state.dialog?.let { dialog ->
        DeleteKeyConfirm(dialog = dialog, vendors = state.vendors, busy = state.busy, viewModel = viewModel)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun KeyRow(
    credential: Credential,
    vendors: Map<String, VendorInfo>,
    checking: Boolean,
    toggling: Boolean,
    onEdit: () -> Unit,
    onReplaceSecret: () -> Unit,
    onToggle: () -> Unit,
    onDelete: () -> Unit,
) {
    val vendor = vendorName(credential.vendor, vendors)
    val title = credentialTitle(credential, vendors)
    var menuOpen by rememberSaveable { mutableStateOf(false) }
    Column(modifier = Modifier.testTag(KEY_ROW_TEST_TAG + credential.id)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = ThinktinSpacing.ListItemMinHeight)
                .clickable(role = Role.Button, onClickLabel = stringResource(R.string.keys_edit), onClick = onEdit)
                .padding(start = ThinktinSpacing.Page, end = 4.dp, top = 12.dp, bottom = 12.dp),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            VendorBadge(vendor)
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                // 标签是用户起的，不标 AI 生成。
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.semantics { heading() },
                )
                Text(
                    text = stringResource(R.string.keys_vendor_last4, vendor, credential.last4),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    text = credential.dailyTokenLimit?.let { stringResource(R.string.keys_daily_limit, formatTokens(it)) }
                        ?: stringResource(R.string.keys_no_limit),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    val status = stringResource(if (credential.disabled) R.string.keys_status_disabled else R.string.keys_status_active)
                    Text(
                        text = status,
                        style = MaterialTheme.typography.labelMedium,
                        // 停用用次要文字色（警告色在浅色底上对比度不够 4.5:1）。
                        color = if (credential.disabled) {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        } else {
                            ThinktinTheme.extendedColors.success
                        },
                        modifier = Modifier.semantics { contentDescription = statusLabel(credential) },
                    )
                    credential.protocols.forEach { protocol ->
                        val label = protocolLabel(protocol)
                        Tag(label, accessibleLabel = stringResource(R.string.agent_protocol_a11y, label))
                    }
                }
            }
            Box {
                if (checking || toggling) {
                    val loading = stringResource(R.string.loading)
                    CircularProgressIndicator(
                        strokeWidth = 2.dp,
                        modifier = Modifier
                            .padding(12.dp)
                            .size(24.dp)
                            .semantics { contentDescription = loading },
                    )
                } else {
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(Icons.Outlined.MoreVert, contentDescription = stringResource(R.string.keys_more, title))
                    }
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.keys_edit)) },
                        onClick = {
                            menuOpen = false
                            onEdit()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.keys_replace)) },
                        onClick = {
                            menuOpen = false
                            onReplaceSecret()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(if (credential.disabled) R.string.keys_enable else R.string.keys_disable)) },
                        onClick = {
                            menuOpen = false
                            onToggle()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.keys_delete), color = MaterialTheme.colorScheme.error) },
                        onClick = {
                            menuOpen = false
                            onDelete()
                        },
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
private fun statusLabel(credential: Credential): String = stringResource(
    R.string.keys_status_a11y,
    stringResource(if (credential.disabled) R.string.keys_status_disabled else R.string.keys_status_active),
)

/** 删除确认：有别名在用时列出“实例：别名（主 key / 降级）”，并说明删除前会先把它拿掉、只靠它的实例会等 key。 */
@Composable
private fun DeleteKeyConfirm(
    dialog: DeleteKeyDialog,
    vendors: Map<String, VendorInfo>,
    busy: Boolean,
    viewModel: KeysViewModel,
) {
    val credential = dialog.credential
    val inUse = dialog.usages.isNotEmpty()
    ConfirmDialog(
        title = stringResource(R.string.keys_delete_title, credentialTitle(credential, vendors), credential.last4),
        text = stringResource(if (inUse) R.string.keys_delete_in_use_message else R.string.keys_delete_message),
        confirm = stringResource(if (inUse) R.string.keys_delete_detach else R.string.keys_delete),
        danger = true,
        busy = busy,
        onConfirm = viewModel::confirmDelete,
        onDismiss = viewModel::dismissDialog,
    ) {
        if (inUse) {
            Column(
                modifier = Modifier
                    .heightIn(max = 240.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                dialog.usages.forEach { usage ->
                    // 实例名是用户起的，不标 AI 生成。
                    Text(
                        text = stringResource(
                            R.string.keys_usage_item,
                            usage.instanceName,
                            usage.alias,
                            stringResource(if (usage.primary) R.string.keys_usage_primary else R.string.keys_usage_fallback),
                        ),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
                Text(
                    text = stringResource(R.string.keys_delete_wait_warning),
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
    }
}
