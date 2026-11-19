package app.lumiq.camera

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.widthIn
import app.lumiq.ui.DialogText
import app.lumiq.ui.LumiqDialog
import app.lumiq.ui.LumiqMenu
import app.lumiq.ui.MenuDivider
import app.lumiq.ui.MenuHeader
import app.lumiq.ui.MenuRow
import app.lumiq.ui.PrimaryButton
import app.lumiq.ui.RoundGlyphButton
import app.lumiq.ui.SecondaryButton
import app.lumiq.AppState
import app.lumiq.aishot.AIShotInstruction
import app.lumiq.aishot.AIShotModel
import app.lumiq.aishot.AIShotOverlay
import app.lumiq.aishot.drawPlus
import app.lumiq.settings.FlashMode
import app.lumiq.settings.PhotoAspect
import app.lumiq.ui.Glyph
import app.lumiq.ui.GlyphIcon
import app.lumiq.ui.LumiqLogo
import app.lumiq.ui.LumiqMark
import app.lumiq.ui.Palette
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.min
import kotlin.math.roundToInt

/** The main camera, laid out like the iPhone CameraView. */
@Composable
fun CameraScreen(
    app: AppState,
    onOpenLibrary: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenGoldenHour: () -> Unit,
    onReview: (File) -> Unit,
) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val camera = app.camera
    val aiShot = app.aiShot
    val settings = app.settings
    val scope = rememberCoroutineScope()

    var granted by remember { mutableStateOf(hasCameraPermission(context)) }
    var asked by remember { mutableStateOf(false) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        granted = ok; asked = true
        camera.access = if (ok) CameraController.Access.Checking else CameraController.Access.Denied
    }
    LaunchedEffect(Unit) { if (!granted) permission.launch(Manifest.permission.CAMERA) }

    val aspect = settings.aspect.ratio
    DisposableEffect(granted) {
        if (granted) camera.start(owner, aspect)
        onDispose { aiShot.stop(); camera.stop() }
    }
    LaunchedEffect(aspect) { if (granted) camera.setAspect(aspect) }
    // Classic guide pauses while AI Shot is active (same as iPhone).
    LaunchedEffect(settings.guide, aiShot.phase.isActive) { camera.setGuideEnabled(settings.guide && !aiShot.phase.isActive) }
    LaunchedEffect(camera.guide?.ready) { if (camera.guide?.ready == true) app.haptics.soft() }

    var showAspect by remember { mutableStateOf(false) }
    var showExposure by remember { mutableStateOf(false) }
    var showOptions by remember { mutableStateOf(false) }
    var showAIMenu by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var saved by remember { mutableStateOf(false) }

    val busy = saving || camera.isCapturing
    val canShoot = camera.isRunning && !busy

    fun shoot() {
        if (!canShoot) return
        saving = true
        app.haptics.medium()
        camera.takePhoto(settings.flash, settings.shutterSound) { file ->
            if (file == null) { saving = false; return@takePhoto }
            scope.launch {
                val photo = withContext(Dispatchers.IO) { app.store.importCapture(file, settings.autoSaveToGallery) }
                saving = false
                if (photo == null) { camera.errorMessage = "The photo could not be saved."; return@launch }
                aiShot.stop()
                if (settings.reviewAfterCapture) onReview(photo) else {
                    saved = true; delay(1600); saved = false
                }
            }
        }
    }

    // ✕ cancels until the shot is Ready (like Framed); ↻ then finds a new one.
    fun aiShotTapped() {
        val phase = aiShot.phase
        if (phase == AIShotModel.Phase.Finding || phase == AIShotModel.Phase.Aiming || phase == AIShotModel.Phase.Zooming) {
            aiShot.stop(); return
        }
        aiShot.start(camera, aspect)
    }

    BoxWithConstraints(Modifier.fillMaxSize().background(Palette.ink).systemBarsPadding()) {
        val footerHeight = 168.dp
        val available = (maxHeight - 94.dp - footerHeight).coerceAtLeast(160.dp)
        val width = min(maxWidth.value, (available.value * aspect).toFloat()).dp
        val height = (width.value / aspect).toFloat().dp

        Column(Modifier.fillMaxSize()) {
            // Toolbar
            Row(
                Modifier.fillMaxWidth().height(54.dp).padding(horizontal = 18.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                LumiqLogo(height = 20.dp)
                Spacer(Modifier.weight(1f))
                if (camera.hasFlash && !camera.isFront) {
                    val glyph = when (settings.flash) { FlashMode.Off -> Glyph.BoltOff; FlashMode.On -> Glyph.Bolt; FlashMode.Auto -> Glyph.BoltAuto }
                    ToolbarButton(glyph, "Flash ${settings.flash.label}", if (settings.flash == FlashMode.Off) Palette.text else Palette.yellow) {
                        settings.updateFlash(FlashMode.entries[(settings.flash.ordinal + 1) % FlashMode.entries.size])
                    }
                }
                ToolbarButton(Glyph.Sliders, "Settings", Palette.text, onOpenSettings)
                Box {
                    ToolbarButton(Glyph.Ellipsis, "Camera options", Palette.text) { showOptions = true }
                    LumiqMenu(showOptions, onDismiss = { showOptions = false }) {
                        if (camera.hasFrontAndBack) {
                            MenuRow(if (camera.isFront) "Back camera" else "Front camera", Glyph.Flip) { showOptions = false; aiShot.stop(); camera.flip() }
                            MenuDivider()
                        }
                        MenuRow("Grid", Glyph.Grid, checked = settings.grid) { settings.updateGrid(!settings.grid) }
                        MenuRow("Level", Glyph.Level, checked = settings.level) { settings.updateLevel(!settings.level) }
                        MenuRow("Classic live guide", Glyph.Aperture, checked = settings.guide) { settings.updateGuide(!settings.guide) }
                        MenuDivider()
                        MenuRow("Golden hour", Glyph.Sun) { showOptions = false; onOpenGoldenHour() }
                        MenuRow("Settings", Glyph.Sliders) { showOptions = false; onOpenSettings() }
                    }
                }
            }
            // Status row
            Row(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) {
                Box {
                    GlassChip(active = showAspect, onClick = { showAspect = true; showExposure = false }) {
                        AspectGlyph(settings.aspect, Palette.text)
                        Text(settings.aspect.label, color = Palette.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                        GlyphIcon(Glyph.Chevron, Palette.muted, 9.dp, rotation = if (showAspect) 180f else 0f)
                    }
                    LumiqMenu(showAspect, onDismiss = { showAspect = false }) {
                        MenuHeader("Photo shape")
                        PhotoAspect.entries.forEach { a ->
                            val selected = a == settings.aspect
                            MenuRow(a.label, selected = selected, leading = { AspectGlyph(a, if (selected) Palette.accent else Palette.muted) }) {
                                showAspect = false; aiShot.stop(); settings.updateAspect(a)
                            }
                        }
                    }
                }
                Spacer(Modifier.weight(1f))
                GlassChip(active = showExposure, onClick = { showExposure = !showExposure; showAspect = false }) {
                    GlyphIcon(Glyph.Aperture, if (showExposure) Palette.accent else Palette.text, 17.dp)
                    Text("EV ${camera.exposureLabel}", color = if (showExposure) Palette.accent else Palette.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                }
            }
            // Viewfinder
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                Box(Modifier.size(width, height).clip(RoundedCornerShape(22.dp)).background(Color.Black)) {
                    if (granted && camera.access != CameraController.Access.Unavailable) {
                        Viewfinder(app, showExposure = showExposure, saved = saved)
                    } else {
                        PermissionView(denied = asked && !granted, unavailable = camera.access == CameraController.Access.Unavailable,
                            onRetry = { if (!granted) permission.launch(Manifest.permission.CAMERA) else camera.start(owner, aspect) })
                    }
                }
            }
            // Footer: one guidance line, the lens row, then library · shutter · AI Shot.
            FooterLine(app, Modifier.fillMaxWidth().height(40.dp).padding(horizontal = 20.dp))
            Box(Modifier.fillMaxWidth().height(40.dp), contentAlignment = Alignment.Center) {
                if (camera.isRunning) LensButtons(camera)
            }
            Row(
                Modifier.fillMaxWidth().height(88.dp).padding(horizontal = 30.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                LibraryThumbnail(app, enabled = !busy, onClick = onOpenLibrary)
                Spacer(Modifier.weight(1f))
                ShutterButton(enabled = canShoot, busy = busy, onClick = ::shoot)
                Spacer(Modifier.weight(1f))
                Box {
                    AIShotButton(aiShot.phase, enabled = camera.isRunning && !busy, onClick = ::aiShotTapped, onLongClick = { showAIMenu = true })
                    LumiqMenu(showAIMenu, onDismiss = { showAIMenu = false }) {
                        if (aiShot.phase.isActive) MenuRow("Exit AI Shot", Glyph.Close) { showAIMenu = false; aiShot.stop() }
                        MenuRow("Classic live guide", Glyph.Aperture, checked = settings.guide) { settings.updateGuide(!settings.guide) }
                    }
                }
            }
        }
    }

    val error = camera.errorMessage
    if (error != null) {
        LumiqDialog("Camera", onDismiss = { camera.errorMessage = null }, primary = "OK" to { camera.errorMessage = null }) { DialogText(error) }
    }
}

@Composable
private fun Viewfinder(app: AppState, showExposure: Boolean, saved: Boolean) {
    val camera = app.camera
    val aiShot = app.aiShot
    val settings = app.settings
    var focusPoint by remember { mutableStateOf<Offset?>(null) }
    LaunchedEffect(focusPoint) { if (focusPoint != null) { delay(900); focusPoint = null } }

    Box(Modifier.fillMaxSize()) {
        AndroidView(factory = { camera.previewView }, modifier = Modifier.fillMaxSize())
        // Gestures: tap to focus, pinch to zoom.
        Box(
            Modifier.fillMaxSize()
                .pointerInput(Unit) { detectTransformGestures { _, _, zoom, _ -> if (zoom != 1f) camera.pinch(zoom) } }
                .pointerInput(Unit) {
                    detectTapGestures { p ->
                        camera.focus(p.x / size.width, p.y / size.height)
                        focusPoint = p
                    }
                },
        )
        if (settings.grid || aiShot.phase.isActive) GridOverlay()
        val roll = rememberDeviceRoll(settings.level || aiShot.phase.isActive)
        if (settings.level && !aiShot.phase.isActive) LevelOverlay(roll)
        if (aiShot.phase.isActive) AIShotOverlay(aiShot, roll) else if (settings.guide) ClassicGuideOverlay(camera.guide)
        focusPoint?.let { p ->
            Canvas(Modifier.fillMaxSize()) {
                val s = 64.dp.toPx()
                drawRect(Palette.yellow, Offset(p.x - s / 2, p.y - s / 2), Size(s, s), style = Stroke(1.5.dp.toPx()))
            }
        }
        // Only transient things sit on the image; guidance text and lenses are in the footer (like Framed).
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            AnimatedVisibility(saved, enter = fadeIn(), exit = fadeOut()) { SavedBadge() }
            if (showExposure) ExposureStrip(camera)
        }
        if (!camera.isRunning) {
            CircularProgressIndicator(Modifier.align(Alignment.Center).size(28.dp), color = Palette.yellow, strokeWidth = 2.dp)
        }
    }
}

@Composable
private fun GridOverlay() {
    Canvas(Modifier.fillMaxSize()) {
        val c = Color.White.copy(alpha = 0.35f)
        val w = 0.7.dp.toPx()
        for (k in 1..2) {
            drawLine(c, Offset(size.width * k / 3, 0f), Offset(size.width * k / 3, size.height), w)
            drawLine(c, Offset(0f, size.height * k / 3), Offset(size.width, size.height * k / 3), w)
        }
    }
}

@Composable
private fun LevelOverlay(roll: Float) {
    Canvas(Modifier.fillMaxSize()) {
        val level = abs(roll) < 1f
        val color = if (level) Palette.yellow else Color.White.copy(alpha = 0.8f)
        val c = Offset(size.width / 2, size.height / 2)
        val half = size.width * 0.18f
        rotate(if (level) 0f else roll, c) {
            drawLine(color, Offset(c.x - half, c.y), Offset(c.x - 10.dp.toPx(), c.y), 1.5.dp.toPx())
            drawLine(color, Offset(c.x + 10.dp.toPx(), c.y), Offset(c.x + half, c.y), 1.5.dp.toPx())
        }
    }
}

/** Phone tilt (roll) in degrees while `active`; 0 when level or lying flat. */
@Composable
private fun rememberDeviceRoll(active: Boolean): Float {
    val context = LocalContext.current
    var roll by remember { mutableFloatStateOf(0f) }
    DisposableEffect(active) {
        if (!active) return@DisposableEffect onDispose { }
        val manager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val sensor = manager.getDefaultSensor(Sensor.TYPE_GRAVITY) ?: manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                val x = event.values[0]
                val y = event.values[1]
                val z = event.values[2]
                if (abs(z) > 8.5f) return // Flat on a table: no horizon.
                val angle = Math.toDegrees(atan2(x.toDouble(), y.toDouble())).toFloat()
                roll = roll + (angle - roll) * 0.25f
            }
            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }
        if (sensor != null) manager.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_UI)
        onDispose { manager.unregisterListener(listener) }
    }
    return roll
}

/** Classic guide: subject box, the thirds target and a line between them. */
@Composable
private fun ClassicGuideOverlay(reading: GuideReading?) {
    Box(Modifier.fillMaxSize()) {
        Canvas(Modifier.fillMaxSize()) {
            val r = reading ?: return@Canvas
            val target = Offset((r.targetX * size.width).toFloat(), (r.targetY * size.height).toFloat())
            val ready = r.ready
            val s = r.subject
            if (s != null) {
                val left = (s.x * size.width).toFloat()
                val top = (s.y * size.height).toFloat()
                val w = (s.width * size.width).toFloat()
                val h = (s.height * size.height).toFloat()
                drawRoundRect(Color.White.copy(alpha = 0.75f), Offset(left, top), Size(w, h), CornerRadius(10.dp.toPx()), style = Stroke(1.5.dp.toPx()))
                val center = Offset(left + w / 2, top + h / 2)
                if (!ready) drawLine(Palette.yellow.copy(alpha = 0.7f), center, target, 1.2.dp.toPx())
                drawPlus(center, 6.dp.toPx(), Palette.mint, 2.dp.toPx())
            }
            drawCircle(if (ready) Palette.yellow else Color.White.copy(alpha = 0.85f), 14.dp.toPx(), target, style = Stroke(2.dp.toPx()))
        }
        val label = reading?.label
        if (reading?.subject != null && label != null) {
            Box(Modifier.align(Alignment.TopCenter).padding(top = 12.dp)) {
                app.lumiq.ui.Pill {
                    Text(label + if (reading.technique.isNotEmpty()) " · ${reading.technique}" else "", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                }
            }
        }
    }
}

/** The single guidance line under the viewfinder: AI Shot status/tip, classic guide, or the idle hint. */
@Composable
private fun FooterLine(app: AppState, modifier: Modifier) {
    val aiShot = app.aiShot
    Box(modifier, contentAlignment = Alignment.Center) {
        when {
            aiShot.phase.isActive -> AIShotInstruction(aiShot)
            app.settings.guide -> {
                val reading = app.camera.guide
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.size(7.dp).clip(CircleShape).background(if (reading?.ready == true) Palette.yellow else Palette.mint))
                    Text(
                        reading?.instruction ?: "Looking for a subject…", color = Color.White, fontSize = 13.sp,
                        fontWeight = FontWeight.Medium, textAlign = TextAlign.Center, maxLines = 2,
                    )
                }
            }
            app.camera.isRunning -> Text("Point at something and tap AI Shot", color = Palette.muted, fontSize = 13.sp, textAlign = TextAlign.Center)
        }
    }
}

@Composable
private fun SavedBadge() {
    Row(
        Modifier.clip(RoundedCornerShape(50)).background(Color(0xE6111118)).border(1.dp, Palette.stroke, RoundedCornerShape(50)).padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        GlyphIcon(Glyph.Check, Palette.mint, 14.dp)
        Text("Saved to your library", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun ExposureStrip(camera: CameraController) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(Color(0xE6111118)).border(1.dp, Palette.stroke, RoundedCornerShape(20.dp))
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Exposure", color = Palette.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Text("  EV ${camera.exposureLabel}", color = Palette.accent, fontSize = 14.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
            TextButton({ camera.setExposure(0) }) { Text("Reset", fontSize = 13.sp, color = Palette.muted) }
        }
        val range = camera.exposureRange
        if (range.last > range.first) {
            Slider(
                value = camera.exposureIndex.toFloat(),
                onValueChange = { camera.setExposure(it.roundToInt()) },
                valueRange = range.first.toFloat()..range.last.toFloat(),
                colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Palette.accent, inactiveTrackColor = Color.White.copy(alpha = 0.15f)),
            )
        } else {
            Text("This camera does not offer exposure compensation.", color = Palette.muted, fontSize = 11.sp)
        }
    }
}

@Composable
private fun LensButtons(camera: CameraController) {
    val stops = camera.zoomStops
    val closest = stops.minByOrNull { abs(it - camera.zoomRatio) } ?: 1.0
    Row(
        Modifier.clip(RoundedCornerShape(50)).background(Palette.glass).border(1.dp, Palette.stroke, RoundedCornerShape(50)).padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        stops.forEach { stop ->
            val selected = stop == closest
            Box(
                Modifier.height(32.dp).widthIn(min = 44.dp).clip(RoundedCornerShape(50)).background(if (selected) Color.White else Color.Transparent)
                    .clickable { camera.setZoom(stop) },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    zoomLabel(if (selected) camera.zoomRatio else stop),
                    color = if (selected) Color.Black else Palette.text.copy(alpha = 0.8f),
                    fontSize = 13.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
                )
            }
        }
    }
}

private fun zoomLabel(value: Double): String =
    if (abs(Math.round(value) - value) < 0.04) String.format(Locale.US, "%.0f×", value) else String.format(Locale.US, "%.1f×", value)

@Composable
private fun ToolbarButton(glyph: Glyph, label: String, tint: Color, onClick: () -> Unit) {
    RoundGlyphButton(glyph, label, onClick, tint = tint, size = 40)
}

/** Frosted capsule for the aspect and exposure controls. */
@Composable
private fun GlassChip(active: Boolean, onClick: () -> Unit, content: @Composable RowScope.() -> Unit) {
    Row(
        Modifier.height(36.dp).clip(RoundedCornerShape(50)).background(if (active) Palette.accent.copy(alpha = 0.16f) else Palette.glass)
            .border(1.dp, if (active) Palette.accent.copy(alpha = 0.5f) else Palette.stroke, RoundedCornerShape(50))
            .clickable(onClick = onClick).padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp), content = content,
    )
}

@Composable
private fun AspectGlyph(aspect: PhotoAspect, tint: Color) {
    Canvas(Modifier.size(17.dp)) {
        val r = aspect.ratio.toFloat()
        val w = if (r >= 1) size.width * 0.9f else size.height * 0.9f * r
        val h = if (r >= 1) size.width * 0.9f / r else size.height * 0.9f
        drawRoundRect(tint, Offset((size.width - w) / 2, (size.height - h) / 2), Size(w, h), CornerRadius(2.dp.toPx()), style = Stroke(1.5.dp.toPx()))
    }
}

@Composable
private fun ShutterButton(enabled: Boolean, busy: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(82.dp).clip(CircleShape).clickable(enabled = enabled, onClickLabel = "Take photo", onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        val alpha = if (enabled || busy) 1f else 0.4f
        Canvas(Modifier.size(78.dp)) {
            drawCircle(Color.White.copy(alpha = alpha), size.minDimension / 2 - 2.dp.toPx(), style = Stroke(4.dp.toPx()))
            drawCircle(Color.White.copy(alpha = alpha), 30.dp.toPx())
        }
        if (busy) CircularProgressIndicator(Modifier.size(24.dp), color = Color.Black, strokeWidth = 2.dp)
    }
}

/** AI Shot (one tap). While finding: ✕ cancels. Once a shot is marked: ↻ finds a new one. Long press for more. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun AIShotButton(phase: AIShotModel.Phase, enabled: Boolean, onClick: () -> Unit, onLongClick: () -> Unit) {
    val searching = phase == AIShotModel.Phase.Finding || phase == AIShotModel.Phase.Aiming || phase == AIShotModel.Phase.Zooming
    Column(
        Modifier.clip(RoundedCornerShape(16.dp)).combinedClickable(enabled = enabled, onClickLabel = "AI Shot", onClick = onClick, onLongClick = onLongClick)
            .padding(4.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            Modifier.size(54.dp).clip(CircleShape)
                .then(if (phase == AIShotModel.Phase.Idle) Modifier.background(Palette.irisGradient) else Modifier.background(Palette.glass))
                .border(1.dp, if (phase == AIShotModel.Phase.Idle) Color.White.copy(alpha = 0.18f) else Palette.stroke, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            when {
                phase == AIShotModel.Phase.Idle -> LumiqMark(Modifier.size(28.dp), starColor = Color.White, bracketColor = Color.White)
                searching -> GlyphIcon(Glyph.Close, Palette.text, 18.dp)
                else -> GlyphIcon(Glyph.Rescan, Palette.accent, 21.dp)
            }
        }
        Text(
            when { phase == AIShotModel.Phase.Idle -> "AI Shot"; searching -> "Cancel"; else -> "New shot" },
            color = if (enabled) Palette.text.copy(alpha = 0.85f) else Palette.muted, fontSize = 12.sp, fontWeight = FontWeight.Medium,
        )
    }
}

@Composable
private fun LibraryThumbnail(app: AppState, enabled: Boolean, onClick: () -> Unit) {
    val first = app.store.photos.firstOrNull()
    var bitmap by remember(first) { mutableStateOf<android.graphics.Bitmap?>(null) }
    LaunchedEffect(first) { bitmap = first?.let { withContext(Dispatchers.IO) { app.store.thumbnail(it, 180) } } }
    Box(
        Modifier.size(52.dp).clip(RoundedCornerShape(16.dp)).background(Palette.panel)
            .border(1.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(16.dp))
            .clickable(enabled = enabled, onClickLabel = "Open photo library", onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        val b = bitmap
        if (b != null) Image(b.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        else GlyphIcon(Glyph.Photo, Color.White, 20.dp)
    }
}

@Composable
private fun PermissionView(denied: Boolean, unavailable: Boolean, onRetry: () -> Unit) {
    val context = LocalContext.current
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
    ) {
        LumiqMark(Modifier.size(52.dp), starColor = Palette.accent, bracketColor = Palette.text)
        Spacer(Modifier.height(18.dp))
        Text(
            when { unavailable -> "Camera unavailable"; denied -> "Camera access is off"; else -> "Lumiq needs the camera" },
            color = Palette.text, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            when { unavailable -> "Another app may be using it."; denied -> "Allow camera access in Android Settings."; else -> "Allow access to start shooting." },
            color = Palette.muted, fontSize = 14.sp, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(20.dp))
        PrimaryButton(if (unavailable) "Retry camera" else "Allow camera", onRetry)
        if (denied) {
            Spacer(Modifier.height(10.dp))
            SecondaryButton("Open Android Settings", {
                context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)))
            })
        }
    }
}

private fun hasCameraPermission(context: Context) =
    ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
