package cn.thinktin.app.ui.keys

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.LocalThinktinService
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.asString
import cn.thinktin.app.ui.common.formatTokens
import cn.thinktin.app.ui.common.resolve
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.ThinktinTopBar
import cn.thinktin.design.component.TopBarIcons
import cn.thinktin.design.theme.ThinktinSpacing

/**
 * key 输入框：密码样式（可切换显示）、不自动更正、不进输入法词库；提示依次是错误、“粘贴时整理过”、“已粘贴”、[hint]。
 */
@Composable
fun ApiKeyField(
    input: KeyInput,
    onChange: (String) -> Unit,
    onToggleVisible: () -> Unit,
    enabled: Boolean,
    hint: String,
    modifier: Modifier = Modifier,
    imeAction: ImeAction = ImeAction.Next,
    onDone: () -> Unit = {},
) {
    val label = stringResource(R.string.key_field_key)
    OutlinedTextField(
        value = input.value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = true,
        enabled = enabled,
        isError = input.error != null,
        visualTransformation = if (input.visible) VisualTransformation.None else PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(
            keyboardType = KeyboardType.Password,
            capitalization = KeyboardCapitalization.None,
            autoCorrectEnabled = false,
            imeAction = imeAction,
        ),
        keyboardActions = KeyboardActions(onDone = { onDone() }),
        trailingIcon = {
            IconButton(onClick = onToggleVisible) {
                Icon(
                    if (input.visible) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                    contentDescription = stringResource(if (input.visible) R.string.key_hide else R.string.key_show),
                )
            }
        },
        supportingText = {
            val text = when {
                input.error != null -> input.error.asString()
                input.cleaned -> stringResource(R.string.key_pasted_cleaned)
                input.pasted -> stringResource(R.string.key_pasted)
                else -> hint
            }
            Text(text, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        },
        modifier = modifier
            .fillMaxWidth()
            .semantics { contentDescription = label },
    )
}

/** 编辑和换 key 两页共用的骨架：顶栏、加载中、加载失败、key 已被删除。 */
@Composable
private fun KeyFormScaffold(
    title: String,
    onBack: () -> Unit,
    snackbar: SnackbarHostState,
    loading: Boolean,
    loadError: UiText?,
    missing: Boolean,
    onRetry: () -> Unit,
    ready: Boolean,
    content: @Composable ColumnScope.() -> Unit,
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
                ready -> Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(ThinktinSpacing.Page),
                    verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
                    content = content,
                )
                missing -> EmptyState(
                    title = stringResource(R.string.key_missing),
                    actionLabel = stringResource(R.string.action_back),
                    onAction = onBack,
                    modifier = Modifier.align(Alignment.Center),
                )
                loading -> {
                    val label = stringResource(R.string.loading)
                    CircularProgressIndicator(
                        modifier = Modifier
                            .align(Alignment.Center)
                            .semantics { contentDescription = label },
                    )
                }
                else -> EmptyState(
                    title = stringResource(R.string.keys_load_failed),
                    message = loadError?.asString(),
                    actionLabel = stringResource(R.string.action_retry),
                    onAction = onRetry,
                    modifier = Modifier.align(Alignment.Center),
                )
            }
        }
    }
}

/** 编辑 key（路由 keys/{credentialId}/edit）：独立页面（有输入框，不用对话框）。 */
@Composable
fun KeyEditScreen(credentialId: String, onBack: () -> Unit, onSaved: () -> Unit, onReplaceSecret: () -> Unit) {
    val service = LocalThinktinService.current
    val viewModel: KeyEditViewModel = viewModel(
        key = "key-edit-$credentialId",
        factory = viewModelFactory { initializer { KeyEditViewModel(service, credentialId) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is KeyFormEvent.Saved -> onSaved()
                is KeyFormEvent.Message -> snackbar.showSnackbar(event.text.resolve(context))
            }
        }
    }
    val credential = state.credential
    KeyFormScaffold(
        title = stringResource(R.string.keys_edit),
        onBack = onBack,
        snackbar = snackbar,
        loading = state.loading,
        loadError = state.loadError,
        missing = state.missing,
        onRetry = viewModel::load,
        ready = credential != null,
    ) {
        if (credential == null) return@KeyFormScaffold
        val vendor = vendorName(credential.vendor, state.vendors)
        Text(
            text = stringResource(R.string.keys_vendor_last4, vendor, credential.last4),
            style = MaterialTheme.typography.bodyLarge,
        )
        val label = stringResource(R.string.key_field_label)
        OutlinedTextField(
            value = state.label,
            onValueChange = viewModel::onLabelChange,
            label = { Text(label) },
            placeholder = { Text(vendor) },
            singleLine = true,
            enabled = state.editable,
            isError = state.labelError != null,
            supportingText = {
                Text(state.labelError?.asString() ?: stringResource(R.string.key_label_hint, KeyRules.MAX_LABEL_LENGTH))
            },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = label },
        )
        ListItem(
            headlineContent = { Text(stringResource(R.string.key_field_enabled)) },
            supportingContent = { Text(stringResource(R.string.key_enabled_hint)) },
            trailingContent = { Switch(checked = !state.disabled, onCheckedChange = null) },
            colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
            modifier = Modifier.toggleable(
                value = !state.disabled,
                enabled = state.editable,
                role = Role.Switch,
                onValueChange = { enabled -> viewModel.onDisabledChange(!enabled) },
            ),
        )
        // 每日上限（11.9 起能改）：清空就是不限；下面一行是现在生效的值。
        FormField(
            label = stringResource(R.string.key_field_daily_limit),
            value = state.dailyLimit,
            onValueChange = viewModel::onDailyLimitChange,
            error = state.dailyLimitError,
            hint = stringResource(R.string.key_limit_edit_hint),
            enabled = state.editable,
            keyboardType = KeyboardType.Number,
            imeAction = ImeAction.Done,
        )
        Text(
            text = credential.dailyTokenLimit?.let { stringResource(R.string.keys_daily_limit, formatTokens(it)) }
                ?: stringResource(R.string.keys_no_limit),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        PrimaryButton(
            text = stringResource(R.string.action_save),
            onClick = viewModel::save,
            enabled = state.editable,
            loading = state.saving,
            modifier = Modifier.fillMaxWidth(),
        )
        TextButton(onClick = onReplaceSecret, enabled = !state.saving) {
            Text(stringResource(R.string.keys_replace))
        }
    }
}

/** 换 key（路由 keys/{credentialId}/secret）：密码输入，同一个厂商、同一条记录，模型别名不用改。 */
@Composable
fun KeySecretScreen(credentialId: String, onBack: () -> Unit, onSaved: () -> Unit) {
    val service = LocalThinktinService.current
    val viewModel: KeySecretViewModel = viewModel(
        key = "key-secret-$credentialId",
        factory = viewModelFactory { initializer { KeySecretViewModel(service, credentialId) } },
    )
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val context = LocalContext.current
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is KeyFormEvent.Saved -> onSaved()
                is KeyFormEvent.Message -> snackbar.showSnackbar(event.text.resolve(context))
            }
        }
    }
    val credential = state.credential
    KeyFormScaffold(
        title = stringResource(R.string.keys_replace),
        onBack = onBack,
        snackbar = snackbar,
        loading = state.loading,
        loadError = state.loadError,
        missing = state.missing,
        onRetry = viewModel::load,
        ready = credential != null,
    ) {
        if (credential == null) return@KeyFormScaffold
        Text(
            text = stringResource(
                R.string.key_replace_intro,
                credentialTitle(credential, state.vendors),
                vendorName(credential.vendor, state.vendors),
                credential.last4,
            ),
            style = MaterialTheme.typography.bodyLarge,
        )
        ApiKeyField(
            input = state.key,
            onChange = viewModel::onKeyChange,
            onToggleVisible = viewModel::toggleVisible,
            enabled = !state.saving && !state.finished,
            hint = stringResource(R.string.key_hint_payg),
            imeAction = ImeAction.Done,
            onDone = viewModel::save,
        )
        PrimaryButton(
            text = stringResource(R.string.keys_replace),
            onClick = viewModel::save,
            enabled = !state.saving && !state.finished,
            loading = state.saving,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 4.dp),
        )
    }
}
