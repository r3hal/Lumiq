package app.lumiq.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Geometry is drawn in a 135×135 design box, exactly as the iPhone LumiqBrand.swift. */
private fun bracketsPath(): Path = Path().apply {
    moveTo(72f, 7f); lineTo(24f, 7f)
    arcTo(Rect(7f, 7f, 41f, 41f), 270f, -90f, false)
    lineTo(7f, 70f)
    moveTo(128f, 65f); lineTo(128f, 100f)
    arcTo(Rect(72f, 72f, 128f, 128f), 0f, 90f, false)
    lineTo(63f, 128f)
}

private fun sparkPath(): Path = Path().apply {
    moveTo(68f, 35f)
    quadraticTo(71f, 64f, 100f, 67f)
    quadraticTo(71f, 70f, 68f, 99f)
    quadraticTo(65f, 70f, 36f, 67f)
    quadraticTo(65f, 64f, 68f, 35f)
    close()
}

private val Brackets = bracketsPath()
private val Spark = sparkPath()

/** Draws the mark into the current draw scope. */
fun DrawScope.drawLumiqMark(
    starColor: Color,
    bracketColor: Color,
    weight: Float = 14f,
    sparkScale: Float = 1f,
    sparkRotation: Float = 0f,
) {
    val s = minOf(size.width, size.height) / 135f
    withTransform({
        translate(size.width / 2 - 67.5f * s, size.height / 2 - 67.5f * s)
        scale(s, s, pivot = Offset.Zero)
    }) {
        drawPath(Brackets, bracketColor, style = Stroke(width = weight, cap = StrokeCap.Round, join = StrokeJoin.Round))
        rotate(sparkRotation, pivot = Offset(68f, 67f)) {
            scale(sparkScale, sparkScale, pivot = Offset(68f, 67f)) { drawPath(Spark, starColor) }
        }
    }
}

@Composable
fun LumiqMark(
    modifier: Modifier = Modifier,
    starColor: Color = Brand.softIris,
    bracketColor: Color = Brand.porcelain,
    weight: Float = 14f,
) {
    Canvas(modifier) { drawLumiqMark(starColor, bracketColor, weight) }
}

/** Mark + "Lumiq" wordmark, as in the primary logo. */
@Composable
fun LumiqLogo(height: Dp = 24.dp, textColor: Color = Brand.porcelain, starColor: Color = Brand.softIris) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(height * 0.32f),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.semantics { contentDescription = "Lumiq" },
    ) {
        LumiqMark(Modifier.size(height), starColor = starColor, bracketColor = textColor)
        Text("Lumiq", color = textColor, fontSize = (height.value * 1.05f).sp, fontWeight = FontWeight.Medium, letterSpacing = (-0.3).sp)
    }
}

/**
 * Shown when the app opens. Starts like the system launch screen (mark centered
 * on Ink) and then reveals the name, the same animation as on iPhone.
 */
@Composable
fun LumiqSplash(onFinished: () -> Unit) {
    val spark = remember { Animatable(0f) }
    val reveal = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        launch { spark.animateTo(1f, spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessLow)) }
        launch { delay(150); reveal.animateTo(1f, tween(450)) }
        delay(1100)
        onFinished()
    }
    Box(Modifier.fillMaxSize().background(Brand.ink), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(22.dp),
            modifier = Modifier.offset(y = (35f * (1 - reveal.value)).dp),
        ) {
            Canvas(Modifier.size(120.dp)) {
                drawLumiqMark(Brand.softIris, Brand.porcelain, sparkScale = 0.6f + 0.4f * spark.value, sparkRotation = -45f * (1 - spark.value))
            }
            Text(
                "Lumiq", color = Brand.porcelain, fontSize = 40.sp, fontWeight = FontWeight.Medium, letterSpacing = (-0.5).sp,
                modifier = Modifier.graphicsLayer { alpha = reveal.value; translationY = 8.dp.toPx() * (1 - reveal.value) },
            )
        }
    }
}
