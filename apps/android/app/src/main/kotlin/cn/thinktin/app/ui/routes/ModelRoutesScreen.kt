package cn.thinktin.app.ui.routes

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowDropDown
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.catalog.protocolLabel
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.resolve
import cn.thinktin.app.ui.keys.KeyRules
import cn.thinktin.app.ui.keys.credentialOption
import cn.thinktin.data.model.Credential
import cn.thinktin.data.model.VendorInfo
import cn.thinktin.design.component.BannerTone
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.component.WarningBanner
import cn.thinktin.design.theme.ThinktinShapes
import cn.thinktin.design.theme.ThinktinSpacing

/** 测试用：别名卡片的 testTag 前缀（后接行号，从 0 开始）。 */
const val ROUTE_CARD_TEST_TAG = "route-card-"

/**
 * 实例的模型别名与降级链（第 4.4 / 4.5 节，路由 instance/{instanceId}/routes）。入口：实例设置。
 * [onOpenKeys]：顶栏的 key 管理；[onAddKey]：没有能用的 key 时直接去添加。
 */
@Composable
fun ModelRoutesScreen(
    instanceId: String,
    onBack: () -> Unit,
    onOpenKeys: () -> Unit,
    onAddKey: () -> Unit,
) {
    val service = LocalThinktinService.current
    val viewModel: ModelRoutesViewModel = viewModel(
        key = "routes-$instanceId",
        factory = viewModelFactory { initializer { ModelRoutesViewModel(service, instanceId) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    LaunchedEffect(viewModel) { viewModel.onShown() }
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is ModelRoutesEvent.Message -> snackbar.showSnackbar(event.text.resolve(context))
            }
        }
    }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = stringResource(R.string.page_model_routes),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = onBack,
                actions = {
                    IconButton(onClick = onOpenKeys) {
                        Icon(Icons.Outlined.Key, contentDescription = stringResource(R.string.routes_manage_keys))
                    }
                },
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .consumeWindowInsets(padding)
                .imePadding(),
        ) {
            when {
                state.instance != null && !state.loading -> RoutesContent(state, viewModel, onAddKey)
                state.loading -> {
                    val label = stringResource(R.string.loading)
                    CircularProgressIndicator(
                        modifier = Modifier
                            .align(Alignment.Center)
                            .semantics { contentDescription = label },
                    )
                }
                else -> EmptyState(
                    title = stringResource(R.string.routes_load_failed),
                    message = state.loadError?.asString(),
                    actionLabel = stringResource(R.string.action_retry),
                    onAction = viewModel::load,
                    modifier = Modifier.align(Alignment.Center),
                )
            }
        }
    }
}

@Composable
private fun RoutesContent(state: ModelRoutesUiState, viewModel: ModelRoutesViewModel, onAddKey: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(ThinktinSpacing.Page),
        verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
    ) {
        if (state.mainMissing) {
            WarningBanner(text = stringResource(R.string.routes_main_missing))
        }
        // 实例名是用户起的，不标 AI 生成。
        Text(
            text = state.instance?.name.orEmpty(),
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            text = stringResource(R.string.routes_intro),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        state.activeProtocol?.let { protocol ->
            Text(
                text = stringResource(R.string.routes_protocol_hint, protocolLabel(protocol)),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (state.usableCredentials.isEmpty()) {
            WarningBanner(
                text = stringResource(R.string.routes_no_usable_keys),
                tone = BannerTone.Info,
                actionLabel = stringResource(R.string.keys_add),
                onAction = onAddKey,
            )
        }
        state.drafts.forEachIndexed { index, draft ->
            RouteCard(
                index = index,
                draft = draft,
                errors = state.errors[draft.id],
                state = state,
                viewModel = viewModel,
            )
        }
        if (state.canAddRoute) {
            SecondaryButton(
                text = stringResource(R.string.routes_add_alias),
                onClick = viewModel::addRoute,
                enabled = !state.saving,
            )
        }
        state.formError?.let { error ->
            Text(
                text = error.asString(),
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
        PrimaryButton(
            text = stringResource(R.string.action_save),
            onClick = viewModel::save,
            loading = state.saving,
            modifier = Modifier.fillMaxWidth(),
        )
        if (state.dirty && state.saved.isNotEmpty()) {
            TextButton(onClick = viewModel::reset, enabled = !state.saving) {
                Text(stringResource(R.string.routes_discard))
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun RouteCard(
    index: Int,
    draft: RouteDraft,
    errors: RouteErrors?,
    state: ModelRoutesUiState,
    viewModel: ModelRoutesViewModel,
) {
    val enabled = !state.saving
    val aliasName = draft.alias.ifBlank { stringResource(R.string.routes_alias_unnamed) }
    Surface(
        shape = ThinktinShapes.Card,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(ROUTE_CARD_TEST_TAG + index),
    ) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                val aliasLabel = stringResource(R.string.routes_field_alias)
                OutlinedTextField(
                    value = draft.alias,
                    onValueChange = { viewModel.onAliasChange(draft.id, it) },
                    label = { Text(aliasLabel) },
                    singleLine = true,
                    enabled = enabled,
                    isError = errors?.alias != null,
                    supportingText = {
                        Text(
                            errors?.alias?.asString() ?: stringResource(
                                if (draft.alias.trim() == KeyRules.MAIN_ALIAS) R.string.routes_alias_main_hint else R.string.routes_alias_hint,
                            ),
                        )
                    },
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next, autoCorrectEnabled = false),
                    modifier = Modifier
                        .weight(1f)
                        .semantics { contentDescription = aliasLabel },
                )
                IconButton(onClick = { viewModel.removeRoute(draft.id) }, enabled = enabled) {
                    Icon(Icons.Outlined.Delete, contentDescription = stringResource(R.string.routes_remove_alias, aliasName))
                }
            }
            KeySelector(
                label = stringResource(R.string.routes_field_key),
                selectedId = draft.credentialId,
                state = state,
                error = errors?.credential,
                warning = state.keyWarning(draft.credentialId),
                enabled = enabled,
                onSelect = { viewModel.onCredentialChange(draft.id, it) },
            )
            ModelField(
                label = stringResource(R.string.routes_field_model),
                value = draft.model,
                credentialId = draft.credentialId,
                state = state,
                error = errors?.model,
                enabled = enabled,
                onChange = { viewModel.onModelChange(draft.id, it) },
            )

            Text(
                text = stringResource(R.string.routes_fallbacks_title),
                style = MaterialTheme.typography.labelLarge,
                modifier = Modifier
                    .padding(top = 4.dp)
                    .semantics { heading() },
            )
            if (draft.fallbacks.isEmpty()) {
                Text(
                    text = stringResource(R.string.routes_fallbacks_empty),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            draft.fallbacks.forEachIndexed { i, fallback ->
                val position = i + 1
                val fallbackErrors = errors?.fallbacks?.get(i)
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = stringResource(R.string.routes_fallback_title, position),
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.weight(1f),
                        )
                        IconButton(onClick = { viewModel.moveFallback(draft.id, i, up = true) }, enabled = enabled && i > 0) {
                            Icon(Icons.Outlined.ArrowUpward, contentDescription = stringResource(R.string.routes_fallback_up, position))
                        }
                        IconButton(
                            onClick = { viewModel.moveFallback(draft.id, i, up = false) },
                            enabled = enabled && i < draft.fallbacks.lastIndex,
                        ) {
                            Icon(Icons.Outlined.ArrowDownward, contentDescription = stringResource(R.string.routes_fallback_down, position))
                        }
                        IconButton(onClick = { viewModel.removeFallback(draft.id, i) }, enabled = enabled) {
                            Icon(Icons.Outlined.Close, contentDescription = stringResource(R.string.routes_fallback_remove, position))
                        }
                    }
                    KeySelector(
                        label = stringResource(R.string.routes_field_fallback_key, position),
                        selectedId = fallback.credentialId,
                        state = state,
                        error = fallbackErrors?.first,
                        warning = state.keyWarning(fallback.credentialId),
                        enabled = enabled,
                        onSelect = { viewModel.onFallbackCredentialChange(draft.id, i, it) },
                    )
                    ModelField(
                        label = stringResource(R.string.routes_field_fallback_model, position),
                        value = fallback.model,
                        credentialId = fallback.credentialId,
                        state = state,
                        error = fallbackErrors?.second,
                        enabled = enabled,
                        onChange = { viewModel.onFallbackModelChange(draft.id, i, it) },
                    )
                }
            }
            if (draft.fallbacks.size < KeyRules.MAX_FALLBACKS) {
                TextButton(onClick = { viewModel.addFallback(draft.id) }, enabled = enabled) {
                    Text(stringResource(R.string.routes_add_fallback, aliasName))
                }
            }
        }
    }
}

/**
 * 选 key：按钮显示当前选的（“工作 key（Anthropic · …a1b2）”），点开列出能用的 key；当前选的不能用了（停用、协议不对、删了）
 * 也照样显示，错误在下面；实例原来就用着的停用 key 不算错，下面是 [warning]。
 */
@Composable
private fun KeySelector(
    label: String,
    selectedId: String?,
    state: ModelRoutesUiState,
    error: UiText?,
    warning: UiText?,
    enabled: Boolean,
    onSelect: (String) -> Unit,
) {
    var open by rememberSaveable { mutableStateOf(false) }
    val selected = state.credentials.firstOrNull { it.id == selectedId }
    val text = when {
        selected != null -> credentialOption(selected, state.vendors)
        selectedId != null -> stringResource(R.string.routes_key_deleted)
        else -> stringResource(R.string.routes_choose_key)
    }
    val description = stringResource(R.string.routes_key_selector_a11y, label, text)
    Column {
        Text(text = label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Box {
            SecondaryButton(
                text = text,
                onClick = { open = true },
                enabled = enabled,
                trailingIcon = Icons.Outlined.ArrowDropDown,
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { contentDescription = description },
            )
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                state.usableCredentials.forEach { credential ->
                    DropdownMenuItem(
                        text = { Text(credentialOption(credential, state.vendors)) },
                        onClick = {
                            open = false
                            onSelect(credential.id)
                        },
                    )
                }
                if (state.usableCredentials.isEmpty()) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.routes_no_usable_keys)) },
                        onClick = { open = false },
                        enabled = false,
                    )
                }
            }
        }
        if (error != null) {
            Text(
                text = error.asString(),
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
        } else if (warning != null) {
            Text(
                text = warning.asString(),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

/** 上游模型：手填，下面是这把 key 的厂商推荐的模型（点一下填进去）。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ModelField(
    label: String,
    value: String,
    credentialId: String?,
    state: ModelRoutesUiState,
    error: UiText?,
    enabled: Boolean,
    onChange: (String) -> Unit,
) {
    val suggestions = suggestedModels(credentialId, state.credentials, state.vendors)
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = true,
        enabled = enabled,
        isError = error != null,
        supportingText = { Text(error?.asString() ?: stringResource(R.string.routes_model_hint)) },
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next, autoCorrectEnabled = false),
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = label },
    )
    if (suggestions.isNotEmpty()) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            suggestions.forEach { model ->
                val description = stringResource(R.string.routes_use_model, model)
                SuggestionChip(
                    onClick = { onChange(model) },
                    label = { Text(model) },
                    enabled = enabled,
                    modifier = Modifier.semantics { contentDescription = description },
                )
            }
        }
    }
}

private fun suggestedModels(credentialId: String?, credentials: List<Credential>, vendors: Map<String, VendorInfo>): List<String> {
    val vendor = credentials.firstOrNull { it.id == credentialId }?.vendor ?: return emptyList()
    return vendors[vendor]?.models.orEmpty()
}
