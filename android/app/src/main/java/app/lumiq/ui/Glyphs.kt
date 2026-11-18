package app.lumiq.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Line glyphs drawn in a 24-unit box, standing in for the SF Symbols used on
 * iPhone (bolt, photo, sliders, aperture, arrows…). No icon font is needed.
 */
enum class Glyph { Bolt, BoltOff, BoltAuto, Photo, Sliders, Ellipsis, Aperture, Close, Rescan, Arrow, Check, Warning, Flip, Grid, Level, Sun, Share, Trash, Edit, Back, Chevron, Rotate, Key }

@Composable
fun GlyphIcon(glyph: Glyph, tint: Color, size: Dp = 22.dp, modifier: Modifier = Modifier, rotation: Float = 0f) {
    Canvas(modifier.size(size)) { rotate(rotation) { drawGlyph(glyph, tint) } }
}

fun DrawScope.drawGlyph(glyph: Glyph, tint: Color) {
    val u = size.minDimension / 24f
    fun p(x: Float, y: Float) = Offset(x * u, y * u)
    val stroke = Stroke(width = 1.8f * u, cap = StrokeCap.Round, join = StrokeJoin.Round)
    fun line(vararg pts: Pair<Float, Float>, close: Boolean = false, fill: Boolean = false) {
        val path = Path()
        pts.forEachIndexed { i, (x, y) -> if (i == 0) path.moveTo(x * u, y * u) else path.lineTo(x * u, y * u) }
        if (close) path.close()
        if (fill) drawPath(path, tint) else drawPath(path, tint, style = stroke)
    }
    when (glyph) {
        Glyph.Bolt, Glyph.BoltOff, Glyph.BoltAuto -> {
            line(13f to 2f, 5f to 13.5f, 11f to 13.5f, 10f to 22f, 18.5f to 10f, 12.5f to 10f, close = true, fill = glyph == Glyph.Bolt)
            if (glyph == Glyph.BoltOff) line(3f to 3f, 21f to 21f)
            if (glyph == Glyph.BoltAuto) drawCircle(tint, 3.2f * u, p(19.5f, 19.5f))
        }
        Glyph.Photo -> {
            drawRoundRect(tint, p(3f, 5f), Size(18f * u, 14f * u), CornerRadius(2.5f * u), style = stroke)
            line(3.5f to 17f, 9f to 11.5f, 13f to 15.5f, 15.5f to 13f, 20.5f to 17.5f)
            drawCircle(tint, 1.6f * u, p(16f, 9f))
        }
        Glyph.Sliders -> {
            line(4f to 7f, 20f to 7f); line(4f to 12f, 20f to 12f); line(4f to 17f, 20f to 17f)
            drawCircle(tint, 2.2f * u, p(9f, 7f)); drawCircle(tint, 2.2f * u, p(15f, 12f)); drawCircle(tint, 2.2f * u, p(7f, 17f))
        }
        Glyph.Ellipsis -> { drawCircle(tint, 1.9f * u, p(5f, 12f)); drawCircle(tint, 1.9f * u, p(12f, 12f)); drawCircle(tint, 1.9f * u, p(19f, 12f)) }
        Glyph.Aperture -> {
            drawCircle(tint, 9f * u, p(12f, 12f), style = stroke)
            for (k in 0 until 6) rotate(60f * k, p(12f, 12f)) { line(12f to 3f, 16.5f to 13.5f) }
        }
        Glyph.Close -> { line(6f to 6f, 18f to 18f); line(18f to 6f, 6f to 18f) }
        Glyph.Rescan -> {
            drawArc(tint, -60f, 300f, false, p(4.5f, 4.5f), Size(15f * u, 15f * u), style = stroke)
            line(15.5f to 2.5f, 19f to 5.2f, 15f to 7.5f)
        }
        Glyph.Arrow -> { line(12f to 20f, 12f to 4f); line(6f to 10f, 12f to 4f, 18f to 10f) }
        Glyph.Check -> {
            drawCircle(tint, 10f * u, p(12f, 12f))
            line(7.5f to 12.5f, 10.5f to 15.5f, 16.5f to 9f)
        }
        Glyph.Warning -> {
            drawCircle(tint, 9f * u, p(12f, 12f), style = stroke)
            line(12f to 7f, 12f to 13f); drawCircle(tint, 1.2f * u, p(12f, 16.5f))
        }
        Glyph.Flip -> {
            drawArc(tint, 200f, 150f, false, p(4f, 4f), Size(16f * u, 16f * u), style = stroke)
            drawArc(tint, 20f, 150f, false, p(4f, 4f), Size(16f * u, 16f * u), style = stroke)
            line(17.5f to 3.5f, 19.5f to 7.5f, 15.5f to 8.5f)
            line(6.5f to 20.5f, 4.5f to 16.5f, 8.5f to 15.5f)
        }
        Glyph.Grid -> {
            drawRoundRect(tint, p(3f, 3f), Size(18f * u, 18f * u), CornerRadius(2f * u), style = stroke)
            line(9f to 3f, 9f to 21f); line(15f to 3f, 15f to 21f); line(3f to 9f, 21f to 9f); line(3f to 15f, 21f to 15f)
        }
        Glyph.Level -> { line(2f to 12f, 8f to 12f); line(16f to 12f, 22f to 12f); drawCircle(tint, 3f * u, p(12f, 12f), style = stroke) }
        Glyph.Sun -> {
            drawCircle(tint, 4f * u, p(12f, 12f), style = stroke)
            for (k in 0 until 8) rotate(45f * k, p(12f, 12f)) { line(12f to 2.5f, 12f to 5f) }
        }
        Glyph.Share -> { line(12f to 15f, 12f to 3f); line(8f to 7f, 12f to 3f, 16f to 7f); line(7f to 10f, 5f to 10f, 5f to 21f, 19f to 21f, 19f to 10f, 17f to 10f) }
        Glyph.Trash -> {
            line(4f to 6f, 20f to 6f); line(9f to 6f, 9f to 3.5f, 15f to 3.5f, 15f to 6f)
            line(6f to 6f, 7f to 21f, 17f to 21f, 18f to 6f); line(10f to 10f, 10f to 17f); line(14f to 10f, 14f to 17f)
        }
        Glyph.Edit -> { line(4f to 7f, 20f to 7f); line(4f to 17f, 20f to 17f); drawCircle(tint, 2.4f * u, p(15f, 7f)); drawCircle(tint, 2.4f * u, p(9f, 17f)) }
        Glyph.Back -> line(15f to 4f, 7f to 12f, 15f to 20f)
        Glyph.Chevron -> line(6f to 9f, 12f to 15f, 18f to 9f)
        Glyph.Rotate -> {
            drawArc(tint, 180f, 270f, false, p(4f, 6f), Size(14f * u, 14f * u), style = stroke)
            line(1.5f to 10.5f, 4f to 13.5f, 7f to 11f)
        }
        Glyph.Key -> {
            drawCircle(tint, 4.5f * u, p(8f, 12f), style = stroke)
            line(12.5f to 12f, 21f to 12f, 21f to 15.5f); line(17.5f to 12f, 17.5f to 15f)
        }
    }
}
