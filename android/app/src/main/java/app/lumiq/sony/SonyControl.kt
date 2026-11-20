package app.lumiq.sony

import org.json.JSONArray

// Port of SonyControlPolicy.swift, SonyFocusWorkflow.swift and SonyRemoteSnapshot.swift.

data class SonyControlState(val cameraStatus: String? = null, val focusStatus: String? = null, val availableMethods: Set<String>? = null) {
    val captureBusy: Boolean
        get() = cameraStatus in setOf("StillCapturing", "StillSaving", "MovieRecording", "AudioRecording", "IntervalRecording", "NotReady", "ContentsTransfer")

    companion object {
        fun from(values: JSONArray): SonyControlState {
            var s = SonyControlState()
            walkTyped(values) { item ->
                when (item.optString("type")) {
                    "cameraStatus" -> s = s.copy(cameraStatus = item.opt("cameraStatus") as? String)
                    "focusStatus" -> s = s.copy(focusStatus = item.opt("focusStatus") as? String)
                    "availableApiList" -> (item.opt("names") as? JSONArray)?.let { names ->
                        s = s.copy(availableMethods = (0 until names.length()).mapNotNull { names.opt(it) as? String }.toSet())
                    }
                }
            }
            return s
        }
    }
}

object SonyMethodCapabilities {
    /** Method names from getMethodTypes: entries shaped [name, [params], [results], version]. */
    fun names(result: JSONArray): Set<String> {
        val names = HashSet<String>()
        fun walk(value: Any?) {
            val a = value as? JSONArray ?: return
            val first = a.opt(0)
            if (a.length() >= 4 && first is String && a.opt(1) is JSONArray && a.opt(2) is JSONArray && a.opt(3) is String) names += first
            else for (i in 0 until a.length()) walk(a.opt(i))
        }
        for (i in 0 until result.length()) walk(result.opt(i))
        return names
    }
}

class SonyReconnectPolicy {
    var attempts = 0; private set
    fun reset() { attempts = 0 }
    fun nextDelayMs(requested: Boolean): Long? {
        if (!requested || attempts >= 3) return null
        val delay = 1_000L shl attempts
        attempts++
        return delay
    }
}

private fun strings(a: JSONArray?): Set<String> = a?.let { (0 until it.length()).mapNotNull { i -> it.opt(i) as? String }.toSet() }.orEmpty()

/**
 * Exactly one shutter command per user action. A pending capture uses awaitTakePicture; actTakePicture is
 * never re-sent after a timeout.
 */
object SonyCaptureWorkflow {
    fun take(call: SonyCall, supported: Set<String> = emptySet(), active: () -> Boolean, wait: (Long) -> Unit = { Thread.sleep(it) }): List<String> {
        fun check() { if (!active()) throw SonyCancelled() }
        fun result(method: String, params: List<Any?> = emptyList(), timeoutMs: Int = 3_000): JSONArray {
            check(); val r = call(method, params, timeoutMs); check(); return sonyResult(r)
        }
        fun available(): MutableSet<String> {
            val list = result("getAvailableApiList").opt(0) as? JSONArray ?: throw SonyRemoteError("Sony did not report its current controls.")
            return strings(list).toMutableSet()
        }
        var methods = available()
        if ("getEvent" in methods) {
            val state = SonyControlState.from(result("getEvent", listOf(false)))
            if (state.captureBusy) throw SonyRemoteError("Sony is busy (${state.cameraStatus ?: "current operation"}). Finish that operation before taking a photo.")
        }
        if ("getShootMode" in methods) {
            val mode = result("getShootMode").opt(0) as? String
            if (mode != null && mode != "still") {
                val modes = if ("setShootMode" in methods && "getAvailableShootMode" in methods) result("getAvailableShootMode").let { it.opt(it.length() - 1) as? JSONArray } else null
                if (modes == null || "still" !in strings(modes)) throw SonyRemoteError("Select still-photo mode on Sony, then try the shutter again.")
                result("setShootMode", listOf("still"))
                methods.remove("actTakePicture")
            }
        }
        repeat(8) { if ("actTakePicture" !in methods) { wait(200); methods = available() } }
        if ("actTakePicture" !in methods) throw SonyRemoteError("Sony has not enabled still capture in this mode. Select still-photo mode and wait for it to become ready.")
        val focusMode = if ("getFocusMode" in methods) runCatching { result("getFocusMode").opt(0) as? String }.getOrNull() else null
        val halfPress = focusMode != "MF" && "actHalfPressShutter" in methods && ("cancelHalfPressShutter" in methods || "cancelHalfPressShutter" in supported)
        var halfPressed = false
        try {
            if (halfPress) {
                try { result("actHalfPressShutter"); halfPressed = true } catch (e: SonyAPIError) {
                    // Optional AF preparation was refused (5/12); a normal capture can still work.
                    if (e.code != 5 && e.code != 12) throw e
                }
                if (halfPressed && "getEvent" in methods) {
                    for (i in 0 until 12) {
                        val status = SonyControlState.from(result("getEvent", listOf(false))).focusStatus
                        if (status == "Focused") break
                        if (status == "Failed") throw SonyRemoteError("Sony autofocus did not lock. Aim at a clear edge or focus manually on the camera, then try again.")
                        if (status == null) { wait(500); break }
                        wait(150)
                    }
                } else if (halfPressed) wait(500)
            }
            var capture = try { result("actTakePicture", timeoutMs = 30_000) } catch (e: SonyAPIError) {
                if (e.code != 40403 || "awaitTakePicture" !in available()) throw e
                result("awaitTakePicture", timeoutMs = 30_000)
            }
            if (halfPressed) { runCatching { call("cancelHalfPressShutter", emptyList(), 2_000) }; halfPressed = false }
            check()
            val urls = strings(capture.opt(0) as? JSONArray).toList()
            if (urls.isEmpty()) throw SonyRemoteError("Sony may have taken the photo but returned no transfer URL. Check the camera card before shooting again.")
            return urls
        } catch (e: Exception) {
            if (halfPressed && active()) runCatching { call("cancelHalfPressShutter", emptyList(), 2_000) }
            throw e
        }
    }
}

/** User-requested Sony autofocus (half-press, wait for lock, release). */
object SonyFocusWorkflow {
    fun trigger(call: SonyCall, supported: Set<String>, active: () -> Boolean, wait: (Long) -> Unit = { Thread.sleep(it) }): String {
        fun check() { if (!active()) throw SonyCancelled() }
        check()
        val methods = SonySettingWorkflow.methods(call); check()
        if ("actHalfPressShutter" !in methods || ("cancelHalfPressShutter" !in methods && "cancelHalfPressShutter" !in supported)) {
            throw SonyRemoteError("Sony does not currently advertise a releasable autofocus trigger.")
        }
        if ("getFocusMode" in methods) {
            val mode = sonyResult(call("getFocusMode", emptyList(), 2_000)).opt(0) as? String; check()
            if (mode == "MF") throw SonyRemoteError("Select autofocus on the Sony camera or lens first.")
        }
        if ("getEvent" in methods) {
            val state = SonyControlState.from(sonyResult(call("getEvent", listOf(false), 2_000))); check()
            if (state.captureBusy) throw SonyRemoteError("Sony is busy. Wait for its current operation to finish.")
        }
        try {
            val ack = sonyResult(call("actHalfPressShutter", emptyList(), 3_000)); check()
            if (SonySettingParser.integer(ack.opt(0)) != 0) throw SonyRemoteError("Sony did not acknowledge the autofocus trigger.")
            var message = "Autofocus trigger acknowledged; camera did not confirm focus lock."
            if ("getEvent" in methods) {
                for (i in 0 until 12) {
                    val status = SonyControlState.from(sonyResult(call("getEvent", listOf(false), 2_000))).focusStatus; check()
                    if (status == "Focused") { message = "Sony reported focus locked."; break }
                    if (status == "Failed") throw SonyRemoteError("Sony autofocus failed. Aim at a clear edge or focus on the camera.")
                    if (status == null) break
                    wait(150); check()
                }
            }
            call("cancelHalfPressShutter", emptyList(), 2_000); check()
            return message
        } catch (e: Exception) {
            if (active()) runCatching { call("cancelHalfPressShutter", emptyList(), 2_000) }
            throw e
        }
    }
}

/** One confirmed camera/mode snapshot. Event omissions never mean removal. */
data class SonyRemoteSnapshot(
    val methods: Set<String> = emptySet(),
    val supported: Set<String> = emptySet(),
    val supportComplete: Boolean = false,
    val availabilityKnown: Boolean = false,
    val settings: Map<SonyRemoteSetting, SonyRemoteSettingState> = emptyMap(),
    val writeRestrictions: Map<SonyRemoteSetting, SonyRemoteControlStatus> = emptyMap(),
    val telemetry: SonyTelemetry = SonyTelemetry(),
    val control: SonyControlState = SonyControlState(),
) {
    fun status(setting: SonyRemoteSetting, pending: Boolean = false): SonyRemoteControlStatus {
        if (pending) return SonyRemoteControlStatus.CommandInProgress
        if (!availabilityKnown) return SonyRemoteControlStatus.Unknown
        writeRestrictions[setting]?.let { return it }
        if (setting.setter !in methods) {
            if (supportComplete && setting.setter !in supported) return SonyRemoteControlStatus.Unsupported
            return SonyRemoteControlStatus.TemporarilyUnavailable("The camera does not currently advertise ${setting.setter} in ${telemetry.mode ?: "this shooting mode"}.")
        }
        val value = settings[setting]
        if (value?.current == null) {
            return when (val read = value?.readStatus ?: SonySettingReadStatus.Unknown) {
                SonySettingReadStatus.Unknown, SonySettingReadStatus.Loading, SonySettingReadStatus.Available -> SonyRemoteControlStatus.Unknown
                SonySettingReadStatus.Unsupported -> SonyRemoteControlStatus.TemporarilyUnavailable("The setter is advertised, but a readable value is unavailable.")
                is SonySettingReadStatus.Unavailable -> SonyRemoteControlStatus.TemporarilyUnavailable(read.reason)
                is SonySettingReadStatus.ConnectionError -> SonyRemoteControlStatus.Failed(read.reason)
                is SonySettingReadStatus.Error -> SonyRemoteControlStatus.Failed(read.reason)
            }
        }
        if (value.choices.isEmpty()) return SonyRemoteControlStatus.TemporarilyUnavailable("No writable values were reported for this camera, lens and mode.")
        return SonyRemoteControlStatus.Available
    }

    fun merge(setting: SonyRemoteSetting, value: SonyRemoteSettingState): SonyRemoteSnapshot =
        copy(settings = settings + (setting to (settings[setting] ?: SonyRemoteSettingState()).merging(value))).synchronizeTelemetry()

    fun applyMethods(available: Set<String>): SonyRemoteSnapshot {
        val restrictions = writeRestrictions.filterKeys { s -> !(s.setter !in methods && s.setter in available) }
        return copy(methods = available, supported = supported + available, availabilityKnown = true, writeRestrictions = restrictions)
    }

    fun writeFailed(setting: SonyRemoteSetting, error: Throwable): SonyRemoteSnapshot {
        var next = merge(setting, SonyRemoteSettingState.failure(error))
        if (error is SonyAPIError && error.method == setting.setter) {
            if (error.code == 12) next = next.copy(writeRestrictions = next.writeRestrictions + (setting to SonyRemoteControlStatus.Unsupported))
            else if (error.code == 5 || error.code == 403) {
                next = next.copy(writeRestrictions = next.writeRestrictions + (setting to SonyRemoteControlStatus.TemporarilyUnavailable(error.message ?: "")))
            }
        }
        return next
    }

    /** Call only after checking the exposure mode; a mode change needs a new snapshot. */
    fun applyEvent(values: JSONArray, includeMethods: Boolean = true): SonyRemoteSnapshot {
        val event = SonyControlState.from(values)
        var next = copy(control = control.copy(
            cameraStatus = event.cameraStatus ?: control.cameraStatus,
            focusStatus = event.focusStatus ?: control.focusStatus,
            availableMethods = null,
        ))
        if (includeMethods) event.availableMethods?.let { next = next.applyMethods(it) }
        SonyEventValues.telemetry(values).mode?.let { next = next.copy(telemetry = next.telemetry.copy(mode = it)) }
        for (setting in SonyRemoteSetting.entries) SonySettingParser.event(setting, values)?.let { next = next.merge(setting, it) }
        return next
    }

    fun noteFailure(error: Throwable): SonyRemoteSnapshot {
        var next = this
        for (setting in SonyRemoteSetting.entries) next = next.merge(setting, SonyRemoteSettingState.failure(error))
        return next
    }

    fun synchronizeTelemetry(): SonyRemoteSnapshot {
        var t = telemetry
        settings[SonyRemoteSetting.Iso]?.current?.let { t = t.copy(iso = it.label) }
        settings[SonyRemoteSetting.Aperture]?.current?.let { t = t.copy(aperture = it.label) }
        settings[SonyRemoteSetting.Shutter]?.current?.let { t = t.copy(shutter = it.label) }
        (settings[SonyRemoteSetting.Compensation]?.current as? SonySettingValue.Compensation)?.let { t = t.copy(ev = SonySettingValue.ev(it.index, it.step)) }
        return if (t == telemetry) this else copy(telemetry = t)
    }
}

class SonyModeChangedDuringRead : RuntimeException("Sony exposure mode changed during a read")

object SonySnapshotWorkflow {
    fun read(previous: SonyRemoteSnapshot, call: SonyCall, active: () -> Boolean): SonyRemoteSnapshot {
        fun check() { if (!active()) throw SonyCancelled() }
        fun request(method: String, params: List<Any?> = emptyList()): JSONArray { check(); val r = call(method, params, 3_000); check(); return sonyResult(r) }
        check()
        val methods = SonySettingWorkflow.methods(call); check()
        var next = previous.applyMethods(methods)
        var initialEvents: JSONArray? = null
        if ("getEvent" in methods) {
            try { initialEvents = request("getEvent", listOf(false)) } catch (e: SonyCancelled) { throw e } catch (e: Exception) { next = next.noteFailure(e) }
        }
        val firstMode = if ("getExposureMode" in methods) {
            runCatching { request("getExposureMode").opt(0) as? String }.getOrNull() ?: initialEvents?.let { SonyEventValues.telemetry(it).mode }
        } else initialEvents?.let { SonyEventValues.telemetry(it).mode }
        check()
        if (firstMode != null && firstMode != previous.telemetry.mode) {
            // Only the new-mode candidate loses old-mode choices; the published snapshot stays intact.
            next = next.copy(writeRestrictions = emptyMap(), settings = next.settings.mapValues { (setting, s) ->
                val cleared = s.copy(choices = emptyList(), choicesReported = false)
                val c = s.current
                if (setting == SonyRemoteSetting.Compensation && c is SonySettingValue.Compensation) cleared.copy(current = c.copy(step = null)) else cleared
            })
        }
        if (firstMode != null) next = next.copy(telemetry = next.telemetry.copy(mode = firstMode))
        initialEvents?.let { next = next.applyEvent(it, includeMethods = false) }
        for (setting in SonyRemoteSetting.entries) {
            check()
            try {
                val value = SonySettingWorkflow.read(setting, methods, event = initialEvents, allowEventRequest = false, call = call)
                check(); next = next.merge(setting, value)
                if (value.current == null && next.supportComplete && "getEvent" !in methods &&
                    setting.getter !in next.supported && setting.available !in next.supported
                ) {
                    next = next.copy(settings = next.settings + (setting to next.settings.getValue(setting).copy(readStatus = SonySettingReadStatus.Unsupported)))
                }
            } catch (e: SonyCancelled) { throw e } catch (e: Exception) {
                check(); next = next.merge(setting, SonyRemoteSettingState.failure(e))
            }
        }
        // A mode change during this multi-request read invalidates the whole candidate.
        if ("getExposureMode" in methods) {
            val finalMode = request("getExposureMode").opt(0) as? String
            check()
            if (finalMode == null) throw SonyRemoteError("Sony returned no readable exposure mode; keeping the previous control snapshot.")
            if (firstMode != null && firstMode != finalMode) throw SonyModeChangedDuringRead()
            next = next.copy(telemetry = next.telemetry.copy(mode = finalMode))
        } else if ("getEvent" in methods) {
            val finalEvent = if (firstMode != null) request("getEvent", listOf(false)) else runCatching { request("getEvent", listOf(false)) }.getOrNull()
            if (finalEvent != null) {
                val finalMode = SonyEventValues.telemetry(finalEvent).mode
                if (firstMode != null && finalMode != null && firstMode != finalMode) throw SonyModeChangedDuringRead()
                next = next.applyEvent(finalEvent, includeMethods = false)
            }
        }
        check(); return next
    }
}

/** Short (non-long-poll) getEvent: the same client also carries shutter and settings commands. */
class SonyRemotePollPolicy {
    var nextEvent = 0L; private set
    var nextSnapshot = 0L; private set
    var hardFailures = 0; private set

    fun snapshotRead(atMs: Long) { nextSnapshot = atMs + SNAPSHOT_MS; nextEvent = atMs + EVENT_MS }
    fun eventRead(atMs: Long) { nextEvent = atMs + EVENT_MS }
    fun backoff(snapshot: Boolean, atMs: Long) { if (snapshot) snapshotRead(atMs) else eventRead(atMs) }
    fun success() { hardFailures = 0 }

    /** True once the camera has been unreachable three times in a row without live frames. */
    fun failed(error: Throwable, recentLiveFrame: Boolean): Boolean {
        if (error !is SonyNetworkError || recentLiveFrame) return false
        hardFailures++
        return hardFailures >= 3
    }

    companion object {
        const val EVENT_MS = 3_000L
        const val SNAPSHOT_MS = 15_000L
        fun feedbackMethod(methods: Set<String>): String? = when {
            "getEvent" in methods -> "getEvent"
            "getExposureMode" in methods -> "getExposureMode"
            else -> null
        }
    }
}
