@file:OptIn(ExperimentalMaterial3ExpressiveApi::class)

package com.charkle.android.designsystem

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat

/**
 * Zone A: Pure neutral studio canvas (`#F6F6F5` / `#141517`) with Studio Cobalt accent (`#2A60E0` / `#5B8DEF`).
 * Strictly conforms to `DESIGN.md` & `.trellis/spec/android/m3-expressive-design-system.md`.
 */
val CharkleLightColorScheme: ColorScheme = lightColorScheme(
    primary = Color(0xFF2A60E0),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFDDE7FF),
    onPrimaryContainer = Color(0xFF102B6E),
    secondary = Color(0xFF4E5D78),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFE4E8F0),
    onSecondaryContainer = Color(0xFF1D2638),
    tertiary = Color(0xFF4E7D96),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFD9EDF7),
    onTertiaryContainer = Color(0xFF103447),
    background = Color(0xFFF6F6F5),
    onBackground = Color(0xFF18191C),
    surface = Color(0xFFF6F6F5),
    onSurface = Color(0xFF18191C),
    surfaceVariant = Color(0xFFEDEDE9),
    onSurfaceVariant = Color(0xFF5C6069),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFF2F1EE),
    surfaceContainer = Color(0xFFEDEDE9),
    surfaceContainerHigh = Color(0xFFE6E5E0),
    surfaceContainerHighest = Color(0xFFDFDED8),
    outline = Color(0xFF8A8F99),
    outlineVariant = Color(0x14000000),
    error = Color(0xFFD93B30),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFCE6E4),
    onErrorContainer = Color(0xFF690E08),
    inverseSurface = Color(0xFF1E2025),
    inverseOnSurface = Color(0xFFF2F3F5),
    inversePrimary = Color(0xFF9BB7FF)
)

val CharkleDarkColorScheme: ColorScheme = darkColorScheme(
    primary = Color(0xFF5B8DEF),
    onPrimary = Color(0xFF0A1A3A),
    primaryContainer = Color(0xFF1E3566),
    onPrimaryContainer = Color(0xFFDCE7FF),
    secondary = Color(0xFF9FB0CC),
    onSecondary = Color(0xFF1A2538),
    secondaryContainer = Color(0xFF272D38),
    onSecondaryContainer = Color(0xFFDCE3F0),
    tertiary = Color(0xFF84B6D0),
    onTertiary = Color(0xFF0F2D3E),
    tertiaryContainer = Color(0xFF1F3C4C),
    onTertiaryContainer = Color(0xFFD0EBF9),
    background = Color(0xFF141517),
    onBackground = Color(0xFFF2F3F5),
    surface = Color(0xFF141517),
    onSurface = Color(0xFFF2F3F5),
    surfaceVariant = Color(0xFF24272C),
    onSurfaceVariant = Color(0xFFA1A6B0),
    surfaceContainerLowest = Color(0xFF0F1012),
    surfaceContainerLow = Color(0xFF17191D),
    surfaceContainer = Color(0xFF1E2025),
    surfaceContainerHigh = Color(0xFF24272C),
    surfaceContainerHighest = Color(0xFF2C3037),
    outline = Color(0xFF6E737D),
    outlineVariant = Color(0x17FFFFFF),
    error = Color(0xFFF2584D),
    onError = Color(0xFF420603),
    errorContainer = Color(0xFF4A1A17),
    onErrorContainer = Color(0xFFFFDAD6),
    inverseSurface = Color(0xFFF2F3F5),
    inverseOnSurface = Color(0xFF18191C),
    inversePrimary = Color(0xFF2A60E0)
)

@Immutable
data class CharkleExtendedColors(
    val positive: Color,
    val warning: Color,
    val inkTertiary: Color,
    val isDark: Boolean
)

private val CharkleLightExtendedColors = CharkleExtendedColors(
    positive = Color(0xFF249A4B),
    warning = Color(0xFFC98212),
    inkTertiary = Color(0xFF8A8F99),
    isDark = false
)

private val CharkleDarkExtendedColors = CharkleExtendedColors(
    positive = Color(0xFF34C769),
    warning = Color(0xFFF2B23E),
    inkTertiary = Color(0xFF6E737D),
    isDark = true
)

val LocalCharkleExtendedColors = staticCompositionLocalOf { CharkleLightExtendedColors }

val LocalCharkleReduceMotion = staticCompositionLocalOf { false }

@Composable
fun rememberReduceMotionEnabled(): Boolean {
    val context = LocalContext.current
    return remember(context) {
        runCatching {
            Settings.Global.getFloat(
                context.contentResolver,
                Settings.Global.ANIMATOR_DURATION_SCALE,
                1f
            ) == 0f
        }.getOrDefault(false)
    }
}

object CharklePaletteTokens {
    /** 10 calibrated low-saturation studio filter swatches from `DESIGN.md §2.4`. */
    val filterSwatches: List<String> = listOf(
        "#1E2024", "#5C6B73", "#3D5A80", "#4E7D96", "#6B8E76",
        "#D4A373", "#BA6B55", "#E5B243", "#C8B8A6", "#F0EEE9"
    )

    val folderPalette: List<String> = listOf(
        "#2A60E0", "#4E7D96", "#6B8E76", "#C98212",
        "#BA6B55", "#5C6B73", "#3D5A80", "#8A7968"
    )
}

val CharkleTypography = Typography(
    displaySmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 32.sp,
        lineHeight = 38.sp,
        letterSpacing = (-0.5).sp,
        fontFeatureSettings = "tnum"
    ),
    headlineMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 26.sp,
        lineHeight = 32.sp,
        letterSpacing = (-0.3).sp
    ),
    headlineSmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 22.sp,
        lineHeight = 28.sp,
        letterSpacing = (-0.2).sp
    ),
    titleMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 16.sp,
        lineHeight = 22.sp
    ),
    titleSmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 14.sp,
        lineHeight = 20.sp
    ),
    bodyMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Normal,
        fontSize = 14.sp,
        lineHeight = 20.sp
    ),
    bodySmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Normal,
        fontSize = 12.5.sp,
        lineHeight = 18.sp
    ),
    labelLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 13.5.sp,
        lineHeight = 18.sp,
        fontFeatureSettings = "tnum"
    ),
    labelMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Medium,
        fontSize = 12.sp,
        lineHeight = 16.sp,
        fontFeatureSettings = "tnum"
    ),
    labelSmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 11.sp,
        lineHeight = 15.sp,
        letterSpacing = 0.2.sp,
        fontFeatureSettings = "tnum"
    )
)

val CharkleShapes = Shapes(
    extraSmall = RoundedCornerShape(6.dp),
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(14.dp),
    large = RoundedCornerShape(20.dp),
    extraLarge = RoundedCornerShape(28.dp)
)

enum class CharkleAppearanceMode {
    System,
    Light,
    Dark
}

/**
 * Zone A root theme: enforces a pure neutral studio canvas while enabling full Material 3 Expressive
 * motion physics and optional system Monet accent on controls only.
 */
@Composable
fun CharkleExpressiveTheme(
    appearanceMode: CharkleAppearanceMode = CharkleAppearanceMode.System,
    followSystemAccentOnControls: Boolean = false,
    content: @Composable () -> Unit
) {
    val context = LocalContext.current
    val reduceMotion = rememberReduceMotionEnabled()
    val darkTheme = when (appearanceMode) {
        CharkleAppearanceMode.System -> isSystemInDarkTheme()
        CharkleAppearanceMode.Light -> false
        CharkleAppearanceMode.Dark -> true
    }

    val colorScheme = remember(darkTheme, followSystemAccentOnControls, context) {
        val baseScheme = if (darkTheme) CharkleDarkColorScheme else CharkleLightColorScheme
        if (followSystemAccentOnControls && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val sys = if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
            // Preserve 100% pure neutral surfaces; only adopt system accent roles on interactive controls.
            baseScheme.copy(
                primary = sys.primary,
                onPrimary = sys.onPrimary,
                primaryContainer = sys.primaryContainer,
                onPrimaryContainer = sys.onPrimaryContainer,
                inversePrimary = sys.inversePrimary
            )
        } else {
            baseScheme
        }
    }

    val extended = if (darkTheme) CharkleDarkExtendedColors else CharkleLightExtendedColors

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = view.context.findActivity()?.window ?: return@SideEffect
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !darkTheme
                isAppearanceLightNavigationBars = !darkTheme
            }
        }
    }

    CompositionLocalProvider(
        LocalCharkleExtendedColors provides extended,
        LocalCharkleReduceMotion provides reduceMotion,
        LocalContentColor provides colorScheme.onBackground
    ) {
        MaterialExpressiveTheme(
            colorScheme = colorScheme,
            motionScheme = MotionScheme.expressive(),
            typography = CharkleTypography,
            shapes = CharkleShapes,
            content = content
        )
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
