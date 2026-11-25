package app.lumiq.sony

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.lumiq.aishot.AIShotCamera
import app.lumiq.aishot.AIShotTracker
import app.lumiq.aishot.CameraSnapshot
import app.lumiq.aishot.LumaFrame
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Sony camera over its DIRECT Wi-Fi (Camera Remote API), the Android counterpart of Focal/Sony/SonyRemoteCamera.
 * Connected means the camera answered with its advertised controls; streaming means real live-view frames
 * were decoded. Nothing is faked: controls appear only when the camera advertises them.
 */
class SonyRemoteCamera(context: Context) {
    enum class State { Disconnected, Connecting, Reconnecting, Connected, Streaming, Failed }

    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("sony", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    var state by mutableStateOf(State.Disconnected); private set
    var message by mutableStateOf<String?>(null); private set
    var model by mutableStateOf("Sony camera"); private set
    var frame by mutableStateOf<Bitmap?>(null); private set
    val hasFrame get() = frame != null
    var imageAspect by mutableStateOf(3.0 / 2); private set
    var resolution by mutableStateOf("—"); private set
    var fps by mutableStateOf<Double?>(null); private set
    var remote by mutableStateOf(SonyRemoteSnapshot()); private set
    var isCapturing by mutableStateOf(false); private set
    var isFocusing by mutableStateOf(false); private set
    var controlFeedback by mutableStateOf<String?>(null); private set
    val pendingSettings = mutableStateListOf<SonyRemoteSetting>()
    var host by mutableStateOf(SonyEndpoint.initialHost(prefs.getString("lastCameraHost", null)))
    var searching by mutableStateOf(false); private set
    var discoveryMessage by mutableStateOf<String?>(null); private set
    val discovered = mutableStateListOf<SonyDiscoveredCamera>()

    val isConnected get() = state == State.Connected || state == State.Streaming
    val methods get() = remote.methods
    val controlsBusy get() = isCapturing || isFocusing || pendingSettings.isNotEmpty() || remote.control.captureBusy
    val canCapture get() = isConnected && "actTakePicture" in methods && !controlsBusy
    val supportsTouchFocus get() = state == State.Streaming && "setTouchAFPosition" in methods
    val canTriggerAF get() = isConnected && !controlsBusy && "actHalfPressShutter" in methods &&
        ("cancelHalfPressShutter" in methods || "cancelHalfPressShutter" in remote.supported)

    fun settingDisabledReason(setting: SonyRemoteSetting): String? {
        if (!isConnected) return "Connect a Sony camera first."
        if (isCapturing || remote.control.captureBusy) return "The camera is busy taking or saving a photograph."
        return remote.status(setting, pending = setting in pendingSettings).reason
    }

    private var generation = 0
    private var link: SonyWifiLink? = null
    private var client: SonyApiClient? = null
    private var connectJob: Job? = null
    private var monitorJob: Job? = null
    private var recoveryJob: Job? = null
    private var discoveryJob: Job? = null
    private var stream: Thread? = null
    @Volatile private var streamConnection: HttpURLConnection? = null
    @Volatile private var lastFrameAt = 0L
    @Volatile private var latestJpeg: ByteArray? = null
    @Volatile private var tracker: AIShotTracker? = null
    private var wantsConnection = false
    private val recovery = SonyReconnectPolicy()
    private var refreshRequested = true
    private var pollRevision = 0
    var discoveredDescriptorUrl: String? = null

    // region Discovery

    fun search() {
        discoveryJob?.cancel()
        val found = SonyWifiLink.find(appContext)
        discovered.clear()
        if (found == null) {
            discoveryMessage = "Join the camera's DIRECT Wi-Fi in Android Settings, then search again. You can also enter its address manually."
            return
        }
        searching = true
        discoveryMessage = "Checking camera descriptors on your Wi-Fi…"
        discoveryJob = scope.launch {
            val results = withContext(Dispatchers.IO) { runCatching { SonyDiscovery.discover(found, host) }.getOrDefault(emptyList()) }
            searching = false
            discovered.clear(); discovered.addAll(results)
            discoveryMessage = if (results.isEmpty()) "No compatible camera found. Check that the camera shows its Connection screen, or enter its address manually."
            else "Camera found. Connect to start live view."
        }
    }

    fun choose(camera: SonyDiscoveredCamera) { host = camera.host; discoveredDescriptorUrl = camera.descriptorUrl }

    // endregion

    // region Connection

    fun connect(automatic: Boolean = false) {
        val selected = host.trim()
        if (!SonyEndpoint.validHost(selected)) {
            state = State.Failed; message = "Enter the camera's private IPv4 address after joining its DIRECT Wi-Fi."; return
        }
        val wifi = SonyWifiLink.find(appContext)
        if (wifi == null) {
            state = State.Failed; message = "Join the camera's DIRECT Wi-Fi in Android Settings first (stay connected even if Android says it has no internet)."; return
        }
        if (!automatic) recovery.reset()
        close(preserveRequest = false)
        wantsConnection = true; host = selected; link = wifi
        state = if (automatic) State.Reconnecting else State.Connecting
        message = if (automatic) "Restoring Sony live view…" else null
        val current = generation
        connectJob = scope.launch {
            try {
                val descriptor = withContext(Dispatchers.IO) { readDescriptor(selected, wifi) }
                if (current != generation) return@launch
                prefs.edit().putString("lastCameraHost", selected).apply()
                val api = SonyApiClient(descriptor.endpoint, wifi.connector)
                client = api
                val setup = withContext(Dispatchers.IO) { negotiate(api) }
                if (current != generation) return@launch
                model = descriptor.model
                var initial = remote.applyMethods(setup.methods).copy(supported = remote.supported + setup.methods + setup.supported, supportComplete = setup.supported.isNotEmpty())
                initial = initial.copy(settings = SonyRemoteSetting.entries.associateWith { SonyRemoteSettingState(readStatus = SonySettingReadStatus.Loading) })
                remote = initial
                var liveUrl = descriptor.liveUrl
                if ("startLiveview" in setup.methods) {
                    try {
                        liveUrl = withContext(Dispatchers.IO) { sonyResult(api.call("startLiveview")).opt(0) as? String } ?: liveUrl
                    } catch (e: Exception) {
                        if (current != generation) return@launch
                        message = "Remote controls connected. Live view unavailable: ${e.message}"
                    }
                }
                if (current != generation) return@launch
                state = State.Connected
                if (liveUrl != null) {
                    try { openStream(SonyEndpoint.validate(liveUrl, selected), wifi, current) } catch (e: SonyRemoteError) {
                        message = "Remote controls connected, but Sony returned an invalid live-view address."
                    }
                } else if (message == null) message = "Remote controls connected. This mode does not advertise a live-view stream."
                refreshRequested = true
                startMonitor(api, current)
            } catch (e: SonyCancelled) {
            } catch (e: Exception) {
                if (current != generation) return@launch
                fail("Could not connect to the Sony camera. Check its DIRECT Wi-Fi and Ctrl w/ Smartphone mode. ${e.message.orEmpty()}", current, recoverable = e is SonyNetworkError)
            }
        }
    }

    private fun readDescriptor(selected: String, wifi: SonyWifiLink): SonyDescriptor {
        val urls = buildList {
            discoveredDescriptorUrl?.let { u -> runCatching { SonyEndpoint.validate(u, selected) }.getOrNull()?.let(::add) }
            add("http://$selected:64321/DmsRmtDesc.xml"); add("http://$selected:61000/DmsRmtDesc.xml")
        }.distinct()
        var last: Exception? = null
        for (u in urls) {
            try {
                val c = wifi.connector.open(URL(u))
                try {
                    c.connectTimeout = 2_500; c.readTimeout = 3_000; c.instanceFollowRedirects = false; c.useCaches = false
                    if (c.responseCode !in 200..299) throw SonyRemoteError("The camera did not return a descriptor.")
                    return SonyDescriptor.parse(c.inputStream.use { SonyApiClient.readLimited(it, 512 * 1024) }, selected)
                } finally { c.disconnect() }
            } catch (e: java.io.IOException) { last = SonyNetworkError(e) } catch (e: Exception) { last = e }
        }
        throw last ?: SonyRemoteError("No advertised Sony wireless service was found.")
    }

    private class Setup(val methods: Set<String>, val supported: Set<String>)

    private fun negotiate(api: SonyApiClient): Setup {
        fun available() = SonySettingWorkflow.methods { m, p, t -> api.call(m, p, t) }
        var methods = available()
        if ("startRecMode" in methods && "actTakePicture" !in methods) {
            try { api.call("startRecMode") } catch (e: SonyAPIError) { if (e.code != 5) throw e }
            Thread.sleep(350)
            methods = available()
        }
        var supported = emptySet<String>()
        if ("getMethodTypes" in methods) {
            runCatching { supported = SonyMethodCapabilities.names(sonyResult(api.call("getMethodTypes", listOf(""), 2_000))) }
        }
        // Ask only for a live-view size the camera advertises; older firmware keeps its default.
        if ("setLiveviewSize" in methods) {
            val query = if ("getAvailableLiveviewSize" in methods) "getAvailableLiveviewSize" else "getSupportedLiveviewSize"
            if (query in methods) runCatching {
                SonyLiveViewSize.largest(sonyResult(api.call(query)))?.let { api.call("setLiveviewSize", listOf(it)) }
            }
        }
        return Setup(methods, supported)
    }

    fun pause() { close(preserveRequest = true) }

    fun resume() { if (wantsConnection && (state == State.Disconnected || state == State.Failed)) connect() }

    fun disconnect() { close(preserveRequest = false) }

    private fun fail(detail: String, current: Int, recoverable: Boolean) {
        if (current != generation) return
        val requested = wantsConnection
        close(preserveRequest = true)
        val delayMs = if (recoverable) recovery.nextDelayMs(requested) else null
        if (delayMs != null) {
            state = State.Reconnecting
            message = "Sony connection interrupted. Reconnecting ${recovery.attempts}/3…"
            val revision = generation
            recoveryJob = scope.launch {
                delay(delayMs)
                if (revision == generation && wantsConnection) connect(automatic = true)
            }
        } else {
            state = State.Failed
            message = detail + if (recoverable) " Rejoin the camera's Wi-Fi, then tap Connect." else ""
        }
    }

    private fun close(preserveRequest: Boolean) {
        val closingMethods = methods
        val closingSupported = remote.supported
        generation++
        connectJob?.cancel(); monitorJob?.cancel(); recoveryJob?.cancel()
        connectJob = null; monitorJob = null; recoveryJob = null
        pendingSettings.clear(); refreshRequested = true; pollRevision++
        stopStream()
        client?.let { api ->
            api.cancelPending()
            Thread {
                if ("cancelHalfPressShutter" in closingMethods || "cancelHalfPressShutter" in closingSupported) runCatching { api.call("cancelHalfPressShutter", emptyList(), 2_000) }
                if ("stopLiveview" in closingMethods) runCatching { api.call("stopLiveview", emptyList(), 2_000) }
                api.shutdown()
            }.start()
        }
        client = null
        remote = SonyRemoteSnapshot()
        model = "Sony camera"; resolution = "—"; fps = null; imageAspect = 3.0 / 2
        isCapturing = false; isFocusing = false; controlFeedback = null
        frame = null; latestJpeg = null
        if (!preserveRequest) wantsConnection = false
        state = State.Disconnected
    }

    fun dispose() { close(preserveRequest = false); scope.coroutineContext[Job]?.cancel() }

    // endregion

    // region Live view

    private fun openStream(url: String, wifi: SonyWifiLink, current: Int) {
        lastFrameAt = SystemClock.uptimeMillis()
        val thread = Thread({
            val parser = SonyLiveViewParser()
            var lastPublished = 0L
            var frames = 0
            var windowStart = SystemClock.uptimeMillis()
            try {
                val c = wifi.connector.open(URL(url))
                streamConnection = c
                c.connectTimeout = 5_000; c.readTimeout = 10_000; c.instanceFollowRedirects = false; c.useCaches = false
                if (c.responseCode !in 200..299) throw SonyRemoteError("Sony live view HTTP ${c.responseCode}.")
                val input = c.inputStream
                val chunk = ByteArray(64 * 1024)
                while (!Thread.currentThread().isInterrupted) {
                    val n = input.read(chunk)
                    if (n < 0) break
                    val jpegs = parser.append(chunk, n)
                    val jpeg = jpegs.lastOrNull() ?: continue // Only the newest frame matters.
                    val now = SystemClock.uptimeMillis()
                    lastFrameAt = now
                    if (now - lastPublished < 66) continue // About 15 frames a second on screen.
                    lastPublished = now
                    val bitmap = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: continue
                    latestJpeg = jpeg
                    tracker?.ingest(luma(bitmap, 200))
                    frames++
                    val window = now - windowStart
                    val measured = if (window >= 2_000) (frames * 1000.0 / window).also { frames = 0; windowStart = now } else null
                    main.post {
                        if (current != generation) return@post
                        frame = bitmap
                        if (state != State.Streaming) state = State.Streaming
                        imageAspect = bitmap.width.toDouble() / bitmap.height
                        resolution = "${bitmap.width} × ${bitmap.height}"
                        measured?.let { fps = it }
                    }
                }
                main.post { streamEnded("Sony ended the live-view stream.", current) }
            } catch (e: Exception) {
                if (!Thread.currentThread().isInterrupted) main.post { streamEnded("Sony live view stopped: ${e.message ?: e.javaClass.simpleName}", current) }
            }
        }, "sony-liveview")
        stream = thread
        thread.start()
    }

    private fun stopStream() {
        stream?.interrupt(); streamConnection?.disconnect()
        stream = null; streamConnection = null
    }

    private fun streamEnded(detail: String, current: Int) {
        if (current != generation) return
        if (isCapturing) {
            // Some cameras stop live view during a still capture; the capture continues and live view returns after.
            stopStream(); frame = null; state = State.Reconnecting; message = "Live view paused while the Sony takes the photo"
        } else {
            fail(detail, current, recoverable = true)
        }
    }

    // endregion

    // region Monitor (one background reader for events and settings)

    private fun startMonitor(api: SonyApiClient, current: Int) {
        if (monitorJob != null) return
        monitorJob = scope.launch {
            val policy = SonyRemotePollPolicy()
            while (isActive && current == generation) {
                val now = SystemClock.uptimeMillis()
                if (stream != null && !isCapturing && now - lastFrameAt > 8_000) {
                    fail("Sony live view stopped.", current, recoverable = true); return@launch
                }
                if (!isCapturing && !isFocusing && pendingSettings.isEmpty()) {
                    val revision = pollRevision
                    val active = { current == generation && revision == pollRevision }
                    val call: SonyCall = { m, p, t -> if (!active()) throw SonyCancelled(); api.call(m, p, t) }
                    val readingSnapshot = refreshRequested || now >= policy.nextSnapshot
                    try {
                        if (readingSnapshot) {
                            refreshRequested = false
                            val previous = remote
                            val next = withContext(Dispatchers.IO) { SonySnapshotWorkflow.read(previous, call, active) }
                            if (!active()) throw SonyCancelled()
                            remote = next
                            policy.snapshotRead(SystemClock.uptimeMillis()); policy.success()
                        } else {
                            val feedback = SonyRemotePollPolicy.feedbackMethod(methods)
                            if (feedback != null && now >= policy.nextEvent) {
                                val result = withContext(Dispatchers.IO) { sonyResult(call(feedback, if (feedback == "getEvent") listOf(false) else emptyList(), 3_000)) }
                                if (!active()) throw SonyCancelled()
                                val mode = if (feedback == "getEvent") SonyEventValues.telemetry(result).mode else result.opt(0) as? String
                                if (mode != null && mode != remote.telemetry.mode) refreshRequested = true
                                else if (feedback == "getEvent") {
                                    val next = remote.applyEvent(result)
                                    val exposureApis = SonyRemoteSetting.entries.flatMap { listOf(it.setter, it.getter, it.available) }.toSet()
                                    if (next.methods.intersect(exposureApis) != remote.methods.intersect(exposureApis)) refreshRequested = true
                                    remote = next
                                }
                                policy.eventRead(SystemClock.uptimeMillis()); policy.success()
                            }
                        }
                    } catch (e: SonyCancelled) {
                        if (current != generation) return@launch
                        refreshRequested = true
                    } catch (e: SonyModeChangedDuringRead) {
                        refreshRequested = true; delay(1_000)
                    } catch (e: Exception) {
                        if (active()) {
                            remote = remote.noteFailure(e)
                            if (policy.failed(e, recentLiveFrame = hasFrame && SystemClock.uptimeMillis() - lastFrameAt < 5_000)) {
                                fail("The Sony is unreachable. Wake the camera and check Wi-Fi.", current, recoverable = true); return@launch
                            }
                            policy.backoff(readingSnapshot, SystemClock.uptimeMillis())
                        }
                    }
                }
                delay(250)
            }
        }
    }

    fun refreshSettings() { if (isConnected) refreshRequested = true }

    private fun interruptBackgroundRead() { pollRevision++; refreshRequested = true }

    // endregion

    // region Commands

    fun change(setting: SonyRemoteSetting, value: SonySettingValue) {
        if (settingDisabledReason(setting) != null) return
        val api = client ?: return
        val current = generation
        interruptBackgroundRead(); pendingSettings += setting; controlFeedback = null
        scope.launch {
            try {
                val feedback = withContext(Dispatchers.IO) {
                    SonySettingWorkflow.change(setting, value, { m, p, t -> if (current != generation) throw SonyCancelled(); api.call(m, p, t) }, { current == generation })
                }
                if (current != generation) return@launch
                remote = remote.merge(setting, feedback)
                controlFeedback = "${setting.title} confirmed by the camera: ${feedback.current?.label ?: "—"}"
            } catch (e: SonyCancelled) {
            } catch (e: Exception) {
                if (current != generation) return@launch
                remote = remote.writeFailed(setting, e)
                controlFeedback = e.message
            } finally {
                if (current == generation) { pendingSettings -= setting; refreshRequested = true }
            }
        }
    }

    fun triggerAutofocus() {
        if (!canTriggerAF) return
        val api = client ?: return
        val current = generation
        interruptBackgroundRead(); isFocusing = true; controlFeedback = null
        scope.launch {
            try {
                val result = withContext(Dispatchers.IO) {
                    SonyFocusWorkflow.trigger({ m, p, t -> if (current != generation) throw SonyCancelled(); api.call(m, p, t) }, remote.supported, { current == generation })
                }
                if (current == generation) controlFeedback = result
            } catch (e: SonyCancelled) {
            } catch (e: Exception) {
                if (current == generation) controlFeedback = e.message
            } finally {
                if (current == generation) isFocusing = false
            }
        }
    }

    /** Touch focus at a point of the live view (0–1 each way), when the camera advertises it. */
    fun focus(x: Float, y: Float) {
        if (!supportsTouchFocus || controlsBusy) return
        val api = client ?: return
        val current = generation
        interruptBackgroundRead(); isFocusing = true
        scope.launch {
            try {
                withContext(Dispatchers.IO) { api.call("setTouchAFPosition", listOf(x.coerceIn(0f, 1f) * 100.0, y.coerceIn(0f, 1f) * 100.0), 2_000) }
            } catch (e: SonyCancelled) {
            } catch (e: Exception) {
                if (current == generation) message = e.message
            } finally {
                if (current == generation) isFocusing = false
            }
        }
    }

    /** Takes one photo on the Sony and transfers its JPEG. Throws with a plain explanation on failure. */
    suspend fun capture(): ByteArray {
        val api = client
        val wifi = link
        if (!canCapture || api == null || wifi == null) throw SonyRemoteError("Sony remote capture is not currently available, or the camera is busy.")
        interruptBackgroundRead()
        val current = generation
        val selected = host
        isCapturing = true
        try {
            val urls = try {
                withContext(Dispatchers.IO) {
                    SonyCaptureWorkflow.take({ m, p, t -> if (current != generation) throw SonyCancelled(); api.call(m, p, t) }, remote.supported, { current == generation })
                }
            } catch (e: SonyNetworkError) {
                throw SonyRemoteError("The Sony connection was interrupted. A photo may already be on the camera card. Check the card before taking another.")
            }
            if (current != generation) throw SonyCancelled()
            val url = SonyEndpoint.validate(urls.first(), selected)
            val bytes = withContext(Dispatchers.IO) {
                try {
                    val c = wifi.connector.open(URL(url))
                    try {
                        c.connectTimeout = 5_000; c.readTimeout = 30_000; c.instanceFollowRedirects = false; c.useCaches = false
                        if (c.responseCode !in 200..299) throw SonyRemoteError("The Sony photo transfer failed. Check the camera's card for the capture.")
                        c.inputStream.use { SonyApiClient.readLimited(it, 64 * 1024 * 1024) }
                    } finally { c.disconnect() }
                } catch (e: java.io.IOException) {
                    throw SonyRemoteError("Sony took the photo, but the transfer was interrupted. The original should be on the camera card.")
                }
            }
            val valid = bytes.size > 2 && bytes[0] == 0xff.toByte() && bytes[1] == 0xd8.toByte() &&
                BitmapFactory.Options().apply { inJustDecodeBounds = true }.also { BitmapFactory.decodeByteArray(bytes, 0, bytes.size, it) }.outWidth > 0
            if (!valid) throw SonyRemoteError("The Sony photo transfer failed. Check the camera's card for the capture.")
            return bytes
        } finally {
            if (current == generation) {
                isCapturing = false
                lastFrameAt = SystemClock.uptimeMillis()
                if (stream == null && wantsConnection && state == State.Reconnecting) connect(automatic = true)
            }
        }
    }

    // endregion

    /** AI Shot on the Sony picture: no remote zoom (zoom on the lens), frames and tracking from live view. */
    val aiShotCamera = object : AIShotCamera {
        override val zoom = 1.0
        override val minimumZoom = 1.0
        override val maximumZoom = 1.0
        override fun setZoom(value: Double, animated: Boolean) = Unit
        override val zoomsByHand = true
        override suspend fun snapshot(): CameraSnapshot? {
            val jpeg = latestJpeg ?: return null
            return withContext(Dispatchers.Default) {
                val bitmap = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return@withContext null
                CameraSnapshot(jpeg, luma(bitmap, 200))
            }
        }
        override fun setAIShotTracker(tracker: AIShotTracker?) { this@SonyRemoteCamera.tracker = tracker }
    }

    companion object {
        /** Grayscale copy of a frame for the AI Shot tracker. */
        fun luma(bitmap: Bitmap, width: Int): LumaFrame {
            val height = max(1, (width * bitmap.height.toDouble() / bitmap.width).roundToInt())
            val small = Bitmap.createScaledBitmap(bitmap, width, height, true)
            val pixels = IntArray(width * height)
            small.getPixels(pixels, 0, width, 0, 0, width, height)
            if (small !== bitmap) small.recycle()
            val out = ByteArray(width * height)
            for (i in pixels.indices) {
                val p = pixels[i]
                out[i] = ((((p shr 16) and 0xff) * 77 + ((p shr 8) and 0xff) * 150 + (p and 0xff) * 29) shr 8).toByte()
            }
            return LumaFrame(width, height, out)
        }
    }
}
