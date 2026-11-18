package app.lumiq.camera

import android.graphics.Bitmap
import app.lumiq.aishot.NRect
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.objects.ObjectDetection
import com.google.mlkit.vision.objects.defaults.ObjectDetectorOptions
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max

/** One reading of the classic on-device live guide. */
data class GuideReading(
    val subject: NRect?,
    val label: String?,
    val targetX: Double,
    val targetY: Double,
    val instruction: String,
    val ready: Boolean,
    val technique: String,
)

/**
 * Classic live guide: finds the main subject on-device (ML Kit, offline) and
 * guides it onto a rule-of-thirds point, like the iPhone guide does with Vision.
 * Runs on the camera analysis thread.
 */
class LiveGuide {
    private val detector = ObjectDetection.getClient(
        ObjectDetectorOptions.Builder()
            .setDetectorMode(ObjectDetectorOptions.STREAM_MODE)
            .enableClassification()
            .build(),
    )
    private var smoothed: NRect? = null
    private var target: Pair<Double, Double>? = null
    private var misses = 0
    private var centeredFrames = 0

    fun reset() { smoothed = null; target = null; misses = 0; centeredFrames = 0 }

    fun close() = runCatching { detector.close() }

    fun analyze(bitmap: Bitmap): GuideReading {
        val objects = runCatching {
            Tasks.await(detector.process(InputImage.fromBitmap(bitmap, 0)), 800, TimeUnit.MILLISECONDS)
        }.getOrNull().orEmpty()
        val w = bitmap.width.toDouble()
        val h = bitmap.height.toDouble()
        val best = objects.maxByOrNull { it.boundingBox.width() * it.boundingBox.height() }
        if (best == null) {
            misses += 1
            if (misses > 4) { smoothed = null; target = null }
        } else {
            misses = 0
            val b = best.boundingBox
            val box = NRect(b.left / w, b.top / h, b.width() / w, b.height() / h)
            val previous = smoothed
            smoothed = if (previous == null) box else NRect(
                previous.x + (box.x - previous.x) * 0.45, previous.y + (box.y - previous.y) * 0.45,
                previous.width + (box.width - previous.width) * 0.45, previous.height + (box.height - previous.height) * 0.45,
            )
        }
        val subject = smoothed ?: return GuideReading(null, null, 0.5, 0.5, "Point at a subject", false, "")
        val label = best?.labels?.maxByOrNull { it.confidence }?.text?.lowercase()?.takeIf { it.isNotBlank() } ?: "subject"

        // Large subjects are centered; others go to the nearest thirds point (with hysteresis).
        val large = subject.width > 0.55 || subject.height > 0.55
        val chosen: Pair<Double, Double> = if (large) 0.5 to 0.5 else {
            val points = listOf(1.0 / 3 to 1.0 / 3, 2.0 / 3 to 1.0 / 3, 1.0 / 3 to 2.0 / 3, 2.0 / 3 to 2.0 / 3)
            val nearest = points.minBy { hypot(it.first - subject.midX, it.second - subject.midY) }
            val current = target
            if (current != null && current != (0.5 to 0.5) &&
                hypot(current.first - subject.midX, current.second - subject.midY) <
                hypot(nearest.first - subject.midX, nearest.second - subject.midY) + 0.08
            ) current else nearest
        }
        target = chosen
        val dx = subject.midX - chosen.first
        val dy = subject.midY - chosen.second
        val centered = max(abs(dx), abs(dy)) < 0.05
        centeredFrames = if (centered) centeredFrames + 1 else 0
        val ready = centeredFrames >= 2
        val text = when {
            ready -> "Hold it there · Ready"
            else -> {
                // Moving the phone left moves the subject right in the frame.
                val parts = ArrayList<String>()
                if (abs(dx) > 0.04) parts.add(if (dx < 0) "left" else "right")
                if (abs(dy) > 0.04) parts.add(if (dy < 0) "up" else "down")
                if (parts.isEmpty()) "Almost there" else "Move " + parts.joinToString(" & ")
            }
        }
        return GuideReading(subject, label, chosen.first, chosen.second, text, ready, if (large) "centered" else "rule of thirds")
    }
}
