package cn.thinktin.design.component

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import org.commonmark.ext.gfm.strikethrough.Strikethrough
import org.commonmark.ext.gfm.strikethrough.StrikethroughExtension
import org.commonmark.ext.gfm.tables.TableBlock
import org.commonmark.ext.gfm.tables.TableCell
import org.commonmark.ext.gfm.tables.TableHead
import org.commonmark.ext.gfm.tables.TableRow
import org.commonmark.ext.gfm.tables.TablesExtension
import org.commonmark.node.BlockQuote
import org.commonmark.node.BulletList
import org.commonmark.node.Code
import org.commonmark.node.Emphasis
import org.commonmark.node.FencedCodeBlock
import org.commonmark.node.HardLineBreak
import org.commonmark.node.Heading
import org.commonmark.node.HtmlBlock
import org.commonmark.node.HtmlInline
import org.commonmark.node.Image
import org.commonmark.node.IndentedCodeBlock
import org.commonmark.node.Link
import org.commonmark.node.ListItem
import org.commonmark.node.Node
import org.commonmark.node.OrderedList
import org.commonmark.node.Paragraph
import org.commonmark.node.SoftLineBreak
import org.commonmark.node.StrongEmphasis
import org.commonmark.node.Text
import org.commonmark.node.ThematicBreak
import org.commonmark.parser.Parser

/*
 * Markdown（agent 的回复，第 4.3 节）：commonmark（BSD-2-Clause）解析成下面这几种块，再由 [MarkdownText] 用 Compose 画，
 * 不用 WebView。支持标题、段落（粗体、斜体、删除线、行内代码、链接）、列表（可嵌套）、代码块、引用、分割线、表格
 * （简化：等宽列）。HTML 原样当文字显示，图片显示成链接。
 */

/** 解析出的块。 */
@Immutable
sealed interface MdBlock {
    data class Heading(val level: Int, val text: AnnotatedString) : MdBlock
    data class Paragraph(val text: AnnotatedString) : MdBlock
    data class CodeBlock(val code: String, val language: String?) : MdBlock

    /** [items] 每项是一组块（列表项里可以有段落、子列表、代码块）。 */
    data class ListBlock(val ordered: Boolean, val start: Int, val items: List<List<MdBlock>>) : MdBlock
    data class Quote(val blocks: List<MdBlock>) : MdBlock
    data object Rule : MdBlock
    data class Table(val header: List<AnnotatedString>, val rows: List<List<AnnotatedString>>) : MdBlock
}

/** 行内样式要用的颜色（由主题给）。 */
@Immutable
data class MarkdownColors(val link: Color, val codeBackground: Color)

object MarkdownParser {
    private val parser: Parser = Parser.builder()
        .extensions(listOf(TablesExtension.create(), StrikethroughExtension.create()))
        .build()

    /** 只把这些协议的链接做成可点的（其余的当普通文字，避免 intent:、javascript: 之类）。 */
    private val SAFE_SCHEMES = listOf("https://", "http://", "mailto:")

    fun parse(markdown: String, colors: MarkdownColors): List<MdBlock> {
        val document = try {
            parser.parse(markdown)
        } catch (_: RuntimeException) {
            // 解析器不该失败；万一失败就当纯文本，不崩。
            return listOf(MdBlock.Paragraph(AnnotatedString(markdown)))
        }
        return blocks(document, colors)
    }

    private fun children(node: Node): List<Node> {
        val out = mutableListOf<Node>()
        var child = node.firstChild
        while (child != null) {
            out += child
            child = child.next
        }
        return out
    }

    private fun blocks(parent: Node, colors: MarkdownColors): List<MdBlock> = children(parent).mapNotNull { node ->
        when (node) {
            is Heading -> MdBlock.Heading(node.level.coerceIn(1, 6), inlines(node, colors))
            is Paragraph -> MdBlock.Paragraph(inlines(node, colors))
            is FencedCodeBlock -> MdBlock.CodeBlock(
                node.literal.orEmpty().removeSuffix("\n"),
                node.info?.trim()?.substringBefore(' ')?.takeIf { it.isNotEmpty() },
            )
            is IndentedCodeBlock -> MdBlock.CodeBlock(node.literal.orEmpty().removeSuffix("\n"), null)
            is BulletList -> MdBlock.ListBlock(false, 1, children(node).map { blocks(it, colors) })
            is OrderedList -> MdBlock.ListBlock(true, node.markerStartNumber ?: 1, children(node).map { blocks(it, colors) })
            is ListItem -> MdBlock.Quote(blocks(node, colors))
            is BlockQuote -> MdBlock.Quote(blocks(node, colors))
            is ThematicBreak -> MdBlock.Rule
            is HtmlBlock -> MdBlock.Paragraph(AnnotatedString(node.literal.orEmpty().trimEnd()))
            is TableBlock -> table(node, colors)
            else -> {
                // 不认识的块（扩展）：取其中的文字。
                val text = inlines(node, colors)
                if (text.isEmpty()) null else MdBlock.Paragraph(text)
            }
        }
    }

    private fun table(node: TableBlock, colors: MarkdownColors): MdBlock.Table {
        var header = emptyList<AnnotatedString>()
        val rows = mutableListOf<List<AnnotatedString>>()
        for (section in children(node)) {
            for (row in children(section)) {
                if (row !is TableRow) continue
                val cells = children(row).filterIsInstance<TableCell>().map { inlines(it, colors) }
                if (section is TableHead) header = cells else rows += cells
            }
        }
        return MdBlock.Table(header, rows)
    }

    /** 行内节点 → 带样式的文字。 */
    fun inlines(node: Node, colors: MarkdownColors): AnnotatedString {
        val builder = AnnotatedString.Builder()
        appendInlines(builder, node, colors)
        return builder.toAnnotatedString()
    }

    private fun appendInlines(b: AnnotatedString.Builder, parent: Node, colors: MarkdownColors) {
        for (node in children(parent)) {
            when (node) {
                is Text -> b.append(node.literal.orEmpty())
                is SoftLineBreak -> b.append(' ')
                is HardLineBreak -> b.append('\n')
                is Code -> b.withStyle(
                    SpanStyle(fontFamily = FontFamily.Monospace, background = colors.codeBackground),
                ) { append(node.literal.orEmpty()) }
                is Emphasis -> b.withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { appendInlines(this, node, colors) }
                is StrongEmphasis -> b.withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { appendInlines(this, node, colors) }
                is Strikethrough -> b.withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) {
                    appendInlines(this, node, colors)
                }
                is Link -> link(b, node.destination.orEmpty(), colors) { appendInlines(this, node, colors) }
                is Image -> link(b, node.destination.orEmpty(), colors) {
                    val alt = inlines(node, colors)
                    append(if (alt.isEmpty()) node.destination.orEmpty() else alt)
                }
                is HtmlInline -> b.append(node.literal.orEmpty())
                else -> appendInlines(b, node, colors)
            }
        }
    }

    private fun link(
        b: AnnotatedString.Builder,
        url: String,
        colors: MarkdownColors,
        content: AnnotatedString.Builder.() -> Unit,
    ) {
        if (SAFE_SCHEMES.none { url.startsWith(it, ignoreCase = true) }) {
            b.content()
            return
        }
        val style = TextLinkStyles(SpanStyle(color = colors.link, textDecoration = TextDecoration.Underline))
        b.pushLink(LinkAnnotation.Url(url, style))
        b.content()
        b.pop()
    }

    /** 纯文字（读屏、复制整段时用）。 */
    fun plainText(blocks: List<MdBlock>): String = buildString {
        fun add(block: MdBlock, indent: String) {
            when (block) {
                is MdBlock.Heading -> appendLine(indent + block.text.text)
                is MdBlock.Paragraph -> appendLine(indent + block.text.text)
                is MdBlock.CodeBlock -> appendLine(block.code)
                is MdBlock.ListBlock -> block.items.forEachIndexed { i, item ->
                    val marker = if (block.ordered) "${block.start + i}. " else "• "
                    item.forEachIndexed { j, b -> add(b, if (j == 0) indent + marker else "$indent   ") }
                }
                is MdBlock.Quote -> block.blocks.forEach { add(it, indent) }
                MdBlock.Rule -> appendLine("—")
                is MdBlock.Table -> (listOf(block.header) + block.rows).forEach { row ->
                    appendLine(indent + row.joinToString(" | ") { it.text })
                }
            }
        }
        blocks.forEach { add(it, "") }
    }.trimEnd()
}
