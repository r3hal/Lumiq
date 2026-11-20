package app.lumiq.sony

import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/** A Sony JSON-RPC error, with a plain explanation of what the user can do. */
class SonyAPIError(val method: String, val code: Int, val detail: String) : SonyRemoteError(describe(method, code, detail)) {
    companion object {
        private fun describe(method: String, code: Int, detail: String): String {
            val action = when (method) {
                "actTakePicture", "awaitTakePicture" -> "take the photo"
                "setTouchAFPosition" -> "set touch focus"
                else -> "complete $method"
            }
            val explanation = when (code) {
                5, 403 -> "Sony refused to $action in its current mode. Select still-photo mode and let the camera finish its current operation."
                40400 -> "Sony could not take the photo. Focus on a clear edge, check the memory card and shooting mode, then try again."
                40401 -> "Sony is not ready yet. Let focus or the current operation finish, then try again."
                40403 -> "Sony is still processing this photo. Check the camera card before taking another."
                12 -> "This Sony mode does not support $method."
                else -> "Sony could not $action."
            }
            return explanation + " ($method, code $code)" + if (detail.isBlank()) "" else "\n${detail.trim()}"
        }

        fun parse(obj: JSONObject, method: String): SonyAPIError? {
            val values = obj.optJSONArray("error") ?: return null
            val code = (values.opt(0) as? Number)?.toInt() ?: return null
            val detail = (1 until values.length()).mapNotNull { (values.opt(it) as? String)?.ifEmpty { null } }.joinToString(" · ")
            return SonyAPIError(method, code, detail)
        }
    }
}

/** Opens connections to the camera, over the camera's Wi-Fi network when one is known. */
fun interface SonyConnector {
    fun open(url: URL): HttpURLConnection
}

/** "result" (or "results" for getMethodTypes) of a JSON-RPC reply. */
fun sonyResult(obj: JSONObject): JSONArray =
    obj.optJSONArray("result") ?: obj.optJSONArray("results") ?: throw SonyRemoteError("Invalid Sony API result.")

/** A camera command: method, params, timeout (ms) → JSON-RPC reply. Blocking. */
typealias SonyCall = (method: String, params: List<Any?>, timeoutMs: Int) -> JSONObject

/**
 * Sony JSON-RPC client. Commands run one at a time (the camera handles one request well; a shutter
 * command must never overlap a settings read). Blocking; call from a background thread.
 */
class SonyApiClient(private val endpoint: String, private val connector: SonyConnector) {
    private val lock = Object()
    private var nextId = 1
    @Volatile private var closed = false
    @Volatile private var active: HttpURLConnection? = null
    @Volatile private var generation = 0

    fun call(method: String, params: List<Any?> = emptyList(), timeoutMs: Int = 5_000): JSONObject {
        val myGeneration = generation
        synchronized(lock) {
            if (closed || myGeneration != generation) throw SonyCancelled()
            val id = nextId++
            val body = JSONObject().put("method", method).put("params", JSONArray(params)).put("id", id).put("version", "1.0")
            val connection = connector.open(URL(endpoint))
            active = connection
            try {
                connection.requestMethod = "POST"
                connection.instanceFollowRedirects = false
                connection.connectTimeout = minOf(timeoutMs, 5_000)
                connection.readTimeout = timeoutMs
                connection.doOutput = true
                connection.useCaches = false
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                val status = connection.responseCode
                val bytes = (if (status in 200..299) connection.inputStream else connection.errorStream)?.use { readLimited(it, 2 * 1024 * 1024) } ?: ByteArray(0)
                if (status !in 200..299) throw SonyRemoteError("Sony control HTTP request failed ($status).")
                val obj = runCatching { JSONObject(String(bytes, Charsets.UTF_8)) }.getOrNull()
                    ?: throw SonyRemoteError("Sony returned an unreadable reply for $method.")
                SonyAPIError.parse(obj, method)?.let { throw it }
                if (obj.has("error")) throw SonyRemoteError("Sony returned an unreadable error for $method.")
                if (obj.optJSONArray("result") == null && !(method == "getMethodTypes" && obj.optJSONArray("results") != null)) {
                    throw SonyRemoteError("Sony returned no readable result array for $method.")
                }
                return obj
            } catch (e: IOException) {
                if (closed || myGeneration != generation) throw SonyCancelled()
                throw SonyNetworkError(e)
            } finally {
                active = null
                connection.disconnect()
            }
        }
    }

    /** Drops queued work and aborts the request in flight. */
    fun cancelPending() { generation++; active?.disconnect() }

    fun shutdown() { closed = true; cancelPending() }

    companion object {
        fun readLimited(input: java.io.InputStream, limit: Int): ByteArray {
            val out = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                out.write(buffer, 0, n)
                if (out.size() > limit) throw SonyRemoteError("Sony reply is too large.")
            }
            return out.toByteArray()
        }
    }
}

/** The connection was closed or replaced; not a camera failure. */
class SonyCancelled : RuntimeException("Cancelled")

/** The camera could not be reached (Wi-Fi left, camera asleep…). */
class SonyNetworkError(cause: IOException) : SonyRemoteError("The camera could not be reached: ${cause.message ?: cause.javaClass.simpleName}") {
    init { initCause(cause) }
}
