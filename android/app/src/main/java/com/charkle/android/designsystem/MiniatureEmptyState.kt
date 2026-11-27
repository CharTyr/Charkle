package com.charkle.android.designsystem

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

enum class EmptyVignetteKind {
    EmptyLibrary,
    InboxZero,
    NoResults,
    EmptyFolder,
    EmptyMoodboard
}

/**
 * Miniature UI Vignettes strictly following `DESIGN.md §5.2`:
 * 160x120 aspect rounded plate with subtle 45-degree hatch + 2-3 miniature product shapes
 * and at most 1 accent focal point (never cheesy illustrations or emoji).
 */
@Composable
fun MiniatureEmptyState(
    kind: EmptyVignetteKind,
    title: String,
    subtitle: String,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
    modifier: Modifier = Modifier
) {
    val isDark = LocalCharkleExtendedColors.current.isDark
    val plateColor = if (isDark) {
        MaterialTheme.colorScheme.surfaceContainerHigh
    } else {
        MaterialTheme.colorScheme.surfaceContainerLow
    }
    val hatchColor = if (isDark) Color.White.copy(alpha = 0.045f) else Color.Black.copy(alpha = 0.045f)
    val cardColor = MaterialTheme.colorScheme.surfaceContainerLowest
    val strokeColor = MaterialTheme.colorScheme.outlineVariant
    val accent = MaterialTheme.colorScheme.primary
    val positive = LocalCharkleExtendedColors.current.positive

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 32.dp, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier
                .size(width = 160.dp, height = 120.dp)
                .drawWithCache {
                    val corner = 18.dp.toPx()
                    val strokePx = 1.dp.toPx()
                    val stroke = Stroke(width = strokePx)
                    val clip = Path().apply {
                        addRoundRect(
                            RoundRect(
                                left = 0f,
                                top = 0f,
                                right = size.width,
                                bottom = size.height,
                                cornerRadius = CornerRadius(corner, corner)
                            )
                        )
                    }
                    val step = 10.dp.toPx()
                    val pad = 18.dp.toPx()
                    val w = size.width - pad * 2
                    val h = size.height - pad * 2
                    val cardR = CornerRadius(8.dp.toPx(), 8.dp.toPx())
                    val plateCorner = CornerRadius(corner, corner)
                    val searchBarCorner = CornerRadius(9.dp.toPx(), 9.dp.toPx())
                    val inboxCorner = CornerRadius(12.dp.toPx(), 12.dp.toPx())
                    val connectorWidth = 2.dp.toPx()
                    val dotRadius = 5.dp.toPx()
                    val haloRadius = 16.dp.toPx()

                    onDrawBehind {
                        clipPath(clip) {
                            drawRect(color = plateColor)
                            var x = -size.height
                            while (x < size.width + size.height) {
                                drawLine(
                                    color = hatchColor,
                                    start = Offset(x, size.height),
                                    end = Offset(x + size.height, 0f),
                                    strokeWidth = strokePx
                                )
                                x += step
                            }
                        }
                        drawRoundRect(
                            color = strokeColor,
                            cornerRadius = plateCorner,
                            style = stroke
                        )

                        when (kind) {
                            EmptyVignetteKind.EmptyLibrary, EmptyVignetteKind.EmptyFolder -> {
                                drawRoundRect(cardColor, Offset(pad, pad), Size(w * 0.45f, h * 0.62f), cardR)
                                drawRoundRect(strokeColor, Offset(pad, pad), Size(w * 0.45f, h * 0.62f), cardR, style = stroke)
                                drawRoundRect(cardColor, Offset(pad + w * 0.52f, pad), Size(w * 0.48f, h * 0.40f), cardR)
                                drawRoundRect(strokeColor, Offset(pad + w * 0.52f, pad), Size(w * 0.48f, h * 0.40f), cardR, style = stroke)
                                drawRoundRect(accent.copy(alpha = 0.16f), Offset(pad + w * 0.52f, pad + h * 0.48f), Size(w * 0.48f, h * 0.52f), cardR)
                                drawCircle(accent, radius = dotRadius, center = Offset(pad + w * 0.76f, pad + h * 0.74f))
                            }
                            EmptyVignetteKind.InboxZero -> {
                                drawRoundRect(cardColor, Offset(pad + w * 0.14f, pad + h * 0.14f), Size(w * 0.72f, h * 0.72f), inboxCorner)
                                drawRoundRect(strokeColor, Offset(pad + w * 0.14f, pad + h * 0.14f), Size(w * 0.72f, h * 0.72f), inboxCorner, style = stroke)
                                drawCircle(positive.copy(alpha = 0.16f), radius = haloRadius, center = center)
                                drawCircle(positive, radius = dotRadius, center = center)
                            }
                            EmptyVignetteKind.NoResults -> {
                                drawRoundRect(cardColor, Offset(pad, pad + 6.dp.toPx()), Size(w, 18.dp.toPx()), searchBarCorner)
                                drawRoundRect(strokeColor, Offset(pad, pad + 6.dp.toPx()), Size(w, 18.dp.toPx()), searchBarCorner, style = stroke)
                                drawRoundRect(cardColor, Offset(pad, pad + 34.dp.toPx()), Size(w * 0.46f, h * 0.46f), cardR)
                                drawRoundRect(strokeColor, Offset(pad, pad + 34.dp.toPx()), Size(w * 0.46f, h * 0.46f), cardR, style = stroke)
                                drawRoundRect(cardColor, Offset(pad + w * 0.54f, pad + 34.dp.toPx()), Size(w * 0.46f, h * 0.46f), cardR)
                                drawRoundRect(strokeColor, Offset(pad + w * 0.54f, pad + 34.dp.toPx()), Size(w * 0.46f, h * 0.46f), cardR, style = stroke)
                            }
                            EmptyVignetteKind.EmptyMoodboard -> {
                                drawRoundRect(cardColor, Offset(pad, pad + 8.dp.toPx()), Size(w * 0.44f, h * 0.58f), cardR)
                                drawRoundRect(strokeColor, Offset(pad, pad + 8.dp.toPx()), Size(w * 0.44f, h * 0.58f), cardR, style = stroke)
                                drawRoundRect(accent.copy(alpha = 0.15f), Offset(pad + w * 0.50f, pad + 20.dp.toPx()), Size(w * 0.46f, h * 0.52f), cardR)
                                drawLine(accent, Offset(pad + w * 0.44f, pad + h * 0.36f), Offset(pad + w * 0.50f, pad + h * 0.46f), strokeWidth = connectorWidth)
                            }
                        }
                    }
                }
        )

        Spacer(Modifier.height(18.dp))
        Text(
            text = title,
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface,
            textAlign = TextAlign.Center
        )
        Spacer(Modifier.height(6.dp))
        Text(
            text = subtitle,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
        if (!actionLabel.isNullOrBlank() && onAction != null) {
            Spacer(Modifier.height(16.dp))
            Button(onClick = onAction) {
                Text(actionLabel)
            }
        }
    }
}
