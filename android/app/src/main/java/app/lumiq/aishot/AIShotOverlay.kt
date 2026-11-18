package app.lumiq.aishot

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.lumiq.ui.Glyph
import app.lumiq.ui.GlyphIcon
import app.lumiq.ui.Palette
import app.lumiq.ui.Pill
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot

/**
 * Viewfinder overlay for AI Shot, matching Framed: a viewfinder-shaped yellow box around the
 * AI's shot, a dashed line from the center, a level reticle (— + —) whose middle line follows
 * the phone's tilt and turns yellow when level/Ready, and the subject pill (+ "Ready").
 * `roll` is the device tilt in degrees.
 */
@Composable
fun AIShotOverlay(model: AIShotModel, roll: Float, modifier: Modifier = Modifier) {
    val phase = model.phase
    val pulse = rememberInfiniteTransition(label = "finding")
    val breathe by pulse.animateFloat(0.94f, 1.06f, infiniteRepeatable(tween(800), RepeatMode.Reverse), label = "breathe")
    Box(modifier.fillMaxSize()) {
        Canvas(Modifier.fillMaxSize()) {
            val center = Offset(size.width / 2, size.height / 2)
            if (phase == AIShotModel.Phase.Finding) {
                val side = size.width * 0.42f
                scale(breathe, center) {
                    drawBrackets(Offset(center.x - side / 2, center.y - side / 2), Size(side, side), Palette.yellow.copy(alpha = 0.55f + 0.45f * (breathe - 0.94f) / 0.12f))
                }
                return@Canvas
            }
            val ready = phase == AIShotModel.Phase.Ready
            val f = model.frame
            if (phase.isLocked && f != null) {
                val left = (f.x * size.width).toFloat()
                val top = (f.y * size.height).toFloat()
                val w = (f.width * size.width).toFloat()
                val h = (f.height * size.height).toFloat()
                val target = Offset(left + w / 2, top + h / 2)
                if (f.width < 0.85) {
                    drawRoundRect(Color.Black.copy(alpha = 0.3f), Offset(left, top + 1.5f), Size(w, h), CornerRadius(10.dp.toPx()), style = Stroke(5.dp.toPx()))
                    drawRoundRect(Palette.yellow, Offset(left, top), Size(w, h), CornerRadius(10.dp.toPx()), style = Stroke(3.dp.toPx()))
                }
                if (!ready && hypot(target.x - center.x, target.y - center.y) > 18.dp.toPx()) {
                    drawLine(
                        Palette.yellow.copy(alpha = 0.85f), center, target, 1.5.dp.toPx(),
                        pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 5.dp.toPx())),
                    )
                }
                drawPlus(target, 8.dp.toPx(), if (ready) Palette.yellow else Palette.mint, 2.dp.toPx())
            }
            if (phase.isActive) drawLevelReticle(center, roll, ready)
        }
        if (phase.isLocked) {
            Box(Modifier.align(Alignment.TopCenter).padding(top = 12.dp)) { ShotPill(model) }
        }
    }
}

/** Framed-style reticle: fixed side ticks, a horizon line that follows the tilt. */
private fun DrawScope.drawLevelReticle(center: Offset, roll: Float, ready: Boolean) {
    val level = abs(roll) < 1.5f
    val tick = Color.White.copy(alpha = 0.75f)
    val gap = 56.dp.toPx()
    val arm = 20.dp.toPx()
    val w = 1.dp.toPx()
    drawLine(tick, Offset(center.x - gap - arm, center.y), Offset(center.x - gap, center.y), w)
    drawLine(tick, Offset(center.x + gap, center.y), Offset(center.x + gap + arm, center.y), w)
    val color = if (ready || level) Palette.yellow else Color.White.copy(alpha = 0.9f)
    rotate(if (level) 0f else roll.coerceIn(-45f, 45f), center) {
        val half = (if (ready) gap + arm else gap - 8.dp.toPx())
        drawLine(color, Offset(center.x - half, center.y), Offset(center.x + half, center.y), 1.2.dp.toPx(), StrokeCap.Round)
    }
    drawPlus(center, 6.dp.toPx(), Color.White, 1.2.dp.toPx())
}

@Composable
private fun ShotPill(model: AIShotModel) {
    Pill(Modifier.animateContentSize()) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(model.suggestion?.subject ?: "your shot", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (model.phase == AIShotModel.Phase.Ready) {
                Box(Modifier.width(1.dp).height(12.dp).background(Color.White.copy(alpha = 0.35f)))
                Text("Ready", color = Palette.yellow, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

/**
 * The guidance line under the viewfinder: "Finding your shot…", then the AI's tip (with an
 * arrow while aiming), a check at Ready, or the error.
 */
@Composable
fun AIShotInstruction(model: AIShotModel) {
    val phase = model.phase
    Row(
        Modifier.animateContentSize(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        val direction = model.direction
        when {
            phase == AIShotModel.Phase.Finding ->
                CircularProgressIndicator(Modifier.size(12.dp), color = Palette.yellow, strokeWidth = 1.5.dp)
            direction != null && phase == AIShotModel.Phase.Aiming -> {
                val degrees = Math.toDegrees(atan2(direction.dx, -direction.dy)).toFloat()
                GlyphIcon(Glyph.Arrow, Palette.yellow, 15.dp, rotation = degrees)
            }
            phase == AIShotModel.Phase.Ready -> GlyphIcon(Glyph.Check, Palette.yellow, 15.dp)
            phase is AIShotModel.Phase.Failed -> GlyphIcon(Glyph.Warning, Palette.orange, 15.dp)
        }
        Text(
            model.instruction,
            color = if (phase == AIShotModel.Phase.Finding) Palette.yellow else Color.White,
            fontSize = 13.sp, fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
        )
    }
}

fun DrawScope.drawPlus(c: Offset, half: Float, color: Color, width: Float) {
    drawLine(color, Offset(c.x, c.y - half), Offset(c.x, c.y + half), width, StrokeCap.Round)
    drawLine(color, Offset(c.x - half, c.y), Offset(c.x + half, c.y), width, StrokeCap.Round)
}

/** Four soft corner brackets. */
fun DrawScope.drawBrackets(topLeft: Offset, size: Size, color: Color, width: Float = 2.5f * density) {
    val arm = minOf(size.width, size.height) * 0.22f
    val corners = listOf(
        Triple(topLeft, 1f, 1f), Triple(Offset(topLeft.x + size.width, topLeft.y), -1f, 1f),
        Triple(Offset(topLeft.x, topLeft.y + size.height), 1f, -1f), Triple(Offset(topLeft.x + size.width, topLeft.y + size.height), -1f, -1f),
    )
    for ((corner, sx, sy) in corners) {
        drawLine(color, Offset(corner.x + sx * arm, corner.y), corner, width, StrokeCap.Round)
        drawLine(color, corner, Offset(corner.x, corner.y + sy * arm), width, StrokeCap.Round)
    }
}
