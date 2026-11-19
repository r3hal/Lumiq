package app.lumiq.aishot

import android.content.Context
import app.lumiq.BuildConfig

/**
 * AI Shot uses the Gemini key built into this APK at build time (LUMIQ_GEMINI_KEY; see android/README.md).
 * There is no in-app setup.
 */
class AIShotConfig(context: Context) {
    init {
        // Server URL, app token and personal key saved by the former AI Shot setup screen must not
        // silently override the built-in key, and the setup screen to change them no longer exists.
        context.applicationContext.deleteSharedPreferences("aishot")
    }

    fun geminiKey(): String? = BuildConfig.BUILT_IN_GEMINI_KEY.trim().ifEmpty { null }

    val isConfigured: Boolean get() = geminiKey() != null
}
