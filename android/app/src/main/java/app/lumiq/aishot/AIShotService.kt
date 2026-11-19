package app.lumiq.aishot

import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.util.Base64
import java.util.Locale
import java.util.concurrent.TimeUnit
import java.util.concurrent.Future
import java.util.concurrent.Executors
import java.util.concurrent.ExecutorCompletionService
import java.util.concurrent.ExecutionException
import java.util.concurrent.Callable
import kotlin.math.max
import kotlin.math.min

/** Normalized rectangle (0–1, top-left origin) in viewfinder coordinates. */
data class NRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    val midX get() = x + width / 2
    val midY get() = y + height / 2
    val maxX get() = x + width
    val maxY get() = y + height
}

/**
 * One AI decision for the current view (tap ✦ → marked shot). `frame` is the part
 * of the visible viewfinder that should become the photo. Width == height in
 * normalized units means it has the same shape as the viewfinder.
 */
data class AIShotSuggestion(
    val subject: String,
    val tip: String,
    val technique: String,
    val frame: NRect,
    val zoom: Double,
    val provider: String,
)

sealed class AIShotError(val userMessage: String) : Exception(userMessage) {
    object NotConfigured : AIShotError("AI Shot is not available in this build (no AI key was built in).")
    object NoFrame : AIShotError("No camera frame yet. Try again.")
    object Offline : AIShotError("No internet connection.")
    object Timeout : AIShotError("The AI took too long. Tap ↻ to retry.")
    object Unauthorized : AIShotError("The built-in AI key was refused. Install the latest Lumiq update.")
    object Quota : AIShotError("Free AI limit reached for now. Try again in a minute.")
    object Busy : AIShotError("The AI is busy right now. Tap ↻ to retry.")
    object InvalidResponse : AIShotError("The AI answer could not be used. Tap ↻ to retry.")
    class Server(val code: Int) : AIShotError("AI server error $code. Tap ↻ to retry.")
}

class AIShotRequest(
    val jpeg: ByteArray,
    val aspect: Double,
    val zoom: Double,
    val minimumZoom: Double,
    val maximumZoom: Double,
    /** Rules learned from Lumiq users' results (see AIShotLearning); may be empty. */
    val guidance: List<String> = emptyList(),
)

/** Pure parsing and validation, shared with unit tests. Mirrors ai-server/src/index.js. */
object AIShotLogic {
    fun prompt(r: AIShotRequest): String =
        "You are a world-class photographer standing behind someone holding a phone camera. Look at this live camera view and pick " +
            "the single most beautiful photo that can be taken from it right now by only pointing the camera and zooming in. Prefer a " +
            "clear subject with a clean composition: crop out clutter, empty floor, cut-off objects and distracting edges. A tighter, " +
            "intentional crop usually beats the full view. If the full view is already best, return the whole frame.\n" +
            "The viewfinder shape is ${fmt(r.aspect, 2)}:1 (width:height). Current zoom ${fmt(r.zoom, 1)}x; you may zoom in at most " +
            "${fmt(r.maximumZoom / r.zoom, 1)}x more.\n" +
            "Return JSON only: {\"subject\": \"2-5 lowercase words\", \"tip\": \"one imperative photographer instruction, max 9 words\", " +
            "\"technique\": \"rule of thirds|centered|leading lines|symmetry|negative space|framing|fill the frame|layers|detail\", " +
            "\"box_2d\": [ymin, xmin, ymax, xmax] ideal photo crop, integers 0-1000, \"confidence\": 0-1}" +
            (if (r.guidance.isEmpty()) "" else "\nWhat Lumiq users have chosen recently (apply when relevant):\n" + r.guidance.joinToString("\n") { "- $it" })

    private fun fmt(v: Double, digits: Int) = String.format(Locale.US, "%.${digits}f", v)

    /** Response of the Lumiq AI server (already normalized there, validated again here). */
    fun parseServer(body: String, r: AIShotRequest): AIShotSuggestion {
        val root = runCatching { JSONObject(body) }.getOrNull() ?: throw AIShotError.InvalidResponse
        val frame = root.optJSONObject("frame") ?: throw AIShotError.InvalidResponse
        val x = number(frame, "x")
        val y = number(frame, "y")
        val w = number(frame, "width")
        val h = number(frame, "height")
        if (x == null || y == null || w == null || h == null) throw AIShotError.InvalidResponse
        return validated(
            AIShotSuggestion(
                subject = root.optString("subject", "your shot"), tip = root.optString("tip", ""),
                technique = root.optString("technique", ""), frame = NRect(x, y, w, h),
                zoom = number(root, "zoom") ?: r.zoom, provider = root.optString("provider", "server"),
            ), r,
        )
    }

    private fun number(o: JSONObject, key: String): Double? {
        if (!o.has(key) || o.isNull(key)) return null
        val value = o.optDouble(key, Double.NaN)
        return if (value.isFinite()) value else null
    }

    /** A model's JSON text with box_2d = [ymin, xmin, ymax, xmax] on a 0–1000 (or 0–1) scale. */
    fun parseModelJson(text: String, r: AIShotRequest, provider: String): AIShotSuggestion {
        val start = text.indexOf('{')
        val end = text.lastIndexOf('}')
        if (start < 0 || end <= start) throw AIShotError.InvalidResponse
        val root = runCatching { JSONObject(text.substring(start, end + 1)) }.getOrNull() ?: throw AIShotError.InvalidResponse
        val box: JSONArray = root.optJSONArray("box_2d") ?: root.optJSONArray("box") ?: throw AIShotError.InvalidResponse
        if (box.length() != 4) throw AIShotError.InvalidResponse
        val raw = DoubleArray(4) { box.optDouble(it, Double.NaN) }
        if (raw.any { !it.isFinite() }) throw AIShotError.InvalidResponse
        val scale = if ((raw.maxOrNull() ?: 0.0) <= 1.0001) 1.0 else 1000.0
        val v = DoubleArray(4) { min(1.0, max(0.0, raw[it] / scale)) }
        val ymin = min(v[0], v[2])
        val ymax = max(v[0], v[2])
        val xmin = min(v[1], v[3])
        val xmax = max(v[1], v[3])
        if (xmax - xmin < 0.02 || ymax - ymin < 0.02) throw AIShotError.InvalidResponse
        return validated(
            AIShotSuggestion(
                subject = root.optString("subject", "your shot"), tip = root.optString("tip", ""),
                technique = root.optString("technique", ""), frame = NRect(xmin, ymin, xmax - xmin, ymax - ymin),
                zoom = r.zoom, provider = provider,
            ), r, fitShape = true,
        )
    }

    /** Fits the crop to the viewfinder shape and keeps it reachable and on screen. */
    fun validated(raw: AIShotSuggestion, r: AIShotRequest, fitShape: Boolean = false): AIShotSuggestion {
        val f = raw.frame
        if (listOf(f.x, f.y, f.width, f.height).any { !it.isFinite() } || f.width <= 0 || f.height <= 0) {
            throw AIShotError.InvalidResponse
        }
        var size = if (fitShape) max(f.width, f.height) else f.width
        size = min(1.0, maxOf(size, r.zoom / max(r.maximumZoom, r.zoom), 0.12))
        if (size > 0.9) size = 1.0
        val x = min(1 - size, max(0.0, f.midX - size / 2))
        val y = min(1 - size, max(0.0, f.midY - size / 2))
        val subject = clean(raw.subject, 48).lowercase(Locale.ROOT).ifEmpty { "your shot" }
        val tip = clean(raw.tip, 80).ifEmpty { "Center the frame and hold steady." }
        return raw.copy(
            frame = NRect(x, y, size, size),
            zoom = min(r.maximumZoom, max(r.zoom, r.zoom / size)),
            subject = subject, tip = tip,
        )
    }

    fun clean(text: String, maximum: Int): String {
        val flat = text.split(Regex("[\\s\\p{Cntrl}]+")).filter { it.isNotEmpty() }.joinToString(" ")
        return if (flat.length > maximum) flat.take(maximum - 1) + "…" else flat
    }

    fun geminiText(body: String): String {
        val root = runCatching { JSONObject(body) }.getOrNull() ?: throw AIShotError.InvalidResponse
        val parts = root.optJSONArray("candidates")?.optJSONObject(0)?.optJSONObject("content")?.optJSONArray("parts")
            ?: throw AIShotError.InvalidResponse
        val text = StringBuilder()
        for (i in 0 until parts.length()) {
            val part = parts.optJSONObject(i) ?: continue
            if (part.optBoolean("thought", false)) continue
            text.append(part.optString("text", ""))
        }
        return text.toString()
    }

    fun errorFor(status: Int): AIShotError = when (status) {
        401, 403 -> AIShotError.Unauthorized
        429 -> AIShotError.Quota
        408, 504 -> AIShotError.Timeout
        500, 502, 503 -> AIShotError.Busy
        else -> AIShotError.Server(status)
    }

    /** Errors where another model (or a moment later) may still succeed. */
    fun tryNextModel(e: AIShotError): Boolean =
        e is AIShotError.Quota || e is AIShotError.Busy || e is AIShotError.Timeout || e is AIShotError.InvalidResponse ||
            (e is AIShotError.Server && (e.code == 400 || e.code == 404))
}

/**
 * Requests tried in order, each with its read timeout (ms). Measured with AI Shot's own request on the
 * free key (Nov 2026): gemini-flash-lite-latest answers in about 1–4 s but is often "busy" (HTTP 503),
 * and a busy answer comes back within a second, so it is simply asked again; gemini-flash-latest often
 * hangs or is over quota; the Gemma model is often busy. See [ModelRace] for how they are run.
 */
val GEMINI_MODELS = listOf(
    "gemini-flash-lite-latest" to 6_000,
    "gemini-flash-lite-latest" to 6_000,
    "gemma-4-26b-a4b-it" to 8_000,
    "gemini-flash-lite-latest" to 6_000,
    "gemini-flash-latest" to 8_000,
    "gemini-flash-lite-latest" to 6_000,
)

/**
 * A model that is out of quota or timed out is skipped for a while, so the next AI Shot does not wait on
 * it again. "Busy" (503) does not count: it comes back fast and the next try often works.
 * Shared by the whole app process.
 */
class ModelCooldown(private val seconds: Double = 120.0) {
    private val until = HashMap<String, Double>()

    @Synchronized fun isCooling(model: String, now: Double): Boolean = (until[model] ?: 0.0) > now

    @Synchronized fun failed(model: String, now: Double) { until[model] = now + seconds }

    @Synchronized fun succeeded(model: String) { until.remove(model) }

    /** [models] without the ones cooling down; when every model is cooling, the first is tried anyway. */
    fun plan(models: List<Pair<String, Int>>, now: Double): List<Pair<String, Int>> =
        models.filter { !isCooling(it.first, now) }.ifEmpty { models.take(1) }

    companion object {
        val shared = ModelCooldown()

        fun coolsDown(e: AIShotError) = e is AIShotError.Quota || e is AIShotError.Timeout
    }
}

/**
 * Runs the planned requests so the first good answer wins as soon as possible:
 * - a request that fails (busy, bad answer) is followed by the next one after [retryPauseMs];
 * - when a request has not answered after [hedgeMs], the next one starts alongside it
 *   (at most [maxParallel] at once), and whichever answers first is used;
 * - after [totalMs] it gives up with [AIShotError.Timeout].
 * Errors that another request cannot fix (no key, refused key) stop at once.
 */
object ModelRace {
    private val pool = Executors.newCachedThreadPool { r -> Thread(r, "ai-shot").apply { isDaemon = true } }

    fun <T> run(
        plan: List<Pair<String, Int>>,
        hedgeMs: Long = 2_500,
        retryPauseMs: Long = 250,
        totalMs: Long = 14_000,
        maxParallel: Int = 2,
        attempt: (model: String, timeoutMs: Int) -> T,
    ): T {
        require(plan.isNotEmpty())
        val results = ExecutorCompletionService<T>(pool)
        val started = mutableListOf<Future<T>>()
        val deadline = System.nanoTime() + totalMs * 1_000_000
        var next = 0
        var running = 0
        var last: AIShotError = AIShotError.Busy
        fun launch() {
            val (model, timeout) = plan[next++]
            running++
            started += results.submit(Callable { attempt(model, timeout) })
        }
        fun left() = (deadline - System.nanoTime()) / 1_000_000
        try {
            launch()
            while (left() > 0) {
                if (running == 0) {
                    if (next >= plan.size) break
                    Thread.sleep(min(retryPauseMs, max(0, left())))
                    launch(); continue
                }
                val wait = if (next < plan.size && running < maxParallel) min(hedgeMs, left()) else left()
                val done = results.poll(max(1, wait), TimeUnit.MILLISECONDS)
                if (done == null) {
                    if (next < plan.size && running < maxParallel) launch()
                    continue
                }
                running--
                try {
                    return done.get()
                } catch (e: ExecutionException) {
                    val error = e.cause as? AIShotError ?: AIShotError.InvalidResponse
                    if (!AIShotLogic.tryNextModel(error)) throw error
                    last = error
                }
            }
            throw if (left() <= 0) AIShotError.Timeout else last
        } finally {
            started.forEach { it.cancel(true) }
        }
    }
}

/** Calls Gemini directly with the key built into this APK. */
class AIShotService(private val config: AIShotConfig) {

    /** Blocking network call; run it on a background dispatcher. */
    fun suggest(request: AIShotRequest): AIShotSuggestion {
        config.geminiKey()?.let { return viaGemini(it, request) }
        throw AIShotError.NotConfigured
    }

    private fun now() = System.nanoTime() / 1e9

    private fun base64(bytes: ByteArray) = Base64.getEncoder().encodeToString(bytes)

    private fun viaGemini(key: String, r: AIShotRequest): AIShotSuggestion {
        val cooldown = ModelCooldown.shared
        val parts = JSONArray()
            .put(JSONObject().put("text", AIShotLogic.prompt(r)))
            .put(JSONObject().put("inlineData", JSONObject().put("mimeType", "image/jpeg").put("data", base64(r.jpeg))))
        val body = JSONObject()
            .put("contents", JSONArray().put(JSONObject().put("role", "user").put("parts", parts)))
            .put(
                "generationConfig",
                // No thinkingConfig: current models reject thinkingBudget = 0 with HTTP 400. The answer is
                // about 80 tokens, so a small limit also cuts off a model that starts rambling.
                JSONObject().put("temperature", 0.3).put("maxOutputTokens", 512)
                    .put("responseMimeType", "application/json"),
            )
            .toString()
        return ModelRace.run(cooldown.plan(GEMINI_MODELS, now())) { model, timeout ->
            try {
                val response = post(
                    "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent",
                    body, mapOf("x-goog-api-key" to key), readTimeoutMs = timeout,
                )
                AIShotLogic.parseModelJson(AIShotLogic.geminiText(response), r, model).also { cooldown.succeeded(model) }
            } catch (e: AIShotError) {
                if (ModelCooldown.coolsDown(e)) cooldown.failed(model, now())
                throw e
            }
        }
    }

    private fun post(url: String, json: String, headers: Map<String, String>, readTimeoutMs: Int = 25_000): String {
        val connection = try {
            URL(url).openConnection() as HttpURLConnection
        } catch (_: Exception) {
            throw AIShotError.NotConfigured
        }
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 5_000
            connection.readTimeout = readTimeoutMs
            connection.doOutput = true
            connection.useCaches = false
            connection.setRequestProperty("Content-Type", "application/json")
            for ((k, v) in headers) connection.setRequestProperty(k, v)
            connection.outputStream.use { it.write(json.toByteArray(Charsets.UTF_8)) }
            val status = connection.responseCode
            if (status != 200) throw AIShotLogic.errorFor(status)
            return connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
        } catch (e: AIShotError) {
            throw e
        } catch (_: SocketTimeoutException) {
            throw AIShotError.Timeout
        } catch (_: IOException) {
            throw AIShotError.Offline
        } finally {
            connection.disconnect()
        }
    }
}
