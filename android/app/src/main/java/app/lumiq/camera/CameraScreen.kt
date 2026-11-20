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
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.systemBars
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.unit.Dp
import androidx.compose.foundation.layout.heightIn
import app.lumiq.sony.SonyRemoteCamera
import app.lumiq.AppState
import app.lumiq.aishot.AIShotInstruction
import app.lumiq.aishot.AIShotModel
import app.lumiq.aishot.DeviceTilt
import app.lumiq.aishot.LevelMath
import app.lumiq.aishot.ShotOutcome
import app.lumiq.aishot.AIShotOverlay
import app.lumiq.aishot.drawPlus
import app.lumiq.settings.FlashMode
import app.lumiq.settings.PhotoAspect
import app.lumiq.ui.Glyph
import app.lumiq.ui.GlyphIcon
import app.lumiq.ui.LumiqLogo
import app.lumiq.ui.LumiqMark
import app.lumiq.ui.Palette
import app.lumiq.ui.Pill
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
    onOpenSony: () -> Unit,
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

    val sony = app.sony
    val useSony = app.cameraSource == CameraSource.Sony
    val aspect = settings.aspect.ratio
    // With a Sony, its live view is the viewfinder at the Sony's own frame shape.
    val viewAspect = if (useSony) sony.imageAspect else aspect
    DisposableEffect(granted, useSony) {
        if (useSony) sony.resume() else if (granted) camera.start(owner, aspect)
        onDispose { aiShot.stop(); camera.stop(); sony.pause() }
    }
    LaunchedEffect(aspect) { if (granted && !useSony) camera.setAspect(aspect) }
    // Classic guide pauses while AI Shot is active (same as iPhone).
    LaunchedEffect(settings.guide, aiShot.phase.isActive) { camera.setGuideEnabled(settings.guide && !aiShot.phase.isActive) }
    LaunchedEffect(camera.guide?.ready) { if (camera.guide?.ready == true) app.haptics.soft() }

    var showAspect by remember { mutableStateOf(false) }
    var showExposure by remember { mutableStateOf(false) }
    var showOptions by remember { mutableStateOf(false) }
    var showAIMenu by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var saved by remember { mutableStateOf(false) }
    var shots by remember { mutableIntStateOf(0) }

    val busy = saving || camera.isCapturing || (useSony && sony.isCapturing)
    val canShoot = (if (useSony) sony.canCapture else camera.isRunning) && !busy
    val aiCamera = if (useSony) sony.aiShotCamera else camera
    val aiAvailable = if (useSony) sony.hasFrame else camera.isRunning
    var sonyError by remember { mutableStateOf<String?>(null) }

    fun shootSony() {
        saving = true
        shots += 1
        aiShot.photoTaken()
        app.haptics.medium()
        scope.launch {
            try {
                val bytes = sony.capture()
                val photo = withContext(Dispatchers.IO) {
                    val temp = File(context.cacheDir, "sony-${System.currentTimeMillis()}.jpg").apply { writeBytes(bytes) }
                    app.store.importCapture(temp, settings.autoSaveToGallery)
                }
                saving = false
                if (photo == null) { sonyError = "The photo could not be saved."; return@launch }
                aiShot.stop()
                if (settings.reviewAfterCapture) onReview(photo) else { saved = true; delay(1600); saved = false }
            } catch (e: Exception) {
                saving = false
                if (e !is app.lumiq.sony.SonyCancelled) sonyError = e.message ?: "The Sony photo failed."
            }
        }
    }

    fun shoot() {
        if (!canShoot) return
        if (useSony) { shootSony(); return }
        saving = true
        shots += 1
        aiShot.photoTaken() // Learning: a photo taken while a shot is marked means the pick was good.
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

    var askLearning by remember { mutableStateOf(false) }

    // ✕ cancels until the shot is Ready; ↻ then finds a new one.
    fun aiShotTapped() {
        val phase = aiShot.phase
        if (phase == AIShotModel.Phase.Finding || phase == AIShotModel.Phase.Aiming || phase == AIShotModel.Phase.Zooming) {
            aiShot.stop(ShotOutcome.Cancelled); return
        }
        if (app.learning.needsConsent) { askLearning = true; return }
        aiShot.start(aiCamera, viewAspect)
    }

    if (askLearning) {
        fun answer(share: Boolean) {
            app.learning.updateConsent(share)
            askLearning = false
            aiShot.start(aiCamera, viewAspect)
        }
        LumiqDialog(
            "Help AI Shot learn?", onDismiss = { askLearning = false },
            primary = "Share results" to { answer(true) }, secondary = "Not now" to { answer(false) },
        ) {
            DialogText(
                "Lumiq can send the result of each AI Shot (what the AI suggested and whether you took the photo) " +
                    "so AI Shot learns which picks people like. No photos, no location and nothing that identifies you. " +
                    "Nothing is saved on your phone. You can change this in Settings.",
            )
        }
    }

    // A short dark blink on the image when a photo is taken.
    val blink = remember { Animatable(0f) }
    LaunchedEffect(shots) { if (shots > 0) { blink.snapTo(0.75f); blink.animateTo(0f, tween(320)) } }

    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        val bars = WindowInsets.systemBars.asPaddingValues()
        val statusBar = bars.calculateTopPadding()
        val navBar = bars.calculateBottomPadding()
        val topBar = 56.dp
        // The image is shown at the photo's exact shape (capture is cropped to the viewfinder), as wide as
        // possible while leaving room for the hint, lenses and shutter underneath.
        val controls = 210.dp
        val available = (maxHeight - statusBar - topBar - navBar - controls).coerceAtLeast(200.dp)
        val width = min(maxWidth.value, (available.value * viewAspect).toFloat()).dp
        val height = (width.value / viewAspect).toFloat().dp

        Column(Modifier.fillMaxSize().padding(top = statusBar, bottom = navBar)) {
            // Top bar: photo shape on the left; flash, exposure and more on the right. It takes any spare
            // height, so the image always sits directly on the controls at the bottom of the screen.
            Row(
                Modifier.fillMaxWidth().weight(1f).heightIn(min = topBar).padding(start = 12.dp, end = 12.dp, bottom = 6.dp),
                verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (useSony) {
                    BarChip(active = false, label = "Sony camera", onClick = onOpenSony) {
                        Box(Modifier.size(8.dp).clip(CircleShape).background(if (sony.state == SonyRemoteCamera.State.Streaming) Palette.mint else Palette.orange))
                        Text(if (sony.hasFrame) sony.model else "Sony", color = Palette.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                        GlyphIcon(Glyph.Chevron, Palette.muted, 10.dp, rotation = -90f)
                    }
                } else Box {
                    BarChip(active = showAspect, label = "Photo shape", onClick = { showAspect = true; showExposure = false }) {
                        AspectGlyph(settings.aspect, Palette.text)
                        Text(settings.aspect.label, color = Palette.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                        GlyphIcon(Glyph.Chevron, Palette.muted, 10.dp, rotation = if (showAspect) 180f else 0f)
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
                if (!useSony && camera.hasFlash && !camera.isFront) {
                    val glyph = when (settings.flash) { FlashMode.Off -> Glyph.BoltOff; FlashMode.On -> Glyph.Bolt; FlashMode.Auto -> Glyph.BoltAuto }
                    ToolbarButton(glyph, "Flash ${settings.flash.label}", if (settings.flash == FlashMode.Off) Palette.text else Palette.yellow) {
                        settings.updateFlash(FlashMode.entries[(settings.flash.ordinal + 1) % FlashMode.entries.size])
                    }
                }
                BarChip(active = showExposure, label = "Exposure", onClick = { if (useSony) onOpenSony() else { showExposure = !showExposure; showAspect = false } }) {
                    GlyphIcon(Glyph.Aperture, if (showExposure) Palette.accent else Palette.text, 22.dp)
                    GlyphIcon(Glyph.Chevron, Palette.muted, 10.dp, rotation = if (showExposure) 180f else 0f)
                }
                Box {
                    ToolbarButton(Glyph.Ellipsis, "More", Palette.text) { showOptions = true }
                    LumiqMenu(showOptions, onDismiss = { showOptions = false }) {
                        MenuHeader("Camera")
                        MenuRow("Phone camera", Glyph.Photo, selected = !useSony) { showOptions = false; aiShot.stop(); app.cameraSource = CameraSource.Phone }
                        MenuRow("Sony camera", Glyph.Aperture, selected = useSony) {
                            showOptions = false; aiShot.stop(); app.cameraSource = CameraSource.Sony
                            if (!sony.isConnected) onOpenSony()
                        }
                        MenuDivider()
                        if (!useSony && camera.hasFrontAndBack) {
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
            // The image.
            Box(Modifier.fillMaxWidth().height(height), contentAlignment = Alignment.Center) {
                Box(Modifier.size(width, height).background(Color.Black)) {
                    if (useSony) {
                        SonyViewfinder(app, saved = saved, saving = busy, onOpenSony = onOpenSony)
                    } else if (granted && camera.access != CameraController.Access.Unavailable) {
                        Viewfinder(app, showExposure = showExposure, saved = saved, saving = busy, topInset = 0.dp, bottomInset = 0.dp)
                    } else {
                        PermissionView(denied = asked && !granted, unavailable = camera.access == CameraController.Access.Unavailable,
                            onRetry = { if (!granted) permission.launch(Manifest.permission.CAMERA) else camera.start(owner, aspect) })
                    }
                    if (blink.value > 0f) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = blink.value)))
                }
            }
            // Under the image: hint, lenses, then library · shutter · AI Shot.
            Column(Modifier.fillMaxWidth().height(controls), horizontalAlignment = Alignment.CenterHorizontally) {
                FooterLine(app, Modifier.fillMaxWidth().padding(top = 10.dp).heightIn(min = 22.dp).padding(horizontal = 24.dp))
                Box(Modifier.fillMaxWidth().padding(top = 10.dp).height(44.dp), contentAlignment = Alignment.Center) {
                    if (useSony) {
                        if (sony.hasFrame) SonyExposureLine(sony)
                    } else if (camera.isRunning) LensButtons(camera)
                }
                Row(Modifier.fillMaxWidth().padding(top = 14.dp).padding(horizontal = 32.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) { LibraryThumbnail(app, enabled = !busy, onClick = onOpenLibrary) }
                    ShutterButton(enabled = canShoot, busy = busy, onClick = ::shoot)
                    Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                        Box {
                            AIShotButton(aiShot.phase, enabled = aiAvailable && !busy, onClick = ::aiShotTapped, onLongClick = { showAIMenu = true })
                            LumiqMenu(showAIMenu, onDismiss = { showAIMenu = false }) {
                                if (aiShot.phase.isActive) MenuRow("Exit AI Shot", Glyph.Close) { showAIMenu = false; aiShot.stop(ShotOutcome.Cancelled) }
                                MenuRow("Classic live guide", Glyph.Aperture, checked = settings.guide) { settings.updateGuide(!settings.guide) }
                            }
                        }
                    }
                }
            }
        }
    }

    sonyError?.let { e ->
        LumiqDialog("Sony camera", onDismiss = { sonyError = null }, primary = "OK" to { sonyError = null }) { DialogText(e) }
    }
    val error = camera.errorMessage
    if (error != null) {
        LumiqDialog("Camera", onDismiss = { camera.errorMessage = null }, primary = "OK" to { camera.errorMessage = null }) { DialogText(error) }
    }
}

@Composable
private fun Viewfinder(app: AppState, showExposure: Boolean, saved: Boolean, saving: Boolean, topInset: Dp, bottomInset: Dp) {
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
        val tilt = rememberDeviceTilt(settings.level || aiShot.phase.isActive)
        if (settings.level && !aiShot.phase.isActive) LevelOverlay(tilt)
        if (aiShot.phase.isActive) AIShotOverlay(aiShot, tilt, topInset = topInset) else if (settings.guide) ClassicGuideOverlay(camera.guide, topInset)
        focusPoint?.let { p ->
            Canvas(Modifier.fillMaxSize()) {
                val s = 64.dp.toPx()
                drawRect(Palette.yellow, Offset(p.x - s / 2, p.y - s / 2), Size(s, s), style = Stroke(1.5.dp.toPx()))
            }
        }
        // Only transient things sit on the image; guidance text and lenses are in the footer (like Framed).
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = bottomInset + 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            AnimatedVisibility(saved, enter = fadeIn(), exit = fadeOut()) { SavedBadge() }
            if (showExposure) ExposureStrip(camera)
        }
        // While a photo is being taken and saved, the live view stays up with a progress pill.
        AnimatedVisibility(saving, Modifier.align(Alignment.Center), enter = fadeIn(), exit = fadeOut()) {
            Pill {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(Modifier.size(14.dp), color = Palette.text, strokeWidth = 2.dp)
                    Text("Saving photo…", color = Palette.text, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                }
            }
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
private fun LevelOverlay(tilt: DeviceTilt) {
    Canvas(Modifier.fillMaxSize()) {
        val level = tilt.isLevel
        val color = if (level) Palette.yellow else Color.White.copy(alpha = 0.8f)
        val c = Offset(size.width / 2, size.height / 2)
        val half = size.width * 0.18f
        rotate(tilt.base + if (level) 0f else tilt.tilt, c) {
            drawLine(color, Offset(c.x - half, c.y), Offset(c.x - 10.dp.toPx(), c.y), 1.5.dp.toPx())
            drawLine(color, Offset(c.x + 10.dp.toPx(), c.y), Offset(c.x + half, c.y), 1.5.dp.toPx())
        }
    }
}

/** How the phone is held and tilted while `active` (upright, sideways or upside down); unchanged while lying flat. */
@Composable
private fun rememberDeviceTilt(active: Boolean): DeviceTilt {
    val context = LocalContext.current
    var tilt by remember { mutableStateOf(DeviceTilt()) }
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
                roll = LevelMath.smooth(roll, angle, 0.25f)
                tilt = LevelMath.tilt(roll, tilt.base)
            }
            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }
        if (sensor != null) manager.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_UI)
        onDispose { manager.unregisterListener(listener) }
    }
    return tilt
}

/** Classic guide: subject box, the thirds target and a line between them. */
@Composable
private fun ClassicGuideOverlay(reading: GuideReading?, topInset: Dp) {
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
            Box(Modifier.align(Alignment.TopCenter).padding(top = topInset + 12.dp)) {
                Pill {
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
                        reading?.instruction ?: "Looking for a subject…", color = Color.White, fontSize = 12.sp,
                        fontWeight = FontWeight.Medium, textAlign = TextAlign.Center, maxLines = 2,
                    )
                }
            }
            app.cameraSource == CameraSource.Sony && !app.sony.hasFrame -> Text(
                app.sony.message ?: if (app.sony.state == SonyRemoteCamera.State.Connecting || app.sony.state == SonyRemoteCamera.State.Reconnecting) "Connecting to the Sony…" else "Connect a Sony camera",
                color = Palette.muted, fontSize = 12.sp, textAlign = TextAlign.Center, maxLines = 2,
            )
            app.cameraSource == CameraSource.Sony || app.camera.isRunning -> Text("Point at something and tap AI Shot", color = Palette.muted, fontSize = 12.sp, textAlign = TextAlign.Center, maxLines = 1)
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
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        stops.forEach { stop ->
            val selected = stop == closest
            Box(
                Modifier.size(42.dp).clip(CircleShape).background(if (selected) Palette.accent.copy(alpha = 0.22f) else Color.White.copy(alpha = 0.09f))
                    .clickable { camera.setZoom(stop) },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    zoomLabel(if (selected) camera.zoomRatio else stop),
                    color = if (selected) Palette.accent else Palette.text.copy(alpha = 0.75f),
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
    Box(Modifier.size(44.dp).clip(CircleShape).clickable(onClickLabel = label, onClick = onClick), contentAlignment = Alignment.Center) {
        GlyphIcon(glyph, tint, 22.dp)
    }
}

/** Top-bar control (photo shape, exposure); tinted while its panel is open. */
@Composable
private fun BarChip(active: Boolean, label: String, onClick: () -> Unit, content: @Composable RowScope.() -> Unit) {
    Row(
        Modifier.height(40.dp).clip(RoundedCornerShape(50)).background(if (active) Palette.accent.copy(alpha = 0.16f) else Color.Transparent)
            .clickable(onClickLabel = label, onClick = onClick).padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp), content = content,
    )
}

@Composable
private fun AspectGlyph(aspect: PhotoAspect, tint: Color) {
    Canvas(Modifier.size(20.dp)) {
        val r = aspect.ratio.toFloat()
        val w = if (r >= 1) size.width * 0.9f else size.height * 0.9f * r
        val h = if (r >= 1) size.width * 0.9f / r else size.height * 0.9f
        drawRoundRect(tint, Offset((size.width - w) / 2, (size.height - h) / 2), Size(w, h), CornerRadius(2.dp.toPx()), style = Stroke(1.5.dp.toPx()))
    }
}

@Composable
private fun ShutterButton(enabled: Boolean, busy: Boolean, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.88f else 1f, spring(dampingRatio = 0.55f, stiffness = 600f), label = "shutter")
    Box(
        Modifier.size(84.dp).clip(CircleShape)
            .clickable(interaction, indication = null, enabled = enabled, onClickLabel = "Take photo", onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        val alpha = if (enabled || busy) 1f else 0.4f
        Canvas(Modifier.size(80.dp)) {
            drawCircle(Color.White.copy(alpha = alpha), size.minDimension / 2 - 2.dp.toPx(), style = Stroke(4.dp.toPx()))
            drawCircle(Color.White.copy(alpha = alpha), 31.dp.toPx() * scale)
        }
        if (busy) CircularProgressIndicator(Modifier.size(24.dp), color = Palette.accentStrong, strokeWidth = 2.dp)
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
        val spin = rememberInfiniteTransition(label = "finding")
        val angle by spin.animateFloat(0f, 360f, infiniteRepeatable(tween(1100, easing = LinearEasing)), label = "angle")
        Box(
            Modifier.size(54.dp)
                .drawWithContent {
                    drawContent()
                    if (phase == AIShotModel.Phase.Finding) {
                        drawArc(Palette.accent, angle, 90f, false, style = Stroke(2.5.dp.toPx(), cap = StrokeCap.Round))
                    }
                }
                .clip(CircleShape)
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

/** Phone camera, or a Sony connected over Wi-Fi. */
enum class CameraSource { Phone, Sony }

/** The Sony's live view, with the same AI Shot, grid and level overlays as the phone camera. */
@Composable
private fun SonyViewfinder(app: AppState, saved: Boolean, saving: Boolean, onOpenSony: () -> Unit) {
    val sony = app.sony
    val aiShot = app.aiShot
    val settings = app.settings
    val frame = sony.frame
    var focusPoint by remember { mutableStateOf<Offset?>(null) }
    LaunchedEffect(focusPoint) { if (focusPoint != null) { delay(900); focusPoint = null } }
    Box(Modifier.fillMaxSize()) {
        if (frame != null) {
            Image(frame.asImageBitmap(), contentDescription = "Sony live view", contentScale = ContentScale.FillBounds, modifier = Modifier.fillMaxSize())
            Box(
                Modifier.fillMaxSize().pointerInput(sony.supportsTouchFocus) {
                    detectTapGestures { p ->
                        if (sony.supportsTouchFocus) { sony.focus(p.x / size.width, p.y / size.height); focusPoint = p }
                    }
                },
            )
            if (settings.grid || aiShot.phase.isActive) GridOverlay()
            val tilt = rememberDeviceTilt(settings.level || aiShot.phase.isActive)
            if (settings.level && !aiShot.phase.isActive) LevelOverlay(tilt)
            if (aiShot.phase.isActive) AIShotOverlay(aiShot, tilt)
            focusPoint?.let { p ->
                Canvas(Modifier.fillMaxSize()) {
                    val s = 64.dp.toPx()
                    drawRect(Palette.yellow, Offset(p.x - s / 2, p.y - s / 2), Size(s, s), style = Stroke(1.5.dp.toPx()))
                }
            }
        } else {
            Column(Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                val connecting = sony.state == SonyRemoteCamera.State.Connecting || sony.state == SonyRemoteCamera.State.Reconnecting
                Text(if (connecting) "Connecting to the Sony…" else "Sony camera", color = Palette.text, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                if (connecting) CircularProgressIndicator(Modifier.size(22.dp), color = Palette.accent, strokeWidth = 2.dp)
                sony.message?.let { Text(it, color = Palette.muted, fontSize = 13.sp, textAlign = TextAlign.Center, maxLines = 4, modifier = Modifier.padding(top = 8.dp)) }
                Spacer(Modifier.height(16.dp))
                PrimaryButton(if (sony.isConnected) "Sony controls" else "Connect Sony camera", onOpenSony)
            }
        }
        AnimatedVisibility(saving, Modifier.align(Alignment.Center), enter = fadeIn(), exit = fadeOut()) {
            Pill {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(Modifier.size(14.dp), color = Palette.text, strokeWidth = 2.dp)
                    Text("Sony is taking the photo…", color = Palette.text, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                }
            }
        }
        AnimatedVisibility(saved, Modifier.align(Alignment.BottomCenter).padding(bottom = 12.dp), enter = fadeIn(), exit = fadeOut()) { SavedBadge() }
    }
}

/** The Sony's exposure as the camera reports it (shown where the phone's lens buttons are). */
@Composable
private fun SonyExposureLine(sony: SonyRemoteCamera) {
    val t = sony.remote.telemetry
    val parts = listOfNotNull(t.mode, t.shutter, t.aperture?.let { "f/$it" }, t.iso?.let { "ISO $it" }, t.ev?.let { String.format(Locale.US, "%+.1f EV", it) })
    Text(
        if (parts.isEmpty()) "Exposure not reported" else parts.joinToString("  ·  "),
        color = Palette.muted, fontSize = 13.sp, fontWeight = FontWeight.Medium, maxLines = 1,
    )
}
