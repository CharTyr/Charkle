package com.charkle.android

import com.charkle.android.core.AndroidSecretVaultImpl
import com.charkle.android.core.AssetDto
import com.charkle.android.core.CachedMediaPathsDto
import com.charkle.android.core.DriveSyncConfigDto
import com.charkle.android.core.FilterCriteriaDto
import com.charkle.android.core.FolderDto
import com.charkle.android.core.SyncBackendProfileDto
import com.charkle.android.core.VaultBackingStore
import com.charkle.android.core.VaultKeyProvider
import com.charkle.android.store.LibraryScope
import com.charkle.android.store.MediaPathCache
import com.charkle.android.store.OAuthRedirectResult
import com.charkle.android.store.PendingPkceSession
import com.charkle.android.store.buildEffectiveCriteria
import com.charkle.android.store.collectFolderSubtreeIds
import com.charkle.android.store.evaluateOAuthRedirect
import com.charkle.android.store.sanitizeStagedFileName
import com.charkle.android.system.calculateWidgetInSampleSize
import com.charkle.android.system.hasActiveSyncTarget
import com.charkle.android.system.pickWidgetAsset
import com.charkle.android.system.shouldRetrySyncError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.UnrecoverableKeyException
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

class CharkleCoreHardeningTest {

    private class InMemoryVaultStore : VaultBackingStore {
        val data = mutableMapOf<String, String>()
        override fun getString(key: String): String? = data[key]
        override fun putString(key: String, value: String) {
            data[key] = value
        }
        override fun remove(key: String) {
            data.remove(key)
        }
        override fun clearAll() {
            data.clear()
        }
    }

    private class TestAesKeyProvider : VaultKeyProvider {
        var failNextGetWithKeyError: Boolean = false
        var resetCount: Int = 0
        private var currentKey: SecretKey = generateAes256()

        override fun getOrCreateKey(): SecretKey {
            if (failNextGetWithKeyError) {
                failNextGetWithKeyError = false
                throw UnrecoverableKeyException("Simulated Keystore invalidation")
            }
            return currentKey
        }

        override fun resetAndCreateKey(): SecretKey {
            resetCount += 1
            currentKey = generateAes256()
            return currentKey
        }

        fun rotateKeySilently() {
            currentKey = generateAes256()
        }

        private fun generateAes256(): SecretKey {
            val gen = KeyGenerator.getInstance("AES")
            gen.init(256)
            return gen.generateKey()
        }
    }

    @Test
    fun secretVaultRoundTripsAndRecoversFromCorruptionAndKeyInvalidation() {
        val backing = InMemoryVaultStore()
        val keyProvider = TestAesKeyProvider()
        val vault = AndroidSecretVaultImpl(backing, keyProvider)

        vault.setSecret("oauth.token", "令牌-abc-123")
        assertEquals("令牌-abc-123", vault.getSecret("oauth.token"))

        // Corrupted Base64 or truncated payload returns null and cleans up dead entry
        backing.putString("bad.entry", "!!!not-base64!!!")
        assertNull(vault.getSecret("bad.entry"))
        assertFalse(backing.data.containsKey("bad.entry"))

        // Simulate Auto-Backup restored ciphertext encrypted under a different hardware key
        keyProvider.rotateKeySilently()
        assertNull(vault.getSecret("oauth.token"))
        assertFalse("Unreadable foreign ciphertext must be purged", backing.data.containsKey("oauth.token"))

        // Simulate Keystore invalidation during setSecret -> self-heals by rotating key once
        keyProvider.failNextGetWithKeyError = true
        vault.setSecret("webdav.pass", "s3cr3t!")
        assertEquals(1, keyProvider.resetCount)
        assertEquals("s3cr3t!", vault.getSecret("webdav.pass"))

        // Simulate Keystore invalidation during getSecret -> does not crash, clears & rotates cleanly
        keyProvider.failNextGetWithKeyError = true
        assertNull(vault.getSecret("webdav.pass"))
        assertEquals(2, keyProvider.resetCount)
        assertTrue(backing.data.isEmpty())
    }

    @Test
    fun mediaPathCacheNormalizesUuidCaseAndHandlesEviction() {
        val cache = MediaPathCache(maxEntries = 4)
        val upper = "11111111-2222-3333-4444-555555555555"
        val lower = upper.lowercase()

        cache.putAll(
            mapOf(
                upper to CachedMediaPathsDto(
                    gridThumbPath = "/cache/Thumbnails/$upper.jpg",
                    previewThumbPath = "/cache/Previews/$upper.jpg",
                    originalPath = "/cache/Originals/$upper.png"
                )
            )
        )

        assertTrue(cache.contains(lower))
        assertEquals("/cache/Thumbnails/$upper.jpg", cache.thumbnailPath(lower, previewTier = false))
        assertEquals("/cache/Previews/$upper.jpg", cache.thumbnailPath(lower, previewTier = true))
        assertEquals("/cache/Originals/$upper.png", cache.originalOrThumbPath(lower))

        cache.clearOriginalPaths()
        assertEquals("/cache/Previews/$upper.jpg", cache.originalOrThumbPath(lower))
        assertEquals("/cache/Thumbnails/$upper.jpg", cache.thumbnailPath(lower, previewTier = false))

        cache.markResolvedEmpty(listOf("22222222-2222-2222-2222-222222222222"), emptyMap())
        assertTrue(cache.contains("22222222-2222-2222-2222-222222222222"))
        assertNull(cache.thumbnailPath("22222222-2222-2222-2222-222222222222", false))
    }

    @Test
    fun effectiveCriteriaResetsStaleScopeFlagsAcrossScopes() {
        val dirtyBase = FilterCriteriaDto(
            searchQuery = "poster",
            selectedColorHex = "#D4A373",
            onlyInbox = true,
            onlyUntagged = true,
            onlyRecentDays = 7,
            onlyTrashed = true,
            includeTrashed = true,
            folderId = "OLD-FOLDER"
        )

        val all = buildEffectiveCriteria(LibraryScope.AllItems, dirtyBase)
        assertEquals("poster", all.searchQuery)
        assertEquals("#D4A373", all.selectedColorHex)
        assertFalse(all.onlyInbox)
        assertFalse(all.onlyUntagged)
        assertNull(all.onlyRecentDays)
        assertFalse(all.onlyTrashed)
        assertFalse(all.includeTrashed)
        assertNull(all.folderId)

        val trash = buildEffectiveCriteria(LibraryScope.Trash, dirtyBase)
        assertTrue(trash.onlyTrashed)
        assertTrue(trash.includeTrashed)
        assertFalse(trash.onlyInbox)
        assertNull(trash.onlyRecentDays)

        val smart = buildEffectiveCriteria(LibraryScope.SmartFolder("SF-1"), dirtyBase)
        assertFalse(smart.onlyTrashed)
        assertFalse(smart.includeTrashed)
        assertNull(smart.folderId)
        assertEquals("poster", smart.searchQuery)
    }

    @Test
    fun folderSubtreeCollectionHandlesCyclesAndNestedDescendants() {
        val folders = listOf(
            FolderDto(id = "aaa", name = "Root", parentId = null),
            FolderDto(id = "bbb", name = "Child", parentId = "AAA"),
            FolderDto(id = "ccc", name = "GrandChild", parentId = "bbb"),
            FolderDto(id = "ddd", name = "CycleBack", parentId = "CCC")
        )
        val subtree = collectFolderSubtreeIds("aaa", folders)
        assertEquals(setOf("AAA", "BBB", "CCC", "DDD"), subtree)
    }

    @Test
    fun oauthRedirectEvaluationCoversCancelExpiryMismatchAndSuccess() {
        val session = PendingPkceSession(
            codeVerifier = "verifier_123",
            state = "state_abc",
            redirectUri = "charkle-android://oauth/callback",
            expiresAtMs = 10_000L
        )

        val denied = evaluateOAuthRedirect(null, "state_abc", "access_denied", session, 5_000L)
        assertTrue(denied is OAuthRedirectResult.Failed && denied.clearSession)

        val mismatch = evaluateOAuthRedirect("code_1", "wrong_state", null, session, 5_000L)
        assertTrue(mismatch is OAuthRedirectResult.Failed && !mismatch.clearSession)

        val expired = evaluateOAuthRedirect("code_1", "state_abc", null, session, 20_000L)
        assertTrue(expired is OAuthRedirectResult.Failed && expired.clearSession)

        val missingSession = evaluateOAuthRedirect("code_1", "state_abc", null, null, 5_000L)
        assertTrue(missingSession is OAuthRedirectResult.Failed)

        val ok = evaluateOAuthRedirect(" code_1 ", "state_abc", null, session, 9_000L)
        assertTrue(ok is OAuthRedirectResult.Authorized)
        assertEquals("code_1", (ok as OAuthRedirectResult.Authorized).code)
    }

    @Test
    fun stagedFileNameSanitizationPreservesChineseAndDerivesExtension() {
        assertEquals("建筑参考.png", sanitizeStagedFileName("建筑参考.png", "jpeg"))
        assertEquals("海报参考.webp", sanitizeStagedFileName("海报参考", "webp"))
        assertEquals("evil.png", sanitizeStagedFileName("../../evil.png", "png"))
        assertEquals("capture_123.pdf", sanitizeStagedFileName(null, "pdf", fallbackTimestampMs = 123L))
    }

    @Test
    fun syncWorkerTargetAndRetryPoliciesAreAccurate() {
        assertFalse(hasActiveSyncTarget(DriveSyncConfigDto(mode = "localOnly", localLibraryPath = "")))
        assertTrue(hasActiveSyncTarget(DriveSyncConfigDto(mode = "localOnly", localLibraryPath = "/storage/emulated/0/Charkle")))
        assertTrue(
            hasActiveSyncTarget(
                DriveSyncConfigDto(
                    mode = "localOnly",
                    backends = listOf(
                        SyncBackendProfileDto(id = "1", mode = "webDAV", isEnabled = true)
                    )
                )
            )
        )
        assertFalse(
            hasActiveSyncTarget(
                DriveSyncConfigDto(
                    mode = "localOnly",
                    backends = listOf(
                        SyncBackendProfileDto(id = "1", mode = "webDAV", isEnabled = false)
                    )
                )
            )
        )

        assertTrue(shouldRetrySyncError(RuntimeException("Connection reset by peer"), runAttemptCount = 0))
        assertFalse(shouldRetrySyncError(RuntimeException("Connection reset by peer"), runAttemptCount = 3))
        assertFalse(shouldRetrySyncError(RuntimeException("Google 授权失败"), runAttemptCount = 0))
        assertFalse(shouldRetrySyncError(RuntimeException("Not configured"), runAttemptCount = 0))
    }

    @Test
    fun widgetBitmapSamplingAndAssetSelectionPreventOomAndRepeats() {
        assertEquals(1, calculateWidgetInSampleSize(400, 300, maxSide = 480))
        assertEquals(2, calculateWidgetInSampleSize(1200, 900, maxSide = 480))
        assertEquals(4, calculateWidgetInSampleSize(3840, 2160, maxSide = 480))
        assertEquals(1, calculateWidgetInSampleSize(0, -10, maxSide = 480))

        val a = AssetDto(id = "AAAA", title = "A")
        val b = AssetDto(id = "BBBB", title = "B")
        assertNull(pickWidgetAsset(emptyList(), null))
        assertEquals(a, pickWidgetAsset(listOf(a), "AAAA"))
        assertEquals(b, pickWidgetAsset(listOf(a, b), "aaaa", picker = { it.first() }))
    }
}
