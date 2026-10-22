package cn.thinktin.design.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

/*
 * 第 2.2 节：标题与问候用系统衬线（Noto Serif / Noto Serif CJK），正文用系统无衬线，代码用等宽。
 * 不打包字体文件。
 */

private fun serif(size: Int) = TextStyle(
    fontFamily = FontFamily.Serif,
    fontWeight = FontWeight.Normal,
    fontSize = size.sp,
    lineHeight = 1.2.em,
)

private fun sans(size: Int, lineHeight: Int, weight: FontWeight = FontWeight.Normal) = TextStyle(
    fontFamily = FontFamily.Default,
    fontWeight = weight,
    fontSize = size.sp,
    lineHeight = lineHeight.sp,
)

internal val ThinktinTypography = Typography(
    displayLarge = serif(34),
    displayMedium = serif(32),
    displaySmall = serif(30),
    headlineLarge = serif(30),
    headlineMedium = serif(28),
    // 衬线只用在 28–34sp（第 2.2 节）；headlineSmall 是对话框标题的默认样式，用无衬线。
    headlineSmall = sans(24, 32),
    titleLarge = sans(20, 28, FontWeight.Medium),
    titleMedium = sans(16, 24, FontWeight.Medium),
    titleSmall = sans(14, 20, FontWeight.Medium),
    bodyLarge = sans(16, 24),
    bodyMedium = sans(14, 20),
    bodySmall = sans(12, 16),
    labelLarge = sans(14, 20, FontWeight.Medium),
    labelMedium = sans(12, 16, FontWeight.Medium),
    labelSmall = sans(12, 16),
)

/** Material Typography 之外的文字样式。 */
object ThinktinTextStyles {
    /** 代码块、工具调用参数：等宽 13sp。 */
    val Code: TextStyle = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontSize = 13.sp,
        lineHeight = 18.sp,
    )

    /** 首页问候语：衬线 34sp。 */
    val Greeting: TextStyle = serif(34)
}
