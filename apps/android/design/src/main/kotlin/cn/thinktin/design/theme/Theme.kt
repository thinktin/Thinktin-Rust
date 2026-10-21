package cn.thinktin.design.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable

/** 外观：跟随系统，或在设置里固定浅色 / 深色。 */
enum class Appearance {
    System,
    Light,
    Dark,
}

/**
 * ThinkTin 主题。动态取色（Material You）关闭，保持品牌色稳定。
 */
@Composable
fun ThinktinTheme(
    appearance: Appearance = Appearance.System,
    content: @Composable () -> Unit,
) {
    val dark = when (appearance) {
        Appearance.System -> isSystemInDarkTheme()
        Appearance.Light -> false
        Appearance.Dark -> true
    }
    CompositionLocalProvider(LocalExtendedColors provides if (dark) DarkExtendedColors else LightExtendedColors) {
        MaterialTheme(
            colorScheme = if (dark) DarkColors else LightColors,
            typography = ThinktinTypography,
            shapes = ThinktinMaterialShapes,
            content = content,
        )
    }
}

/** 取当前主题的值：`ThinktinTheme.extendedColors.success`。 */
object ThinktinTheme {
    val colors: ColorScheme
        @Composable @ReadOnlyComposable
        get() = MaterialTheme.colorScheme

    val extendedColors: ExtendedColors
        @Composable @ReadOnlyComposable
        get() = LocalExtendedColors.current
}
