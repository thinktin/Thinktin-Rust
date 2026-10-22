package cn.thinktin.app.ui.chat

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import cn.thinktin.app.R
import cn.thinktin.app.ui.common.UiText
import cn.thinktin.app.ui.common.asString
import cn.thinktin.design.component.AiGeneratedLabel
import cn.thinktin.design.component.PrimaryButton
import cn.thinktin.design.component.SecondaryButton
import cn.thinktin.design.theme.ThinktinShapes
import cn.thinktin.design.theme.ThinktinSpacing

const val SECRET_SHEET_TEST_TAG = "chat-secret-sheet"
const val VAULT_SHEET_TEST_TAG = "chat-vault-sheet"

/** 遮罩透明度（同 Material 底部面板）。 */
private const val SCRIM_ALPHA = 0.32f

/**
 * 盖在页面上的底部面板（不是 ModalBottomSheet / 对话框：弹出窗口里的输入框在 Robolectric 下一直不空闲，见 README）。
 * 点遮罩收起。
 */
@Composable
fun BottomPanel(
    title: String,
    onDismiss: () -> Unit,
    testTag: String,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Box(modifier.fillMaxSize()) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.scrim.copy(alpha = SCRIM_ALPHA))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onDismiss,
                )
                .clearAndSetSemantics {},
        )
        Surface(
            shape = ThinktinShapes.Sheet,
            color = MaterialTheme.colorScheme.surface,
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
            modifier = Modifier
                .align(androidx.compose.ui.Alignment.BottomCenter)
                .fillMaxWidth()
                .testTag(testTag)
                .semantics { paneTitle = title },
        ) {
            Column(
                modifier = Modifier
                    .navigationBarsPadding()
                    .imePadding()
                    .verticalScroll(rememberScrollState())
                    .padding(ThinktinSpacing.Page),
                verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
            ) {
                Text(title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
                content()
            }
        }
    }
}

/** 拦下密码后的保险箱表单：名字、用途、账号、密码（预填命中的值）。 */
@Composable
fun SecretSheet(
    form: SecretForm,
    onChange: ((SecretForm) -> SecretForm) -> Unit,
    onSave: () -> Unit,
    onSendAnyway: () -> Unit,
    onDismiss: () -> Unit,
) {
    BottomPanel(title = stringResource(R.string.chat_secret_title), onDismiss = onDismiss, testTag = SECRET_SHEET_TEST_TAG) {
        Text(
            stringResource(R.string.chat_secret_message),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            stringResource(R.string.chat_secret_found, mask(form.secret.value)),
            style = MaterialTheme.typography.bodySmall,
        )
        if (form.remaining > 0) {
            Text(
                stringResource(R.string.chat_secret_remaining, form.remaining),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Field(
            label = stringResource(R.string.chat_secret_name),
            value = form.name,
            onValueChange = { v -> onChange { it.copy(name = v) } },
            enabled = !form.saving,
            error = form.nameError,
            supporting = stringResource(R.string.chat_secret_name_hint, form.name.ifBlank { "…" }),
        )
        Field(
            label = stringResource(R.string.chat_secret_purpose),
            value = form.purpose,
            onValueChange = { v -> onChange { it.copy(purpose = v) } },
            enabled = !form.saving,
        )
        Field(
            label = stringResource(R.string.chat_secret_username),
            value = form.username,
            onValueChange = { v -> onChange { it.copy(username = v) } },
            enabled = !form.saving,
        )
        PasswordField(
            label = stringResource(R.string.chat_secret_password),
            value = form.password,
            onValueChange = { v -> onChange { it.copy(password = v) } },
            enabled = !form.saving,
        )
        FormError(form.error)
        Row(horizontalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph)) {
            SecondaryButton(
                text = stringResource(R.string.action_cancel),
                onClick = onDismiss,
                enabled = !form.saving,
                modifier = Modifier.weight(1f),
            )
            PrimaryButton(
                text = stringResource(R.string.chat_secret_save),
                onClick = onSave,
                loading = form.saving,
                modifier = Modifier.weight(1f),
            )
        }
        TextButton(onClick = onSendAnyway, enabled = !form.saving) {
            Text(stringResource(R.string.chat_secret_send_anyway), color = MaterialTheme.colorScheme.error)
        }
    }
}

/** agent 的填写请求：账号、密码（按 agent 要的字段）、用途（可选）。 */
@Composable
fun VaultFillSheet(
    form: VaultFillForm,
    onChange: ((VaultFillForm) -> VaultFillForm) -> Unit,
    onSubmit: () -> Unit,
    onDecline: () -> Unit,
    onDismiss: () -> Unit,
) {
    BottomPanel(
        title = stringResource(R.string.chat_vault_form_title, form.name),
        onDismiss = onDismiss,
        testTag = VAULT_SHEET_TEST_TAG,
    ) {
        form.agentPurpose?.let { purpose ->
            // agent 写的用途（第 8.4 节）。
            AiGeneratedLabel()
            Text(purpose, style = MaterialTheme.typography.bodyMedium)
        }
        if (form.wantsUsername) {
            Field(
                label = stringResource(R.string.chat_vault_field_username),
                value = form.username,
                onValueChange = { v -> onChange { it.copy(username = v) } },
                enabled = !form.submitting,
            )
        }
        if (form.wantsPassword) {
            PasswordField(
                label = stringResource(R.string.chat_secret_password),
                value = form.password,
                onValueChange = { v -> onChange { it.copy(password = v) } },
                enabled = !form.submitting,
            )
        }
        Field(
            label = stringResource(R.string.chat_vault_form_purpose),
            value = form.purpose,
            onValueChange = { v -> onChange { it.copy(purpose = v) } },
            enabled = !form.submitting,
        )
        FormError(form.error)
        Row(horizontalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph)) {
            SecondaryButton(
                text = stringResource(R.string.chat_vault_decline),
                onClick = onDecline,
                enabled = !form.submitting,
                modifier = Modifier.weight(1f),
            )
            PrimaryButton(
                text = stringResource(R.string.chat_vault_form_submit),
                onClick = onSubmit,
                loading = form.submitting,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

/** 只露出头尾，免得表单上方又把整段密码显示一遍。 */
fun mask(value: String): String = when {
    value.length <= 4 -> "•".repeat(value.length)
    value.length <= 10 -> value.take(2) + "•".repeat(value.length - 2)
    else -> value.take(4) + "•".repeat(minOf(8, value.length - 6)) + value.takeLast(2)
}

@Composable
private fun Field(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    enabled: Boolean,
    error: UiText? = null,
    supporting: String? = null,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        enabled = enabled,
        isError = error != null,
        supportingText = (error?.asString() ?: supporting)?.let { text -> { Text(text) } },
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = label },
    )
}

@Composable
private fun PasswordField(label: String, value: String, onValueChange: (String) -> Unit, enabled: Boolean) {
    var visible by rememberSaveable { mutableStateOf(false) }
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        enabled = enabled,
        visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
        trailingIcon = {
            IconButton(onClick = { visible = !visible }) {
                Icon(
                    if (visible) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                    contentDescription = stringResource(if (visible) R.string.chat_secret_hide else R.string.chat_secret_show),
                )
            }
        },
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = label },
    )
}

@Composable
private fun FormError(error: UiText?) {
    if (error == null) return
    Text(
        text = error.asString(),
        color = MaterialTheme.colorScheme.error,
        style = MaterialTheme.typography.bodyMedium,
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
    )
}
