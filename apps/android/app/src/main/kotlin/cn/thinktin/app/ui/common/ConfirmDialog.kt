package cn.thinktin.app.ui.common

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import cn.thinktin.app.R

/** 通用确认框：危险操作的确认按钮用错误色；[busy] 时转圈、不可关。 */
@Composable
fun ConfirmDialog(
    title: String,
    text: String,
    confirm: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    danger: Boolean = false,
    busy: Boolean = false,
    confirmEnabled: Boolean = true,
    dismiss: String? = null,
    onDismissButton: (() -> Unit)? = null,
    extra: (@Composable () -> Unit)? = null,
) {
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(text)
                extra?.invoke()
            }
        },
        confirmButton = {
            TextButton(onClick = onConfirm, enabled = !busy && confirmEnabled) {
                if (busy) {
                    val label = stringResource(R.string.loading)
                    CircularProgressIndicator(
                        strokeWidth = 2.dp,
                        modifier = Modifier
                            .size(18.dp)
                            .semantics { contentDescription = label },
                    )
                } else {
                    Text(confirm, color = if (danger) MaterialTheme.colorScheme.error else Color.Unspecified)
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismissButton ?: onDismiss, enabled = !busy) {
                Text(dismiss ?: stringResource(R.string.action_cancel))
            }
        },
    )
}
