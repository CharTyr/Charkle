package com.charkle.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.charkle.android.ui.shell.AdaptiveRootShell

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val app = application as CharkleApplication
        if (savedInstanceState == null) {
            handleLaunchIntent(intent, app)
        }

        setContent {
            AdaptiveRootShell(store = app.store)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val app = application as CharkleApplication
        handleLaunchIntent(intent, app)
    }

    private fun handleLaunchIntent(incoming: Intent?, app: CharkleApplication) {
        if (incoming == null) return
        if ((incoming.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return

        var consumed = false

        if (incoming.action == ACTION_QUICK_CAPTURE ||
            incoming.getBooleanExtra(EXTRA_OPEN_CAPTURE, false)
        ) {
            app.store.requestOpenCaptureFromIntent()
            consumed = true
        }

        val uri = incoming.data
        val assetIdFromExtra = incoming.getStringExtra(EXTRA_OPEN_ASSET_ID)?.trim()
        val assetIdFromUri = if (uri?.scheme == SCHEME_CHARKLE && uri.host == HOST_ASSET) {
            uri.lastPathSegment?.trim()
        } else {
            null
        }
        val targetAssetId = assetIdFromExtra?.takeIf { it.isNotEmpty() }
            ?: assetIdFromUri?.takeIf { it.isNotEmpty() }
        if (targetAssetId != null) {
            app.store.requestOpenAssetFromIntent(targetAssetId)
            consumed = true
        }

        if (uri != null && uri.scheme == SCHEME_CHARKLE && uri.host == HOST_OAUTH) {
            app.store.handleOAuthRedirectUri(uri)
            consumed = true
        }

        if (consumed) {
            // Strip consumed deep-link extras/data so rotation or activity recreation never replays them.
            val sanitized = Intent(incoming).apply {
                removeExtra(EXTRA_OPEN_CAPTURE)
                removeExtra(EXTRA_OPEN_ASSET_ID)
                if (action == ACTION_QUICK_CAPTURE || action == ACTION_OPEN_ASSET) {
                    action = Intent.ACTION_MAIN
                }
                if (data?.scheme == SCHEME_CHARKLE) {
                    data = null
                }
            }
            setIntent(sanitized)
        }
    }

    companion object {
        const val ACTION_QUICK_CAPTURE = "com.charkle.android.ACTION_QUICK_CAPTURE"
        const val ACTION_OPEN_ASSET = "com.charkle.android.ACTION_OPEN_ASSET"
        const val EXTRA_OPEN_CAPTURE = "com.charkle.android.EXTRA_OPEN_CAPTURE"
        const val EXTRA_OPEN_ASSET_ID = "com.charkle.android.EXTRA_OPEN_ASSET_ID"
        private const val SCHEME_CHARKLE = "charkle-android"
        private const val HOST_OAUTH = "oauth"
        private const val HOST_ASSET = "asset"
    }
}
