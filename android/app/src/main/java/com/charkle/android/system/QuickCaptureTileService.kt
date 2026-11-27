package com.charkle.android.system

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.charkle.android.MainActivity

/**
 * Android Quick Settings Tile ("Charkle 闪采"):
 * 1-tap from the system notification shade launches Charkle directly into the Quick Capture modal
 * for clipboard links, photos, and visual references.
 */
class QuickCaptureTileService : TileService() {

    override fun onTileAdded() {
        super.onTileAdded()
        syncTilePresentation()
    }

    override fun onStartListening() {
        super.onStartListening()
        syncTilePresentation()
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) {
            unlockAndRun { launchQuickCapture() }
        } else {
            launchQuickCapture()
        }
    }

    private fun syncTilePresentation() {
        qsTile?.apply {
            state = Tile.STATE_INACTIVE
            label = "Charkle 闪采"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                subtitle = "快速收藏灵感"
            }
            updateTile()
        }
    }

    private fun launchQuickCapture() {
        val intent = Intent(this, MainActivity::class.java).apply {
            action = MainActivity.ACTION_QUICK_CAPTURE
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra(MainActivity.EXTRA_OPEN_CAPTURE, true)
        }
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val pendingIntent = PendingIntent.getActivity(
                    this,
                    REQUEST_CODE_QUICK_CAPTURE,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                startActivityAndCollapse(pendingIntent)
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
        }
    }

    companion object {
        private const val REQUEST_CODE_QUICK_CAPTURE = 4011
    }
}
