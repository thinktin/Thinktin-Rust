package cn.thinktin.design.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/** 第 2.1 节的色值（浅色 / 深色）。 */
object ThinktinPalette {
    object Light {
        val Background = Color(0xFFF7F5F0)
        val Surface = Color(0xFFFFFFFF)
        val SurfaceVariant = Color(0xFFEFEBE3)
        val OnSurface = Color(0xFF1F1E1B)
        val OnSurfaceVariant = Color(0xFF6B675F)
        val Primary = Color(0xFFC9653F)
        val OnPrimary = Color(0xFFFFFFFF)
        val Secondary = Color(0xFF4F6F8F)
        val Error = Color(0xFFB3261E)
        val Success = Color(0xFF3E7D5A)
        val Warning = Color(0xFFB07A1E)
        val Outline = Color(0xFFD9D4CA)
    }

    object Dark {
        val Background = Color(0xFF1F1E1B)
        val Surface = Color(0xFF2A2926)
        val SurfaceVariant = Color(0xFF353430)
        val OnSurface = Color(0xFFF2EFE8)
        val OnSurfaceVariant = Color(0xFFA8A49B)
        val Primary = Color(0xFFE08A64)
        val OnPrimary = Color(0xFF1F1E1B)
        val Secondary = Color(0xFF8FB0CF)
        val Error = Color(0xFFF2B8B5)
        val Success = Color(0xFF8FCBA6)
        val Warning = Color(0xFFE2B45F)
        val Outline = Color(0xFF45433E)
    }
}

/** Material 3 色板之外的语义色：成功（运行成功、在线）、警告（等待审批、等待 key）。 */
@Immutable
data class ExtendedColors(
    val success: Color,
    val onSuccess: Color,
    val warning: Color,
    val onWarning: Color,
)

internal val LightExtendedColors = ExtendedColors(
    success = ThinktinPalette.Light.Success,
    onSuccess = Color.White,
    warning = ThinktinPalette.Light.Warning,
    onWarning = Color.White,
)

internal val DarkExtendedColors = ExtendedColors(
    success = ThinktinPalette.Dark.Success,
    onSuccess = ThinktinPalette.Dark.Background,
    warning = ThinktinPalette.Dark.Warning,
    onWarning = ThinktinPalette.Dark.Background,
)

val LocalExtendedColors = staticCompositionLocalOf { LightExtendedColors }

// 容器色（抽屉、卡片、输入框）都落在 surface / surfaceVariant 上：不用阴影分层（第 2.3 节）。
internal val LightColors: ColorScheme = with(ThinktinPalette.Light) {
    lightColorScheme(
        primary = Primary,
        onPrimary = OnPrimary,
        primaryContainer = SurfaceVariant,
        onPrimaryContainer = OnSurface,
        secondary = Secondary,
        onSecondary = Color.White,
        secondaryContainer = SurfaceVariant,
        onSecondaryContainer = OnSurface,
        tertiary = Secondary,
        onTertiary = Color.White,
        background = Background,
        onBackground = OnSurface,
        surface = Surface,
        onSurface = OnSurface,
        surfaceVariant = SurfaceVariant,
        onSurfaceVariant = OnSurfaceVariant,
        surfaceTint = Color.Transparent,
        surfaceBright = Surface,
        surfaceDim = SurfaceVariant,
        surfaceContainerLowest = Surface,
        surfaceContainerLow = Surface,
        surfaceContainer = Surface,
        surfaceContainerHigh = SurfaceVariant,
        surfaceContainerHighest = SurfaceVariant,
        inverseSurface = ThinktinPalette.Dark.Surface,
        inverseOnSurface = ThinktinPalette.Dark.OnSurface,
        inversePrimary = ThinktinPalette.Dark.Primary,
        error = Error,
        onError = Color.White,
        errorContainer = Color(0xFFF9DEDC),
        onErrorContainer = Color(0xFF410E0B),
        outline = Outline,
        outlineVariant = Outline,
        scrim = Color.Black,
    )
}

internal val DarkColors: ColorScheme = with(ThinktinPalette.Dark) {
    darkColorScheme(
        primary = Primary,
        onPrimary = OnPrimary,
        primaryContainer = SurfaceVariant,
        onPrimaryContainer = OnSurface,
        secondary = Secondary,
        onSecondary = Background,
        secondaryContainer = SurfaceVariant,
        onSecondaryContainer = OnSurface,
        tertiary = Secondary,
        onTertiary = Background,
        background = Background,
        onBackground = OnSurface,
        surface = Surface,
        onSurface = OnSurface,
        surfaceVariant = SurfaceVariant,
        onSurfaceVariant = OnSurfaceVariant,
        surfaceTint = Color.Transparent,
        surfaceBright = SurfaceVariant,
        surfaceDim = Background,
        surfaceContainerLowest = Background,
        surfaceContainerLow = Surface,
        surfaceContainer = Surface,
        surfaceContainerHigh = SurfaceVariant,
        surfaceContainerHighest = SurfaceVariant,
        inverseSurface = ThinktinPalette.Light.Surface,
        inverseOnSurface = ThinktinPalette.Light.OnSurface,
        inversePrimary = ThinktinPalette.Light.Primary,
        error = Error,
        onError = Color(0xFF601410),
        errorContainer = Color(0xFF8C1D18),
        onErrorContainer = Color(0xFFF9DEDC),
        outline = Outline,
        outlineVariant = Outline,
        scrim = Color.Black,
    )
}
