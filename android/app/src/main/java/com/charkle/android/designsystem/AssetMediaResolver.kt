package com.charkle.android.designsystem

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import com.charkle.android.store.CharkleAppStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Lock-free thumbnail lookup synchronized with [CharkleAppStore]'s background media path prefetch
 * (`mediaCacheRevision`). Performs zero FFI or disk I/O on the Compose main thread.
 */
@Composable
fun rememberAssetThumbnailFile(
    store: CharkleAppStore,
    assetId: String,
    updatedAt: Double = 0.0,
    previewTier: Boolean = false
): File? {
    val mediaRevision by remember(store) {
        store.state.map { it.mediaCacheRevision }.distinctUntilChanged()
    }.collectAsState(initial = store.state.value.mediaCacheRevision)

    return remember(store, assetId, updatedAt, previewTier, mediaRevision) {
        store.thumbnailFile(assetId, previewTier = previewTier)
    }
}

/**
 * Resolves the highest-fidelity display file for an asset without blocking the main thread:
 * immediately observes cached thumbnail/original via `mediaCacheRevision`, then upgrades
 * asynchronously to the original file on [Dispatchers.IO].
 */
@Composable
fun rememberAssetPreviewFile(
    store: CharkleAppStore,
    assetId: String,
    updatedAt: Double = 0.0,
    upgradeToOriginal: Boolean = true
): File? {
    val mediaRevision by remember(store) {
        store.state.map { it.mediaCacheRevision }.distinctUntilChanged()
    }.collectAsState(initial = store.state.value.mediaCacheRevision)

    val fastLocal = remember(store, assetId, updatedAt, mediaRevision) {
        store.originalOrThumbFile(assetId)
    }
    val requestKey = remember(assetId, updatedAt, upgradeToOriginal) {
        Triple(assetId, updatedAt, upgradeToOriginal)
    }

    val upgraded by produceState<File?>(
        initialValue = fastLocal,
        key1 = store,
        key2 = requestKey
    ) {
        if (!upgradeToOriginal) return@produceState
        val fullOrig = withContext(Dispatchers.IO) {
            store.resolveOriginalFile(assetId)
        }
        if (fullOrig != null) {
            value = fullOrig
        }
    }
    return upgraded ?: fastLocal
}
