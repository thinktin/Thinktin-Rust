package cn.thinktin.design.component

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import cn.thinktin.design.R
import cn.thinktin.design.theme.ThinktinShapes
import cn.thinktin.design.theme.ThinktinTheme

/**
 * 底部胶囊输入框（第 4.3 节）：左“+”（附件），中间多行文本，右侧发送（主色圆钮）；
 * [running] 时右侧变成停止按钮。
 */
@Composable
fun Composer(
    value: String,
    onValueChange: (String) -> Unit,
    onSend: () -> Unit,
    modifier: Modifier = Modifier,
    running: Boolean = false,
    onStop: () -> Unit = {},
    onAttach: (() -> Unit)? = null,
    enabled: Boolean = true,
    placeholder: String = stringResource(R.string.design_composer_placeholder),
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = ThinktinShapes.Composer,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 6.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            if (onAttach != null) {
                IconButton(onClick = onAttach, enabled = enabled) {
                    Icon(Icons.Outlined.Add, contentDescription = stringResource(R.string.design_attach))
                }
            }
            val textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface)
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                enabled = enabled,
                textStyle = textStyle,
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                maxLines = 6,
                // 读屏：输入框自己带名字（占位文字），不是一个无名编辑框加一段单独的文字。
                modifier = Modifier
                    .weight(1f)
                    .semantics { contentDescription = placeholder },
                decorationBox = { innerTextField ->
                    Box(
                        modifier = Modifier
                            .heightIn(min = 48.dp)
                            .padding(horizontal = 8.dp, vertical = 12.dp),
                        contentAlignment = Alignment.CenterStart,
                    ) {
                        if (value.isEmpty()) {
                            Text(
                                text = placeholder,
                                style = textStyle,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.clearAndSetSemantics {},
                            )
                        }
                        innerTextField()
                    }
                },
            )
            if (running) {
                FilledIconButton(
                    onClick = onStop,
                    colors = IconButtonDefaults.filledIconButtonColors(
                        containerColor = MaterialTheme.colorScheme.onSurface,
                        contentColor = MaterialTheme.colorScheme.surface,
                    ),
                ) {
                    Icon(Icons.Outlined.Stop, contentDescription = stringResource(R.string.design_stop), Modifier.size(20.dp))
                }
            } else {
                FilledIconButton(
                    onClick = onSend,
                    enabled = enabled && value.isNotBlank(),
                    colors = IconButtonDefaults.filledIconButtonColors(
                        containerColor = MaterialTheme.colorScheme.primary,
                        contentColor = MaterialTheme.colorScheme.onPrimary,
                    ),
                ) {
                    Icon(Icons.Outlined.ArrowUpward, contentDescription = stringResource(R.string.design_send))
                }
            }
        }
    }
}

@Preview(showBackground = true)
@Composable
internal fun ComposerPreview() {
    ThinktinTheme {
        Composer(value = "", onValueChange = {}, onSend = {}, onAttach = {}, modifier = Modifier.padding(16.dp))
    }
}

@Preview(showBackground = true)
@Composable
internal fun ComposerRunningPreview() {
    ThinktinTheme {
        Composer(
            value = "再加一个边界情况",
            onValueChange = {},
            onSend = {},
            running = true,
            onAttach = {},
            modifier = Modifier.padding(16.dp),
        )
    }
}
