package cn.thinktin.design.component

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import cn.thinktin.design.R
import cn.thinktin.design.theme.ThinktinTheme

/**
 * AI 生成标识（第 8.4 节，16.3）：agent 写的文字前面标上“【AI 生成】”/“[AI-generated]”
 * （和服务端 proto::labels 的文案一致）。哪些字段要标见规范的表；复制、分享时用 [aiGeneratedLabel] 追加文字。
 */
@Composable
fun AiGeneratedLabel(modifier: Modifier = Modifier) {
    Text(
        text = aiGeneratedLabel(),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.secondary,
        maxLines = 1,
        modifier = modifier,
    )
}

/** 标识文字本身（给复制、分享、读屏拼接用）。 */
@Composable
fun aiGeneratedLabel(): String = stringResource(R.string.design_ai_generated)

@Preview(showBackground = true)
@Composable
internal fun AiGeneratedLabelPreview() {
    ThinktinTheme { AiGeneratedLabel() }
}
