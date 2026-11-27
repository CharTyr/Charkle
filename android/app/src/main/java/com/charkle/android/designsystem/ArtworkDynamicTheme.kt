@file:OptIn(ExperimentalMaterial3ExpressiveApi::class)

package com.charkle.android.designsystem

import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.luminance
import com.materialkolor.PaletteStyle
import com.materialkolor.material3.DynamicMaterialExpressiveTheme
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

private val StudioCobaltSeed = Color(0xFF2A60E0)

private val ColorProofingDarkColorScheme = CharkleDarkColorScheme.copy(
    background = Color(0xFF0A0B0D),
    surface = Color(0xFF0A0B0D),
    surfaceContainer = Color(0xFF181A1F),
    surfaceContainerHigh = Color(0xFF22252C)
)

fun parseHexColor(hex: String?): Color? {
    if (hex.isNullOrBlank()) return null
    val raw = hex.trim().removePrefix("#")
    val cleaned = if (raw.length == 3) {
        buildString(6) {
            for (ch in raw) {
                append(ch)
                append(ch)
            }
        }
    } else {
        raw
    }
    if (cleaned.length != 6 && cleaned.length != 8) return null
    val value = cleaned.toLongOrNull(16) ?: return null
    return if (cleaned.length == 6) {
        Color(0xFF000000L or value)
    } else {
        Color(value)
    }
}

/**
 * Picks the best expressive seed color from a sorted list of dominant hex swatches,
 * skipping near-pure black/white so Quick Look & Inbox Triage stay rich and legible.
 */
fun pickExpressiveArtworkSeed(hexes: List<String>): Color? {
    var fallback: Color? = null
    for (hex in hexes) {
        val c = parseHexColor(hex) ?: continue
        if (fallback == null) fallback = c
        val r = c.red
        val g = c.green
        val b = c.blue
        val maxC = max(r, max(g, b))
        val minC = min(r, min(g, b))
        val chroma = maxC - minC
        val lum = 0.2126f * r + 0.7152f * g + 0.0722f * b
        if (chroma >= 0.14f && lum in 0.09f..0.91f) {
            return c
        }
    }
    return fallback
}

private fun isNearAchromatic(color: Color): Boolean {
    val maxC = max(color.red, max(color.green, color.blue))
    val minC = min(color.red, min(color.green, color.blue))
    return abs(maxC - minC) < 0.09f
}

/**
 * Zone B: Artwork-driven Material 3 Expressive dynamic theme for Quick Look & Inbox Triage.
 * Smoothly animates surface washes, connected buttons, and bottom controls to match the active
 * artwork's dominant color, with instant 1-tap Neutral Color-Proofing override.
 */
@Composable
fun ArtworkDynamicExpressiveTheme(
    dominantHexes: List<String>,
    isDark: Boolean,
    colorProofingEnabled: Boolean = false,
    content: @Composable () -> Unit
) {
    val reduceMotion = LocalCharkleReduceMotion.current

    if (colorProofingEnabled) {
        val neutralScheme = if (isDark) ColorProofingDarkColorScheme else CharkleLightColorScheme
        MaterialExpressiveTheme(
            colorScheme = neutralScheme,
            motionScheme = MotionScheme.expressive(),
            typography = CharkleTypography,
            shapes = CharkleShapes
        ) {
            CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onBackground) {
                content()
            }
        }
        return
    }

    val seed = remember(dominantHexes) {
        pickExpressiveArtworkSeed(dominantHexes) ?: StudioCobaltSeed
    }
    // Use PaletteStyle.Fidelity (faithful artwork hue across primary, secondary, and surface tones)
    // instead of PaletteStyle.Expressive (which intentionally rotates secondary to a contrasting hue).
    val style = remember(seed) {
        if (isNearAchromatic(seed)) PaletteStyle.Neutral else PaletteStyle.Fidelity
    }

    DynamicMaterialExpressiveTheme(
        seedColor = seed,
        isDark = isDark,
        style = style,
        animate = !reduceMotion,
        typography = CharkleTypography,
        shapes = CharkleShapes
    ) {
        CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onBackground) {
            content()
        }
    }
}

/**
 * Rich, atmospheric Material 3 Expressive vertical tonal field for Zone B (Quick Look & Inbox Triage).
 * Normalizes `PaletteStyle.Fidelity` tint luminance so both dark-seed artworks in Light mode and
 * bright-seed artworks in Dark mode preserve faithful hue while guaranteeing WCAG AA+ contrast for
 * `onSurface` typography. Immediately drops to pure neutral studio ground when [colorProofingEnabled].
 */
@Composable
fun expressiveZoneBBackdropBrush(
    isDark: Boolean,
    colorProofingEnabled: Boolean = false
): Brush {
    val scheme = MaterialTheme.colorScheme
    if (colorProofingEnabled) {
        val bg = scheme.background
        return remember(bg) { Brush.verticalGradient(listOf(bg, bg)) }
    }

    val top: Color
    val mid: Color
    val bottom: Color
    if (isDark) {
        // Under Fidelity, bright pastel/yellow seeds can produce a high-luminance primaryContainer.
        // Deepen bright tints toward background so dark-mode white typography stays high-contrast.
        val containerLum = scheme.primaryContainer.luminance()
        val safeTint = if (containerLum > 0.22f) {
            val darken = ((containerLum - 0.16f) / (containerLum + 0.05f)).coerceIn(0.35f, 0.78f)
            lerp(scheme.primaryContainer, scheme.background, darken)
        } else {
            scheme.primaryContainer
        }
        top = lerp(scheme.surfaceContainerHighest, safeTint, 0.34f)
        mid = lerp(scheme.surfaceContainer, safeTint, 0.22f)
        bottom = lerp(scheme.background, safeTint, 0.14f)
    } else {
        // Under Fidelity, dark saturated seeds can produce a dark primaryContainer in Light mode.
        // Lift dark tints toward surface/white so light-mode dark typography stays crisp (>= 7:1).
        val containerLum = scheme.primaryContainer.luminance()
        val safeTint = if (containerLum < 0.62f) {
            val lift = ((0.68f - containerLum) / (1f - containerLum + 0.05f)).coerceIn(0.45f, 0.84f)
            lerp(scheme.primaryContainer, Color.White, lift)
        } else {
            scheme.primaryContainer
        }
        top = lerp(scheme.surfaceContainerHigh, safeTint, 0.56f)
        mid = lerp(scheme.surfaceContainerLow, safeTint, 0.38f)
        bottom = lerp(scheme.surfaceContainer, safeTint, 0.46f)
    }

    return remember(top, mid, bottom) {
        Brush.verticalGradient(listOf(top, mid, bottom))
    }
}
