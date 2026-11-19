package app.lumiq.aishot

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.lumiq.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.UUID

/** How one AI Shot ended. */
enum class ShotOutcome(val wire: String) {
    /** A photo was taken while the shot was marked. */
    Taken("taken"),
    /** The user asked for a different shot. */
    NewShot("new_shot"),
    /** The user cancelled or exited AI Shot. */
    Cancelled("cancelled"),
    /** Tracking lost the shot (says nothing about the pick itself). */
    Lost("lost"),
}

/** Anonymous result of one AI Shot. No image and nothing that identifies the person. */
data class ShotResult(
    val model: String,
    val technique: String,
    val subject: String,
    val aiZoom: Double,
    val startZoom: Double,
    val crop: Double,
    val aspect: Double,
    val outcome: ShotOutcome,
    val reachedReady: Boolean,
    val secondsToReady: Double?,
    val userZoom: Double?,
)

/** Pure encoding/decoding, shared with unit tests. Mirrors ai-server/src/learning.js. */
object LearningLogic {
    fun feedbackJson(result: ShotResult, session: String, app: String): String = JSONObject()
        .put("session", session)
        .put("model", result.model.take(40))
        .put("technique", result.technique)
        .put("subject", result.subject.take(60))
        .put("aiZoom", round(result.aiZoom))
        .put("startZoom", round(result.startZoom))
        .put("crop", round(result.crop))
        .put("aspect", round(result.aspect))
        .put("outcome", result.outcome.wire)
        .put("reachedReady", result.reachedReady)
        .apply { result.secondsToReady?.let { put("secondsToReady", round(it)) } }
        .apply { result.userZoom?.let { put("userZoom", round(it)) } }
        .put("app", app.take(24))
        .toString()

    /** At most five short, plain-text rules from the server's /v1/guidance answer. */
    fun parseGuidance(body: String): List<String> {
        val array = runCatching { JSONObject(body).optJSONArray("guidance") }.getOrNull() ?: return emptyList()
        return (0 until array.length()).mapNotNull { i ->
            array.optString(i).replace(Regex("[\\p{Cntrl}]"), " ").replace(Regex("\\s+"), " ").trim().take(160).ifEmpty { null }
        }.take(5)
    }

    private fun round(v: Double) = String.format(Locale.US, "%.3f", v).toDouble()
}

/**
 * AI Shot learning. When the person agrees, the result of each AI Shot is sent straight to the
 * Lumiq learning server (BuildConfig.LEARNING_URL); nothing about shots is stored on the phone.
 * Rules the server has learned from everyone's results are fetched at start and added to the
 * AI's instructions. Only the yes/no choice itself is remembered.
 */
class AIShotLearning(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("learning", Context.MODE_PRIVATE)
    private val io = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val base = BuildConfig.LEARNING_URL.trimEnd('/')
    /** Random id for this app run only (kept in memory, never saved). */
    private val session = UUID.randomUUID().toString()

    val isAvailable: Boolean get() = base.startsWith("https://")

    /** null until the person has been asked. */
    var consent by mutableStateOf(if (prefs.contains(KEY)) prefs.getBoolean(KEY, false) else null); private set
    val needsConsent: Boolean get() = isAvailable && consent == null

    /** Rules learned from everyone's results (in memory only). */
    @Volatile var guidance: List<String> = emptyList(); private set

    fun updateConsent(value: Boolean) {
        consent = value
        prefs.edit().putBoolean(KEY, value).apply()
    }

    fun refreshGuidance() {
        if (!isAvailable) return
        io.launch {
            runCatching {
                val c = URL("$base/v1/guidance").openConnection() as HttpURLConnection
                c.connectTimeout = 6_000; c.readTimeout = 8_000
                try {
                    if (c.responseCode == 200) guidance = LearningLogic.parseGuidance(c.inputStream.bufferedReader().use { it.readText() })
                } finally { c.disconnect() }
            }
        }
    }

    /** Sends one result; dropped silently when offline (nothing is queued on the phone). */
    fun report(result: ShotResult) {
        if (!isAvailable || consent != true) return
        val body = LearningLogic.feedbackJson(result, session, BuildConfig.VERSION_NAME)
        io.launch {
            runCatching {
                val c = URL("$base/v1/feedback").openConnection() as HttpURLConnection
                c.requestMethod = "POST"; c.doOutput = true
                c.connectTimeout = 6_000; c.readTimeout = 8_000
                c.setRequestProperty("Content-Type", "application/json")
                try {
                    c.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                    c.responseCode
                } finally { c.disconnect() }
            }
        }
    }

    fun dispose() = io.cancel()

    private companion object {
        const val KEY = "aiShot.shareResults"
    }
}
