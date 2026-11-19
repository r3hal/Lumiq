package app.lumiq

import app.lumiq.aishot.LumaFrame
import app.lumiq.aishot.NRect
import app.lumiq.aishot.OneEuroFilter
import app.lumiq.aishot.TemplateTracker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.exp
import kotlin.math.sqrt
import kotlin.random.Random

/** The AI Shot target + must hold still when the phone does, and still follow a real pan. */
class AIShotSteadinessTest {
    private val width = 200
    private val height = 267

    /** Smooth textured scene (blobs) shifted by (sx, sy) pixels, plus sensor noise. */
    private fun scene(sx: Double, sy: Double, noise: Double, random: Random): LumaFrame {
        val blobs = listOf(Triple(90.0, 120.0, 14.0), Triple(118.0, 140.0, 9.0), Triple(70.0, 150.0, 7.0), Triple(105.0, 100.0, 6.0))
        val data = ByteArray(width * height)
        for (y in 0 until height) for (x in 0 until width) {
            var v = 60.0
            for ((bx, by, r) in blobs) {
                val dx = x - bx - sx
                val dy = y - by - sy
                v += 150 * exp(-(dx * dx + dy * dy) / (2 * r * r))
            }
            if (noise > 0) v += random.nextDouble(-noise, noise)
            data[y * width + x] = v.coerceIn(0.0, 255.0).toInt().toByte()
        }
        return LumaFrame(width, height, data)
    }

    private val part = NRect(0.3, 0.32, 0.3, 0.3)

    @Test fun trackerReportsSubPixelMotion() {
        val random = Random(1)
        val tracker = TemplateTracker()
        tracker.seed(scene(0.0, 0.0, 0.0, random), part)
        val start = tracker.update(scene(0.0, 0.0, 0.0, random))!!.rect
        val moved = tracker.update(scene(0.5, 0.0, 0.0, random))!!.rect
        val shiftPx = (moved.midX - start.midX) * width
        assertEquals(0.5, shiftPx, 0.25)
    }

    @Test fun filterRemovesNoiseButFollowsAPan() {
        val random = Random(2)
        val filter = OneEuroFilter(minCutoff = 0.6, beta = 4.0)
        val input = (0 until 120).map { 0.5 + random.nextDouble(-0.01, 0.01) }
        val still = input.mapIndexed { i, v -> filter.filter(v, i / 30.0) }.drop(30)
        val reduction = spread(input.drop(30)) / spread(still)
        assertTrue("noise only reduced ${reduction}x", reduction > 2.5)

        // A pan of 0.3 of the view in one second is followed within a fraction of a second.
        val pan = OneEuroFilter(minCutoff = 0.6, beta = 4.0)
        var out = 0.0
        for (i in 0..45) out = pan.filter(0.2 + 0.3 * minOf(1.0, i / 30.0), i / 30.0)
        assertEquals(0.5, out, 0.02)
    }

    @Test fun targetHoldsStillOnANoisyStillScene() {
        val (old, new) = jitter()
        println("AI Shot target jitter on a still scene, screen pixels on a 1080 px wide view (std): old ${"%.2f".format(old)}, new ${"%.2f".format(new)}")
        assertTrue("new jitter $new px", new < 1.5)
        assertTrue("new $new should be far below old $old", new < old / 3)
    }

    /** Std of the drawn target center (in 1080 px screen units) for the old and the new pipeline. */
    private fun jitter(): Pair<Double, Double> {
        val random = Random(3)
        val first = scene(0.0, 0.0, 12.0, random)
        val tracker = TemplateTracker()
        tracker.seed(first, part)
        val filterX = OneEuroFilter(0.6, 4.0)
        val filterY = OneEuroFilter(0.6, 4.0)
        var oldX = part.midX
        var oldY = part.midY
        val oldPoints = mutableListOf<Pair<Double, Double>>()
        val newPoints = mutableListOf<Pair<Double, Double>>()
        for (i in 0 until 150) {
            // Hand tremor: up to ±0.3 px of real motion plus 12 levels of sensor noise.
            val frame = scene(random.nextDouble(-0.3, 0.3), random.nextDouble(-0.3, 0.3), 12.0, random)
            val rect = tracker.update(frame)!!.rect
            val t = i / 30.0
            // Old: whole-pixel positions smoothed with a fixed 0.55 blend.
            oldX += (Math.round(rect.midX * width) / width.toDouble() - oldX) * 0.55
            oldY += (Math.round(rect.midY * height) / height.toDouble() - oldY) * 0.55
            val nx = filterX.filter(rect.midX, t)
            val ny = filterY.filter(rect.midY, t)
            if (i >= 30) {
                oldPoints += oldX to oldY
                newPoints += nx to ny
            }
        }
        return screenSpread(oldPoints) to screenSpread(newPoints)
    }

    private fun screenSpread(points: List<Pair<Double, Double>>): Double {
        val sx = spread(points.map { it.first }) * 1080
        val sy = spread(points.map { it.second }) * 1440
        return sqrt(sx * sx + sy * sy)
    }

    private fun spread(values: List<Double>): Double {
        val mean = values.average()
        return sqrt(values.sumOf { (it - mean) * (it - mean) } / values.size)
    }
}
