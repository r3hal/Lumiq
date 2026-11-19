package app.lumiq.aishot

import android.os.Handler
import android.os.Looper
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** Grayscale camera frame, already cropped to the visible viewfinder and upright. */
class LumaFrame(val width: Int, val height: Int, val data: ByteArray) {
    fun at(x: Int, y: Int): Int {
        val cx = if (x < 0) 0 else if (x >= width) width - 1 else x
        val cy = if (y < 0) 0 else if (y >= height) height - 1 else y
        return data[cy * width + cx].toInt() and 0xFF
    }
}

/**
 * Normalized cross-correlation template tracker on a small luma image.
 * Plays the role of Vision's VNTrackObjectRequest on iPhone: it follows the
 * marked part of the scene while the user pans the phone.
 */
class TemplateTracker {
    data class Observation(val rect: NRect, val confidence: Double)

    private var gridW = 0
    private var gridH = 0
    private var template = FloatArray(0)
    private var x = 0.0
    private var y = 0.0
    private var w = 0.0
    private var h = 0.0

    /** Returns false when the frame is unusable. */
    fun seed(frame: LumaFrame, rect: NRect): Boolean {
        if (frame.width < 8 || frame.height < 8) return false
        var r = rect
        // Flat areas (a white wall) cannot be followed; grow the patch until it has texture.
        for (attempt in 0 until 4) {
            place(frame, r)
            val sample = sample(frame, x, y)
            if (std(sample) >= 4f || attempt == 3) {
                template = sample
                return true
            }
            val grow = min(0.9, max(r.width, r.height) * 1.5)
            r = NRect(r.midX - grow / 2, r.midY - grow / 2, grow, grow)
        }
        return true
    }

    private fun place(frame: LumaFrame, r: NRect) {
        w = max(6.0, r.width * frame.width)
        h = max(6.0, r.height * frame.height)
        x = r.midX * frame.width - w / 2
        y = r.midY * frame.height - h / 2
        gridW = min(28, max(8, w.roundToInt()))
        gridH = min(28, max(8, h.roundToInt()))
    }

    private fun sample(frame: LumaFrame, ox: Double, oy: Double): FloatArray {
        val out = FloatArray(gridW * gridH)
        val sx = w / gridW
        val sy = h / gridH
        var k = 0
        for (j in 0 until gridH) {
            val py = (oy + (j + 0.5) * sy).toInt()
            for (i in 0 until gridW) {
                out[k++] = frame.at((ox + (i + 0.5) * sx).toInt(), py).toFloat()
            }
        }
        return out
    }

    private fun std(a: FloatArray): Float {
        var mean = 0f
        for (v in a) mean += v
        mean /= a.size
        var variance = 0f
        for (v in a) variance += (v - mean) * (v - mean)
        return sqrt(variance / a.size)
    }

    /** Zero-mean normalized cross correlation between the template and a patch at (ox, oy). */
    private fun ncc(frame: LumaFrame, ox: Double, oy: Double, t: FloatArray, tMean: Float, tStd: Float): Float {
        val sx = w / gridW
        val sy = h / gridH
        var sum = 0f
        var sumSq = 0f
        var cross = 0f
        var k = 0
        for (j in 0 until gridH) {
            val py = (oy + (j + 0.5) * sy).toInt()
            for (i in 0 until gridW) {
                val v = frame.at((ox + (i + 0.5) * sx).toInt(), py).toFloat()
                sum += v
                sumSq += v * v
                cross += v * (t[k++] - tMean)
            }
        }
        val n = t.size.toFloat()
        val mean = sum / n
        val variance = max(0f, sumSq / n - mean * mean)
        val std = sqrt(variance)
        if (std < 1f || tStd < 1f) return 0f
        return cross / (n * std * tStd)
    }

    /** Vertex of the parabola through (-1, left), (0, center), (1, right), limited to ±0.5 px. */
    private fun parabolicOffset(left: Float, center: Float, right: Float): Double {
        val curvature = left - 2 * center + right
        if (curvature >= -1e-6f) return 0.0 // Not a peak (flat or a valley): keep the whole-pixel position.
        return (0.5 * (left - right) / curvature).coerceIn(-0.5, 0.5)
    }

    fun update(frame: LumaFrame): Observation? {
        if (template.isEmpty()) return null
        var tMean = 0f
        for (v in template) tMean += v
        tMean /= template.size
        val tStd = max(1f, std(template))

        val radius = max(6, (frame.width * 0.14).roundToInt())
        var bestScore = -2f
        var bestX = x
        var bestY = y
        var dy = -radius
        while (dy <= radius) {
            var dx = -radius
            while (dx <= radius) {
                val score = ncc(frame, x + dx, y + dy, template, tMean, tStd)
                if (score > bestScore) { bestScore = score; bestX = x + dx; bestY = y + dy }
                dx += 2
            }
            dy += 2
        }
        val coarseX = bestX
        val coarseY = bestY
        for (fy in -1..1) for (fx in -1..1) {
            if (fx == 0 && fy == 0) continue
            val score = ncc(frame, coarseX + fx, coarseY + fy, template, tMean, tStd)
            if (score > bestScore) { bestScore = score; bestX = coarseX + fx; bestY = coarseY + fy }
        }
        // Sub-pixel refinement: fit a parabola through the scores one pixel either side of the peak.
        // Without it the position jumps in whole pixels of the 200 px tracking image (about 0.5 % of the
        // view each), which made the target + shake even when the phone was held still.
        val peakX = bestX
        val peakY = bestY
        bestX = peakX + parabolicOffset(ncc(frame, peakX - 1, peakY, template, tMean, tStd), bestScore, ncc(frame, peakX + 1, peakY, template, tMean, tStd))
        bestY = peakY + parabolicOffset(ncc(frame, peakX, peakY - 1, template, tMean, tStd), bestScore, ncc(frame, peakX, peakY + 1, template, tMean, tStd))
        // Keep the box reachable: allow it to leave the view by at most half its size.
        x = min(frame.width - w / 2, max(-w / 2, bestX))
        y = min(frame.height - h / 2, max(-h / 2, bestY))

        if (bestScore > 0.85f) {
            // Follow slow changes in light and perspective.
            val fresh = sample(frame, x, y)
            for (k in template.indices) template[k] = template[k] * 0.9f + fresh[k] * 0.1f
        }
        val rect = NRect(x / frame.width, y / frame.height, w / frame.width, h / frame.height)
        return Observation(rect, min(1.0, max(0.0, bestScore.toDouble())))
    }
}

/**
 * Thread bridge between the camera analysis thread and the main thread:
 * `ingest` is called for every analysis frame, observations arrive on main.
 */
class AIShotTracker {
    var onObservation: ((TemplateTracker.Observation?, Int) -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()
    private var generation = 0
    private var pendingRect: NRect? = null
    private var pendingReference: LumaFrame? = null
    private var tracker: TemplateTracker? = null
    private var activeGeneration = -1

    /** Starts tracking `rect`; seeds on `reference` (the frame the AI saw) when given. */
    fun track(rect: NRect, reference: LumaFrame? = null): Int = synchronized(lock) {
        generation += 1
        pendingRect = rect
        pendingReference = reference
        generation
    }

    fun stop() = synchronized(lock) {
        generation += 1
        pendingRect = null
        pendingReference = null
        tracker = null
        activeGeneration = -1
    }

    /** Analysis thread. */
    fun ingest(frame: LumaFrame) {
        val seed: Pair<NRect, LumaFrame?>?
        val current: Int
        synchronized(lock) {
            seed = pendingRect?.let { it to pendingReference }
            pendingRect = null
            pendingReference = null
            current = generation
            if (seed == null && tracker == null) return
        }
        var active = if (seed == null && activeGeneration == current) tracker else null
        if (seed != null) {
            val fresh = TemplateTracker()
            val reference = seed.second?.takeIf { it.width == frame.width && it.height == frame.height } ?: frame
            if (!fresh.seed(reference, seed.first)) return
            active = fresh
            synchronized(lock) {
                if (current != generation) return
                tracker = fresh
                activeGeneration = current
            }
        }
        val observation = active?.update(frame)
        main.post { onObservation?.invoke(observation, current) }
    }
}
