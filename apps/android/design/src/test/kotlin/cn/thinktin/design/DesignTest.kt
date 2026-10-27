package cn.thinktin.design

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import cn.thinktin.design.component.AiGeneratedLabel
import cn.thinktin.design.component.Composer
import cn.thinktin.design.component.EmptyState
import cn.thinktin.design.component.ToolCallCard
import cn.thinktin.design.component.ToolCallStatus
import cn.thinktin.design.theme.Appearance
import cn.thinktin.design.theme.ThinktinTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-rCN")
class DesignTest {
    @get:Rule
    val compose = createComposeRule()

    /** 规范第 2.1 节的色值（十六进制字面量，不引用 ThinktinPalette 常量）。 */
    @Test
    fun lightAndDarkSchemesMatchSpecHexValues() {
        val captured = mutableMapOf<String, Color>()
        compose.setContent {
            for ((mode, appearance) in listOf("light" to Appearance.Light, "dark" to Appearance.Dark)) {
                ThinktinTheme(appearance) {
                    val c = MaterialTheme.colorScheme
                    val e = ThinktinTheme.extendedColors
                    captured += mapOf(
                        "$mode.background" to c.background,
                        "$mode.surface" to c.surface,
                        "$mode.surfaceVariant" to c.surfaceVariant,
                        "$mode.onBackground" to c.onBackground,
                        "$mode.onSurface" to c.onSurface,
                        "$mode.onSurfaceVariant" to c.onSurfaceVariant,
                        "$mode.primary" to c.primary,
                        "$mode.onPrimary" to c.onPrimary,
                        "$mode.secondary" to c.secondary,
                        "$mode.error" to c.error,
                        "$mode.outline" to c.outline,
                        "$mode.success" to e.success,
                        "$mode.warning" to e.warning,
                    )
                }
            }
        }
        compose.waitForIdle()
        val spec = mapOf(
            "background" to (0xFFF7F5F0 to 0xFF1F1E1B),
            "surface" to (0xFFFFFFFF to 0xFF2A2926),
            "surfaceVariant" to (0xFFEFEBE3 to 0xFF353430),
            "onBackground" to (0xFF1F1E1B to 0xFFF2EFE8),
            "onSurface" to (0xFF1F1E1B to 0xFFF2EFE8),
            "onSurfaceVariant" to (0xFF6B675F to 0xFFA8A49B),
            "primary" to (0xFFC9653F to 0xFFE08A64),
            "onPrimary" to (0xFFFFFFFF to 0xFF1F1E1B),
            "secondary" to (0xFF4F6F8F to 0xFF8FB0CF),
            "error" to (0xFFB3261E to 0xFFF2B8B5),
            "success" to (0xFF3E7D5A to 0xFF8FCBA6),
            "warning" to (0xFFB07A1E to 0xFFE2B45F),
            "outline" to (0xFFD9D4CA to 0xFF45433E),
        )
        for ((role, values) in spec) {
            assertEquals("light.$role", Color(values.first), captured["light.$role"])
            assertEquals("dark.$role", Color(values.second), captured["dark.$role"])
        }
    }

    @Test
    fun serifStylesStayInSpecRange() {
        var typography: Typography? = null
        compose.setContent { ThinktinTheme { typography = MaterialTheme.typography } }
        compose.waitForIdle()
        val t = typography!!
        val all = listOf(
            t.displayLarge, t.displayMedium, t.displaySmall, t.headlineLarge, t.headlineMedium, t.headlineSmall,
            t.titleLarge, t.titleMedium, t.titleSmall, t.bodyLarge, t.bodyMedium, t.bodySmall,
            t.labelLarge, t.labelMedium, t.labelSmall,
        )
        // 第 2.2 节：衬线只用于 28–34sp 的标题。
        for (style in all.filter { it.fontFamily == FontFamily.Serif }) {
            assertTrue("衬线字号 ${style.fontSize} 不在 28–34sp", style.fontSize.value in 28f..34f)
        }
        assertTrue(t.headlineSmall.fontFamily != FontFamily.Serif)
    }

    @Test
    fun composerSendsAndStops() {
        var text by mutableStateOf("")
        var sent = 0
        var stopped = 0
        var running by mutableStateOf(false)
        compose.setContent {
            ThinktinTheme {
                Composer(
                    value = text,
                    onValueChange = { text = it },
                    onSend = { sent++ },
                    running = running,
                    onStop = { stopped++ },
                    onAttach = {},
                )
            }
        }
        // 占位文字是输入框自己的名字（读屏能认出这个输入框），不是单独的文字节点。
        compose.onNode(hasSetTextAction() and hasContentDescription("给 agent 发消息")).assertExists()
        compose.onNodeWithText("给 agent 发消息").assertDoesNotExist()
        compose.onNodeWithContentDescription("添加附件").assertExists()
        compose.onNodeWithContentDescription("发送").assertIsNotEnabled()
        text = "你好"
        compose.onNodeWithContentDescription("发送").assertIsEnabled().performClick()
        assertEquals(1, sent)
        running = true
        compose.onNodeWithContentDescription("停止").performClick()
        assertEquals(1, stopped)
    }

    @Test
    fun toolCallCardExpands() {
        compose.setContent {
            ThinktinTheme {
                ToolCallCard(title = "运行脚本", kind = "execute", status = ToolCallStatus.Completed, details = "echo hi")
            }
        }
        compose.onNodeWithText("已完成").assertExists()
        compose.onNodeWithText("echo hi").assertDoesNotExist()
        compose.onNodeWithContentDescription("展开").performClick()
        compose.onNodeWithText("echo hi").assertExists()
    }

    @Test
    fun aiGeneratedLabelUsesSpecText() {
        compose.setContent { ThinktinTheme { AiGeneratedLabel() } }
        compose.onNodeWithText("【AI 生成】").assertExists()
    }

    @Test
    fun emptyStateShowsAction() {
        var clicked = false
        compose.setContent {
            ThinktinTheme { EmptyState(title = "还没有 agent", actionLabel = "领养", onAction = { clicked = true }) }
        }
        compose.onNodeWithText("领养").performClick()
        assertTrue(clicked)
    }
}
