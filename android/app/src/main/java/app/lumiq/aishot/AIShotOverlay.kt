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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
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
import kotlin.math.atan2
import kotlin.math.hypot

/** Viewfinder overlay for AI Shot: target box, center crosshair, label pill. */
@Composable
fun AIShotOverlay(model: AIShotModel, modifier: Modifier = Modifier) {
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
            }
            val f = model.frame
            if (phase.isLocked && f != null) {
                val left = (f.x * size.width).toFloat()
                val top = (f.y * size.height).toFloat()
                val w = (f.width * size.width).toFloat()
                val h = (f.height * size.height).toFloat()
                val target = Offset(left + w / 2, top + h / 2)
                val ready = phase == AIShotModel.Phase.Ready
                if (f.width < 0.85) {
                    drawRoundRect(Color.Black.copy(alpha = 0.3f), Offset(left, top + 1.5f), Size(w, h), CornerRadius(12.dp.toPx()), style = Stroke(4.dp.toPx()))
                    drawRoundRect(Palette.yellow, Offset(left, top), Size(w, h), CornerRadius(12.dp.toPx()), style = Stroke((if (ready) 3f else 2.5f).dp.toPx()))
                }
                if (phase == AIShotModel.Phase.Aiming && hypot(target.x - center.x, target.y - center.y) > 18.dp.toPx()) {
                    drawLine(
                        Palette.yellow.copy(alpha = 0.8f), center, target, 1.5.dp.toPx(),
                        pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 5.dp.toPx())),
                    )
                }
                drawPlus(target, 8.dp.toPx(), if (ready) Palette.yellow else Palette.mint, 2.dp.toPx())
            }
            if (phase.isActive && phase != AIShotModel.Phase.Finding) {
                drawPlus(center, 12.dp.toPx(), Color.White.copy(alpha = 0.9f), 1.2.dp.toPx())
            }
        }
        Box(Modifier.align(Alignment.TopCenter).padding(top = 12.dp)) { ShotPill(model) }
    }
}

@Composable
private fun ShotPill(model: AIShotModel) {
    when (model.phase) {
        AIShotModel.Phase.Finding -> Pill {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                CircularProgressIndicator(Modifier.size(11.dp), color = Palette.yellow, strokeWidth = 1.5.dp)
                Text("Finding your shot…", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium)
            }
        }
        AIShotModel.Phase.Aiming, AIShotModel.Phase.Zooming, AIShotModel.Phase.Ready -> Pill(Modifier.animateContentSize()) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(model.suggestion?.subject ?: "your shot", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (model.phase == AIShotModel.Phase.Ready) {
                    Box(Modifier.width(1.dp).height(12.dp).background(Color.White.copy(alpha = 0.35f)))
                    Text("Ready", color = Palette.yellow, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
        else -> Unit
    }
}

/** Instruction line under the viewfinder (replaces the classic guidance card). */
@Composable
fun AIShotInstruction(model: AIShotModel) {
    val phase = model.phase
    Row(
        Modifier.clip(RoundedCornerShape(50)).background(Color.Black.copy(alpha = 0.6f)).padding(horizontal = 14.dp, vertical = 8.dp)
            .animateContentSize(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        val direction = model.direction
        when {
            direction != null && phase == AIShotModel.Phase.Aiming -> {
                val degrees = Math.toDegrees(atan2(direction.dx, -direction.dy)).toFloat()
                GlyphIcon(Glyph.Arrow, Palette.yellow, 16.dp, rotation = degrees)
            }
            phase == AIShotModel.Phase.Ready -> GlyphIcon(Glyph.Check, Palette.yellow, 16.dp)
            phase is AIShotModel.Phase.Failed -> GlyphIcon(Glyph.Warning, Palette.orange, 16.dp)
        }
        Text(model.instruction, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 2, textAlign = TextAlign.Center)
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
