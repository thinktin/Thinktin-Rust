package cn.thinktin.design.component

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import cn.thinktin.design.R
import cn.thinktin.design.theme.ThinktinShapes
import cn.thinktin.design.theme.ThinktinTextStyles
import cn.thinktin.design.theme.ThinktinTheme

/** 工具调用的状态（agent.tool_call / agent.tool_call_update 的 status）。 */
enum class ToolCallStatus(val wire: String) {
    Pending("pending"),
    InProgress("in_progress"),
    Completed("completed"),
    Failed("failed"),
    ;

    companion object {
        fun fromWire(value: String?): ToolCallStatus = entries.firstOrNull { it.wire == value } ?: Pending
    }
}

/** 按工具的 kind（read / edit / search / execute / fetch……）选图标。 */
fun toolCallIcon(kind: String?): ImageVector = when (kind) {
    "read" -> Icons.Outlined.Description
    "edit" -> Icons.Outlined.Edit
    "search" -> Icons.Outlined.Search
    "execute" -> Icons.Outlined.Terminal
    "fetch" -> Icons.Outlined.Public
    else -> Icons.Outlined.Build
}

/**
 * 工具调用卡片（占位版，13.5 再细化）：头部“图标 + 标题 + 状态”，点开显示参数与结果（等宽）。
 */
@Composable
fun ToolCallCard(
    title: String,
    modifier: Modifier = Modifier,
    kind: String? = null,
    status: ToolCallStatus = ToolCallStatus.Pending,
    details: String? = null,
    initiallyExpanded: Boolean = false,
) {
    var expanded by rememberSaveable { mutableStateOf(initiallyExpanded) }
    val canExpand = !details.isNullOrEmpty()
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = ThinktinShapes.Card,
        color = MaterialTheme.colorScheme.surfaceVariant,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
    ) {
        Column {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .then(
                        if (canExpand) {
                            Modifier.clickable(role = Role.Button) { expanded = !expanded }
                        } else {
                            Modifier
                        },
                    )
                    .padding(horizontal = 12.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(toolCallIcon(kind), contentDescription = null, modifier = Modifier.size(18.dp))
                Text(
                    text = title,
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                ToolCallStatusLabel(status)
                if (canExpand) {
                    Icon(
                        imageVector = if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                        contentDescription = stringResource(if (expanded) R.string.design_collapse else R.string.design_expand),
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
            AnimatedVisibility(visible = expanded && canExpand) {
                Text(
                    text = details.orEmpty(),
                    style = ThinktinTextStyles.Code,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 12.dp, end = 12.dp, bottom = 12.dp),
                )
            }
        }
    }
}

@Composable
private fun ToolCallStatusLabel(status: ToolCallStatus) {
    val colors = MaterialTheme.colorScheme
    val (color, label) = when (status) {
        ToolCallStatus.Pending -> colors.onSurfaceVariant to R.string.design_tool_pending
        ToolCallStatus.InProgress -> colors.primary to R.string.design_tool_in_progress
        ToolCallStatus.Completed -> ThinktinTheme.extendedColors.success to R.string.design_tool_completed
        ToolCallStatus.Failed -> colors.error to R.string.design_tool_failed
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        StatusDot(color, size = 8.dp, style = if (status == ToolCallStatus.InProgress) DotStyle.Pulsing else DotStyle.Filled)
        Text(stringResource(label), style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
    }
}

@Preview(showBackground = true)
@Composable
internal fun ToolCallCardPreview() {
    ThinktinTheme {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            ToolCallCard(title = "读取 README.md", kind = "read", status = ToolCallStatus.Completed)
            ToolCallCard(
                title = "删除 build/ 下 30 天前的文件",
                kind = "execute",
                status = ToolCallStatus.Pending,
                details = "{\"command\": \"find build -mtime +30 -delete\"}",
                initiallyExpanded = true,
            )
        }
    }
}
