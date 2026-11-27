package com.charkle.android.core

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import uniffi.charkle_android_ffi.AndroidSecretVault
import uniffi.charkle_android_ffi.CharkleFfiException
import java.security.GeneralSecurityException
import java.security.InvalidKeyException
import java.security.KeyStore
import java.security.KeyStoreException
import java.security.ProviderException
import java.security.UnrecoverableKeyException
import java.util.Base64
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Minimal key-value backing store abstraction allowing JVM unit testing of vault recovery paths.
 */
internal interface VaultBackingStore {
    fun getString(key: String): String?
    fun putString(key: String, value: String)
    fun remove(key: String)
    fun clearAll()
}

/**
 * Minimal symmetric key provider abstraction decoupling Keystore rotation from crypto framing.
 */
internal interface VaultKeyProvider {
    fun getOrCreateKey(): SecretKey
    fun resetAndCreateKey(): SecretKey
}

private class SharedPrefsVaultBackingStore(
    context: Context,
    private val prefsName: String
) : VaultBackingStore {
    private val appContext = context.applicationContext ?: context
    private val prefs: SharedPreferences by lazy {
        appContext.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
    }

    override fun getString(key: String): String? = prefs.getString(key, null)

    override fun putString(key: String, value: String) {
        prefs.edit().putString(key, value).apply()
    }

    override fun remove(key: String) {
        prefs.edit().remove(key).apply()
    }

    override fun clearAll() {
        prefs.edit().clear().apply()
    }
}

private class AndroidKeyStoreKeyProvider(
    private val keyAlias: String
) : VaultKeyProvider {
    override fun getOrCreateKey(): SecretKey {
        val ks = loadKeyStore()
        val existing = runCatching { ks.getKey(keyAlias, null) as? SecretKey }
            .getOrElse { err ->
                if (isRecoverableKeyError(err)) {
                    return resetAndCreateKey()
                }
                throw err
            }
        if (existing != null) return existing
        return generateKey()
    }

    override fun resetAndCreateKey(): SecretKey {
        runCatching {
            val ks = loadKeyStore()
            if (ks.containsAlias(keyAlias)) {
                ks.deleteEntry(keyAlias)
            }
        }
        return generateKey()
    }

    private fun loadKeyStore(): KeyStore {
        return KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
    }

    private fun generateKey(): SecretKey {
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
        val spec = KeyGenParameterSpec.Builder(
            keyAlias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }

    companion object {
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
    }
}

private fun isRecoverableKeyError(t: Throwable): Boolean {
    return t is KeyPermanentlyInvalidatedException ||
        t is UnrecoverableKeyException ||
        t is InvalidKeyException ||
        t is KeyStoreException ||
        t is ProviderException
}

/**
 * Hardware-backed Android Keystore AES-256-GCM implementation of `charkle-core`'s `SecretVault`.
 *
 * Resilient against Keystore invalidation, OS upgrade key corruption, and Auto-Backup restored
 * ciphertext from a different device (self-healing by purging dead ciphertext and rotating the key).
 */
class AndroidSecretVaultImpl internal constructor(
    private val store: VaultBackingStore,
    private val keyProvider: VaultKeyProvider
) : AndroidSecretVault {

    constructor(context: Context) : this(
        store = SharedPrefsVaultBackingStore(context, PREFS_NAME),
        keyProvider = AndroidKeyStoreKeyProvider(KEY_ALIAS)
    )

    @Synchronized
    override fun getSecret(key: String): String? {
        val raw = store.getString(key) ?: return null
        return try {
            decrypt(raw, keyProvider.getOrCreateKey())
        } catch (t: Throwable) {
            when {
                isRecoverableKeyError(t) -> {
                    // Keystore key was permanently invalidated or corrupted; reset cleanly.
                    runCatching {
                        store.clearAll()
                        keyProvider.resetAndCreateKey()
                    }
                    null
                }
                t is AEADBadTagException ||
                    t is IllegalArgumentException ||
                    t is GeneralSecurityException -> {
                    // Corrupted or foreign-device backup ciphertext; purge dead entry.
                    runCatching { store.remove(key) }
                    null
                }
                else -> null
            }
        }
    }

    @Synchronized
    override fun setSecret(key: String, value: String) {
        try {
            val encoded = encrypt(value, keyProvider.getOrCreateKey())
            store.putString(key, encoded)
        } catch (firstErr: Throwable) {
            if (isRecoverableKeyError(firstErr)) {
                try {
                    // Old key is permanently unusable; discard unreadable entries and rotate key once.
                    store.clearAll()
                    val freshKey = keyProvider.resetAndCreateKey()
                    val encoded = encrypt(value, freshKey)
                    store.putString(key, encoded)
                    return
                } catch (retryErr: Throwable) {
                    throw CharkleFfiException.Internal(
                        "Failed to store secret after key recovery: ${retryErr.message}"
                    )
                }
            }
            throw CharkleFfiException.Internal("Failed to store secret: ${firstErr.message}")
        }
    }

    @Synchronized
    override fun deleteSecret(key: String) {
        runCatching { store.remove(key) }
    }

    private fun encrypt(plainText: String, key: SecretKey): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val iv = cipher.iv
        require(iv != null && iv.size in MIN_IV_BYTES..MAX_IV_BYTES) {
            "Unexpected GCM IV length: ${iv?.size ?: 0}"
        }
        val encrypted = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
        val combined = ByteArray(1 + iv.size + encrypted.size)
        combined[0] = iv.size.toByte()
        System.arraycopy(iv, 0, combined, 1, iv.size)
        System.arraycopy(encrypted, 0, combined, 1 + iv.size, encrypted.size)
        return Base64.getEncoder().encodeToString(combined)
    }

    private fun decrypt(encoded: String, key: SecretKey): String {
        val combined = Base64.getDecoder().decode(encoded)
        if (combined.size < 1 + MIN_IV_BYTES + GCM_TAG_BYTES) {
            throw IllegalArgumentException("Encrypted vault entry is truncated")
        }
        val ivLen = combined[0].toInt() and 0xFF
        if (ivLen !in MIN_IV_BYTES..MAX_IV_BYTES || 1 + ivLen + GCM_TAG_BYTES > combined.size) {
            throw IllegalArgumentException("Invalid IV length in encrypted vault entry: $ivLen")
        }
        val iv = combined.copyOfRange(1, 1 + ivLen)
        val payload = combined.copyOfRange(1 + ivLen, combined.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
        return String(cipher.doFinal(payload), Charsets.UTF_8)
    }

    companion object {
        private const val PREFS_NAME = "charkle_secure_vault_v1"
        private const val KEY_ALIAS = "charkle_vault_aes256_gcm"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val MIN_IV_BYTES = 12
        private const val MAX_IV_BYTES = 16
        private const val GCM_TAG_BITS = 128
        private const val GCM_TAG_BYTES = GCM_TAG_BITS / 8
    }
}
