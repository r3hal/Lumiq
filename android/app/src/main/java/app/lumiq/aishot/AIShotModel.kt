package app.lumiq.aishot

import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.lumiq.ui.Haptics
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/** What AI Shot needs from the camera. */
interface AIShotCamera {
    val zoom: Double
    val minimumZoom: Double
    val maximumZoom: Double
    fun setZoom(value: Double, animated: Boolean = true)
    /** The current visible viewfinder as a ≤768 px JPEG plus the tracking frame. */
    suspend fun snapshot(): CameraSnapshot?
    /** Attaches the tracker to the analysis stream (null detaches it). */
    fun setAIShotTracker(tracker: AIShotTracker?)
}

class CameraSnapshot(val jpeg: ByteArray, val luma: LumaFrame)

/** A direction vector (x right, y down). */
data class Vec(val dx: Double, val dy: Double)

/**
 * Framed-style one-tap AI shot, the same state machine as the iPhone AIShotModel:
 * tap ✦ → "Finding your shot…" → one AI pick (subject, tip, frame) →
 * a tracked target box → center it → automatic zoom → "Ready".
 * One decision per tap: nothing re-plans or flickers while you aim.
 */
class AIShotModel(private val config: AIShotConfig, private val haptics: Haptics) {
    sealed class Phase {
        object Idle : Phase()
        object Finding : Phase()
        object Aiming : Phase()
        object Zooming : Phase()
        object Ready : Phase()
        data class Failed(val message: String) : Phase()

        val isActive get() = this != Idle
        val isLocked get() = this == Aiming || this == Zooming || this == Ready
    }

    var phase by mutableStateOf<Phase>(Phase.Idle); private set
    var suggestion by mutableStateOf<AIShotSuggestion?>(null); private set
    /** The tracked shot in viewfinder coordinates (normalized, top-left). */
    var frame by mutableStateOf<NRect?>(null); private set
    var instruction by mutableStateOf(""); private set
    /** Unit direction the camera should move while aiming. */
    var direction by mutableStateOf<Vec?>(null); private set

    private val scope: CoroutineScope = MainScope()
    private val service = AIShotService(config)
    private val tracker = AIShotTracker()
    private var camera: AIShotCamera? = null
    private var job: Job? = null
    private var token = 0
    private var trackedZoom = 1.0
    private var zoomRequested = false
    private var zoomSettleUntil = 0.0
    private var zoomStartedAt = 0.0
    private var lowConfidenceSince: Double? = null
    private var centeredSince: Double? = null
    private var lastGuidanceChange = 0.0
    // Steady target: heavy smoothing while the phone is held still, quick to follow a real pan.
    private val smoothX = OneEuroFilter(minCutoff = 0.6, beta = 4.0)
    private val smoothY = OneEuroFilter(minCutoff = 0.6, beta = 4.0)

    // Tunables (same as iPhone)
    private val readyEnter = 0.045
    private val readyExit = 0.085
    private val zoomWhenWithin = 0.12
    private val readyHold = 0.35

    init {
        tracker.onObservation = { observation, generation -> observe(observation, generation) }
    }

    private fun now() = SystemClock.uptimeMillis() / 1000.0

    fun start(camera: AIShotCamera, previewAspect: Double) {
        cancelWork()
        this.camera = camera
        if (!config.isConfigured) { fail(AIShotError.NotConfigured.userMessage); return }
        camera.setAIShotTracker(tracker)
        phase = Phase.Finding
        instruction = "Finding your shot…"
        suggestion = null; frame = null; direction = null
        haptics.soft()
        val zoom = camera.zoom
        val minimum = camera.minimumZoom
        val maximum = min(camera.maximumZoom, 6.0)
        job = scope.launch {
            try {
                val snapshot = camera.snapshot() ?: run { fail(AIShotError.NoFrame.userMessage); return@launch }
                val request = AIShotRequest(snapshot.jpeg, previewAspect, zoom, minimum, max(zoom, maximum))
                val result = withContext(Dispatchers.IO) { service.suggest(request) }
                ensureActive()
                lock(result, snapshot.luma, zoom)
            } catch (e: CancellationException) {
                throw e
            } catch (e: AIShotError) {
                fail(e.userMessage)
            } catch (e: Exception) {
                fail(AIShotError.InvalidResponse.userMessage)
            }
        }
    }

    /** Leaves AI Shot completely (classic guidance may resume). */
    fun stop() {
        cancelWork()
        camera?.setAIShotTracker(null)
        phase = Phase.Idle; suggestion = null; frame = null; instruction = ""; direction = null
    }

    fun dispose() { stop(); scope.cancel() }

    // Locking the AI decision

    private fun lock(s: AIShotSuggestion, reference: LumaFrame, zoom: Double) {
        suggestion = s
        trackedZoom = zoom; zoomRequested = false; centeredSince = null; lowConfidenceSince = null
        frame = s.frame
        resetSmoothing(s.frame)
        phase = Phase.Aiming
        instruction = s.tip
        haptics.success()
        token = tracker.track(trackedPart(s.frame), reference)
    }

    private fun observe(observation: TemplateTracker.Observation?, generation: Int) {
        val s = suggestion ?: return
        val current = frame ?: return
        val camera = camera ?: return
        if (generation != token || !phase.isLocked) return
        val now = now()

        // Zoom changed (ours or a pinch): rescale the shot and restart tracking.
        val zoomRatio = camera.zoom / max(0.01, trackedZoom)
        if (abs(zoomRatio - 1) > 0.02) {
            if (zoomSettleUntil == 0.0) zoomSettleUntil = now + 0.3
            if (now < zoomSettleUntil) return
            zoomSettleUntil = 0.0
            val scaled = rescale(current, zoomRatio)
            trackedZoom = camera.zoom
            frame = scaled
            resetSmoothing(scaled, now)
            token = tracker.track(trackedPart(scaled))
            if (phase == Phase.Zooming) phase = Phase.Aiming
            return
        }

        if (observation == null || observation.confidence < 0.3) {
            if (lowConfidenceSince == null) lowConfidenceSince = now
            if (now - (lowConfidenceSince ?: now) > 1.5) fail("Lost the shot. Tap ↻ to find a new one.")
            return
        }
        lowConfidenceSince = null

        // Smooth the tracked box so the target + and box stay still while the phone is held still.
        val measured = shot(observation.rect, current)
        val smoothed = NRect(
            smoothX.filter(measured.midX, now) - current.width / 2,
            smoothY.filter(measured.midY, now) - current.height / 2,
            current.width, current.height,
        )
        frame = smoothed

        val dx = smoothed.midX - 0.5
        val dy = smoothed.midY - 0.5
        val offset = max(abs(dx), abs(dy))
        val needsZoom = s.zoom / max(0.01, camera.zoom) > 1.1 && camera.zoom < camera.maximumZoom - 0.05

        // Zoom scales the remaining offset by the zoom ratio, so only zoom once it stays
        // centered afterwards (otherwise the target jumps back off-center, as seen on device).
        val zoomStep = min(s.zoom, camera.maximumZoom) / max(0.01, camera.zoom)
        val zoomWithin = max(0.025, min(zoomWhenWithin, readyExit * 0.8 / max(1.0, zoomStep)))
        if (needsZoom && !zoomRequested && offset < zoomWithin) {
            zoomRequested = true; zoomStartedAt = now
            phase = Phase.Zooming; direction = null
            camera.setZoom(min(s.zoom, camera.maximumZoom))
            return
        }

        val zoomDone = !needsZoom || zoomRequested
        if (phase == Phase.Zooming && now - zoomStartedAt > 1.2) phase = Phase.Aiming // Zoom could not change further.
        if (phase == Phase.Ready) {
            if (offset > readyExit) { phase = Phase.Aiming; centeredSince = null }
        } else if (zoomDone && offset < readyEnter) {
            if (centeredSince == null) centeredSince = now
            if (now - (centeredSince ?: now) >= readyHold) {
                phase = Phase.Ready; instruction = s.tip; direction = null
                haptics.medium()
            }
        } else {
            centeredSince = null
        }

        if (phase == Phase.Aiming) updateDirection(dx, dy, now)
    }

    /**
     * Like Framed, the text stays the AI's tip; direction is only an arrow (plus the box and
     * dashed line on the image). The arrow turns at most ~4×/s so it does not flicker.
     */
    private fun updateDirection(dx: Double, dy: Double, now: Double) {
        val length = hypot(dx, dy)
        if (length <= 0.025) { direction = null; return }
        if (now - lastGuidanceChange <= 0.25 && direction != null) return
        direction = Vec(dx / length, dy / length)
        lastGuidanceChange = now
    }

    private fun resetSmoothing(rect: NRect, time: Double = Double.NaN) {
        smoothX.reset(rect.midX, time)
        smoothY.reset(rect.midY, time)
    }

    private fun fail(message: String) {
        tracker.stop(); token = -1
        camera?.setAIShotTracker(null) // Rescan re-attaches it.
        phase = Phase.Failed(message); instruction = message; direction = null; frame = null
        haptics.warning()
    }

    private fun cancelWork() {
        job?.cancel(); job = null
        tracker.stop(); token = -1
        zoomRequested = false; zoomSettleUntil = 0.0; centeredSince = null; lowConfidenceSince = null
    }

    companion object {
        /** The tracker follows the middle of the shot; a box that fills the view after zooming cannot be tracked itself. */
        fun trackedPart(frame: NRect): NRect {
            val w = max(0.12, frame.width * 0.65)
            val h = max(0.12, frame.height * 0.65)
            return NRect(frame.midX - w / 2, frame.midY - h / 2, w, h)
        }

        fun shot(part: NRect, like: NRect): NRect =
            NRect(part.midX - like.width / 2, part.midY - like.height / 2, like.width, like.height)

        /** Zoom scales the view about its center. */
        fun rescale(rect: NRect, ratio: Double): NRect =
            NRect(0.5 + (rect.x - 0.5) * ratio, 0.5 + (rect.y - 0.5) * ratio, rect.width * ratio, rect.height * ratio)
    }
}
