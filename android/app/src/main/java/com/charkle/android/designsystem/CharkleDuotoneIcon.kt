package com.charkle.android.designsystem

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

private object DuotoneSvgCache {
    val rawTemplates = ConcurrentHashMap<String, String>()
    val tintedBytes = ConcurrentHashMap<String, ByteArray>()
}

/**
 * Renders Charkle's 37 built-in 16-grid duotone SVG icons from `assets/icons/duotone-<name>.svg`
 * with runtime Light/Dark/Active/Custom-Folder dual-channel color remapping (`DESIGN.md §5.1`).
 * Loads templates off the main thread and shares Coil memory cache keys across identical icons.
 */
@Composable
fun CharkleDuotoneIcon(
    name: String,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    active: Boolean = false,
    customHex: String? = null
) {
    val context = LocalContext.current
    val isDark = LocalCharkleExtendedColors.current.isDark

    val (primaryHex, secondaryHex) = remember(isDark, active, customHex) {
        if (!customHex.isNullOrBlank()) {
            deriveFolderDuotoneHex(customHex, isDark)
        } else if (isDark) {
            if (active) "#9BB7FF" to "#3E5998" else "#8EA8E8" to "#3D4E75"
        } else {
            if (active) "#2A60E0" to "#AFC6F7" else "#445C94" to "#B4BED4"
        }
    }

    val cacheKey = remember(name, primaryHex, secondaryHex) {
        "duotone:$name:$primaryHex:$secondaryHex"
    }
    val initialBytes = remember(cacheKey) { DuotoneSvgCache.tintedBytes[cacheKey] }

    val svgBytes by produceState(initialValue = initialBytes, key1 = cacheKey, key2 = context) {
        val hit = DuotoneSvgCache.tintedBytes[cacheKey]
        if (hit != null) {
            value = hit
            return@produceState
        }
        val bytes = withContext(Dispatchers.IO) {
            runCatching {
                val raw = DuotoneSvgCache.rawTemplates.getOrPut(name) {
                    context.assets.open("icons/duotone-$name.svg").bufferedReader().use { it.readText() }
                }
                raw
                    .replace("#445C94", primaryHex, ignoreCase = true)
                    .replace("#B4BED4", secondaryHex, ignoreCase = true)
                    .toByteArray(Charsets.UTF_8)
            }.getOrNull()
        }
        if (bytes != null) {
            DuotoneSvgCache.tintedBytes[cacheKey] = bytes
            value = bytes
        }
    }

    if (svgBytes != null) {
        val request = remember(cacheKey, svgBytes, context) {
            ImageRequest.Builder(context)
                .data(svgBytes)
                .memoryCacheKey(cacheKey)
                .build()
        }
        AsyncImage(
            model = request,
            contentDescription = contentDescription,
            modifier = modifier
        )
    }
}

private fun deriveFolderDuotoneHex(hex: String, isDark: Boolean): Pair<String, String> {
    val parsed = parseHexColor(hex) ?: return if (isDark) "#8EA8E8" to "#3D4E75" else "#445C94" to "#B4BED4"
    val lum = parsed.luminance()
    val r = (parsed.red * 255f).toInt()
    val g = (parsed.green * 255f).toInt()
    val b = (parsed.blue * 255f).toInt()

    return if (!isDark) {
        // Darken very light custom folder colors slightly so they remain crisp on white cards.
        val pr: Int
        val pg: Int
        val pb: Int
        if (lum > 0.72f) {
            pr = (r * 0.62f).toInt().coerceIn(0, 255)
            pg = (g * 0.62f).toInt().coerceIn(0, 255)
            pb = (b * 0.62f).toInt().coerceIn(0, 255)
        } else {
            pr = r
            pg = g
            pb = b
        }
        val sr = (pr * 0.5f + 255f * 0.5f).toInt().coerceIn(0, 255)
        val sg = (pg * 0.5f + 255f * 0.5f).toInt().coerceIn(0, 255)
        val sb = (pb * 0.5f + 255f * 0.5f).toInt().coerceIn(0, 255)
        toHex(pr, pg, pb) to toHex(sr, sg, sb)
    } else {
        // Lift very dark custom folder colors so they stay visible against dark drawer surfaces.
        val lift = if (lum < 0.16f) 0.42f else 0.14f
        val pr = (r * (1f - lift) + 255f * lift).toInt().coerceIn(0, 255)
        val pg = (g * (1f - lift) + 255f * lift).toInt().coerceIn(0, 255)
        val pb = (b * (1f - lift) + 255f * lift).toInt().coerceIn(0, 255)
        val sr = (pr * 0.48f + 0x24 * 0.52f).toInt().coerceIn(0, 255)
        val sg = (pg * 0.48f + 0x27 * 0.52f).toInt().coerceIn(0, 255)
        val sb = (pb * 0.48f + 0x2C * 0.52f).toInt().coerceIn(0, 255)
        toHex(pr, pg, pb) to toHex(sr, sg, sb)
    }
}

private fun toHex(r: Int, g: Int, b: Int): String =
    String.format(Locale.ROOT, "#%02X%02X%02X", r, g, b)

fun Color.toHexString(): String {
    val argb = this.toArgb()
    return String.format(Locale.ROOT, "#%06X", argb and 0xFFFFFF)
}
