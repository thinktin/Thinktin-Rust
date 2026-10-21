package cn.thinktin.design.component

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import cn.thinktin.data.model.InstanceState
import cn.thinktin.data.model.RunState
import cn.thinktin.design.theme.ThinktinTheme

/** 状态点的样子。 */
enum class DotStyle {
    Filled,

    /** 空心（已归档）。 */
    Hollow,

    /** 闪烁（创建中、运行中）。 */
    Pulsing,
}

/** 基础状态点。[contentDescription] 给读屏用（状态文字），为 null 时只是装饰。 */
@Composable
fun StatusDot(
    color: Color,
    modifier: Modifier = Modifier,
    style: DotStyle = DotStyle.Filled,
    contentDescription: String? = null,
    size: Dp = 10.dp,
) {
    val semantics = if (contentDescription != null) {
        Modifier.semantics { this.contentDescription = contentDescription }
    } else {
        Modifier
    }
    val alpha = if (style == DotStyle.Pulsing) {
        val transition = rememberInfiniteTransition(label = "status-dot")
        val value by transition.animateFloat(
            initialValue = 1f,
            targetValue = 0.35f,
            animationSpec = infiniteRepeatable(tween(durationMillis = 900), RepeatMode.Reverse),
            label = "status-dot-alpha",
        )
        value
    } else {
        1f
    }
    val shape = Modifier
        .size(size)
        .alpha(alpha)
    Box(
        modifier = modifier
            .then(semantics)
            .then(
                if (style == DotStyle.Hollow) {
                    shape.border(1.5.dp, color, CircleShape)
                } else {
                    shape.background(color, CircleShape)
                },
            ),
    )
}

/** 实例状态点（第 8.1 节）：创建中灰闪、运行中绿、已暂停灰、已归档空心、已删除不显示。 */
@Composable
fun StatusDot(state: InstanceState, modifier: Modifier = Modifier, contentDescription: String? = null) {
    val gray = MaterialTheme.colorScheme.onSurfaceVariant
    when (state) {
        InstanceState.Provisioning -> StatusDot(gray, modifier, DotStyle.Pulsing, contentDescription)
        InstanceState.Running -> StatusDot(ThinktinTheme.extendedColors.success, modifier, contentDescription = contentDescription)
        InstanceState.Paused -> StatusDot(gray, modifier, contentDescription = contentDescription)
        InstanceState.Archived -> StatusDot(gray, modifier, DotStyle.Hollow, contentDescription)
        InstanceState.Deleted -> Unit
        InstanceState.Unknown -> StatusDot(gray.copy(alpha = 0.5f), modifier, DotStyle.Hollow, contentDescription)
    }
}

/** 运行状态点：运行中主色闪烁、等待用户处理警告色、成功绿、失败红、其余灰。 */
@Composable
fun StatusDot(state: RunState, modifier: Modifier = Modifier, contentDescription: String? = null) {
    val colors = MaterialTheme.colorScheme
    val extended = ThinktinTheme.extendedColors
    val (color, style) = when (state) {
        RunState.Queued, RunState.Starting -> colors.onSurfaceVariant to DotStyle.Pulsing
        RunState.Running -> colors.primary to DotStyle.Pulsing
        RunState.WaitingApproval, RunState.WaitingDevice, RunState.WaitingQuota, RunState.Backoff ->
            extended.warning to DotStyle.Filled
        RunState.WaitingChildren -> colors.secondary to DotStyle.Filled
        RunState.Succeeded -> extended.success to DotStyle.Filled
        RunState.Failed -> colors.error to DotStyle.Filled
        RunState.Cancelled -> colors.onSurfaceVariant to DotStyle.Filled
        RunState.Unknown -> colors.onSurfaceVariant to DotStyle.Hollow
    }
    StatusDot(color, modifier, style, contentDescription)
}

@Preview(showBackground = true)
@Composable
internal fun StatusDotPreview() {
    ThinktinTheme {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            InstanceState.entries.forEach { StatusDot(it) }
            RunState.entries.forEach { StatusDot(it) }
        }
    }
}
