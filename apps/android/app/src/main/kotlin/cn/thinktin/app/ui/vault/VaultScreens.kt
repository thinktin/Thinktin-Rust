package cn.thinktin.app.ui.vault

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Key
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
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.KeyboardType
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
import cn.thinktin.data.model.Instance
import cn.thinktin.data.model.VaultItem
import cn.thinktin.data.model.VaultRequest
import cn.thinktin.data.model.VaultRequestStatus
import cn.thinktin.data.model.VaultRules
import cn.thinktin.design.component.AiGeneratedLabel
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing
import cn.thinktin.design.theme.ThinktinTheme
import kotlinx.coroutines.launch

const val VAULT_ITEM_ROW_TEST_TAG = "vault-item-"
const val VAULT_REQUEST_ROW_TEST_TAG = "vault-request-"

/** 问题的文案。 */
@Composable
private fun VaultFormProblem.text(): String = when (this) {
    VaultFormProblem.NameEmpty -> stringResource(R.string.vault_problem_name_empty)
    VaultFormProblem.NameInvalid -> stringResource(R.string.vault_problem_name_invalid)
    VaultFormProblem.PurposeTooLong -> stringResource(R.string.vault_problem_too_long, VaultRules.MAX_PURPOSE)
    VaultFormProblem.UsernameTooLong -> stringResource(R.string.vault_problem_too_long, VaultRules.MAX_USERNAME)
    VaultFormProblem.PurposeControl, VaultFormProblem.ControlCharacters -> stringResource(R.string.vault_problem_control)
    is VaultFormProblem.Password -> when (problem) {
        VaultRules.PasswordProblem.TooShort -> stringResource(R.string.vault_problem_password_short, VaultRules.MIN_PASSWORD)
        VaultRules.PasswordProblem.TooLong -> stringResource(R.string.vault_problem_password_long)
        VaultRules.PasswordProblem.ControlCharacters -> stringResource(R.string.vault_problem_control)
    }
    VaultFormProblem.NoInstances -> stringResource(R.string.vault_problem_no_instances)
    VaultFormProblem.TooManyInstances -> stringResource(R.string.vault_problem_too_many_instances, VaultRules.MAX_INSTANCES)
    VaultFormProblem.Full -> stringResource(R.string.vault_full, VaultRules.MAX_ITEMS)
}

@Composable
private fun VaultRequestStatus.label(): String = stringResource(
    when (this) {
        VaultRequestStatus.Pending -> R.string.chat_vault_status_pending
        VaultRequestStatus.Fulfilled -> R.string.chat_vault_status_fulfilled
        VaultRequestStatus.Declined -> R.string.chat_vault_status_declined
        VaultRequestStatus.Expired, VaultRequestStatus.Unknown -> R.string.chat_vault_status_expired
    },
)

/** 能用的实例：所有，或者“只给：A、B”（删掉的实例显示“已删除的实例”）。 */
@Composable
private fun instancesText(item: VaultItem, instances: Map<String, Instance>): String =
    if (item.instanceIds.isEmpty()) {
        stringResource(R.string.vault_all_instances)
    } else {
        val deleted = stringResource(R.string.vault_deleted_instance)
        stringResource(
            R.string.vault_only_instances,
            item.instanceIds.joinToString(stringResource(R.string.vault_list_separator)) { instances[it]?.name ?: deleted },
        )
    }

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

@Composable
private fun Loading() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
}

/**
 * 密码保险箱（13.14，路由 `vault`）：说明、等你填写的请求、条目（条数 / 200，满了提示）、处理过的请求。右上角新建，下拉刷新。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VaultScreen(
    onBack: () -> Unit,
    onOpenItem: (String) -> Unit,
    onOpenRequest: (String) -> Unit,
    onNewItem: () -> Unit,
) {
    val service = LocalThinktinService.current
    val clock = LocalAppContainer.current.clock
    val viewModel: VaultViewModel = viewModel(factory = viewModelFactory { initializer { VaultViewModel(service) } })
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    var deleting by remember { mutableStateOf<VaultItem?>(null) }
    LaunchedEffect(viewModel) { viewModel.onShown() }
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            if (event is VaultEvent.Notice) snackbar.showSnackbar(event.text.resolve(context))
        }
    }
    val now = clock.millis()
    ScreenScaffold(
        title = stringResource(R.string.page_vault),
        onBack = onBack,
        snackbar = snackbar,
        actions = {
            IconButton(onClick = onNewItem, enabled = state.loaded && !state.isFull) {
                Icon(Icons.Outlined.Add, contentDescription = stringResource(R.string.vault_new))
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
                state.loading -> Loading()
                error != null -> LazyColumn(Modifier.fillMaxSize()) {
                    item {
                        EmptyState(
                            title = stringResource(R.string.vault_load_failed),
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
                            stringResource(R.string.vault_intro),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    val pending = state.pending(now)
                    if (pending.isNotEmpty()) {
                        item(key = "pending-header") {
                            SectionHeader(title = stringResource(R.string.vault_section_pending), modifier = Modifier.padding(top = 12.dp))
                        }
                        items(pending, key = { "pending-" + it.id }) { request ->
                            RequestRow(request, state.instances, now, onClick = { onOpenRequest(request.id) })
                            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        }
                    }
                    item(key = "items-header") {
                        SectionHeader(
                            title = stringResource(R.string.vault_section_items, state.items.size, VaultRules.MAX_ITEMS),
                            modifier = Modifier.padding(top = 12.dp),
                        )
                    }
                    if (state.isFull) {
                        item(key = "full") {
                            Text(
                                stringResource(R.string.vault_full, VaultRules.MAX_ITEMS),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.error,
                                modifier = Modifier.padding(vertical = 8.dp),
                            )
                        }
                    }
                    if (state.items.isEmpty()) {
                        item(key = "empty") {
                            Column(Modifier.padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(stringResource(R.string.vault_empty), style = MaterialTheme.typography.bodyMedium)
                                SecondaryButton(text = stringResource(R.string.vault_new), onClick = onNewItem)
                            }
                        }
                    }
                    items(state.items, key = { "item-" + it.id }) { item ->
                        ListItem(
                            headlineContent = { Text(item.name) },
                            supportingContent = {
                                Text(listOfNotNull(item.purpose.ifEmpty { null }, instancesText(item, state.instances)).joinToString(" · "))
                            },
                            leadingContent = { Icon(Icons.Outlined.Key, contentDescription = null) },
                            trailingContent = {
                                if (item.id in state.deleting) {
                                    CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.padding(8.dp))
                                } else {
                                    IconButton(onClick = { deleting = item }) {
                                        Icon(Icons.Outlined.Delete, contentDescription = stringResource(R.string.vault_delete_named, item.name))
                                    }
                                }
                            },
                            colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
                            modifier = Modifier
                                .testTag(VAULT_ITEM_ROW_TEST_TAG + item.id)
                                .clickable(role = Role.Button) { onOpenItem(item.id) },
                        )
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    }
                    val past = state.past(now)
                    if (past.isNotEmpty()) {
                        item(key = "past-header") {
                            SectionHeader(title = stringResource(R.string.vault_section_past), modifier = Modifier.padding(top = 20.dp))
                        }
                        items(past, key = { "past-" + it.id }) { request ->
                            RequestRow(request, state.instances, now, onClick = { onOpenRequest(request.id) })
                            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        }
                    }
                }
            }
        }
    }
    deleting?.let { item ->
        ConfirmDialog(
            title = stringResource(R.string.vault_delete_title, item.name),
            text = stringResource(R.string.vault_delete_message, item.name),
            confirm = stringResource(R.string.action_delete),
            danger = true,
            onConfirm = {
                deleting = null
                viewModel.delete(item)
            },
            onDismiss = { deleting = null },
        )
    }
}

@Composable
private fun RequestRow(request: VaultRequest, instances: Map<String, Instance>, nowMs: Long, onClick: () -> Unit) {
    val status = request.effectiveStatus(nowMs)
    val detail = listOfNotNull(
        instances[request.instanceId]?.name,
        if (status == VaultRequestStatus.Pending) expiresText(request.expiresAtMs, nowMs) else status.label(),
    ).joinToString(" · ")
    ListItem(
        headlineContent = { Text(request.name) },
        supportingContent = {
            Text(
                detail,
                color = if (status == VaultRequestStatus.Pending) ThinktinTheme.extendedColors.warning else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        leadingContent = { Icon(Icons.Outlined.Key, contentDescription = null) },
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
        modifier = Modifier
            .testTag(VAULT_REQUEST_ROW_TEST_TAG + request.id)
            .clickable(role = Role.Button, onClick = onClick),
    )
}

@Composable
private fun expiresText(expiresAtMs: Long, nowMs: Long): String {
    val minutes = ((expiresAtMs - nowMs) / 60_000).coerceAtLeast(0)
    return if (minutes < 60) {
        stringResource(R.string.vault_expires_minutes, minutes.toInt())
    } else {
        stringResource(R.string.vault_expires_hours, (minutes / 60).toInt())
    }
}

/** 一个条目（`vault/item/{id}`）：引用（点了复制）、用途、账号、密码（永远看不到）、能用的实例、时间；修改、删除。 */
@Composable
fun VaultItemScreen(itemId: String, onBack: () -> Unit, onEdit: (String) -> Unit) {
    val service = LocalThinktinService.current
    val clock = LocalAppContainer.current.clock
    val viewModel: VaultItemViewModel = viewModel(
        key = "vault-item-$itemId",
        factory = viewModelFactory { initializer { VaultItemViewModel(service, itemId) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    LaunchedEffect(viewModel) { viewModel.onShown() }
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                VaultEvent.Deleted -> onBack()
                is VaultEvent.Notice -> snackbar.showSnackbar(event.text.resolve(context))
                is VaultEvent.Saved -> Unit
            }
        }
    }
    val detail = state.detail
    ScreenScaffold(
        title = detail?.item?.name ?: stringResource(R.string.vault_item_title),
        onBack = onBack,
        snackbar = snackbar,
        actions = {
            if (detail != null) {
                IconButton(onClick = { onEdit(itemId) }) {
                    Icon(Icons.Outlined.Edit, contentDescription = stringResource(R.string.vault_edit))
                }
            }
        },
    ) { padding ->
        val error = state.loadError
        Box(
            Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            when {
                state.missing -> EmptyState(
                    title = stringResource(R.string.vault_item_missing),
                    message = stringResource(R.string.vault_item_missing_message),
                    modifier = Modifier.padding(top = 48.dp),
                )
                detail != null -> {
                    val item = detail.item
                    val copied = stringResource(R.string.vault_reference_copied)
                    val now = clock.millis()
                    val zone = clock.zone
                    Column(
                        Modifier
                            .fillMaxSize()
                            .verticalScroll(rememberScrollState())
                            .padding(bottom = 24.dp),
                    ) {
                        InfoRow(
                            title = "[vault:${item.name}]",
                            value = stringResource(R.string.vault_reference_hint),
                            onClick = {
                                clipboard.setText(AnnotatedString("[vault:${item.name}]"))
                                scope.launch {
                                    snackbar.currentSnackbarData?.dismiss()
                                    snackbar.showSnackbar(copied)
                                }
                            },
                        )
                        if (item.purpose.isNotEmpty()) InfoRow(stringResource(R.string.vault_purpose), item.purpose)
                        InfoRow(
                            stringResource(R.string.chat_vault_field_username),
                            detail.username.ifEmpty { stringResource(R.string.vault_no_username) },
                        )
                        InfoRow(stringResource(R.string.chat_vault_field_password), stringResource(R.string.vault_password_hidden))
                        InfoRow(stringResource(R.string.vault_instances), instancesText(item, state.instances))
                        SectionHeader(
                            title = stringResource(R.string.vault_section_dates),
                            modifier = Modifier.padding(horizontal = ThinktinSpacing.Page).padding(top = 12.dp),
                        )
                        InfoRow(stringResource(R.string.vault_created), RelativeTime.of(item.createdAtMs, now, zone).asString())
                        InfoRow(stringResource(R.string.vault_updated), RelativeTime.of(item.updatedAtMs, now, zone).asString())
                        InfoRow(
                            stringResource(R.string.vault_last_used),
                            item.lastUsedAtMs?.let { RelativeTime.of(it, now, zone).asString() } ?: stringResource(R.string.vault_never_used),
                        )
                        TextButton(
                            onClick = viewModel::askDelete,
                            enabled = !state.deleting,
                            modifier = Modifier
                                .padding(horizontal = ThinktinSpacing.Page, vertical = 12.dp)
                                .fillMaxWidth(),
                        ) {
                            Text(stringResource(R.string.vault_delete), color = MaterialTheme.colorScheme.error)
                        }
                    }
                }
                error != null -> EmptyState(
                    title = stringResource(R.string.vault_load_failed),
                    message = error.resolve(context),
                    actionLabel = stringResource(R.string.action_retry),
                    onAction = viewModel::load,
                    modifier = Modifier.padding(top = 48.dp),
                )
                else -> Loading()
            }
        }
    }
    if (state.confirmDelete && detail != null) {
        ConfirmDialog(
            title = stringResource(R.string.vault_delete_title, detail.item.name),
            text = stringResource(R.string.vault_delete_message, detail.item.name),
            confirm = stringResource(R.string.action_delete),
            danger = true,
            busy = state.deleting,
            onConfirm = viewModel::delete,
            onDismiss = viewModel::dismissDelete,
        )
    }
}

@Composable
private fun InfoRow(title: String, value: String, onClick: (() -> Unit)? = null) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(value) },
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
        modifier = if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier,
    )
}

/**
 * 新建（`vault/new`）/ 修改（`vault/item/{id}/edit`）条目：名字（新建时）、用途、账号、密码（修改时不填不改）、能用的实例。
 * 保存后退回去。
 */
@Composable
fun VaultEditorScreen(itemId: String?, onBack: () -> Unit, onSaved: (VaultItem) -> Unit) {
    val service = LocalThinktinService.current
    val viewModel: VaultEditorViewModel = viewModel(
        key = "vault-editor-${itemId ?: "new"}",
        factory = viewModelFactory { initializer { VaultEditorViewModel(service, itemId) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is VaultEvent.Saved -> onSaved(event.item)
                is VaultEvent.Notice -> snackbar.showSnackbar(event.text.resolve(context))
                VaultEvent.Deleted -> Unit
            }
        }
    }
    var confirmDiscard by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    val close = {
        if (!state.saving) {
            if (state.hasChanges) confirmDiscard = true else onBack()
        }
    }
    androidx.activity.compose.BackHandler(onBack = close)
    if (confirmDiscard) {
        ConfirmDialog(
            title = stringResource(R.string.plan_discard_title), text = stringResource(R.string.plan_discard_text),
            confirm = stringResource(R.string.plan_discard), onConfirm = { confirmDiscard = false; onBack() },
            onDismiss = { confirmDiscard = false }, danger = true,
        )
    }
    ScreenScaffold(
        title = stringResource(if (state.editing) R.string.vault_edit else R.string.vault_new),
        onBack = close,
        snackbar = snackbar,
        actions = {
            TextButton(
                onClick = viewModel::save,
                enabled = !state.saving && !state.loading && state.loadError == null && (!state.editing || state.hasChanges),
            ) { Text(stringResource(if (state.saving) R.string.vault_saving else R.string.action_save)) }
        },
    ) { padding ->
        val error = state.loadError
        when {
            state.loading -> Box(Modifier.padding(padding)) { Loading() }
            error != null -> Box(Modifier.padding(padding)) {
                EmptyState(
                    title = stringResource(R.string.vault_load_failed),
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
private fun EditorForm(state: VaultEditorUiState, viewModel: VaultEditorViewModel, modifier: Modifier) {
    val problems = state.visibleProblems
    fun problem(vararg kinds: VaultFormProblem): VaultFormProblem? = problems.firstOrNull { it in kinds }
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(ThinktinSpacing.Page),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (VaultFormProblem.Full in problems) {
            Text(VaultFormProblem.Full.text(), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
        }
        if (state.editing) {
            Text(stringResource(R.string.vault_name_fixed, state.name), style = MaterialTheme.typography.bodyMedium)
        } else {
            val nameProblem = problem(VaultFormProblem.NameEmpty, VaultFormProblem.NameInvalid)
            val label = stringResource(R.string.vault_name)
            OutlinedTextField(
                value = state.name,
                onValueChange = viewModel::onName,
                label = { Text(label) },
                singleLine = true,
                isError = nameProblem != null,
                supportingText = {
                    Text(
                        nameProblem?.text()
                            ?: state.renamedTo?.let { stringResource(R.string.vault_renamed, it) }
                            ?: stringResource(R.string.vault_name_hint),
                    )
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { contentDescription = label },
            )
        }
        val purposeLabel = stringResource(R.string.vault_purpose_optional)
        OutlinedTextField(
            value = state.purpose,
            onValueChange = viewModel::onPurpose,
            label = { Text(purposeLabel) },
            isError = problem(VaultFormProblem.PurposeTooLong, VaultFormProblem.PurposeControl) != null,
            supportingText = {
                Text(
                    problem(VaultFormProblem.PurposeTooLong, VaultFormProblem.PurposeControl)?.text()
                        ?: "${VaultRules.length(state.purpose.trim())}/${VaultRules.MAX_PURPOSE}",
                )
            },
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = purposeLabel },
        )
        val usernameLabel = stringResource(R.string.vault_username_optional)
        OutlinedTextField(
            value = state.username,
            onValueChange = viewModel::onUsername,
            label = { Text(usernameLabel) },
            singleLine = true,
            isError = problem(VaultFormProblem.UsernameTooLong, VaultFormProblem.ControlCharacters) != null,
            supportingText = problem(VaultFormProblem.UsernameTooLong, VaultFormProblem.ControlCharacters)?.let { { Text(it.text()) } },
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = usernameLabel },
        )
        val passwordLabel = stringResource(R.string.chat_vault_field_password)
        val passwordProblem = problems.firstOrNull { it is VaultFormProblem.Password }
        OutlinedTextField(
            value = state.password,
            onValueChange = viewModel::onPassword,
            label = { Text(passwordLabel) },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
            isError = passwordProblem != null,
            supportingText = {
                Text(
                    passwordProblem?.text()
                        ?: stringResource(if (state.editing) R.string.vault_password_keep else R.string.vault_password_hint),
                )
            },
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = passwordLabel },
        )
        SectionHeader(title = stringResource(R.string.vault_instances))
        ChoiceRow(stringResource(R.string.vault_all_instances), state.allInstances) { viewModel.setAllInstances(true) }
        ChoiceRow(stringResource(R.string.vault_some_instances), !state.allInstances) { viewModel.setAllInstances(false) }
        if (!state.allInstances) {
            problem(VaultFormProblem.NoInstances, VaultFormProblem.TooManyInstances)?.let {
                Text(it.text(), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
            state.instances.forEach { instance ->
                val checked = instance.id in state.selected
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 48.dp)
                        .clickable(role = Role.Checkbox) { viewModel.toggle(instance.id) },
                ) {
                    Checkbox(checked = checked, onCheckedChange = null)
                    Text(instance.name, modifier = Modifier.padding(start = 8.dp))
                }
            }
        }
    }
}

@Composable
private fun ChoiceRow(text: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(role = Role.RadioButton, onClick = onClick),
    ) {
        RadioButton(selected = selected, onClick = null)
        Text(text, modifier = Modifier.padding(start = 8.dp))
    }
}

/**
 * 填写请求（`vault?requestId=`）：agent 要的账号密码，填好只进保险箱；已有同名条目的先提示会换掉它；处理过、过期了的显示结果。
 */
@Composable
fun VaultRequestScreen(requestId: String, onBack: () -> Unit, onOpenItem: (String) -> Unit, onOpenRun: (String) -> Unit) {
    val service = LocalThinktinService.current
    val clock = LocalAppContainer.current.clock
    val viewModel: VaultRequestViewModel = viewModel(
        key = "vault-request-$requestId",
        factory = viewModelFactory { initializer { VaultRequestViewModel(service, requestId, clock::millis) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            if (event is VaultEvent.Notice) snackbar.showSnackbar(event.text.resolve(context))
        }
    }
    ScreenScaffold(title = stringResource(R.string.vault_request_title), onBack = onBack, snackbar = snackbar) { padding ->
        val request = state.request
        val error = state.loadError
        Box(
            Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            when {
                state.missing -> EmptyState(
                    title = stringResource(R.string.vault_request_missing),
                    message = stringResource(R.string.vault_request_missing_message),
                    modifier = Modifier.padding(top = 48.dp),
                )
                request != null -> RequestForm(state, request, viewModel.status() ?: request.status, clock.millis(), viewModel, onOpenItem, onOpenRun)
                error != null -> EmptyState(
                    title = stringResource(R.string.vault_load_failed),
                    message = error.resolve(context),
                    actionLabel = stringResource(R.string.action_retry),
                    onAction = viewModel::load,
                    modifier = Modifier.padding(top = 48.dp),
                )
                else -> Loading()
            }
        }
    }
}

@Composable
private fun RequestForm(
    state: VaultRequestUiState,
    request: VaultRequest,
    status: VaultRequestStatus,
    nowMs: Long,
    viewModel: VaultRequestViewModel,
    onOpenItem: (String) -> Unit,
    onOpenRun: (String) -> Unit,
) {
    val problems = state.visibleProblems
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(ThinktinSpacing.Page),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(stringResource(R.string.chat_vault_request_title, request.name), style = MaterialTheme.typography.titleMedium)
        state.instanceName?.let {
            Text(stringResource(R.string.vault_request_instance, it), style = MaterialTheme.typography.bodyMedium)
        }
        if (request.purpose.isNotEmpty()) {
            Text(request.purpose, style = MaterialTheme.typography.bodyLarge)
            AiGeneratedLabel()
        }
        request.runId?.let { runId ->
            TextButton(onClick = { onOpenRun(runId) }) { Text(stringResource(R.string.vault_request_open_run)) }
        }
        if (status == VaultRequestStatus.Pending) {
            Text(expiresText(request.expiresAtMs, nowMs), color = ThinktinTheme.extendedColors.warning, style = MaterialTheme.typography.bodyMedium)
            state.existing?.let {
                Text(
                    stringResource(R.string.vault_request_replaces, it.name),
                    style = MaterialTheme.typography.bodyMedium,
                    color = ThinktinTheme.extendedColors.warning,
                )
            }
            if ("username" in request.fields) {
                val label = stringResource(R.string.chat_vault_field_username)
                OutlinedTextField(
                    value = state.username,
                    onValueChange = viewModel::onUsername,
                    label = { Text(label) },
                    singleLine = true,
                    isError = problems.any { it == VaultFormProblem.UsernameTooLong || it == VaultFormProblem.ControlCharacters },
                    supportingText = problems.firstOrNull { it == VaultFormProblem.UsernameTooLong || it == VaultFormProblem.ControlCharacters }
                        ?.let { { Text(it.text()) } },
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = label },
                )
            }
            val passwordLabel = stringResource(R.string.chat_vault_field_password)
            val passwordProblem = problems.firstOrNull { it is VaultFormProblem.Password }
            OutlinedTextField(
                value = state.password,
                onValueChange = viewModel::onPassword,
                label = { Text(passwordLabel) },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                isError = passwordProblem != null,
                supportingText = passwordProblem?.let { { Text(it.text()) } },
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { contentDescription = passwordLabel },
            )
            Text(
                stringResource(R.string.vault_request_note),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            PrimaryButton(
                text = stringResource(R.string.chat_vault_form_submit),
                onClick = viewModel::fulfill,
                enabled = state.password.isNotEmpty(),
                loading = state.busy,
                modifier = Modifier.fillMaxWidth(),
            )
            SecondaryButton(
                text = stringResource(R.string.chat_vault_decline),
                onClick = viewModel::decline,
                enabled = !state.busy,
                modifier = Modifier.fillMaxWidth(),
            )
        } else {
            Text(status.label(), style = MaterialTheme.typography.titleSmall)
            val itemId = request.itemId
            if (status == VaultRequestStatus.Fulfilled && itemId != null) {
                SecondaryButton(text = stringResource(R.string.vault_view_item), onClick = { onOpenItem(itemId) })
            }
        }
    }
}
