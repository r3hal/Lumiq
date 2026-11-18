package app.lumiq.aishot

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import app.lumiq.BuildConfig
import java.net.URI
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Settings for the external free AI. Server URL and token live in app preferences
 * (like iPhone UserDefaults); the optional direct Gemini key is encrypted with a
 * key from the Android Keystore (the Android equivalent of the iPhone Keychain).
 */
class AIShotConfig(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("aishot", Context.MODE_PRIVATE)

    var serverText: String
        get() = prefs.getString(SERVER, "") ?: ""
        set(value) { prefs.edit().putString(SERVER, value.trim()).apply() }

    var tokenText: String
        get() = prefs.getString(TOKEN, "") ?: ""
        set(value) { prefs.edit().putString(TOKEN, value.trim()).apply() }

    fun serverUrl(): String? = normalizeServer(serverText)

    fun appToken(): String? = tokenText.trim().ifEmpty { null }

    /** A key typed in Settings wins; otherwise the key built into this APK (if any). */
    fun geminiKey(): String? = personalGeminiKey() ?: builtInGeminiKey()

    fun personalGeminiKey(): String? = prefs.getString(GEMINI, null)?.let { SecretBox.open(it) }?.trim()?.ifEmpty { null }

    fun builtInGeminiKey(): String? = BuildConfig.BUILT_IN_GEMINI_KEY.trim().ifEmpty { null }

    fun setGeminiKey(value: String?) {
        val key = value?.trim().orEmpty()
        if (key.isEmpty()) prefs.edit().remove(GEMINI).apply()
        else prefs.edit().putString(GEMINI, SecretBox.seal(key)).apply()
    }

    val isConfigured: Boolean get() = serverUrl() != null || geminiKey() != null

    companion object {
        private const val SERVER = "aiShot.serverURL"
        private const val TOKEN = "aiShot.appToken"
        private const val GEMINI = "aiShot.geminiKey.sealed"

        /** https only (or localhost); an empty path becomes /v1/shot. */
        fun normalizeServer(text: String): String? {
            val trimmed = text.trim()
            if (trimmed.isEmpty()) return null
            val uri = runCatching { URI(trimmed) }.getOrNull() ?: return null
            val host = uri.host ?: return null
            if (uri.scheme != "https" && host != "localhost") return null
            val path = if (uri.path.isNullOrEmpty() || uri.path == "/") "/v1/shot" else uri.path
            return runCatching { URI(uri.scheme, uri.userInfo, host, uri.port, path, uri.query, null).toString() }.getOrNull()
        }
    }
}

/** AES-GCM with a non-exportable Android Keystore key. */
private object SecretBox {
    private const val ALIAS = "lumiq.aishot"

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }

    fun seal(plain: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(sealed, Base64.NO_WRAP)
    }

    fun open(stored: String): String? = runCatching {
        val (iv, data) = stored.split(":", limit = 2)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
        String(cipher.doFinal(Base64.decode(data, Base64.NO_WRAP)), Charsets.UTF_8)
    }.getOrNull()
}
