package app.lumiq.settings

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

enum class PhotoAspect(val label: String, val ratio: Double) {
    Standard("3:4", 3.0 / 4), Portrait("4:5", 4.0 / 5), Square("1:1", 1.0), Tall("9:16", 9.0 / 16),
    Landscape("4:3", 4.0 / 3), Wide("16:9", 16.0 / 9),
}

enum class FlashMode(val label: String) { Off("Off"), On("On"), Auto("Auto") }

/** Persistent preferences, mirroring the iPhone CameraSettings defaults. */
class AppSettings(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("camera", Context.MODE_PRIVATE)

    private fun bool(key: String, default: Boolean) = prefs.getBoolean(key, default)
    private fun save(key: String, value: Boolean) = prefs.edit().putBoolean(key, value).apply()

    var guide by mutableStateOf(bool("camera.guide", false)); private set
    var grid by mutableStateOf(bool("camera.grid", false)); private set
    var level by mutableStateOf(bool("camera.level", false)); private set
    var shutterSound by mutableStateOf(bool("camera.sound", false)); private set
    var reviewAfterCapture by mutableStateOf(bool("camera.reviewAfterCapture", true)); private set
    var autoSaveToGallery by mutableStateOf(bool("camera.autoPhotos", false)); private set
    var welcomed by mutableStateOf(bool("app.welcomed", false)); private set
    var aspect by mutableStateOf(
        PhotoAspect.entries.firstOrNull { it.name == prefs.getString("camera.aspect", null) } ?: PhotoAspect.Standard,
    ); private set
    var flash by mutableStateOf(
        FlashMode.entries.firstOrNull { it.name == prefs.getString("camera.flash", null) } ?: FlashMode.Off,
    ); private set

    fun updateGuide(v: Boolean) { guide = v; save("camera.guide", v) }
    fun updateGrid(v: Boolean) { grid = v; save("camera.grid", v) }
    fun updateLevel(v: Boolean) { level = v; save("camera.level", v) }
    fun updateShutterSound(v: Boolean) { shutterSound = v; save("camera.sound", v) }
    fun updateReview(v: Boolean) { reviewAfterCapture = v; save("camera.reviewAfterCapture", v) }
    fun updateAutoSave(v: Boolean) { autoSaveToGallery = v; save("camera.autoPhotos", v) }
    fun markWelcomed() { welcomed = true; save("app.welcomed", true) }
    fun updateAspect(v: PhotoAspect) { aspect = v; prefs.edit().putString("camera.aspect", v.name).apply() }
    fun updateFlash(v: FlashMode) { flash = v; prefs.edit().putString("camera.flash", v.name).apply() }
}
