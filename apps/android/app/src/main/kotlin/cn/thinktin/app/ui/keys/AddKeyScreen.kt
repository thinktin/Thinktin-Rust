package cn.thinktin.app.ui.keys

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.catalog.Tag
import cn.thinktin.app.ui.catalog.protocolLabel
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.resolve
import cn.thinktin.data.model.VendorInfo
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.SectionHeader
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing

/** 测试用：第一步厂商行的 testTag 前缀（后接厂商 id；自定义接口是 custom）。 */
const val VENDOR_ROW_TEST_TAG = "vendor-row-"

/** 测试用：第一步的厂商列表。 */
const val VENDOR_LIST_TEST_TAG = "vendor-list"

/** 添加 key（第 4.5 节，路由 keys/new）：两步，独立页面（有输入框，不用对话框）。成功后 [onAdded] 回列表。 */
@Composable
fun AddKeyScreen(onBack: () -> Unit, onAdded: () -> Unit) {
    val service = LocalThinktinService.current
    val viewModel: AddKeyViewModel = viewModel(factory = viewModelFactory { initializer { AddKeyViewModel(service) } })
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is AddKeyEvent.Added -> onAdded()
                is AddKeyEvent.Message -> snackbar.showSnackbar(event.text.resolve(context))
            }
        }
    }
    BackHandler(enabled = state.step == AddKeyStep.Details) { viewModel.backToVendors() }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            ThinktinTopBar(
                title = stringResource(
                    if (state.step == AddKeyStep.Vendor) R.string.add_key_step_vendor else R.string.add_key_step_details,
                ),
                navigationIcon = TopBarIcons.Back,
                navigationContentDescription = stringResource(R.string.action_back),
                onNavigationClick = { if (!viewModel.backToVendors()) onBack() },
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
                state.step == AddKeyStep.Details -> DetailsStep(state, viewModel)
                state.loading -> {
                    val label = stringResource(R.string.loading)
                    CircularProgressIndicator(
                        modifier = Modifier
                            .align(Alignment.Center)
                            .semantics { contentDescription = label },
                    )
                }
                state.loadError != null -> EmptyState(
                    title = stringResource(R.string.add_key_vendors_failed),
                    message = state.loadError!!.asString(),
                    actionLabel = stringResource(R.string.action_retry),
                    onAction = viewModel::load,
                    modifier = Modifier.align(Alignment.Center),
                )
                else -> VendorStep(state, viewModel)
            }
        }
    }
}

/** 第一步：按协议分组的预置厂商，最后是自定义接口。 */
@Composable
private fun VendorStep(state: AddKeyUiState, viewModel: AddKeyViewModel) {
    LazyColumn(modifier = Modifier.fillMaxSize().testTag(VENDOR_LIST_TEST_TAG)) {
        item {
            Text(
                text = stringResource(R.string.add_key_vendor_intro),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = ThinktinSpacing.Page, vertical = 8.dp),
            )
        }
        state.groups.forEach { group ->
            item(key = "group-" + group.protocols.joinToString(",")) {
                val names = group.protocols.map { protocolLabel(it) }
                SectionHeader(
                    title = stringResource(R.string.add_key_group, names.joinToString(stringResource(R.string.list_separator))),
                    modifier = Modifier.padding(start = ThinktinSpacing.Page, end = ThinktinSpacing.Page, top = 12.dp),
                )
            }
            items(group.vendors, key = { it.id }) { vendor ->
                VendorRow(vendor = vendor, onClick = { viewModel.selectVendor(vendor) })
            }
        }
        item(key = "custom") {
            SectionHeader(
                title = stringResource(R.string.add_key_group_custom),
                modifier = Modifier.padding(start = ThinktinSpacing.Page, end = ThinktinSpacing.Page, top = 12.dp),
            )
            VendorLine(
                testTag = VENDOR_ROW_TEST_TAG + KeyRules.CUSTOM_VENDOR,
                name = stringResource(R.string.key_vendor_custom),
                notes = stringResource(R.string.add_key_custom_summary),
                protocols = emptyList(),
                onClick = viewModel::selectCustom,
            )
        }
    }
}

@Composable
private fun VendorRow(vendor: VendorInfo, onClick: () -> Unit) {
    // 厂商说明是平台写的（厂商适配表），不是 agent 写的，不标 AI 生成。
    VendorLine(
        testTag = VENDOR_ROW_TEST_TAG + vendor.id,
        name = vendor.name,
        notes = vendor.notes,
        protocols = vendor.protocols,
        onClick = onClick,
    )
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun VendorLine(testTag: String, name: String, notes: String, protocols: List<String>, onClick: () -> Unit) {
    Column(modifier = Modifier.testTag(testTag)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = ThinktinSpacing.ListItemMinHeight)
                .clickable(role = Role.Button, onClickLabel = stringResource(R.string.add_key_choose_vendor), onClick = onClick)
                .padding(horizontal = ThinktinSpacing.Page, vertical = 10.dp),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            VendorBadge(name)
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(text = name, style = MaterialTheme.typography.titleMedium)
                if (notes.isNotBlank()) {
                    Text(
                        text = notes,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (protocols.isNotEmpty()) {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        protocols.forEach { protocol ->
                            val label = protocolLabel(protocol)
                            Tag(label, accessibleLabel = stringResource(R.string.agent_protocol_a11y, label))
                        }
                    }
                }
            }
        }
        HorizontalDivider(
            modifier = Modifier.padding(horizontal = ThinktinSpacing.Page),
            color = MaterialTheme.colorScheme.outline,
        )
    }
}

/** 第二步：key、标签、（自定义接口的）地址、每日限额。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DetailsStep(state: AddKeyUiState, viewModel: AddKeyViewModel) {
    val vendorLabel = if (state.custom) stringResource(R.string.key_vendor_custom) else state.vendor?.name.orEmpty()
    val enabled = state.editable
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(ThinktinSpacing.Page),
        verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            VendorBadge(vendorLabel)
            Text(
                text = vendorLabel,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() },
            )
            TextButton(onClick = { viewModel.backToVendors() }, enabled = enabled) {
                Text(stringResource(R.string.add_key_change_vendor))
            }
        }
        ApiKeyField(
            input = state.key,
            onChange = viewModel::onKeyChange,
            onToggleVisible = viewModel::toggleKeyVisible,
            enabled = enabled,
            hint = stringResource(if (state.refusesSubscriptionKeys) R.string.key_hint_no_subscription else R.string.key_hint_payg),
        )
        val labelText = stringResource(R.string.key_field_label)
        FormField(
            label = labelText,
            value = state.label,
            onValueChange = viewModel::onLabelChange,
            error = state.errors[AddKeyField.Label],
            hint = stringResource(R.string.key_label_hint, KeyRules.MAX_LABEL_LENGTH),
            enabled = enabled,
            placeholder = if (state.custom) stringResource(R.string.add_key_custom_label_placeholder) else vendorLabel,
        )
        if (state.custom) {
            Text(
                text = stringResource(R.string.add_key_custom_protocols),
                style = MaterialTheme.typography.labelLarge,
                modifier = Modifier.semantics { heading() },
            )
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                KeyRules.PROTOCOLS.forEach { protocol ->
                    FilterChip(
                        selected = protocol in state.customProtocols,
                        onClick = { viewModel.toggleProtocol(protocol) },
                        label = { Text(protocolLabel(protocol)) },
                        enabled = enabled,
                    )
                }
            }
            state.errors[AddKeyField.Protocols]?.let { ErrorLine(it) }
            KeyRules.PROTOCOLS.filter { it in state.customProtocols }.forEach { protocol ->
                val field = AddKeyViewModel.fieldOf(protocol)
                FormField(
                    label = stringResource(R.string.add_key_base_label, protocolLabel(protocol)),
                    value = AddKeyViewModel.baseOf(state, protocol),
                    onValueChange = { viewModel.onBaseChange(protocol, it) },
                    error = state.errors[field],
                    hint = stringResource(
                        when (protocol) {
                            "anthropic" -> R.string.add_key_base_hint_anthropic
                            "responses" -> R.string.add_key_base_hint_responses
                            else -> R.string.add_key_base_hint_chat
                        },
                    ),
                    enabled = enabled,
                    keyboardType = KeyboardType.Uri,
                    placeholder = "https://",
                )
            }
        }
        FormField(
            label = stringResource(R.string.key_field_daily_limit),
            value = state.dailyLimit,
            onValueChange = viewModel::onDailyLimitChange,
            error = state.errors[AddKeyField.DailyLimit],
            hint = stringResource(R.string.key_daily_limit_hint),
            enabled = enabled,
            keyboardType = KeyboardType.Number,
            imeAction = ImeAction.Done,
        )
        state.formError?.let { ErrorLine(it) }
        PrimaryButton(
            text = stringResource(R.string.add_key_submit),
            onClick = viewModel::submit,
            enabled = enabled,
            loading = state.submitting,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun ErrorLine(text: UiText) {
    Text(
        text = text.asString(),
        color = MaterialTheme.colorScheme.error,
        style = MaterialTheme.typography.bodyMedium,
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
    )
}

@Composable
internal fun FormField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    error: UiText?,
    hint: String,
    enabled: Boolean,
    placeholder: String? = null,
    keyboardType: KeyboardType = KeyboardType.Text,
    imeAction: ImeAction = ImeAction.Next,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        placeholder = placeholder?.let { { Text(it) } },
        singleLine = true,
        enabled = enabled,
        isError = error != null,
        supportingText = { Text(error?.asString() ?: hint) },
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = imeAction, autoCorrectEnabled = false),
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = label },
    )
}
