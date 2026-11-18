package app.lumiq.editing

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.Shader
import kotlin.math.max
import kotlin.math.pow
import kotlin.random.Random

/** Edit settings; the same names and ranges as the iPhone EditRecipe. */
data class EditRecipe(
    val exposure: Double = 0.0,
    val contrast: Double = 1.0,
    val saturation: Double = 1.0,
    val warmth: Double = 0.0,
    val tint: Double = 0.0,
    val fade: Double = 0.0,
    val vignette: Double = 0.0,
    val grain: Double = 0.0,
    val quarterTurns: Int = 0,
)

/** Film looks ported from the iPhone FilmLook presets (parameters the Android renderer supports). */
enum class Look(val title: String, val recipe: EditRecipe) {
    Original("Original", EditRecipe()),
    Cine("Cine", EditRecipe(contrast = 1.08, saturation = 0.85, warmth = -0.08, grain = 0.08)),
    Honey("Honey", EditRecipe(exposure = 0.12, contrast = 0.96, saturation = 0.9, warmth = 0.4)),
    Sienna("Sienna", EditRecipe(contrast = 1.12, saturation = 0.78, warmth = 0.3, grain = 0.1, vignette = 0.12)),
    Arc("Arc", EditRecipe(contrast = 1.18, saturation = 0.72, warmth = -0.12)),
    Archive("Archive", EditRecipe(contrast = 0.88, saturation = 0.62, warmth = 0.25, grain = 0.14, fade = 0.15)),
    Clean("Clean", EditRecipe(contrast = 1.03, saturation = 1.03)),
    Harbor("Harbor", EditRecipe(contrast = 0.94, saturation = 0.82, warmth = -0.32)),
    Dusk("Dusk", EditRecipe(exposure = -0.12, contrast = 1.07, saturation = 0.8, warmth = -0.2, tint = 0.1)),
    Press("Press", EditRecipe(contrast = 1.2, saturation = 0.0, grain = 0.22)),
    Album("Album", EditRecipe(contrast = 0.9, saturation = 0.78, warmth = 0.14, grain = 0.09, fade = 0.1)),
    Relic("Relic", EditRecipe(contrast = 0.92, saturation = 0.7, warmth = 0.3, grain = 0.2, fade = 0.18)),
    Mono("Mono", EditRecipe(contrast = 1.12, saturation = 0.0)),
    Amber("Amber", EditRecipe(contrast = 0.95, saturation = 0.9, warmth = 0.3, grain = 0.12)),
}

object ImageEditor {
    fun colorMatrix(r: EditRecipe): ColorMatrix {
        val result = ColorMatrix()
        // Exposure in stops.
        val gain = 2.0.pow(r.exposure).toFloat()
        result.postConcat(ColorMatrix(floatArrayOf(gain, 0f, 0f, 0f, 0f, 0f, gain, 0f, 0f, 0f, 0f, 0f, gain, 0f, 0f, 0f, 0f, 0f, 1f, 0f)))
        // Contrast around mid grey.
        val c = r.contrast.toFloat()
        val o = 128f * (1 - c)
        result.postConcat(ColorMatrix(floatArrayOf(c, 0f, 0f, 0f, o, 0f, c, 0f, 0f, o, 0f, 0f, c, 0f, o, 0f, 0f, 0f, 1f, 0f)))
        // Saturation.
        result.postConcat(ColorMatrix().apply { setSaturation(r.saturation.toFloat()) })
        // Warmth (amber ↔ blue) and tint (magenta ↔ green).
        val warm = r.warmth.toFloat() * 0.16f
        val tint = r.tint.toFloat() * 0.10f
        result.postConcat(
            ColorMatrix(floatArrayOf(1 + warm, 0f, 0f, 0f, 0f, 0f, 1 - tint, 0f, 0f, 0f, 0f, 0f, 1 - warm, 0f, 0f, 0f, 0f, 0f, 1f, 0f)),
        )
        // Fade lifts the blacks.
        val f = r.fade.toFloat()
        val keep = 1 - f * 0.3f
        val lift = 255f * f * 0.12f
        result.postConcat(ColorMatrix(floatArrayOf(keep, 0f, 0f, 0f, lift, 0f, keep, 0f, 0f, lift, 0f, 0f, keep, 0f, lift, 0f, 0f, 0f, 1f, 0f)))
        return result
    }

    fun render(source: Bitmap, r: EditRecipe): Bitmap {
        val turns = ((r.quarterTurns % 4) + 4) % 4
        val rotated = if (turns == 0) source else {
            Bitmap.createBitmap(source, 0, 0, source.width, source.height, Matrix().apply { postRotate(90f * turns) }, true)
        }
        val out = Bitmap.createBitmap(rotated.width, rotated.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        canvas.drawBitmap(rotated, 0f, 0f, Paint(Paint.FILTER_BITMAP_FLAG).apply { colorFilter = ColorMatrixColorFilter(colorMatrix(r)) })
        if (r.vignette > 0.001) {
            val cx = out.width / 2f
            val cy = out.height / 2f
            val radius = max(out.width, out.height) * 0.75f
            val edge = (r.vignette.coerceIn(0.0, 1.0) * 220).toInt()
            val paint = Paint().apply {
                shader = RadialGradient(cx, cy, radius, intArrayOf(0x00000000, 0x00000000, edge shl 24), floatArrayOf(0f, 0.55f, 1f), Shader.TileMode.CLAMP)
            }
            canvas.drawRect(0f, 0f, out.width.toFloat(), out.height.toFloat(), paint)
        }
        if (r.grain > 0.001) addGrain(out, r.grain)
        if (rotated !== source) rotated.recycle()
        return out
    }

    private fun addGrain(bitmap: Bitmap, amount: Double) {
        // Tiled noise keeps this fast on full-resolution photos.
        val tile = 128
        val noise = Bitmap.createBitmap(tile, tile, Bitmap.Config.ARGB_8888)
        val random = Random(7)
        val alpha = (amount.coerceIn(0.0, 1.0) * 70).toInt()
        val pixels = IntArray(tile * tile) {
            val v = random.nextInt(256)
            (alpha shl 24) or (v shl 16) or (v shl 8) or v
        }
        noise.setPixels(pixels, 0, tile, 0, 0, tile, tile)
        val paint = Paint().apply { shader = android.graphics.BitmapShader(noise, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT) }
        Canvas(bitmap).drawRect(0f, 0f, bitmap.width.toFloat(), bitmap.height.toFloat(), paint)
        noise.recycle()
    }
}
