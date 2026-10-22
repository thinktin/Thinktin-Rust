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

/**
 * 状态点的语义色调。:design 不认识服务端的状态（那在 :data），由 :app 把 InstanceState / RunState 映射成色调。
 */
enum class StatusTone {
    /** 运行中、在线：成功绿。 */
    Online,

    /** 正在干活（运行中的运行）：主色闪烁。 */
    Working,

    /** 创建中、排队、启动中：灰色闪烁。 */
    Starting,

    /** 已暂停、已取消：灰色。 */
    Idle,

    /** 已归档：灰色空心。 */
    Archived,

    /** 等待用户处理（审批、电脑、key）或重试等待：警告色。 */
    Attention,

    /** 等待子任务：信息色（secondary）。 */
    Waiting,

    /** 成功：绿。 */
    Success,

    /** 失败：错误色。 */
    Failure,

    /** 未知取值：淡灰空心。 */
    Unknown,
}

/** 按色调画状态点（第 8.1 节的配色）。 */
@Composable
fun StatusDot(tone: StatusTone, modifier: Modifier = Modifier, contentDescription: String? = null) {
    val colors = MaterialTheme.colorScheme
    val extended = ThinktinTheme.extendedColors
    val gray = colors.onSurfaceVariant
    val (color, style) = when (tone) {
        StatusTone.Online -> extended.success to DotStyle.Filled
        StatusTone.Working -> colors.primary to DotStyle.Pulsing
        StatusTone.Starting -> gray to DotStyle.Pulsing
        StatusTone.Idle -> gray to DotStyle.Filled
        StatusTone.Archived -> gray to DotStyle.Hollow
        StatusTone.Attention -> extended.warning to DotStyle.Filled
        StatusTone.Waiting -> colors.secondary to DotStyle.Filled
        StatusTone.Success -> extended.success to DotStyle.Filled
        StatusTone.Failure -> colors.error to DotStyle.Filled
        StatusTone.Unknown -> gray.copy(alpha = 0.5f) to DotStyle.Hollow
    }
    StatusDot(color, modifier, style, contentDescription)
}

@Preview(showBackground = true)
@Composable
internal fun StatusDotPreview() {
    ThinktinTheme {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StatusTone.entries.forEach { StatusDot(it) }
        }
    }
}
