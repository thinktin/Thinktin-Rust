package cn.thinktin.design

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.ClipboardManager
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.runtime.CompositionLocalProvider
import cn.thinktin.design.component.MARKDOWN_CODE_TEST_TAG
import cn.thinktin.design.component.MarkdownColors
import cn.thinktin.design.component.MarkdownParser
import cn.thinktin.design.component.MarkdownText
import cn.thinktin.design.component.MdBlock
import cn.thinktin.design.component.ToolCallCard
import cn.thinktin.design.component.ToolCallStatus
import cn.thinktin.design.theme.ThinktinTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Markdown（13.5）：commonmark 解析成块、行内样式、只放行安全链接；Compose 渲染与“复制代码”。 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-rCN")
class MarkdownTest {
    @get:Rule
    val compose = createComposeRule()

    private val colors = MarkdownColors(link = Color.Blue, codeBackground = Color.LightGray)

    @Test
    fun parsesBlocks() {
        val blocks = MarkdownParser.parse(
            """
            # 标题
            段落里有**粗体**、*斜体*、~~删除~~、`code` 和 [链接](https://example.com)。

            - 一
            - 二
              1. 子项

            > 引用

            ---

            ```kotlin
            val x = 1
            ```

            | 名字 | 价格 |
            |---|---|
            | A | 1 |
            """.trimIndent(),
            colors,
        )
        assertEquals(
            listOf(
                MdBlock.Heading::class, MdBlock.Paragraph::class, MdBlock.ListBlock::class, MdBlock.Quote::class,
                MdBlock.Rule::class, MdBlock.CodeBlock::class, MdBlock.Table::class,
            ),
            blocks.map { it::class },
        )
        assertEquals(1, (blocks[0] as MdBlock.Heading).level)
        val paragraph = (blocks[1] as MdBlock.Paragraph).text
        assertEquals("段落里有粗体、斜体、删除、code 和 链接。", paragraph.text)
        assertTrue(paragraph.spanStyles.any { it.item.fontWeight == FontWeight.Bold && paragraph.text.substring(it.start, it.end) == "粗体" })
        assertTrue(paragraph.spanStyles.any { it.item.fontFamily == FontFamily.Monospace })
        val link = paragraph.getLinkAnnotations(0, paragraph.length).single()
        assertEquals("https://example.com", (link.item as LinkAnnotation.Url).url)
        val list = blocks[2] as MdBlock.ListBlock
        assertEquals(2, list.items.size)
        assertTrue(list.items[1].any { it is MdBlock.ListBlock && it.ordered })
        assertEquals(MdBlock.CodeBlock("val x = 1", "kotlin"), blocks[5])
        val table = blocks[6] as MdBlock.Table
        assertEquals(listOf("名字", "价格"), table.header.map { it.text })
        assertEquals(listOf(listOf("A", "1")), table.rows.map { row -> row.map { it.text } })
    }

    @Test
    fun unsafeLinksAreNotClickable() {
        val text = (MarkdownParser.parse("[x](javascript:alert(1)) [y](intent://z)", colors).single() as MdBlock.Paragraph).text
        assertTrue(text.getLinkAnnotations(0, text.length).isEmpty())
        assertEquals("x y", text.text)
    }

    @Test
    fun plainTextKeepsStructure() {
        val blocks = MarkdownParser.parse("- a\n- b\n\n```\ncode\n```", colors)
        assertEquals("• a\n• b\ncode", MarkdownParser.plainText(blocks))
    }

    @Test
    fun rendersAndCopiesCodeWithLabel() {
        var copied: String? = null
        val clipboard = object : ClipboardManager {
            override fun getText(): AnnotatedString? = copied?.let(::AnnotatedString)
            override fun setText(annotatedString: AnnotatedString) {
                copied = annotatedString.text
            }
        }
        var copiedCalls = 0
        compose.setContent {
            CompositionLocalProvider(LocalClipboardManager provides clipboard) {
                ThinktinTheme {
                    MarkdownText(
                        markdown = "## 改动\n\n- 第一条\n\n```bash\ngit status\n```",
                        copySuffix = "【AI 生成】",
                        onCopied = { copiedCalls++ },
                    )
                }
            }
        }
        compose.onNode(hasText("改动")).assertExists()
        compose.onNode(hasText("第一条")).assertExists()
        compose.onNode(hasTestTag(MARKDOWN_CODE_TEST_TAG)).assertExists()
        compose.onNode(hasContentDescription("复制代码")).performClick()
        assertEquals("git status\n【AI 生成】", copied)
        assertEquals(1, copiedCalls)
    }

    @Test
    fun toolCallCardShowsSummaryAndAiLabel() {
        compose.setContent {
            ThinktinTheme {
                ToolCallCard(
                    title = "运行测试",
                    kind = "execute",
                    status = ToolCallStatus.Completed,
                    summary = "gradle test",
                    aiGenerated = true,
                    details = "{\"command\": \"gradle test\"}",
                )
            }
        }
        compose.onNode(hasText("【AI 生成】")).assertExists()
        compose.onNode(hasText("gradle test")).assertExists()
        compose.onNode(hasText("已完成")).assertExists()
    }
}
