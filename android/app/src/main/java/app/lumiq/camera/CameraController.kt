package app.lumiq.camera

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaActionSound
import android.util.Rational
import android.util.Size
import android.view.Surface
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.ViewPort
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import app.lumiq.aishot.AIShotCamera
import app.lumiq.aishot.AIShotTracker
import app.lumiq.aishot.CameraSnapshot
import app.lumiq.settings.FlashMode
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * CameraX counterpart of the iPhone CameraController: live preview, photo
 * capture cropped to the viewfinder, lenses/zoom, focus, exposure, and an
 * analysis stream for AI Shot tracking and the classic live guide.
 */
class CameraController(private val context: Context) : AIShotCamera {
    enum class Access { Checking, Available, Denied, Unavailable }

    var access by mutableStateOf(Access.Checking)
    var isRunning by mutableStateOf(false); private set
    var isFront by mutableStateOf(false); private set
    var hasFrontAndBack by mutableStateOf(false); private set
    var hasFlash by mutableStateOf(false); private set
    var isCapturing by mutableStateOf(false); private set
    var zoomRatio by mutableStateOf(1.0); private set
    var minZoom by mutableStateOf(1.0); private set
    var maxZoom by mutableStateOf(1.0); private set
    var exposureIndex by mutableStateOf(0); private set
    var exposureRange by mutableStateOf(0..0); private set
    var exposureStep by mutableStateOf(0.0); private set
    var guide by mutableStateOf<GuideReading?>(null); private set
    var errorMessage by mutableStateOf<String?>(null)

    val previewView: PreviewView = PreviewView(context).apply {
        // TextureView keeps rounded clipping and overlays exact inside Compose.
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        scaleType = PreviewView.ScaleType.FILL_CENTER
    }

    private val scope = MainScope()
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var imageCapture: ImageCapture? = null
    private var owner: LifecycleOwner? = null
    private var boundAspect = 0.75
    private var zoomJob: Job? = null
    private val sound by lazy { MediaActionSound().apply { load(MediaActionSound.SHUTTER_CLICK) } }

    @Volatile private var tracker: AIShotTracker? = null
    @Volatile private var guideEnabled = false
    @Volatile private var mirroredFrames = false
    private val pendingSnapshot = AtomicReference<CompletableDeferred<CameraSnapshot?>?>(null)
    private var liveGuide: LiveGuide? = null
    private var lastGuideAt = 0L

    override val zoom: Double get() = zoomRatio
    override val minimumZoom: Double get() = minZoom
    override val maximumZoom: Double get() = maxZoom

    /** Lens buttons: 0.5× when an ultra-wide exists, 1×, 2×, and 3×/5× when available. */
    val zoomStops: List<Double>
        get() {
            val stops = ArrayList<Double>()
            if (minZoom < 0.95) stops.add((minZoom * 10).roundToInt() / 10.0)
            stops.add(1.0)
            if (maxZoom >= 2.0) stops.add(2.0)
            if (maxZoom >= 4.95) stops.add(5.0) else if (maxZoom >= 3.0) stops.add(3.0)
            return stops
        }

    fun start(owner: LifecycleOwner, aspect: Double) {
        this.owner = owner
        boundAspect = aspect
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            val p = runCatching { future.get() }.getOrNull()
            if (p == null) { access = Access.Unavailable; return@addListener }
            provider = p
            val back = runCatching { p.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA) }.getOrDefault(false)
            val front = runCatching { p.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA) }.getOrDefault(false)
            hasFrontAndBack = back && front
            if (!back && front) isFront = true
            if (!back && !front) { access = Access.Unavailable; return@addListener }
            bind()
        }, ContextCompat.getMainExecutor(context))
    }

    fun setAspect(aspect: Double) {
        if (abs(aspect - boundAspect) < 0.001) return
        boundAspect = aspect
        if (provider != null) bind()
    }

    fun flip() {
        if (!hasFrontAndBack || isCapturing) return
        isFront = !isFront
        bind()
    }

    private fun bind() {
        val p = provider ?: return
        val owner = owner ?: return
        camera?.cameraInfo?.zoomState?.removeObservers(owner)
        p.unbindAll()
        val wide = boundAspect < 0.6 || boundAspect > 1.6
        val ratio = if (wide) AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY else AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY
        val preview = Preview.Builder()
            .setResolutionSelector(ResolutionSelector.Builder().setAspectRatioStrategy(ratio).build())
            .build()
        preview.setSurfaceProvider(previewView.surfaceProvider)
        val capture = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
            .setResolutionSelector(
                ResolutionSelector.Builder().setAspectRatioStrategy(ratio)
                    .setResolutionStrategy(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY).build(),
            )
            .build()
        val analysis = ImageAnalysis.Builder()
            .setResolutionSelector(
                ResolutionSelector.Builder().setAspectRatioStrategy(ratio)
                    .setResolutionStrategy(
                        ResolutionStrategy(
                            if (wide) Size(1280, 720) else Size(1280, 960),
                            ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER,
                        ),
                    ).build(),
            )
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
            .build()
        analysis.setAnalyzer(analysisExecutor) { analyze(it) }

        // The viewport crops capture and analysis to exactly what the viewfinder shows.
        val viewPort = ViewPort.Builder(rational(boundAspect), Surface.ROTATION_0)
            .setScaleType(ViewPort.FILL_CENTER).build()
        val group = UseCaseGroup.Builder().setViewPort(viewPort)
            .addUseCase(preview).addUseCase(capture).addUseCase(analysis).build()
        val selector = if (isFront) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
        mirroredFrames = isFront
        try {
            val bound = p.bindToLifecycle(owner, selector, group)
            camera = bound
            imageCapture = capture
            hasFlash = bound.cameraInfo.hasFlashUnit()
            val exposure = bound.cameraInfo.exposureState
            if (exposure.isExposureCompensationSupported) {
                exposureRange = exposure.exposureCompensationRange.lower..exposure.exposureCompensationRange.upper
                exposureStep = exposure.exposureCompensationStep.toDouble()
                exposureIndex = exposure.exposureCompensationIndex
            } else {
                exposureRange = 0..0; exposureStep = 0.0; exposureIndex = 0
            }
            bound.cameraInfo.zoomState.observe(owner) { state ->
                zoomRatio = state.zoomRatio.toDouble()
                minZoom = state.minZoomRatio.toDouble()
                maxZoom = state.maxZoomRatio.toDouble()
            }
            access = Access.Available
            isRunning = true
        } catch (e: Exception) {
            isRunning = false
            access = Access.Unavailable
            errorMessage = "Camera unavailable: ${e.message ?: "unknown error"}"
        }
    }

    fun stop() {
        zoomJob?.cancel()
        owner?.let { camera?.cameraInfo?.zoomState?.removeObservers(it) }
        provider?.unbindAll()
        camera = null
        imageCapture = null
        isRunning = false
        guide = null
        pendingSnapshot.getAndSet(null)?.complete(null)
    }

    fun release() {
        stop()
        scope.cancel()
        analysisExecutor.execute { liveGuide?.close(); liveGuide = null }
        analysisExecutor.shutdown()
    }

    private fun rational(aspect: Double): Rational {
        val known = listOf(3 to 4, 4 to 5, 1 to 1, 9 to 16, 4 to 3, 16 to 9)
        val match = known.firstOrNull { abs(it.first.toDouble() / it.second - aspect) < 0.01 }
        return if (match != null) Rational(match.first, match.second) else Rational((aspect * 1000).roundToInt(), 1000)
    }

    // MARK: Controls

    override fun setZoom(value: Double, animated: Boolean) {
        val control = camera?.cameraControl ?: return
        val target = min(maxZoom, max(minZoom, value)).toFloat()
        zoomJob?.cancel()
        if (!animated) { control.setZoomRatio(target); return }
        val from = zoomRatio.toFloat()
        zoomJob = scope.launch {
            val steps = 12
            for (k in 1..steps) {
                val t = k / steps.toFloat()
                val eased = 1 - (1 - t) * (1 - t)
                control.setZoomRatio(from + (target - from) * eased)
                delay(28)
            }
        }
    }

    fun pinch(scale: Float) {
        val control = camera?.cameraControl ?: return
        zoomJob?.cancel()
        control.setZoomRatio(min(maxZoom, max(minZoom, zoomRatio * scale)).toFloat())
    }

    /** Tap to focus and meter at a point in the viewfinder (normalized). */
    fun focus(x: Float, y: Float) {
        val c = camera ?: return
        val point = previewView.meteringPointFactory.createPoint(x * previewView.width, y * previewView.height)
        val action = FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE)
            .setAutoCancelDuration(4, TimeUnit.SECONDS).build()
        c.cameraControl.startFocusAndMetering(action)
    }

    fun setExposure(index: Int) {
        val c = camera ?: return
        val clamped = index.coerceIn(exposureRange.first, exposureRange.last)
        exposureIndex = clamped
        c.cameraControl.setExposureCompensationIndex(clamped)
    }

    val exposureLabel: String
        get() {
            val ev = exposureIndex * exposureStep
            return if (abs(ev) < 0.05) "±0" else String.format(java.util.Locale.US, "%+.1f", ev)
        }

    fun setGuideEnabled(enabled: Boolean) {
        guideEnabled = enabled
        if (!enabled) guide = null
    }

    override fun setAIShotTracker(tracker: AIShotTracker?) { this.tracker = tracker }

    override suspend fun snapshot(): CameraSnapshot? {
        val request = CompletableDeferred<CameraSnapshot?>()
        pendingSnapshot.getAndSet(request)?.complete(null)
        val result = withTimeoutOrNull(2000) { request.await() }
        pendingSnapshot.compareAndSet(request, null)
        return result
    }

    /** Takes a full-quality photo cropped to the viewfinder; the file has EXIF orientation. */
    fun takePhoto(flash: FlashMode, shutterSound: Boolean, done: (File?) -> Unit) {
        val capture = imageCapture ?: return done(null)
        if (isCapturing) return
        isCapturing = true
        capture.flashMode = when (flash) {
            FlashMode.Off -> ImageCapture.FLASH_MODE_OFF
            FlashMode.On -> ImageCapture.FLASH_MODE_ON
            FlashMode.Auto -> ImageCapture.FLASH_MODE_AUTO
        }
        val file = File(context.cacheDir, "capture-${System.currentTimeMillis()}.jpg")
        val metadata = ImageCapture.Metadata().apply { isReversedHorizontal = isFront }
        val options = ImageCapture.OutputFileOptions.Builder(file).setMetadata(metadata).build()
        if (shutterSound) runCatching { sound.play(MediaActionSound.SHUTTER_CLICK) }
        capture.takePicture(options, ContextCompat.getMainExecutor(context), object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                isCapturing = false
                done(file)
            }

            override fun onError(exception: ImageCaptureException) {
                isCapturing = false
                errorMessage = "Could not take the photo: ${exception.message ?: "camera error"}"
                done(null)
            }
        })
    }

    // MARK: Analysis (camera thread)

    private fun analyze(image: ImageProxy) {
        try {
            val plane = image.planes.firstOrNull() ?: return
            val sampler = FrameSampler(
                plane.buffer, plane.rowStride, plane.pixelStride, image.cropRect,
                image.imageInfo.rotationDegrees, mirroredFrames,
            )
            val snapshotRequest = pendingSnapshot.getAndSet(null)
            val activeTracker = tracker
            if (snapshotRequest != null) {
                val (w, h) = sampler.size(768)
                val bitmap = sampler.bitmap(w, h)
                val jpeg = ByteArrayOutputStream().use { out ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 82, out); out.toByteArray()
                }
                bitmap.recycle()
                snapshotRequest.complete(CameraSnapshot(jpeg, sampler.luma(TRACK_WIDTH)))
            } else if (activeTracker != null) {
                activeTracker.ingest(sampler.luma(TRACK_WIDTH))
            }
            val now = System.currentTimeMillis()
            if (guideEnabled && activeTracker == null && now - lastGuideAt > 180) {
                lastGuideAt = now
                val (w, h) = sampler.size(360)
                val small = sampler.bitmap(w, h)
                val guideModel = liveGuide ?: LiveGuide().also { liveGuide = it }
                val reading = guideModel.analyze(small)
                small.recycle()
                scope.launch { if (guideEnabled) guide = reading }
            } else if (!guideEnabled && liveGuide != null) {
                liveGuide?.reset()
            }
        } catch (_: Exception) {
            // A single bad frame must never stop the stream.
        } finally {
            image.close()
        }
    }

    companion object {
        const val TRACK_WIDTH = 200
    }
}
