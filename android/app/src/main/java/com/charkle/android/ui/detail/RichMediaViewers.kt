package com.charkle.android.ui.detail

import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Forward10
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Replay10
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import coil3.compose.AsyncImage
import com.charkle.android.core.AssetDto
import com.charkle.android.designsystem.CharkleExpressiveLoader
import com.charkle.android.designsystem.CharkleWavyProgress
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Native Media3 ExoPlayer video stage for Quick Look.
 * Respects HorizontalPager active page state and Android Activity lifecycle so off-screen
 * or backgrounded videos always pause and release cleanly without leaking codecs.
 */
@Composable
fun VideoPlayerStage(
    file: File,
    isActivePage: Boolean = true,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val latestIsActivePage by rememberUpdatedState(isActivePage)

    val player = remember(file.absolutePath) {
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
            prepare()
            playWhenReady = isActivePage
        }
    }

    LaunchedEffect(player, isActivePage) {
        if (isActivePage) {
            player.playWhenReady = true
        } else {
            player.pause()
            player.playWhenReady = false
        }
    }

    DisposableEffect(lifecycleOwner, player) {
        var resumeOnForeground = false
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_PAUSE -> {
                    if (player.isPlaying || player.playWhenReady) {
                        resumeOnForeground = true
                    }
                    player.pause()
                }
                Lifecycle.Event.ON_STOP -> {
                    player.pause()
                }
                Lifecycle.Event.ON_RESUME -> {
                    if (resumeOnForeground && latestIsActivePage) {
                        player.play()
                    }
                    resumeOnForeground = false
                }
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            player.release()
        }
    }

    AndroidView(
        factory = { ctx ->
            PlayerView(ctx).apply {
                this.player = player
                useController = true
            }
        },
        update = { view ->
            if (view.player !== player) {
                view.player = player
            }
        },
        onRelease = { view ->
            view.player = null
        },
        modifier = modifier
            .fillMaxSize()
            .clip(RoundedCornerShape(24.dp))
    )
}

/**
 * Material 3 Expressive Audio Player featuring `LinearWavyProgressIndicator` +
 * iconic pill/squircle transport controls matching our M3 Expressive design direction.
 * Pauses cleanly on pager page switch and Activity backgrounding; polls position only while playing.
 */
@Composable
fun AudioWavyPlayerStage(
    asset: AssetDto,
    file: File,
    isActivePage: Boolean = true,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    val player = remember(file.absolutePath) {
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
            prepare()
        }
    }

    var isPlaying by remember(player) { mutableStateOf(false) }
    var positionMs by remember(player) { mutableLongStateOf(0L) }
    var durationMs by remember(player) {
        mutableLongStateOf(((asset.durationSeconds ?: 0.0) * 1000.0).toLong())
    }

    LaunchedEffect(player, isActivePage) {
        if (!isActivePage && player.isPlaying) {
            player.pause()
        }
    }

    DisposableEffect(lifecycleOwner, player) {
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(playing: Boolean) {
                isPlaying = playing
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                if (player.duration > 0L) durationMs = player.duration
                positionMs = player.currentPosition.coerceAtLeast(0L)
                isPlaying = player.isPlaying
            }
        }
        player.addListener(listener)

        val lifecycleObserver = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_PAUSE || event == Lifecycle.Event.ON_STOP) {
                player.pause()
            }
        }
        lifecycleOwner.lifecycle.addObserver(lifecycleObserver)

        onDispose {
            lifecycleOwner.lifecycle.removeObserver(lifecycleObserver)
            player.removeListener(listener)
            player.release()
        }
    }

    LaunchedEffect(player, isPlaying) {
        if (player.duration > 0L) durationMs = player.duration
        positionMs = player.currentPosition.coerceAtLeast(0L)
        while (isPlaying) {
            positionMs = player.currentPosition.coerceAtLeast(0L)
            if (player.duration > 0L) durationMs = player.duration
            delay(200)
        }
    }

    val progress = if (durationMs > 0L) (positionMs.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f) else 0f

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(22.dp)
    ) {
        Surface(
            shape = RoundedCornerShape(32.dp),
            color = MaterialTheme.colorScheme.primaryContainer,
            contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
            modifier = Modifier.size(164.dp)
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = Icons.Rounded.GraphicEq,
                    contentDescription = null,
                    modifier = Modifier.size(72.dp)
                )
            }
        }

        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = asset.title,
                style = MaterialTheme.typography.headlineSmall,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center
            )
            Text(
                text = asset.fileName,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }

        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            CharkleWavyProgress(
                progress = progress,
                color = MaterialTheme.colorScheme.primary,
                trackColor = MaterialTheme.colorScheme.primaryContainer
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    formatTimeMs(positionMs),
                    style = MaterialTheme.typography.labelMedium.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    formatTimeMs(durationMs),
                    style = MaterialTheme.typography.labelMedium.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        Row(
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Surface(
                onClick = {
                    val target = (player.currentPosition - 10_000L).coerceAtLeast(0L)
                    player.seekTo(target)
                    positionMs = target
                },
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                modifier = Modifier.size(58.dp)
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Replay10, contentDescription = "后退10秒")
                }
            }
            Surface(
                onClick = {
                    if (player.isPlaying) {
                        player.pause()
                    } else {
                        if (player.playbackState == Player.STATE_ENDED) {
                            player.seekTo(0L)
                        }
                        player.play()
                    }
                },
                shape = RoundedCornerShape(20.dp),
                color = MaterialTheme.colorScheme.primary,
                contentColor = MaterialTheme.colorScheme.onPrimary,
                modifier = Modifier
                    .width(96.dp)
                    .height(64.dp)
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = if (isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                        contentDescription = if (isPlaying) "暂停" else "播放",
                        modifier = Modifier.size(32.dp)
                    )
                }
            }
            Surface(
                onClick = {
                    val maxPos = if (durationMs > 0L) durationMs else Long.MAX_VALUE
                    val target = (player.currentPosition + 10_000L).coerceAtMost(maxPos)
                    player.seekTo(target)
                    positionMs = target
                },
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                modifier = Modifier.size(58.dp)
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Forward10, contentDescription = "前进10秒")
                }
            }
        }
    }
}

/**
 * Thread-safe, OOM-protected on-demand PDF renderer backed by a memory-bounded LruCache.
 * Decodes only visible pages on [Dispatchers.IO], caps per-page bitmap size, and closes
 * native [PdfRenderer] + [ParcelFileDescriptor] deterministically under a [Mutex].
 */
private class PdfDocumentSession(
    private val pfd: ParcelFileDescriptor,
    private val renderer: PdfRenderer
) {
    val pageCount: Int = renderer.pageCount

    private val mutex = Mutex()
    @Volatile
    private var closed = false

    // Bound in-memory decoded pages to ~24 MB total to eliminate OOM on long PDFs.
    private val bitmapCache = object : LruCache<Int, Bitmap>(24 * 1024) {
        override fun sizeOf(key: Int, value: Bitmap): Int = (value.byteCount / 1024).coerceAtLeast(1)
    }

    fun getCachedPage(pageIndex: Int): Bitmap? {
        if (closed) return null
        return synchronized(bitmapCache) { bitmapCache.get(pageIndex) }
    }

    suspend fun renderPage(pageIndex: Int): Bitmap? = withContext(Dispatchers.IO) {
        if (closed || pageIndex !in 0 until pageCount) return@withContext null
        getCachedPage(pageIndex)?.let { return@withContext it }

        mutex.withLock {
            if (closed) return@withContext null
            getCachedPage(pageIndex)?.let { return@withContext it }
            ensureActive()

            var uncommitted: Bitmap? = null
            try {
                renderer.openPage(pageIndex).use { page ->
                    val rawW = page.width.coerceAtLeast(1).toFloat()
                    val rawH = page.height.coerceAtLeast(1).toFloat()
                    val scale = min(MAX_PAGE_WIDTH_PX / rawW, MAX_PAGE_HEIGHT_PX / rawH)
                        .coerceAtMost(3f)
                    val targetW = (rawW * scale).roundToInt().coerceIn(1, MAX_PAGE_WIDTH_PX)
                    val targetH = (rawH * scale).roundToInt().coerceIn(1, MAX_PAGE_HEIGHT_PX)

                    val bmp = Bitmap.createBitmap(targetW, targetH, Bitmap.Config.ARGB_8888)
                    uncommitted = bmp
                    bmp.eraseColor(android.graphics.Color.WHITE)
                    page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    ensureActive()

                    synchronized(bitmapCache) {
                        if (!closed) {
                            bitmapCache.put(pageIndex, bmp)
                            uncommitted = null
                        }
                    }
                    if (uncommitted != null) {
                        bmp.recycle()
                        null
                    } else {
                        bmp
                    }
                }
            } catch (_: Throwable) {
                uncommitted?.recycle()
                null
            }
        }
    }

    fun closeAsyncSafe() {
        closed = true
        synchronized(bitmapCache) {
            bitmapCache.evictAll()
        }
        // Try immediate close if uncontended; otherwise schedule background close once render finishes.
        if (mutex.tryLock()) {
            try {
                runCatching { renderer.close() }
                runCatching { pfd.close() }
            } finally {
                mutex.unlock()
            }
        } else {
            Thread {
                kotlinx.coroutines.runBlocking {
                    mutex.withLock {
                        runCatching { renderer.close() }
                        runCatching { pfd.close() }
                    }
                }
            }.start()
        }
    }

    companion object {
        private const val MAX_PAGE_WIDTH_PX = 1080
        private const val MAX_PAGE_HEIGHT_PX = 2160

        fun open(file: File): PdfDocumentSession? {
            var pfd: ParcelFileDescriptor? = null
            var renderer: PdfRenderer? = null
            return try {
                pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                renderer = PdfRenderer(pfd)
                PdfDocumentSession(pfd, renderer)
            } catch (_: Throwable) {
                runCatching { renderer?.close() }
                runCatching { pfd?.close() }
                null
            }
        }
    }
}

/**
 * Native Android PdfRenderer viewer for multi-page PDF documents with lazy background rendering
 * and memory-bounded page caching.
 */
@Composable
fun PdfDocumentStage(
    file: File,
    modifier: Modifier = Modifier
) {
    var session by remember(file.absolutePath) { mutableStateOf<PdfDocumentSession?>(null) }
    var loadFailed by remember(file.absolutePath) { mutableStateOf(false) }

    LaunchedEffect(file.absolutePath) {
        loadFailed = false
        val opened = withContext(Dispatchers.IO) {
            PdfDocumentSession.open(file)
        }
        if (opened == null || opened.pageCount <= 0) {
            opened?.closeAsyncSafe()
            loadFailed = true
        } else {
            session = opened
        }
    }

    DisposableEffect(session) {
        val current = session
        onDispose {
            current?.closeAsyncSafe()
        }
    }

    val activeSession = session
    when {
        loadFailed -> {
            Column(
                modifier = modifier
                    .fillMaxSize()
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Icon(
                    imageVector = Icons.Rounded.ErrorOutline,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(36.dp)
                )
                Spacer(Modifier.height(10.dp))
                Text(
                    text = "无法预览此 PDF 文档",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    text = "文件可能已损坏或受密码保护。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
        activeSession == null -> {
            Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CharkleExpressiveLoader()
            }
        }
        else -> {
            LazyColumn(
                modifier = modifier.fillMaxSize(),
                contentPadding = PaddingValues(12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                items(
                    count = activeSession.pageCount,
                    key = { idx -> "${file.absolutePath}:$idx" }
                ) { idx ->
                    PdfPageCard(
                        session = activeSession,
                        pageIndex = idx,
                        totalPages = activeSession.pageCount
                    )
                }
            }
        }
    }
}

@Composable
private fun PdfPageCard(
    session: PdfDocumentSession,
    pageIndex: Int,
    totalPages: Int
) {
    val cached = remember(session, pageIndex) { session.getCachedPage(pageIndex) }
    val bitmap by produceState(initialValue = cached, key1 = session, key2 = pageIndex) {
        if (value == null) {
            value = session.renderPage(pageIndex)
        }
    }

    val bmp = bitmap
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color.White)
    ) {
        if (bmp != null) {
            val imageBitmap = remember(bmp) { bmp.asImageBitmap() }
            Image(
                bitmap = imageBitmap,
                contentDescription = "PDF 第 ${pageIndex + 1} 页",
                contentScale = ContentScale.FillWidth,
                modifier = Modifier.fillMaxWidth()
            )
        } else {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(0.707f)
                    .background(MaterialTheme.colorScheme.surfaceContainer),
                contentAlignment = Alignment.Center
            ) {
                CharkleExpressiveLoader()
            }
        }

        if (totalPages > 1) {
            Surface(
                shape = CircleShape,
                color = Color.Black.copy(alpha = 0.52f),
                contentColor = Color.White,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(10.dp)
            ) {
                Text(
                    text = "${pageIndex + 1} / $totalPages",
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                )
            }
        }
    }
}

/**
 * Editorial rich preview card for Social Posts, GitHub Repositories, and Markdown / Text documents.
 */
@Composable
fun RichEditorialCardStage(
    asset: AssetDto,
    coverFile: File?,
    onOpenSourceUrl: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    val rich = asset.richMetadata
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 18.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        if (coverFile != null) {
            AsyncImage(
                model = coverFile,
                contentDescription = asset.title,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(asset.aspectRatio.coerceIn(0.6f, 1.8f))
                    .clip(RoundedCornerShape(22.dp))
            )
        }

        Surface(
            shape = RoundedCornerShape(22.dp),
            color = MaterialTheme.colorScheme.surfaceContainerLowest,
            contentColor = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(
                modifier = Modifier.padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text(
                    asset.displayTypeLabel,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary
                )
                Text(
                    asset.title,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface
                )

                rich?.socialPost?.let { post ->
                    val authorLine = listOfNotNull(
                        post.authorName?.takeIf { it.isNotBlank() },
                        post.authorHandle?.takeIf { it.isNotBlank() }?.let { "@$it" }
                    ).joinToString(" · ")
                    if (authorLine.isNotBlank()) {
                        Text(
                            authorLine,
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    post.text?.takeIf { it.isNotBlank() }?.let {
                        Text(it, style = MaterialTheme.typography.bodyMedium)
                    }
                }

                rich?.githubRepo?.let { repo ->
                    if (repo.fullName.isNotBlank()) {
                        Text(
                            repo.fullName,
                            style = MaterialTheme.typography.labelLarge.copy(fontFamily = FontFamily.Monospace)
                        )
                    }
                    repo.description?.takeIf { it.isNotBlank() }?.let {
                        Text(it, style = MaterialTheme.typography.bodyMedium)
                    }
                    val meta = listOfNotNull(
                        repo.language,
                        repo.stars?.let { "★ $it" }
                    ).joinToString(" · ")
                    if (meta.isNotBlank()) {
                        Text(
                            meta,
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }

                rich?.textExcerpt?.takeIf { it.isNotBlank() }?.let { excerpt ->
                    Text(excerpt, style = MaterialTheme.typography.bodyMedium)
                }

                asset.sourceUrl?.takeIf { it.isNotBlank() }?.let { url ->
                    Spacer(Modifier.height(4.dp))
                    Button(onClick = { onOpenSourceUrl(url) }) {
                        Icon(
                            Icons.AutoMirrored.Rounded.OpenInNew,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp)
                        )
                        Spacer(Modifier.width(6.dp))
                        Text("在浏览器中打开原链接")
                    }
                }
            }
        }
    }
}

private fun formatTimeMs(ms: Long): String {
    val totalSec = (ms / 1000L).coerceAtLeast(0L)
    val min = totalSec / 60L
    val sec = totalSec % 60L
    return String.format(Locale.US, "%d:%02d", min, sec)
}
