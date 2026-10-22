package cn.thinktin.design.component

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import cn.thinktin.design.theme.ThinktinShapes
import cn.thinktin.design.theme.ThinktinSpacing
import cn.thinktin.design.theme.ThinktinTheme

/**
 * 消息。用户消息右对齐、surfaceVariant 气泡（右下角 4dp）；agent 文本左对齐、不带气泡（第 4.3 节）。
 */
@Composable
fun MessageBubble(text: String, fromUser: Boolean, modifier: Modifier = Modifier) {
    if (fromUser) {
        Box(modifier = modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            Surface(
                modifier = Modifier.widthIn(max = 320.dp),
                shape = ThinktinShapes.UserBubble,
                color = MaterialTheme.colorScheme.surfaceVariant,
            ) {
                Text(
                    text = text,
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                )
            }
        }
    } else {
        Text(
            text = text,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onBackground,
            modifier = modifier.fillMaxWidth(),
        )
    }
}

/** 分组标题（“最近运行”），右侧可带一个文字按钮。 */
@Composable
fun SectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: () -> Unit = {},
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .weight(1f)
                .semantics { heading() },
        )
        if (actionLabel != null) {
            TextButton(onClick = onAction) { Text(actionLabel) }
        }
    }
}

/** 空状态：衬线大字 + 说明 + 可选主按钮。 */
@Composable
fun EmptyState(
    title: String,
    modifier: Modifier = Modifier,
    message: String? = null,
    actionLabel: String? = null,
    onAction: () -> Unit = {},
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(ThinktinSpacing.Page),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Paragraph),
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.headlineMedium,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        if (message != null) {
            Text(
                text = message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
        if (actionLabel != null) {
            Spacer(Modifier.height(4.dp))
            PrimaryButton(text = actionLabel, onClick = onAction)
        }
    }
}

/** 横幅的语气。 */
enum class BannerTone {
    Info,
    Warning,
    Error,
}

/** 横幅：等待审批 / 等待 key / 离线等（第 4.3、7 节）。 */
@Composable
fun WarningBanner(
    text: String,
    modifier: Modifier = Modifier,
    tone: BannerTone = BannerTone.Warning,
    actionLabel: String? = null,
    onAction: () -> Unit = {},
) {
    val color = when (tone) {
        BannerTone.Info -> MaterialTheme.colorScheme.secondary
        BannerTone.Warning -> ThinktinTheme.extendedColors.warning
        BannerTone.Error -> MaterialTheme.colorScheme.error
    }
    val icon = when (tone) {
        BannerTone.Info -> Icons.Outlined.Info
        BannerTone.Warning -> Icons.Outlined.WarningAmber
        BannerTone.Error -> Icons.Outlined.ErrorOutline
    }
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = ThinktinShapes.Card,
        color = color.copy(alpha = 0.12f),
        contentColor = MaterialTheme.colorScheme.onSurface,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(20.dp))
            Text(text = text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
            if (actionLabel != null) {
                TextButton(onClick = onAction) { Text(actionLabel) }
            }
        }
    }
}

@Preview(showBackground = true)
@Composable
internal fun MessageBubblePreview() {
    ThinktinTheme {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(ThinktinSpacing.Message)) {
            MessageBubble(text = "把 README 翻译成英文", fromUser = true)
            MessageBubble(text = "好的，我先读一下 README，然后逐段翻译，代码块保持原样。", fromUser = false)
        }
    }
}

@Preview(showBackground = true)
@Composable
internal fun SectionHeaderPreview() {
    ThinktinTheme { SectionHeader(title = "最近运行", actionLabel = "全部") }
}

@Preview(showBackground = true)
@Composable
internal fun EmptyStatePreview() {
    ThinktinTheme {
        EmptyState(title = "还没有 agent", message = "从目录里领养一个，开始干活。", actionLabel = "领养一个 agent")
    }
}

@Preview(showBackground = true)
@Composable
internal fun WarningBannerPreview() {
    ThinktinTheme {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            WarningBanner(text = "等待你批准：删除 build/ 下的旧文件", actionLabel = "去处理")
            WarningBanner(text = "离线，显示的是缓存内容", tone = BannerTone.Info)
            WarningBanner(text = "运行失败：上游超时", tone = BannerTone.Error)
        }
    }
}
