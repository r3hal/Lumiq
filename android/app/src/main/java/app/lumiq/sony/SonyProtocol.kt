package app.lumiq.sony

import org.json.JSONArray
import org.json.JSONObject
import org.xml.sax.Attributes
import org.xml.sax.helpers.DefaultHandler
import java.io.ByteArrayInputStream
import java.net.URI
import javax.xml.parsers.SAXParserFactory

// Android port of Focal/Sony (SonyProtocol.swift). Sony Camera Remote API (ScalarWebAPI) over the
// camera's DIRECT Wi-Fi. Pure code, shared with unit tests.

open class SonyRemoteError(message: String) : Exception(message)

/** Only the selected local camera may supply control, stream or photo URLs. */
object SonyEndpoint {
    fun initialHost(previous: String?): String {
        val saved = previous?.trim().orEmpty()
        return if (validHost(saved)) saved else "192.168.122.1"
    }

    /** Canonical private or link-local IPv4 (no leading zeros). */
    fun validHost(host: String): Boolean {
        val segments = host.split(".")
        if (segments.size != 4) return false
        if (!segments.all { s -> s.isNotEmpty() && s.length <= 3 && s.all { it in '0'..'9' } && (s.length == 1 || s[0] != '0') }) return false
        val p = segments.map { it.toInt() }
        if (p.any { it > 255 }) return false
        return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && p[1] in 16..31) || (p[0] == 169 && p[1] == 254)
    }

    /** The URL must point at exactly [host] over http(s), without credentials. */
    fun validate(url: String, host: String): String {
        val uri = runCatching { URI(url) }.getOrNull()
        if (!validHost(host) || uri == null || uri.host != host || uri.scheme !in setOf("http", "https") || uri.rawUserInfo != null) {
            throw SonyRemoteError("The camera returned a URL outside its selected local address.")
        }
        return url
    }
}

data class SonyDescriptor(val model: String, val endpoint: String, val liveUrl: String?) {
    companion object {
        fun parse(data: ByteArray, host: String): SonyDescriptor {
            if (data.size > 512 * 1024) throw SonyRemoteError("Camera descriptor is too large.")
            val handler = Handler()
            val parsed = runCatching {
                val factory = SAXParserFactory.newInstance().apply {
                    isNamespaceAware = true
                    // No external entities or DTDs: the descriptor comes from the network.
                    runCatching { setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
                    runCatching { setFeature("http://xml.org/sax/features/external-general-entities", false) }
                    runCatching { setFeature("http://xml.org/sax/features/external-parameter-entities", false) }
                }
                factory.newSAXParser().parse(ByteArrayInputStream(data), handler)
            }.isSuccess
            val base = handler.cameraUrl
            if (!parsed || base == null) {
                throw SonyRemoteError("This camera mode did not advertise Sony ScalarWebAPI. PTP/IP support is a separate integration; the phone preview will not be substituted.")
            }
            val endpoint = if (base.trimEnd('/').substringAfterLast('/') == "camera") base.trimEnd('/') else base.trimEnd('/') + "/camera"
            val live = handler.liveUrl?.let { SonyEndpoint.validate(it, host) }
            return SonyDescriptor(handler.model ?: "Model not reported", SonyEndpoint.validate(endpoint, host), live)
        }
    }

    private class Handler : DefaultHandler() {
        var model: String? = null
        var cameraUrl: String? = null
        var liveUrl: String? = null
        private val text = StringBuilder()
        private var service = ""
        private var action = ""

        private fun tag(localName: String?, qName: String?) = (localName?.ifEmpty { null } ?: qName.orEmpty()).substringAfterLast(':')

        override fun startElement(uri: String?, localName: String?, qName: String?, attributes: Attributes?) {
            text.setLength(0)
            if (tag(localName, qName) == "X_ScalarWebAPI_Service") { service = ""; action = "" }
        }

        override fun characters(ch: CharArray, start: Int, length: Int) { text.append(ch, start, length) }

        override fun endElement(uri: String?, localName: String?, qName: String?) {
            val value = text.toString().trim()
            when (tag(localName, qName)) {
                "modelName" -> model = value.ifEmpty { null }
                "X_ScalarWebAPI_ServiceType" -> service = value
                "X_ScalarWebAPI_ActionList_URL" -> action = value
                "X_ScalarWebAPI_LiveView_URL" -> liveUrl = value.ifEmpty { null }
                "X_ScalarWebAPI_Service" -> if (service == "camera" && action.isNotEmpty()) cameraUrl = action
            }
            text.setLength(0)
        }
    }
}

/** Growable byte buffer with cheap front discard, for the live-view stream. */
class ByteQueue {
    private var data = ByteArray(64 * 1024)
    private var start = 0
    private var end = 0
    val size get() = end - start

    operator fun get(i: Int): Int = data[start + i].toInt() and 0xff

    fun append(chunk: ByteArray, length: Int = chunk.size) {
        if (end + length > data.size) {
            val needed = size + length
            if (needed > data.size / 2 || start == 0) data = data.copyOfRange(start, end).copyOf(maxOf(data.size * 2, needed * 2))
            else System.arraycopy(data, start, data, 0, size)
            end -= start; start = 0
        }
        System.arraycopy(chunk, 0, data, end, length)
        end += length
    }

    fun discard(count: Int) { start += minOf(count, size); if (start == end) { start = 0; end = 0 } }

    fun copy(count: Int): ByteArray = data.copyOfRange(start, start + count)

    fun indexOf(a: Int, b: Int): Int {
        for (i in 0 until size - 1) if (get(i) == a && get(i + 1) == b) return i
        return -1
    }
}

/**
 * Incremental JPEG end finder. Segment lengths skip APP/EXIF data (which can hold a thumbnail with its own
 * SOI/EOI); entropy-coded data, byte stuffing, restarts and progressive scans are handled.
 */
class SonyJpegFrameScanner {
    sealed class Result {
        object Incomplete : Result()
        data class Complete(val end: Int) : Result()
        data class Invalid(val skip: Int) : Result()
    }

    private var cursor = 2
    private var entropy = false

    fun reset() { cursor = 2; entropy = false }

    fun scan(bytes: ByteQueue): Result {
        if (bytes.size < 2 || bytes[0] != 0xff || bytes[1] != 0xd8) return Result.Invalid(1)
        val count = bytes.size
        while (cursor < count) {
            if (entropy) {
                while (cursor < count && bytes[cursor] != 0xff) cursor++
                if (cursor == count) return Result.Incomplete
            }
            if (bytes[cursor] != 0xff) return Result.Invalid(cursor + 1)
            val start = cursor
            var markerIndex = cursor + 1
            while (markerIndex < count && bytes[markerIndex] == 0xff) markerIndex++
            if (markerIndex >= count) return Result.Incomplete
            val marker = bytes[markerIndex]
            if (marker == 0xd9) return Result.Complete(markerIndex + 1)
            if (marker == 0xd8) return Result.Invalid(start) // A newer frame can recover a truncated one.
            if (entropy && (marker == 0 || marker in 0xd0..0xd7)) { cursor = markerIndex + 1; continue }
            if (marker == 0) return Result.Invalid(markerIndex + 1)
            if (marker == 1 || marker in 0xd0..0xd7) { cursor = markerIndex + 1; continue }
            if (markerIndex + 2 >= count) return Result.Incomplete
            val length = (bytes[markerIndex + 1] shl 8) or bytes[markerIndex + 2]
            if (length < 2) return Result.Invalid(markerIndex + 3)
            val end = markerIndex + 1 + length
            if (end > count) return Result.Incomplete
            cursor = end
            entropy = marker == 0xda || (entropy && marker == 0xdc)
        }
        return Result.Incomplete
    }
}

/** Sony live-view packets and plain marker-framed JPEG streams share this decoder. */
class SonyLiveViewParser {
    private val buffer = ByteQueue()
    private val scanner = SonyJpegFrameScanner()
    private var payloadRemaining: Int? = null
    private var packetPadding = 0
    private var skipTrailer = 0
    var discardedFrames = 0; private set
    var metadataPackets = 0; private set
    var imageFrames = 0; private set
    var framing = "detecting"; private set
    private val maximumFrame = 4 * 1024 * 1024

    fun append(chunk: ByteArray, length: Int = chunk.size): List<ByteArray> {
        buffer.append(chunk, length)
        if (buffer.size > 8 * 1024 * 1024) throw SonyRemoteError("Sony live-view data exceeded the buffer limit.")
        val frames = ArrayList<ByteArray>()
        while (buffer.size > 0) {
            if (skipTrailer > 0) {
                val count = minOf(skipTrailer, buffer.size)
                skipTrailer -= count; discard(count); continue
            }
            if (isPacket(0)) {
                if (buffer.size < 136) break
                val size = (buffer[12] shl 16) or (buffer[13] shl 8) or buffer[14]
                val padding = buffer[15]
                if (size > maximumFrame) throw SonyRemoteError("Sony live-view frame is too large.")
                framing = "Sony packets"
                if (buffer[1] == 2) {
                    val total = 136 + size + padding
                    if (buffer.size < total) break
                    payloadRemaining = null; packetPadding = 0
                    discard(total); metadataPackets++; continue
                }
                // The JPEG itself determines its end; a packet may carry wrapper bytes or a misleading length.
                discard(136); payloadRemaining = size; packetPadding = padding
                continue
            }
            val imageStart = buffer.indexOf(0xff, 0xd8).takeIf { it >= 0 }
            val packetStart = nextPacket(imageStart)
            if (packetStart != null) { discard(packetStart); continue }
            if (imageStart == null) {
                if (buffer.size > 11) discard(buffer.size - 11) // Keep a possibly split packet signature or SOI.
                break
            }
            if (imageStart > 0) { discard(imageStart); continue }
            if (framing == "detecting") framing = "JPEG markers"
            when (val result = scanner.scan(buffer)) {
                SonyJpegFrameScanner.Result.Incomplete -> {
                    if (buffer.size > maximumFrame) throw SonyRemoteError("Sony JPEG exceeded the frame limit before completing.")
                    return frames
                }
                is SonyJpegFrameScanner.Result.Complete -> {
                    if (result.end > maximumFrame) throw SonyRemoteError("Sony JPEG exceeded the frame limit.")
                    frames += buffer.copy(result.end); imageFrames++; discard(result.end)
                    payloadRemaining?.let { if (it >= 0) skipTrailer = it + packetPadding }
                    payloadRemaining = null; packetPadding = 0
                }
                is SonyJpegFrameScanner.Result.Invalid -> {
                    discardedFrames++; payloadRemaining = null; packetPadding = 0
                    discard(maxOf(2, result.skip))
                }
            }
        }
        return frames
    }

    private fun isPacket(i: Int): Boolean {
        if (i < 0 || i + 12 > buffer.size) return false
        return buffer[i] == 0xff && (buffer[i + 1] == 1 || buffer[i + 1] == 2) &&
            buffer[i + 8] == 0x24 && buffer[i + 9] == 0x35 && buffer[i + 10] == 0x68 && buffer[i + 11] == 0x79
    }

    private fun nextPacket(imageStart: Int?): Int? {
        val end = minOf(imageStart ?: buffer.size, maxOf(0, buffer.size - 11))
        for (i in 0 until end) if (isPacket(i)) return i
        return null
    }

    private fun discard(count: Int) {
        val removed = minOf(count, buffer.size)
        payloadRemaining = payloadRemaining?.let { it - removed }
        buffer.discard(removed); scanner.reset()
    }
}

/** Live-view size negotiation: only a size the camera actually advertises. */
object SonyLiveViewSize {
    fun largest(result: JSONArray): String? {
        val available = when {
            result.length() >= 2 && result.opt(1) is JSONArray -> result.getJSONArray(1)
            result.length() == 1 && result.opt(0) is JSONArray -> result.getJSONArray(0)
            else -> return null
        }
        val values = (0 until available.length()).map { available.optString(it) }
        return listOf("L", "M", "S").firstNotNullOfOrNull { preferred -> values.firstOrNull { it.uppercase() == preferred } }
    }
}

/** What the Sony reports about its exposure (read-only telemetry). */
data class SonyTelemetry(
    val mode: String? = null,
    val shutter: String? = null,
    val iso: String? = null,
    val aperture: String? = null,
    val ev: Double? = null,
)

/** Walks Sony event/result structures: arrays of arrays of {"type": …} objects. */
internal fun walkTyped(value: Any?, visit: (JSONObject) -> Unit) {
    when (value) {
        is JSONArray -> for (i in 0 until value.length()) walkTyped(value.opt(i), visit)
        is JSONObject -> if (value.has("type")) visit(value)
    }
}

internal fun JSONObject.text(key: String): String? = when (val v = opt(key)) {
    is String -> v.ifEmpty { null }
    is Number -> v.toString()
    else -> null
}

object SonyEventValues {
    fun telemetry(result: JSONArray): SonyTelemetry {
        var t = SonyTelemetry()
        walkTyped(result) { item ->
            when (item.optString("type")) {
                "exposureMode" -> t = t.copy(mode = item.text("currentExposureMode"))
                "shutterSpeed" -> t = t.copy(shutter = item.text("currentShutterSpeed"))
                "isoSpeedRate" -> t = t.copy(iso = item.text("currentIsoSpeedRate"))
                "fNumber" -> t = t.copy(aperture = item.text("currentFNumber"))
                "exposureCompensation" -> SonySettingParser.integer(item.opt("currentExposureCompensation"))?.let { index ->
                    t = t.copy(ev = SonySettingValue.ev(index, SonySettingParser.integer(item.opt("stepIndexOfExposureCompensation"))))
                }
            }
        }
        return t
    }
}
