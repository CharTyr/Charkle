package com.charkle.android.system

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.charkle.android.CharkleApplication
import com.charkle.android.core.DriveSyncConfigDto
import java.util.concurrent.TimeUnit

internal fun hasActiveSyncTarget(config: DriveSyncConfigDto): Boolean {
    if (config.backends.isEmpty()) {
        return config.mode != "localOnly" || config.localLibraryPath.isNotBlank()
    }
    return config.backends.any { backend ->
        backend.isEnabled && (backend.mode != "localOnly" || backend.localLibraryPath.isNotBlank())
    }
}

internal fun shouldRetrySyncError(error: Throwable, runAttemptCount: Int): Boolean {
    if (runAttemptCount >= 3) return false
    val msg = error.message.orEmpty().lowercase()
    val isPermanent = msg.contains("not configured") ||
        msg.contains("未配置") ||
        msg.contains("缺少") ||
        msg.contains("authentication") ||
        msg.contains("unauthorized") ||
        msg.contains("授权") ||
        msg.contains("invalid argument") ||
        msg.contains("纯本地保存模式")
    return !isPermanent
}

/**
 * Periodic background incremental sync worker respecting connected network and battery health.
 */
class CharkleSyncWorker(
    appContext: Context,
    params: WorkerParameters
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val app = applicationContext as? CharkleApplication ?: return Result.success()
        val config = runCatching { app.repository.syncConfig() }.getOrNull() ?: return Result.success()
        if (!hasActiveSyncTarget(config)) return Result.success()

        return runCatching {
            val report = app.repository.syncNow()
            if (report.pulledOps > 0 || report.discoveredRemoteAssets > 0 || report.downloadedThumbnails > 0) {
                InspirationGlanceWidget.updateAllWidgets(applicationContext)
            }
            Result.success()
        }.getOrElse { error ->
            if (shouldRetrySyncError(error, runAttemptCount)) Result.retry() else Result.failure()
        }
    }

    companion object {
        private const val WORK_NAME = "charkle_periodic_sync"

        fun schedule(context: Context, intervalMinutes: Long) {
            val wm = WorkManager.getInstance(context)
            if (intervalMinutes <= 0L) {
                wm.cancelUniqueWork(WORK_NAME)
                return
            }
            val safeMinutes = intervalMinutes.coerceAtLeast(15L)
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .setRequiresBatteryNotLow(true)
                .build()
            val request = PeriodicWorkRequestBuilder<CharkleSyncWorker>(safeMinutes, TimeUnit.MINUTES)
                .setConstraints(constraints)
                .build()
            wm.enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.UPDATE,
                request
            )
        }
    }
}
