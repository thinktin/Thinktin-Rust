package cn.thinktin.design.component

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import cn.thinktin.design.R
import cn.thinktin.design.theme.ThinktinTextStyles
import cn.thinktin.design.theme.ThinktinTheme

const val MARKDOWN_CODE_TEST_TAG = "markdown-code"

/**
 * 用 Compose 画 Markdown（[MarkdownParser]）。代码块右上角有“复制代码”：复制时在末尾加上 [copySuffix]
 * （agent 的输出要追加 AI 生成标识，第 8.4 节），复制完调 [onCopied]（页面显示“已复制”）。
 */
@Composable
fun MarkdownText(
    markdown: String,
    modifier: Modifier = Modifier,
    color: Color = MaterialTheme.colorScheme.onBackground,
    copySuffix: String = "",
    onCopied: () -> Unit = {},
) {
    val colors = MarkdownColors(
        link = MaterialTheme.colorScheme.secondary,
        codeBackground = MaterialTheme.colorScheme.surfaceVariant,
    )
    val blocks = remember(markdown, colors) { MarkdownParser.parse(markdown, colors) }
    MarkdownBlocks(blocks, modifier, color, copySuffix, onCopied)
}

@Composable
private fun MarkdownBlocks(
    blocks: List<MdBlock>,
    modifier: Modifier,
    color: Color,
    copySuffix: String,
    onCopied: () -> Unit,
) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        blocks.forEach { block -> MarkdownBlock(block, color, copySuffix, onCopied) }
    }
}

@Composable
private fun MarkdownBlock(block: MdBlock, color: Color, copySuffix: String, onCopied: () -> Unit) {
    val typography = MaterialTheme.typography
    when (block) {
        is MdBlock.Heading -> Text(
            text = block.text,
            style = when (block.level) {
                1 -> typography.headlineSmall
                2 -> typography.titleLarge
                3 -> typography.titleMedium
                else -> typography.titleSmall
            },
            color = color,
            modifier = Modifier.semantics { heading() },
        )
        is MdBlock.Paragraph -> Text(block.text, style = typography.bodyLarge, color = color)
        is MdBlock.CodeBlock -> CodeBlock(block, copySuffix, onCopied)
        is MdBlock.ListBlock -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            block.items.forEachIndexed { i, item ->
                Row {
                    Text(
                        text = if (block.ordered) "${block.start + i}." else "•",
                        style = typography.bodyLarge,
                        color = color,
                        modifier = Modifier.widthIn(min = 24.dp),
                    )
                    MarkdownBlocks(item, Modifier.weight(1f), color, copySuffix, onCopied)
                }
            }
        }
        is MdBlock.Quote -> Row(Modifier.height(IntrinsicSize.Min)) {
            Box(
                Modifier
                    .width(3.dp)
                    .fillMaxHeight()
                    .background(MaterialTheme.colorScheme.outline, RoundedCornerShape(2.dp)),
            )
            MarkdownBlocks(
                block.blocks,
                Modifier
                    .padding(start = 10.dp)
                    .weight(1f),
                MaterialTheme.colorScheme.onSurfaceVariant,
                copySuffix,
                onCopied,
            )
        }
        MdBlock.Rule -> HorizontalDivider(color = MaterialTheme.colorScheme.outline)
        is MdBlock.Table -> Table(block, color)
    }
}

@Composable
private fun CodeBlock(block: MdBlock.CodeBlock, copySuffix: String, onCopied: () -> Unit) {
    val clipboard = LocalClipboardManager.current
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceVariant,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(MARKDOWN_CODE_TEST_TAG),
    ) {
        Column {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(start = 12.dp),
            ) {
                Text(
                    text = block.language.orEmpty(),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = {
                    val text = if (copySuffix.isEmpty()) block.code else block.code + "\n" + copySuffix
                    clipboard.setText(AnnotatedString(text))
                    onCopied()
                }) {
                    Icon(
                        Icons.Outlined.ContentCopy,
                        contentDescription = stringResource(R.string.design_copy_code),
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
            Text(
                text = block.code,
                style = ThinktinTextStyles.Code,
                softWrap = false,
                modifier = Modifier
                    .horizontalScroll(rememberScrollState())
                    .padding(start = 12.dp, end = 12.dp, bottom = 12.dp),
            )
        }
    }
}

/** 表格（简化：等宽列，表头加粗；单元格里的文字会换行）。 */
@Composable
private fun Table(block: MdBlock.Table, color: Color) {
    val outline = MaterialTheme.colorScheme.outline
    Surface(
        shape = RoundedCornerShape(8.dp),
        border = BorderStroke(1.dp, outline),
        color = Color.Transparent,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column {
            val columns = maxOf(block.header.size, block.rows.maxOfOrNull { it.size } ?: 0)
            if (block.header.isNotEmpty()) {
                TableRow(block.header, columns, color, MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold))
            }
            block.rows.forEach { row ->
                HorizontalDivider(color = outline)
                TableRow(row, columns, color, MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

@Composable
private fun TableRow(cells: List<AnnotatedString>, columns: Int, color: Color, style: TextStyle) {
    Row(Modifier.fillMaxWidth()) {
        for (i in 0 until columns) {
            Text(
                text = cells.getOrNull(i) ?: AnnotatedString(""),
                style = style,
                color = color,
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 8.dp, vertical = 6.dp),
            )
        }
    }
}

@Preview(showBackground = true)
@Composable
internal fun MarkdownPreview() {
    ThinktinTheme {
        MarkdownText(
            markdown = """
                # 标题
                这是**粗体**、*斜体*、`代码` 和 [链接](https://example.com)。

                - 第一项
                - 第二项
                  1. 子项

                ```kotlin
                fun main() = println("hi")
                ```

                | 名字 | 价格 |
                |---|---|
                | A | 1 |
            """.trimIndent(),
            modifier = Modifier.padding(16.dp),
        )
    }
}
