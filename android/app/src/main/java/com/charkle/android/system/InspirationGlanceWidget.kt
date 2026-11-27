package com.charkle.android.system

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.ActionParameters
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.charkle.android.CharkleApplication
import com.charkle.android.MainActivity
import com.charkle.android.core.AssetDto
import com.charkle.android.core.FilterCriteriaDto
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.ConcurrentHashMap

internal const val MAX_WIDGET_BITMAP_PX = 480

/**
 * Computes a strictly power-of-2 `BitmapFactory.Options.inSampleSize` so Android decoders never
 * allocate full-resolution bitmaps that trigger OOM or RemoteViews Binder IPC failures.
 */
internal fun calculateWidgetInSampleSize(
    srcWidth: Int,
    srcHeight: Int,
    maxSide: Int = MAX_WIDGET_BITMAP_PX
): Int {
    if (srcWidth <= 0 || srcHeight <= 0 || maxSide <= 0) return 1
    var sample = 1
    val longest = maxOf(srcWidth, srcHeight)
    while ((longest / sample) > maxSide * 2) {
        sample *= 2
    }
    return sample.coerceAtLeast(1)
}

/**
 * Selects a featured asset preferring items with cached thumbnails and avoiding repeating
 * `previousAssetId` whenever at least two candidates exist.
 */
internal fun pickWidgetAsset(
    candidates: List<AssetDto>,
    previousAssetId: String?,
    picker: (List<AssetDto>) -> AssetDto? = { it.randomOrNull() }
): AssetDto? {
    if (candidates.isEmpty()) return null
    if (candidates.size == 1 || previousAssetId.isNullOrBlank()) {
        return picker(candidates)
    }
    val distinct = candidates.filterNot { it.id.equals(previousAssetId, ignoreCase = true) }
    return picker(distinct.ifEmpty { candidates })
}

/**
 * Material 3 Expressive Jetpack Glance Home-Screen Widget:
 * Surfaces a random visual reference from the local Charkle library along with
 * its extracted palette dots and 1-tap jump into Zone B Quick Look.
 */
class InspirationGlanceWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val app = context.applicationContext as? CharkleApplication
        val widgetKey = id.toString()
        val featured: Pair<AssetDto, Bitmap?>? = if (app != null) {
            withContext(Dispatchers.IO) {
                runCatching {
                    val assets = app.repository.fetchAssets(FilterCriteriaDto(includeTrashed = false))
                    if (assets.isEmpty()) return@runCatching null
                    val pathsById = runCatching {
                        app.repository.resolveMediaPaths(assets.map { it.id })
                    }.getOrDefault(emptyMap())

                    val withThumbs = assets.filter { asset ->
                        val p = pathsById[asset.id.uppercase()]
                        p?.gridThumbPath != null || p?.previewThumbPath != null
                    }
                    val pool = withThumbs.ifEmpty { assets }
                    val chosen = pickWidgetAsset(pool, lastShownAssetByWidget[widgetKey]) ?: return@runCatching null
                    lastShownAssetByWidget[widgetKey] = chosen.id

                    val entry = pathsById[chosen.id.uppercase()]
                    val thumbPath = entry?.gridThumbPath ?: entry?.previewThumbPath
                    val bmp = thumbPath?.let(::decodeWidgetThumbnail)
                    chosen to bmp
                }.getOrNull()
            }
        } else {
            null
        }

        provideContent {
            GlanceTheme {
                WidgetBody(context = context, featured = featured)
            }
        }
    }

    @Composable
    private fun WidgetBody(
        context: Context,
        featured: Pair<AssetDto, Bitmap?>?
    ) {
        val openIntent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            val assetId = featured?.first?.id
            if (assetId != null) {
                action = MainActivity.ACTION_OPEN_ASSET
                data = Uri.parse("charkle-android://asset/$assetId")
                putExtra(MainActivity.EXTRA_OPEN_ASSET_ID, assetId)
            }
        }

        Box(
            modifier = GlanceModifier
                .fillMaxSize()
                .cornerRadius(24.dp)
                .background(GlanceTheme.colors.surface)
                .clickable(actionStartActivity(openIntent))
        ) {
            val bitmap = featured?.second
            if (bitmap != null) {
                Image(
                    provider = ImageProvider(bitmap),
                    contentDescription = featured.first.title,
                    contentScale = ContentScale.Crop,
                    modifier = GlanceModifier.fillMaxSize().cornerRadius(24.dp)
                )
            } else if (featured == null) {
                Column(
                    modifier = GlanceModifier
                        .fillMaxSize()
                        .padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        text = "Charkle 灵感日签",
                        style = TextStyle(
                            color = GlanceTheme.colors.onSurface,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium
                        ),
                        maxLines = 1
                    )
                    Spacer(GlanceModifier.height(4.dp))
                    Text(
                        text = "暂无素材 · 点按进入收藏",
                        style = TextStyle(
                            color = GlanceTheme.colors.onSurfaceVariant,
                            fontSize = 11.sp
                        ),
                        maxLines = 1
                    )
                }
            }

            if (featured != null) {
                // Bottom subtle legibility caption pill + shuffle button
                Column(
                    modifier = GlanceModifier
                        .fillMaxSize()
                        .padding(12.dp),
                    verticalAlignment = Alignment.Bottom
                ) {
                    Row(
                        modifier = GlanceModifier
                            .fillMaxWidth()
                            .cornerRadius(16.dp)
                            .background(ColorProvider(Color(0xB8141517)))
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(modifier = GlanceModifier.defaultWeight()) {
                            Text(
                                text = featured.first.title.ifBlank { "Charkle 灵感日签" },
                                style = TextStyle(
                                    color = ColorProvider(Color.White),
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Medium
                                ),
                                maxLines = 1
                            )
                            val hexes = featured.first.dominantColors.take(4).map { it.hex }
                            if (hexes.isNotEmpty()) {
                                Spacer(GlanceModifier.height(4.dp))
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    hexes.forEach { hex ->
                                        val parsed = runCatching {
                                            Color(android.graphics.Color.parseColor(hex))
                                        }.getOrNull()
                                        if (parsed != null) {
                                            Box(
                                                modifier = GlanceModifier
                                                    .size(9.dp)
                                                    .cornerRadius(5.dp)
                                                    .background(ColorProvider(parsed))
                                            ) {}
                                            Spacer(GlanceModifier.width(4.dp))
                                        }
                                    }
                                }
                            }
                        }

                        Box(
                            modifier = GlanceModifier
                                .cornerRadius(14.dp)
                                .background(ColorProvider(Color(0x38FFFFFF)))
                                .clickable(actionRunCallback<RefreshInspirationAction>())
                                .padding(horizontal = 10.dp, vertical = 5.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                text = "换一张",
                                style = TextStyle(
                                    color = ColorProvider(Color.White),
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Medium
                                )
                            )
                        }
                    }
                }
            }
        }
    }

    private fun decodeWidgetThumbnail(path: String): Bitmap? {
        return runCatching {
            val file = File(path)
            if (!file.isFile || file.length() <= 0L) return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

            val sample = calculateWidgetInSampleSize(
                srcWidth = bounds.outWidth,
                srcHeight = bounds.outHeight,
                maxSide = MAX_WIDGET_BITMAP_PX
            )
            val opts = BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.RGB_565
            }
            val decoded = BitmapFactory.decodeFile(file.absolutePath, opts) ?: return null
            val longest = maxOf(decoded.width, decoded.height)
            if (longest <= MAX_WIDGET_BITMAP_PX) {
                decoded
            } else {
                val ratio = MAX_WIDGET_BITMAP_PX.toFloat() / longest.toFloat()
                val targetW = (decoded.width * ratio).toInt().coerceAtLeast(1)
                val targetH = (decoded.height * ratio).toInt().coerceAtLeast(1)
                val scaled = Bitmap.createScaledBitmap(decoded, targetW, targetH, true)
                if (scaled !== decoded) {
                    decoded.recycle()
                }
                scaled
            }
        }.getOrNull()
    }

    companion object {
        private val lastShownAssetByWidget = ConcurrentHashMap<String, String>()

        suspend fun updateAllWidgets(context: Context) {
            runCatching {
                InspirationGlanceWidget().updateAll(context.applicationContext ?: context)
            }
        }
    }
}

class RefreshInspirationAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        runCatching {
            InspirationGlanceWidget().update(context, glanceId)
        }
    }
}

class InspirationGlanceWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = InspirationGlanceWidget()
}
