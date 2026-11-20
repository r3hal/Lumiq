package app.lumiq.sony

import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

// Port of SonyRemoteSettings.swift: Sony Camera Remote API v2.40, version-1.0 wire formats. Supported
// ranges are never substituted for the values currently available for this lens and mode.

enum class SonyRemoteSetting(val title: String, val suffix: String) {
    Iso("ISO", "IsoSpeedRate"),
    Aperture("Aperture", "FNumber"),
    Shutter("Shutter speed", "ShutterSpeed"),
    WhiteBalance("White balance", "WhiteBalance"),
    Compensation("Exposure compensation", "ExposureCompensation");

    val getter get() = "get$suffix"
    val available get() = "getAvailable$suffix"
    val setter get() = "set$suffix"
    val eventType get() = suffix.replaceFirstChar { it.lowercase() }
}

sealed class SonySettingValue {
    data class Text(val value: String) : SonySettingValue()
    data class WhiteBalance(val mode: String, val temperature: Int?) : SonySettingValue()
    data class Compensation(val index: Int, val step: Int?) : SonySettingValue()

    val label: String
        get() = when (this) {
            is Text -> value
            is WhiteBalance -> temperature?.let { "$mode · $it K" } ?: mode
            is Compensation -> ev(index, step)?.let { String.format(Locale.US, "%+.2f EV", it) } ?: "Index $index · EV step not reported"
        }

    val parameters: List<Any?>
        get() = when (this) {
            is Text -> listOf(value)
            is WhiteBalance -> listOf(mode, temperature != null, temperature ?: -1)
            is Compensation -> listOf(index)
        }

    companion object {
        fun ev(index: Int, step: Int?): Double? = when {
            step == 1 -> index / 3.0
            step == 2 -> index / 2.0
            index == 0 -> 0.0
            else -> null
        }
    }
}

sealed class SonySettingReadStatus(val label: String) {
    object Unknown : SonySettingReadStatus("Unknown")
    object Loading : SonySettingReadStatus("Loading…")
    object Available : SonySettingReadStatus("Available")
    object Unsupported : SonySettingReadStatus("Unsupported")
    data class Unavailable(val reason: String) : SonySettingReadStatus("Unavailable")
    data class ConnectionError(val reason: String) : SonySettingReadStatus("Connection error")
    data class Error(val reason: String) : SonySettingReadStatus("Read failed")
}

sealed class SonyRemoteControlStatus(val name: String) {
    object Unknown : SonyRemoteControlStatus("Unknown")
    object Available : SonyRemoteControlStatus("Available")
    object Unsupported : SonyRemoteControlStatus("Unsupported")
    object CommandInProgress : SonyRemoteControlStatus("CommandInProgress")
    data class TemporarilyUnavailable(val why: String) : SonyRemoteControlStatus("TemporarilyUnavailable")
    data class Failed(val why: String) : SonyRemoteControlStatus("Error")

    val reason: String?
        get() = when (this) {
            Available -> null
            Unknown -> "Waiting for the camera's control information."
            Unsupported -> "The camera's supported-method list does not include this setter."
            CommandInProgress -> "Waiting for this setting's camera confirmation…"
            is TemporarilyUnavailable -> why
            is Failed -> why
        }
}

data class SonyRemoteSettingState(
    val current: SonySettingValue? = null,
    val choices: List<SonySettingValue> = emptyList(),
    val issue: String? = null,
    val readStatus: SonySettingReadStatus = SonySettingReadStatus.Unknown,
    val choicesReported: Boolean = false,
    val temperatureReported: Boolean = false,
    val sourceMethod: String? = null,
) {
    val displayValue get() = current?.label ?: readStatus.label

    fun merging(update: SonyRemoteSettingState): SonyRemoteSettingState {
        var next = this
        update.current?.let { cur ->
            val old = next.current
            next = when {
                cur is SonySettingValue.Compensation && cur.step == null && old is SonySettingValue.Compensation ->
                    next.copy(current = SonySettingValue.Compensation(cur.index, old.step))
                cur is SonySettingValue.WhiteBalance && cur.temperature == null && !update.temperatureReported &&
                    old is SonySettingValue.WhiteBalance && old.mode == cur.mode -> next.copy(current = cur.copy(temperature = old.temperature))
                else -> next.copy(current = cur)
            }
        }
        if (update.choicesReported) next = next.copy(choices = update.choices, choicesReported = true)
        update.sourceMethod?.let { next = next.copy(sourceMethod = it) }
        // Missing event fields are not explicit read failures.
        if (update.readStatus != SonySettingReadStatus.Unknown) next = next.copy(readStatus = update.readStatus, issue = update.issue)
        return next
    }

    companion object {
        fun failure(error: Throwable): SonyRemoteSettingState {
            val message = error.message ?: "Read failed"
            val status = when {
                error is SonyNetworkError -> SonySettingReadStatus.ConnectionError(message)
                error is SonyAPIError && error.code == 12 -> SonySettingReadStatus.Unsupported
                error is SonyAPIError && error.code in setOf(5, 403, 40401) -> SonySettingReadStatus.Unavailable(message)
                else -> SonySettingReadStatus.Error(message)
            }
            return SonyRemoteSettingState(issue = message, readStatus = status)
        }
    }
}

object SonySettingParser {
    fun integer(value: Any?): Int? {
        if (value !is Number || value is Boolean) return null
        val d = value.toDouble()
        if (!d.isFinite() || Math.rint(d) != d || kotlin.math.abs(d) >= 1_000_000) return null
        return d.toInt()
    }

    private fun strings(value: Any?): List<String>? = (value as? JSONArray)?.let { a -> (0 until a.length()).map { a.opt(it) as? String ?: return null } }

    fun parse(setting: SonyRemoteSetting, result: JSONArray, available: Boolean): SonyRemoteSettingState {
        var current: SonySettingValue? = null
        var choices = mutableListOf<SonySettingValue>()
        var choicesReported = false
        var temperatureReported = false
        when (setting) {
            SonyRemoteSetting.Iso, SonyRemoteSetting.Aperture, SonyRemoteSetting.Shutter -> {
                (result.opt(0) as? String)?.takeIf { it.isNotEmpty() }?.let { current = SonySettingValue.Text(it) }
                if (available && result.length() > 1) strings(result.opt(1))?.let { list ->
                    choicesReported = true
                    choices = list.take(1024).filter { it.isNotEmpty() }.map { SonySettingValue.Text(it) }.toMutableList()
                }
            }
            SonyRemoteSetting.WhiteBalance -> {
                (result.opt(0) as? JSONObject)?.let { value ->
                    (value.opt("whiteBalanceMode") as? String)?.let { mode ->
                        temperatureReported = value.has("colorTemperature")
                        current = SonySettingValue.WhiteBalance(mode, integer(value.opt("colorTemperature"))?.takeIf { it > 0 })
                    }
                }
                val modes = if (available && result.length() > 1) result.opt(1) as? JSONArray else null
                if (modes != null) {
                    choicesReported = true
                    for (i in 0 until minOf(64, modes.length())) {
                        val mode = modes.optJSONObject(i) ?: continue
                        val name = (mode.opt("whiteBalanceMode") as? String)?.ifEmpty { null } ?: continue
                        val range = mode.opt("colorTemperatureRange") as? JSONArray ?: continue
                        if (range.length() == 0) { choices += SonySettingValue.WhiteBalance(name, null); continue }
                        if (range.length() != 3) continue
                        val max = integer(range.opt(0)) ?: continue
                        val min = integer(range.opt(1)) ?: continue
                        val step = integer(range.opt(2)) ?: continue
                        if (min <= 0 || max < min || step <= 0 || (max - min) / step >= 512) continue
                        for (t in min..max step step) choices += SonySettingValue.WhiteBalance(name, t)
                    }
                }
            }
            SonyRemoteSetting.Compensation -> {
                val step = if (available && result.length() >= 4) integer(result.opt(3)) else null
                integer(result.opt(0))?.let { current = SonySettingValue.Compensation(it, step) }
                if (available && result.length() >= 4) {
                    val max = integer(result.opt(1)); val min = integer(result.opt(2))
                    if (max != null && min != null && max >= min && max - min <= 128 && (step == 1 || step == 2)) {
                        choicesReported = true
                        choices = (min..max).map { SonySettingValue.Compensation(it, step) }.toMutableList()
                    }
                }
            }
        }
        val issue = if (current == null) "Camera returned an unrecognized current value." else null
        return SonyRemoteSettingState(
            current = current, choices = choices.distinct(), issue = issue,
            readStatus = if (issue != null) SonySettingReadStatus.Error(issue) else SonySettingReadStatus.Available,
            choicesReported = choicesReported, temperatureReported = temperatureReported,
            sourceMethod = if (available) setting.available else setting.getter,
        )
    }

    fun event(setting: SonyRemoteSetting, values: JSONArray): SonyRemoteSettingState? {
        var item: JSONObject? = null
        walkTyped(values) { if (it.optString("type") == setting.eventType) item = it }
        val found = item ?: return null
        val n = JSONObject.NULL
        val result = when (setting) {
            SonyRemoteSetting.Iso, SonyRemoteSetting.Aperture, SonyRemoteSetting.Shutter ->
                JSONArray().put(found.opt("current${setting.suffix}") ?: n).put(found.opt("${setting.eventType}Candidates") ?: n)
            SonyRemoteSetting.WhiteBalance -> JSONArray()
                .put(JSONObject().put("whiteBalanceMode", found.opt("currentWhiteBalanceMode") ?: n).put("colorTemperature", found.opt("currentColorTemperature") ?: -1))
                .put(found.opt("whiteBalanceCandidates") ?: n)
            SonyRemoteSetting.Compensation -> JSONArray()
                .put(found.opt("currentExposureCompensation") ?: n).put(found.opt("maxExposureCompensation") ?: n)
                .put(found.opt("minExposureCompensation") ?: n).put(found.opt("stepIndexOfExposureCompensation") ?: n)
        }
        var parsed = parse(setting, result, available = true).copy(sourceMethod = "getEvent")
        if (setting == SonyRemoteSetting.WhiteBalance) parsed = parsed.copy(temperatureReported = found.has("currentColorTemperature"))
        val currentKey = if (setting == SonyRemoteSetting.WhiteBalance) "currentWhiteBalanceMode" else "current${setting.suffix}"
        if (!found.has(currentKey)) parsed = parsed.copy(issue = null, readStatus = SonySettingReadStatus.Unknown)
        return parsed
    }
}

/** Blocking settings read/write with camera confirmation. [active] stops stale work after a reconnect. */
object SonySettingWorkflow {
    fun methods(call: SonyCall): Set<String> {
        val list = sonyResult(call("getAvailableApiList", emptyList(), 2_000)).opt(0) as? JSONArray
            ?: throw SonyRemoteError("Sony did not report currently available commands.")
        return (0 until list.length()).mapNotNull { list.opt(it) as? String }.toSet()
    }

    fun read(
        setting: SonyRemoteSetting, methods: Set<String>, event: JSONArray? = null, allowEventRequest: Boolean = true, call: SonyCall,
    ): SonyRemoteSettingState {
        var failure: Throwable? = null
        var partial = SonyRemoteSettingState()
        // A refused availability getter must not hide a working current-value getter.
        for (method in listOf(setting.available, setting.getter)) {
            if (method !in methods) continue
            try {
                val parsed = SonySettingParser.parse(setting, sonyResult(call(method, emptyList(), 3_000)), available = method == setting.available)
                partial = partial.merging(parsed)
                if (partial.current != null && partial.choicesReported) return partial
                if (parsed.current == null) failure = SonyRemoteError(parsed.issue ?: "Unrecognized Sony setting response.")
            } catch (e: SonyCancelled) { throw e } catch (e: Exception) { failure = e }
        }
        var values = event
        if (values == null && allowEventRequest && "getEvent" in methods) {
            try { values = sonyResult(call("getEvent", listOf(false), 3_000)) } catch (e: SonyCancelled) { throw e } catch (e: Exception) { failure = e }
        }
        values?.let { v ->
            SonySettingParser.event(setting, v)?.let { parsed ->
                partial = if (partial.current == null) partial.merging(parsed)
                else if (parsed.choicesReported) partial.copy(choices = parsed.choices, choicesReported = true) else partial
            }
        }
        if (partial.current != null) return partial
        failure?.let { throw it }
        val reason = "No readable value is currently advertised in this camera mode."
        return SonyRemoteSettingState(issue = reason, readStatus = SonySettingReadStatus.Unavailable(reason))
    }

    fun change(
        setting: SonyRemoteSetting, value: SonySettingValue, call: SonyCall, active: () -> Boolean,
        wait: (Long) -> Unit = { Thread.sleep(it) },
    ): SonyRemoteSettingState {
        fun check() { if (!active()) throw SonyCancelled() }
        check()
        val available = methods(call); check()
        if (setting.setter !in available) throw SonyRemoteError("${setting.title} is unavailable in the camera's current mode.")
        val before = read(setting, available, call = call); check()
        if (before.current == null || value !in before.choices) throw SonyRemoteError("That value is not currently available from this camera and lens. Refresh the controls.")
        if (before.current == value) return before
        // Sent once: a network timeout is ambiguous, so a write is never replayed.
        val ack = sonyResult(call(setting.setter, value.parameters, 3_000)); check()
        if (SonySettingParser.integer(ack.opt(0)) != 0) throw SonyRemoteError("Sony did not acknowledge the change. Refresh to read the actual setting.")
        repeat(5) { i ->
            if (i > 0) wait(250)
            check()
            val feedback = read(setting, methods(call), call = call); check()
            if (feedback.current == value) return feedback
        }
        throw SonyRemoteError("Sony acknowledged the request but did not confirm the new value. Refresh the controls; the change may still have applied.")
    }
}
