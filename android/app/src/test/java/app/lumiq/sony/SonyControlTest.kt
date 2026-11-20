package app.lumiq.sony

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** A scripted camera: queued replies per method; getAvailableApiList answers with [methods]. */
private class ScriptedSony(var methods: List<String> = listOf("actTakePicture")) {
    val calls = mutableListOf<String>()
    val params = mutableListOf<Pair<String, List<Any?>>>()
    val replies = HashMap<String, ArrayDeque<() -> JSONArray>>()

    fun reply(method: String, vararg results: () -> JSONArray) { replies.getOrPut(method) { ArrayDeque() }.addAll(results) }
    fun ok(json: String): () -> JSONArray = { JSONArray(json) }
    fun error(method: String, code: Int): () -> JSONArray = { throw SonyAPIError(method, code, "") }

    val call: SonyCall = { method, p, _ ->
        calls += method; params += method to p
        val queue = replies[method]
        val result = when {
            queue != null && queue.isNotEmpty() -> queue.removeFirst()()
            method == "getAvailableApiList" -> JSONArray().put(JSONArray(methods))
            else -> throw SonyRemoteError("Unexpected mock request: $method")
        }
        JSONObject().put("result", result)
    }
}

/** Ports of the key cases in SonyControlPolicyTests, SonyRemoteSettingsTests and SonyRemoteSnapshotTests. */
class SonyControlTest {
    private fun fails(block: () -> Unit): Exception = try { block(); fail("expected an error"); throw IllegalStateException() } catch (e: Exception) { e }

    @Test fun cameraStateAndMethodTypesAreParsed() {
        val state = SonyControlState.from(JSONArray("""[{"type":"cameraStatus","cameraStatus":"MovieRecording"},{"type":"focusStatus","focusStatus":"Focused"},{"type":"availableApiList","names":["getEvent"]}]"""))
        assertTrue(state.captureBusy); assertEquals("Focused", state.focusStatus); assertEquals(setOf("getEvent"), state.availableMethods)
        assertEquals(setOf("cancelHalfPressShutter"), SonyMethodCapabilities.names(JSONArray("""[["cancelHalfPressShutter",[],[],"1.0"]]""")))
        assertEquals(setOf("cancelHalfPressShutter"), SonyMethodCapabilities.names(JSONArray("""[[["cancelHalfPressShutter",[],[],"1.0"]]]""")))
    }

    @Test fun reconnectHasFiniteBackoffAndHonorsManualDisconnect() {
        val p = SonyReconnectPolicy()
        assertNull(p.nextDelayMs(false)); assertEquals(0, p.attempts)
        assertEquals(1_000L, p.nextDelayMs(true)); assertEquals(2_000L, p.nextDelayMs(true)); assertEquals(4_000L, p.nextDelayMs(true))
        assertNull(p.nextDelayMs(true)); p.reset(); assertEquals(1_000L, p.nextDelayMs(true))
    }

    @Test fun autofocusPreparationAndReleaseSurroundSingleShutter() {
        val m = ScriptedSony(listOf("actTakePicture", "actHalfPressShutter", "getEvent"))
        m.reply("getEvent", m.ok("""[{"type":"cameraStatus","cameraStatus":"IDLE"}]"""), m.ok("""[{"type":"focusStatus","focusStatus":"Focused"}]"""))
        m.reply("actHalfPressShutter", m.ok("[]")); m.reply("cancelHalfPressShutter", m.ok("[]"))
        m.reply("actTakePicture", m.ok("""[["http://192.168.122.1/photo.jpg"]]"""))
        val urls = SonyCaptureWorkflow.take(m.call, setOf("cancelHalfPressShutter"), { true }, {})
        assertEquals(1, urls.size)
        assertEquals(1, m.calls.count { it == "actTakePicture" })
        assertTrue(m.calls.indexOf("actHalfPressShutter") < m.calls.indexOf("actTakePicture"))
        assertEquals("cancelHalfPressShutter", m.calls.last())
    }

    @Test fun pendingPhotoAwaitsOriginalCaptureWithoutRefiring() {
        val m = ScriptedSony(listOf("actTakePicture", "awaitTakePicture"))
        m.reply("actTakePicture", m.error("actTakePicture", 40403))
        m.reply("awaitTakePicture", m.ok("""[["http://192.168.122.1/photo.jpg"]]"""))
        SonyCaptureWorkflow.take(m.call, active = { true }, wait = {})
        assertEquals(1, m.calls.count { it == "actTakePicture" }); assertEquals(1, m.calls.count { it == "awaitTakePicture" })
    }

    @Test fun busyCameraNeverReceivesShutter() {
        val m = ScriptedSony(listOf("actTakePicture", "getEvent"))
        m.reply("getEvent", m.ok("""[{"type":"cameraStatus","cameraStatus":"StillSaving"}]"""))
        fails { SonyCaptureWorkflow.take(m.call, active = { true }, wait = {}) }
        assertTrue("actTakePicture" !in m.calls)
    }

    @Test fun focusFailureReleasesHalfPressWithoutTakingPhoto() {
        val m = ScriptedSony(listOf("actTakePicture", "actHalfPressShutter", "cancelHalfPressShutter", "getEvent"))
        m.reply("getEvent", m.ok("[]"), m.ok("""[{"type":"focusStatus","focusStatus":"Failed"}]"""))
        m.reply("actHalfPressShutter", m.ok("[0]")); m.reply("cancelHalfPressShutter", m.ok("[0]"))
        fails { SonyCaptureWorkflow.take(m.call, active = { true }, wait = {}) }
        assertTrue("actTakePicture" !in m.calls); assertEquals("cancelHalfPressShutter", m.calls.last())
    }

    @Test fun timeoutDoesNotReplayAmbiguousShutter() {
        val m = ScriptedSony()
        m.reply("actTakePicture", { throw SonyNetworkError(java.net.SocketTimeoutException("timeout")) })
        fails { SonyCaptureWorkflow.take(m.call, active = { true }, wait = {}) }
        assertEquals(1, m.calls.count { it == "actTakePicture" })
    }

    @Test fun cancelledSessionSendsNoCommand() {
        val m = ScriptedSony()
        fails { SonyCaptureWorkflow.take(m.call, active = { false }, wait = {}) }
        assertTrue(m.calls.isEmpty())
    }

    @Test fun settingsParseOnlyCameraReportedValues() {
        val aperture = SonySettingParser.parse(SonyRemoteSetting.Aperture, JSONArray("""["2.8",["2.8","4.0","5.6"]]"""), available = true)
        assertEquals(SonySettingValue.Text("2.8"), aperture.current); assertEquals(3, aperture.choices.size)
        val wb = SonySettingParser.parse(SonyRemoteSetting.WhiteBalance,
            JSONArray("""[{"whiteBalanceMode":"Color Temperature","colorTemperature":5500},[{"whiteBalanceMode":"Auto WB","colorTemperatureRange":[]},{"whiteBalanceMode":"Color Temperature","colorTemperatureRange":[6000,5000,500]}]]"""), true)
        assertEquals(SonySettingValue.WhiteBalance("Color Temperature", 5500), wb.current)
        assertEquals(1 + 3, wb.choices.size)
        assertEquals(listOf("Color Temperature", true, 5500), SonySettingValue.WhiteBalance("Color Temperature", 5500).parameters)
        val ev = SonySettingParser.parse(SonyRemoteSetting.Compensation, JSONArray("[3, 9, -9, 1]"), true)
        assertEquals("+1.00 EV", ev.current!!.label); assertEquals(19, ev.choices.size)
        val unknownStep = SonySettingParser.parse(SonyRemoteSetting.Compensation, JSONArray("[3]"), false)
        assertTrue(unknownStep.current!!.label.contains("EV step not reported"))
        assertNull(SonySettingParser.integer(true)); assertNull(SonySettingParser.integer(2.5))
    }

    @Test fun changeRequiresAcknowledgmentAndReadback() {
        val m = ScriptedSony(listOf("setIsoSpeedRate", "getAvailableIsoSpeedRate"))
        m.reply("getAvailableIsoSpeedRate", m.ok("""["100",["100","200"]]"""), m.ok("""["100",["100","200"]]"""), m.ok("""["200",["100","200"]]"""))
        m.reply("setIsoSpeedRate", m.ok("[0]"))
        val result = SonySettingWorkflow.change(SonyRemoteSetting.Iso, SonySettingValue.Text("200"), m.call, { true }, {})
        assertEquals(SonySettingValue.Text("200"), result.current)
        assertEquals(1, m.calls.count { it == "setIsoSpeedRate" })
        assertEquals(listOf("200"), m.params.first { it.first == "setIsoSpeedRate" }.second)
    }

    @Test fun unconfirmedWriteIsNeverReportedAsDone() {
        val m = ScriptedSony(listOf("setIsoSpeedRate", "getAvailableIsoSpeedRate"))
        repeat(7) { m.reply("getAvailableIsoSpeedRate", m.ok("""["100",["100","200"]]""")) }
        m.reply("setIsoSpeedRate", m.ok("[0]"))
        fails { SonySettingWorkflow.change(SonyRemoteSetting.Iso, SonySettingValue.Text("200"), m.call, { true }, {}) }
        assertEquals(1, m.calls.count { it == "setIsoSpeedRate" }) // Never re-sent.
    }

    @Test fun valueNotOfferedByLensIsRejectedBeforeAnyWrite() {
        val m = ScriptedSony(listOf("setFNumber", "getAvailableFNumber"))
        m.reply("getAvailableFNumber", m.ok("""["4.0",["4.0","5.6"]]"""))
        fails { SonySettingWorkflow.change(SonyRemoteSetting.Aperture, SonySettingValue.Text("1.8"), m.call, { true }, {}) }
        assertTrue("setFNumber" !in m.calls)
    }

    @Test fun autofocusRequiresReleaseAndAlwaysReleases() {
        val noRelease = ScriptedSony(listOf("actHalfPressShutter"))
        fails { SonyFocusWorkflow.trigger(noRelease.call, emptySet(), { true }, {}) }
        assertTrue("actHalfPressShutter" !in noRelease.calls)
        val m = ScriptedSony(listOf("actHalfPressShutter", "cancelHalfPressShutter", "getEvent"))
        m.reply("getEvent", m.ok("[]"), m.ok("""[{"type":"focusStatus","focusStatus":"Focused"}]"""))
        m.reply("actHalfPressShutter", m.ok("[0]")); m.reply("cancelHalfPressShutter", m.ok("[0]"))
        assertEquals("Sony reported focus locked.", SonyFocusWorkflow.trigger(m.call, emptySet(), { true }, {}))
        assertEquals("cancelHalfPressShutter", m.calls.last()); assertTrue("actTakePicture" !in m.calls)
    }

    @Test fun snapshotStatusNeverEnablesUnadvertisedSetters() {
        var s = SonyRemoteSnapshot().applyMethods(setOf("getIsoSpeedRate"))
        s = s.merge(SonyRemoteSetting.Iso, SonySettingParser.parse(SonyRemoteSetting.Iso, JSONArray("""["100",["100","200"]]"""), true))
        assertTrue(s.status(SonyRemoteSetting.Iso) is SonyRemoteControlStatus.TemporarilyUnavailable)
        s = s.applyMethods(setOf("setIsoSpeedRate"))
        assertEquals(SonyRemoteControlStatus.Available, s.status(SonyRemoteSetting.Iso))
        assertEquals(SonyRemoteControlStatus.CommandInProgress, s.status(SonyRemoteSetting.Iso, pending = true))
        val failed = s.writeFailed(SonyRemoteSetting.Iso, SonyAPIError("setIsoSpeedRate", 12, ""))
        assertEquals(SonyRemoteControlStatus.Unsupported, failed.status(SonyRemoteSetting.Iso))
    }

    @Test fun missingEventFieldsKeepConfirmedValues() {
        var s = SonyRemoteSnapshot().applyMethods(setOf("setIsoSpeedRate"))
            .merge(SonyRemoteSetting.Iso, SonySettingParser.parse(SonyRemoteSetting.Iso, JSONArray("""["400",["200","400"]]"""), true))
        s = s.applyEvent(JSONArray("""[{"type":"cameraStatus","cameraStatus":"IDLE"}]"""))
        assertEquals(SonySettingValue.Text("400"), s.settings[SonyRemoteSetting.Iso]!!.current)
        assertEquals("400", s.telemetry.iso)
    }

    @Test fun pollPolicyNeedsThreeHardFailuresWithoutFrames() {
        val p = SonyRemotePollPolicy()
        val network = SonyNetworkError(java.net.ConnectException("refused"))
        assertTrue(!p.failed(SonyRemoteError("parse"), recentLiveFrame = false))
        assertTrue(!p.failed(network, recentLiveFrame = true))
        assertTrue(!p.failed(network, false)); assertTrue(!p.failed(network, false)); assertTrue(p.failed(network, false))
    }

    @Test fun discoveryCandidatesStayOnTheSubnet() {
        val address = SonyDiscovery.number("192.168.122.10")!!
        val hosts = SonyDiscovery.candidates(address, SonyDiscovery.mask(24), previous = "192.168.122.1")
        assertEquals("192.168.122.1", hosts.first())
        assertTrue(hosts.none { it == "192.168.122.10" || it == "192.168.122.0" || it == "192.168.122.255" })
        assertTrue(hosts.size <= 64 && hosts.all { it.startsWith("192.168.122.") })
        assertTrue(SonyDiscovery.candidates(SonyDiscovery.number("10.0.0.5")!!, 0L).isEmpty())
    }
}
