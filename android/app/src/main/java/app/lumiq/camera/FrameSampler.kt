package app.lumiq.camera

import android.graphics.Bitmap
import android.graphics.Rect
import app.lumiq.aishot.LumaFrame
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Samples an RGBA_8888 analysis frame into the visible viewfinder: crop rect
 * (from the CameraX ViewPort), rotation to upright, and mirroring for the front
 * camera. Output coordinates therefore equal what the user sees on screen, so
 * no extra preview projection is needed (unlike iPhone's PreviewProjection).
 */
class FrameSampler(
    private val buffer: ByteBuffer,
    private val rowStride: Int,
    private val pixelStride: Int,
    private val crop: Rect,
    private val rotation: Int,
    private val mirrored: Boolean,
) {
    private val limit = buffer.limit()

    /** Upright width / height of the visible area. */
    val aspect: Double = if (rotation == 90 || rotation == 270) crop.height().toDouble() / max(1, crop.width())
    else crop.width().toDouble() / max(1, crop.height())

    /** Byte offset of the source pixel for upright normalized (a, b). */
    private fun offset(aIn: Double, b: Double): Int {
        val a = if (mirrored) 1 - aIn else aIn
        val s: Double
        val t: Double
        when (rotation) {
            90 -> { s = b; t = 1 - a }
            180 -> { s = 1 - a; t = 1 - b }
            270 -> { s = 1 - b; t = a }
            else -> { s = a; t = b }
        }
        val x = (crop.left + s * crop.width()).toInt().coerceIn(crop.left, max(crop.left, crop.right - 1))
        val y = (crop.top + t * crop.height()).toInt().coerceIn(crop.top, max(crop.top, crop.bottom - 1))
        return (y * rowStride + x * pixelStride).coerceIn(0, max(0, limit - 4))
    }

    fun size(longSide: Int): Pair<Int, Int> =
        if (aspect >= 1) longSide to max(1, (longSide / aspect).roundToInt())
        else max(1, (longSide * aspect).roundToInt()) to longSide

    fun luma(width: Int): LumaFrame {
        val height = max(1, (width / aspect).roundToInt())
        val out = ByteArray(width * height)
        for (j in 0 until height) {
            val b = (j + 0.5) / height
            for (i in 0 until width) {
                val o = offset((i + 0.5) / width, b)
                val r = buffer.get(o).toInt() and 0xFF
                val g = buffer.get(o + 1).toInt() and 0xFF
                val bl = buffer.get(o + 2).toInt() and 0xFF
                out[j * width + i] = ((r * 77 + g * 150 + bl * 29) shr 8).toByte()
            }
        }
        return LumaFrame(width, height, out)
    }

    fun bitmap(width: Int, height: Int): Bitmap {
        val pixels = IntArray(width * height)
        for (j in 0 until height) {
            val b = (j + 0.5) / height
            for (i in 0 until width) {
                val o = offset((i + 0.5) / width, b)
                val r = buffer.get(o).toInt() and 0xFF
                val g = buffer.get(o + 1).toInt() and 0xFF
                val bl = buffer.get(o + 2).toInt() and 0xFF
                pixels[j * width + i] = (0xFF shl 24) or (r shl 16) or (g shl 8) or bl
            }
        }
        return Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
    }
}
