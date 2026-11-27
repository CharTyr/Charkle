package com.charkle.android

import android.app.Application
import android.os.Build
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.gif.AnimatedImageDecoder
import coil3.gif.GifDecoder
import coil3.request.crossfade
import coil3.svg.SvgDecoder
import com.charkle.android.core.AndroidSecretVaultImpl
import com.charkle.android.core.CharkleRepository
import com.charkle.android.store.CharkleAppStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import uniffi.charkle_android_ffi.AndroidEngineHandle
import java.io.File

class CharkleApplication : Application(), SingletonImageLoader.Factory {

    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private lateinit var engineDeferred: Deferred<AndroidEngineHandle>

    lateinit var vault: AndroidSecretVaultImpl
        private set

    lateinit var repository: CharkleRepository
        private set

    lateinit var store: CharkleAppStore
        private set

    override fun onCreate() {
        super.onCreate()
        val libraryRoot = File(filesDir, "Charkle")
        vault = AndroidSecretVaultImpl(this)
        // Defer native library load, SQLite WAL init, Tokio runtime & TLS setup off the main thread.
        engineDeferred = appScope.async(Dispatchers.IO) {
            libraryRoot.mkdirs()
            AndroidEngineHandle.open(
                dataDir = libraryRoot.absolutePath,
                vault = vault,
                ocr = null
            )
        }
        repository = CharkleRepository(engineDeferred, appScope)
        store = CharkleAppStore(applicationContext, repository, vault)
    }

    suspend fun awaitEngine(): AndroidEngineHandle = engineDeferred.await()

    override fun newImageLoader(context: PlatformContext): ImageLoader {
        return ImageLoader.Builder(context)
            .components {
                add(SvgDecoder.Factory())
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    add(AnimatedImageDecoder.Factory())
                } else {
                    add(GifDecoder.Factory())
                }
            }
            .crossfade(160)
            .build()
    }
}
