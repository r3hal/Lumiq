import AVFoundation
import Combine
import CoreMotion
import CoreImage
import UIKit
import Vision

final class CameraController: NSObject, ObservableObject {
    enum Access: Equatable { case checking, available, denied, unavailable }
    @Published private(set) var access: Access = .checking
    @Published private(set) var reading = CompositionReading()
    @Published private(set) var isCapturing = false
    @Published private(set) var isRunning = false
    @Published private(set) var zoom: Double = 1
    @Published private(set) var minimumZoom: Double = 1
    @Published private(set) var maximumZoom: Double = 6
    @Published private(set) var zoomStops: [Double] = [1, 2]
    @Published private(set) var subjectLabel = "Auto subject"
    @Published private(set) var photoResolution = "Full resolution"
    @Published private(set) var supportsRAW = false
    @Published private(set) var supportsProRAW = false
    @Published private(set) var supportsFlash = false
    @Published private(set) var canMuteShutter = false
    @Published private(set) var scanData: Data?
    @Published private(set) var framingPhase: FramingPhase = .off
    @Published private(set) var guidance = GuidanceMessage()
    @Published private(set) var telemetry = CameraTelemetry()
    @Published private(set) var previewFPS: Double?
    @Published private(set) var previewResolution = "Configuring…"
    @Published private(set) var qualityZoomLimit: Double = 1
    @Published private(set) var isFrontCamera = false
    @Published private(set) var isSwitchingCamera = false
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var exposureRange: ClosedRange<Float> = -3...3
    @Published private(set) var motionAvailable = false
    @Published private(set) var levelReliable = false
    @Published private(set) var coachAdvice: [String] = []
    @Published private(set) var liveMeasurements: PhotoMeasurements?
    @Published private(set) var sceneLabel: String?
    @Published var errorMessage: String?

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.focal.camera", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "app.focal.vision", qos: .utility, autoreleaseFrequency: .workItem)
    private let videoQueue = DispatchQueue(label: "app.focal.video", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var previewScheduler = PreviewAnalysisScheduler() // Video queue only.
    private var previewCadence = PreviewFrameCadence() // Video queue only.
    private var videoAnalysisBuffer: CVPixelBuffer? // Video queue; no overwrite until Vision finishes.
    private var lastAnalysisLevelUpdate: TimeInterval = -.infinity // Video queue only.
    private let previewCopyContext = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: true])
    private var lastVideoTelemetry: TimeInterval = -.infinity
    private var configuredPreviewRate = 30
    private let zoomRequestLock = NSLock()
    private var zoomRequests = ZoomRequestCoalescer()
    private let motion = CMMotionManager()
    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var position: AVCaptureDevice.Position = .back
    private var analysisFrontCamera = false
    private var coachEnabled = false
    private var lastCoach: TimeInterval = -.infinity
    private var lastScene: TimeInterval = -.infinity
    private var configured = false
    private var wantsToRun = false // Camera queue only.
    private var engine = CompositionEngine() // Analysis queue only.
    private var mode: CompositionMode = .thirds
    private var guidanceEnabled = false
    private let guidanceLock = NSLock()
    private var activation = GuidanceActivation()
    private var sceneMeasurements: PhotoMeasurements?
    private var lastSceneMeasurement: TimeInterval = -.infinity
    private var autoFrameEnabled = true
    private var framing = FramingPlanner()
    private var automaticGuidance = AutomaticGuidance()
    private var boxSmoother = SubjectBoxSmoother()
    private var holdDuration = 0.9
    private var analysisSource: CameraSource = .iPhone
    private var latestNativeBounds: CGRect?
    private var latestBoundsZoom: Double = 1
    private var lastTelemetry: TimeInterval = 0
    private let externalLock = NSLock()
    private var externalFramePending = false // Analysis queue only.
    private var analysisZoom: Double = 1
    private var automaticZoomLimit: Double = 1
    private var detailZoomLimit: Double = 1
    private var nativeZoomStops: [Double] = [1]
    private var previewPixelWidth: Double = 1080 // Camera queue only.
    private var zoomGeneration = 0 // Camera queue only.
    private var analysisZoomGeneration = 0 // Analysis queue only.
    private var lastAnalysis: TimeInterval = 0
    private let tracker = SubjectTracker()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var analysisBuffer: CVPixelBuffer?
    private var imageAspect = 0.75
    private var previewAspect = 0.75
    private var wantsScan = true
    private var preferredTarget: UnitPoint2D?
    private var analysisPaused = false
    private var manualInferenceResumeAfter: TimeInterval = 0 // Analysis queue only.
    private var ignoreFramesUntil: TimeInterval = 0
    private var focusCandidate: UnitPoint2D?
    private var focusCandidateSince: TimeInterval = 0
    private var lastAutomaticFocus: TimeInterval = 0
    private var lastFocusedPoint: UnitPoint2D?
    private var zoomMultiplier: CGFloat = 1 // Capture zoom that corresponds to the wide lens's 1×.
    private var captureCompletion: ((Result<CameraCapture, Error>) -> Void)?
    private var pendingProcessed: Data?
    private var pendingRAW: Data?
    private var pendingError: Error?
    private var pendingCaptureID: Int64?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        framing.reset(enabled: false)
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main
        ) { [weak self] _ in
            self?.isRunning = false
            self?.errorMessage = "The camera was interrupted. Close other camera apps, then return to Focal."
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil
        ) { [weak self] _ in self?.resumeIfWanted() })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: .main
        ) { [weak self] _ in
            self?.isRunning = false
            self?.errorMessage = "The camera stopped unexpectedly. Close and reopen Focal to try again."
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        motion.stopDeviceMotionUpdates()
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsToRun = true
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: self.configureAndStart()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard let self else { return }
                    self.queue.async {
                        if granted { self.configureAndStart() }
                        else { DispatchQueue.main.async { self.access = .denied } }
                    }
                }
            default: DispatchQueue.main.async { self.access = .denied }
            }
        }
    }

    func stop() {
        zoomRequestLock.lock(); zoomRequests.clear(); zoomRequestLock.unlock()
        videoQueue.async { self.previewCadence = PreviewFrameCadence() }
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsToRun = false
            self.cancelZoomRamp()
            if self.session.isRunning { self.session.stopRunning() }
            self.motion.stopDeviceMotionUpdates()
            self.analysisQueue.async { self.ignoreFramesUntil = 0; self.resetAnalysis(armFraming: false) }
            DispatchQueue.main.async { self.isRunning = false; self.telemetry = CameraTelemetry() }
        }
    }

    func switchCamera() {
        guard !isCapturing, !isSwitchingCamera, isRunning else { return }
        isSwitchingCamera = true
        queue.async {
            defer { DispatchQueue.main.async { self.isSwitchingCamera = false } }
            guard self.captureCompletion == nil, self.wantsToRun else { return }
            let previous = self.position
            self.cancelZoomRamp()
            self.position = previous == .back ? .front : .back
            self.discardConfiguration()
            self.analysisQueue.async { self.ignoreFramesUntil = 0; self.resetAnalysis() }
            self.configureAndStart()
            if !self.configured {
                self.position = previous
                self.discardConfiguration()
                self.configureAndStart()
                DispatchQueue.main.async { self.errorMessage = "That camera is unavailable. Focal kept the previous camera." }
            }
        }
    }

    func setExposure(_ bias: Float) {
        queue.async {
            guard self.captureCompletion == nil else { return }
            guard let device = self.device else { return }
            let value = max(device.minExposureTargetBias, min(device.maxExposureTargetBias, bias))
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(value, completionHandler: nil)
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.exposureBias = value }
            } catch { DispatchQueue.main.async { self.errorMessage = "Exposure could not be adjusted." } }
        }
    }

    private func discardConfiguration() {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        if output.isAppleProRAWEnabled { output.isAppleProRAWEnabled = false }
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        configured = false
        device = nil
        DispatchQueue.main.async { self.isRunning = false }
    }

    private func guidanceSnapshot() -> GuidanceActivation.Snapshot {
        guidanceLock.lock(); defer { guidanceLock.unlock() }
        return activation.snapshot
    }

    private func publishAnalysis(_ snapshot: GuidanceActivation.Snapshot, update: @escaping () -> Void) {
        DispatchQueue.main.async {
            guard snapshot.enabled, self.guidanceSnapshot() == snapshot else { return }
            update()
        }
    }

    func setSubjectThreshold(_ value: Double) {
        queue.async {
            self.cancelZoomRamp()
            self.analysisQueue.async {
                self.tracker.setThreshold(value)
                self.ignoreFramesUntil = 0
                self.resetAnalysis()
            }
        }
    }

    func setHoldDuration(_ duration: Double) {
        analysisQueue.async { self.holdDuration = max(0.5,min(2,duration)); self.framing.reset(enabled:self.autoFrameEnabled && self.guidanceEnabled && self.analysisSource == .iPhone) }
    }

    func setAnalysisSource(_ source: CameraSource) {
        guidanceLock.lock(); _ = activation.set(activation.snapshot.enabled, source: source); guidanceLock.unlock()
        tracker.cancelInference()
        queue.async {
            self.cancelZoomRamp()
            let front = self.device?.position == .front
            let actualZoom = self.device.map { Double($0.videoZoomFactor/self.zoomMultiplier) } ?? 1
            self.analysisQueue.async {
                self.analysisSource = source
                self.analysisFrontCamera = source == .iPhone && front
                self.analysisZoom = source == .iPhone ? actualZoom : 1
                self.analysisPaused = false
                self.ignoreFramesUntil = 0
                self.resetAnalysis(armFraming:source == .iPhone)
            }
        }
    }

    /// Admission control drops frames while the shared Vision queue is busy.
    func analyzeExternalFrame(_ data: Data) {
        let snapshot = guidanceSnapshot()
        guard snapshot.enabled, snapshot.source == .sony else { return }
        externalLock.lock()
        guard !externalFramePending else { externalLock.unlock(); return }
        externalFramePending = true; externalLock.unlock()
        analysisQueue.async {
            defer { self.externalLock.lock(); self.externalFramePending = false; self.externalLock.unlock() }
            guard self.guidanceSnapshot() == snapshot, self.guidanceEnabled, self.analysisSource == .sony, let source = CIImage(data:data,options:[.applyOrientationProperty:true]) else { return }
            let scale = min(1,1280/max(source.extent.width,source.extent.height))
            let image = source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            var buffer: CVPixelBuffer?
            let attributes: [CFString:Any] = [kCVPixelBufferIOSurfacePropertiesKey:[String:Any]()]
            guard CVPixelBufferCreate(kCFAllocatorDefault,Int(image.extent.width),Int(image.extent.height),kCVPixelFormatType_32BGRA,attributes as CFDictionary,&buffer) == kCVReturnSuccess,let buffer else { return }
            self.imageContext.render(image,to:buffer)
            self.processFrame(buffer)
        }
    }

    func beginManualZoom(completion: @escaping (Double) -> Void) {
        tracker.cancelInference(includeTracking: false)
        queue.async {
            guard self.captureCompletion == nil else { return }
            self.cancelZoomRamp()
            let actual = self.device.map { Double($0.videoZoomFactor/self.zoomMultiplier) } ?? 1
            self.analysisQueue.async {
                if let bounds = self.latestNativeBounds {
                    self.tracker.reseed(bounds:FramingPlanner.zoomedRect(bounds,scale:actual/self.latestBoundsZoom),label:self.tracker.label,manual:self.tracker.manual)
                }
                self.boxSmoother.reset(); self.engine.reset(); self.automaticGuidance.reset()
                self.framing.reset(enabled:false); self.ignoreFramesUntil = 0
                self.manualInferenceResumeAfter = ProcessInfo.processInfo.systemUptime + 0.5
                self.publishFraming()
            }
            DispatchQueue.main.async { completion(actual) }
        }
    }

    private func publishTelemetry() {
        queue.async {
            let now = ProcessInfo.processInfo.systemUptime
            guard now-self.lastTelemetry > 0.3, self.session.isRunning,let device = self.device else { return }
            self.lastTelemetry = now
            let seconds = CMTimeGetSeconds(device.exposureDuration)
            let iso = device.iso
            let aperture = device.lensAperture
            let mode = device.exposureMode == .custom ? "MANUAL" : device.exposureMode == .locked ? "LOCK" : "AUTO"
            let data = CameraTelemetry(mode:mode,shutter:CameraTelemetry.shutterLabel(seconds:seconds),
                iso:iso.isFinite && iso > 0 ? String(format:"%.0f",iso) : nil,ev:Double(device.exposureTargetBias),
                aperture:aperture.isFinite && aperture > 0 ? String(format:"ƒ/%.1f",aperture) : nil)
            DispatchQueue.main.async { self.telemetry = data }
        }
    }

    func setMode(_ mode: CompositionMode) {
        analysisQueue.async { self.mode = mode; self.engine.reset() }
    }

    func setGuidance(_ enabled: Bool) {
        guidanceLock.lock(); let snapshot = activation.set(enabled); guidanceLock.unlock()
        tracker.cancelInference()
        if !enabled {
            DispatchQueue.main.async {
                guard self.guidanceSnapshot() == snapshot else { return }
                self.reading = CompositionReading(); self.guidance = GuidanceMessage()
                self.framingPhase = .off; self.scanData = nil
                self.coachAdvice = []; self.liveMeasurements = nil; self.sceneLabel = nil
            }
        }
        queue.async {
            self.cancelZoomRamp()
            self.analysisQueue.async {
                guard self.guidanceSnapshot() == snapshot else { return }
                self.guidanceEnabled = enabled; self.ignoreFramesUntil = 0; self.resetAnalysis()
            }
        }
    }

    func setCoach(_ enabled: Bool) {
        analysisQueue.async {
            self.coachEnabled = enabled
            self.lastCoach = -.infinity
            if !enabled { DispatchQueue.main.async { self.coachAdvice = []; self.liveMeasurements = nil; self.sceneLabel = nil } }
        }
    }

    func setPreviewPixelWidth(_ width: Double) {
        queue.async { self.previewPixelWidth = max(1080, width) }
    }

    func setAutoFraming(_ enabled: Bool) {
        queue.async {
            self.cancelZoomRamp()
            self.analysisQueue.async {
                self.autoFrameEnabled = enabled
                self.framing.reset(enabled: enabled && self.guidanceEnabled && self.analysisSource == .iPhone)
                self.ignoreFramesUntil = 0
                self.publishFraming()
            }
        }
    }

    func cancelAutoFraming() {
        queue.async {
            self.cancelZoomRamp()
            self.analysisQueue.async {
                self.framing.reset(enabled: false)
                self.ignoreFramesUntil = 0
                self.publishFraming()
            }
        }
    }

    private func cancelZoomRamp() {
        zoomGeneration += 1
        let generation = zoomGeneration
        analysisQueue.async { self.analysisZoomGeneration = generation }
        if let device, device.isRampingVideoZoom {
            do {
                try device.lockForConfiguration()
                device.cancelVideoZoomRamp()
                device.unlockForConfiguration()
            } catch { /* Preserve current zoom if the camera is being interrupted. */ }
        }
        if let device {
            let actual = Double(device.videoZoomFactor / zoomMultiplier)
            analysisQueue.async { self.analysisZoom = actual }
            DispatchQueue.main.async { self.zoom = actual }
        }
    }

    private func publishFraming() {
        let phase = framing.phase
        DispatchQueue.main.async { self.framingPhase = phase }
    }

    func setTarget(_ target: UnitPoint2D?) {
        analysisQueue.async { self.preferredTarget = target; self.engine.reset() }
    }

    func setPreviewAspect(_ aspect: Double) {
        analysisQueue.async { self.previewAspect = aspect; self.engine.reset() }
    }

    func findSubject() {
        guard guidanceSnapshot().enabled else { return }
        queue.async {
            self.cancelZoomRamp()
            self.analysisQueue.async {
                self.resetAnalysis()
                self.ignoreFramesUntil = 0
                DispatchQueue.main.async { self.subjectLabel = "Auto subject"; self.reading = CompositionReading() }
            }
        }
    }

    func selectSubject(at previewPoint: UnitPoint2D) {
        guard guidanceSnapshot().enabled else { return }
        queue.async {
            self.cancelZoomRamp()
            self.analysisQueue.async {
                self.ignoreFramesUntil = 0
                guard self.guidanceEnabled, self.guidanceSnapshot().enabled else { return }
                let projection = PreviewProjection(imageAspect: self.imageAspect, previewAspect: self.previewAspect, mirrored: self.analysisFrontCamera)
                self.tracker.select(at: projection.imagePoint(previewPoint))
                self.engine.reset(); self.boxSmoother.reset(); self.automaticGuidance.reset()
                self.latestNativeBounds = nil
                self.framing.reset(enabled: self.autoFrameEnabled && self.guidanceEnabled && self.analysisSource == .iPhone)
                self.publishFraming()
                self.wantsScan = true
                DispatchQueue.main.async { self.subjectLabel = "Your subject"; self.reading = CompositionReading(); self.guidance = GuidanceMessage() }
            }
        }
    }

    func setZoom(_ displayedZoom: Double) {
        guard !isCapturing else { return }
        zoomRequestLock.lock(); let schedule = zoomRequests.enqueue(displayedZoom); zoomRequestLock.unlock()
        guard schedule else { return }
        tracker.cancelInference(includeTracking: false)
        queue.async {
            self.cancelZoomRamp()
            self.analysisQueue.async {
                self.framing.reset(enabled: false); self.ignoreFramesUntil = 0
                self.manualInferenceResumeAfter = ProcessInfo.processInfo.systemUptime + 0.5
                self.publishFraming()
            }
        }
        queue.asyncAfter(deadline: .now() + 1.0 / 30.0) {
            self.zoomRequestLock.lock(); let requested = self.zoomRequests.take(); self.zoomRequestLock.unlock()
            guard let requested, self.wantsToRun, self.captureCompletion == nil, let device = self.device else { return }
            self.cancelZoomRamp()
            self.analysisQueue.async { self.ignoreFramesUntil = 0; self.framing.reset(enabled: false); self.publishFraming() }
            let upper = min(device.maxAvailableVideoZoomFactor, self.zoomMultiplier * 6)
            let factor = max(device.minAvailableVideoZoomFactor,
                             min(upper, CGFloat(requested) * self.zoomMultiplier))
            guard abs(device.videoZoomFactor - factor) > 0.015 else { return }
            do {
                try device.lockForConfiguration()
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = factor
                device.unlockForConfiguration()
                let value = Double(factor / self.zoomMultiplier)
                self.analysisQueue.async {
                    if let bounds = self.latestNativeBounds {
                        self.tracker.reseed(bounds:FramingPlanner.zoomedRect(bounds,scale:value/self.latestBoundsZoom),label:self.tracker.label,manual:self.tracker.manual)
                    }
                    self.boxSmoother.reset(); self.automaticGuidance.reset(); self.engine.reset()
                    self.analysisZoom = value
                    self.ignoreFramesUntil = ProcessInfo.processInfo.systemUptime + 0.08
                    self.manualInferenceResumeAfter = ProcessInfo.processInfo.systemUptime + 0.5
                }
                DispatchQueue.main.async { self.zoom = value; self.reading = CompositionReading() }
            } catch { DispatchQueue.main.async { self.errorMessage = "Zoom could not be changed. Please try again." } }
        }
    }

    private func resetAnalysis(armFraming: Bool = true) {
        framing.reset(enabled: armFraming && autoFrameEnabled && guidanceEnabled && analysisSource == .iPhone)
        automaticGuidance.reset(); boxSmoother.reset(); latestNativeBounds = nil
        publishFraming()
        engine.reset()
        tracker.reset()
        focusCandidate = nil
        focusCandidateSince = 0
        lastFocusedPoint = nil
        wantsScan = true
        lastCoach = -.infinity; lastScene = -.infinity
        sceneMeasurements = nil; lastSceneMeasurement = -.infinity; manualInferenceResumeAfter = 0
        DispatchQueue.main.async {
            self.scanData = nil; self.reading = CompositionReading(); self.subjectLabel = "Auto subject"; self.guidance = GuidanceMessage()
            self.coachAdvice = []; self.liveMeasurements = nil; self.sceneLabel = nil; self.levelReliable = false
        }
    }

    func focus(at point: CGPoint, continuous: Bool = false, meterExposure: Bool = true) {
        queue.async { [weak self] in
            guard let self, self.captureCompletion == nil, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if continuous && (!self.guidanceSnapshot().enabled || self.guidanceSnapshot().source != .iPhone || device.isAdjustingFocus) { return }
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    // Tap selects the focus location, not a permanently locked
                    // lens distance. Continue refocusing as the camera moves.
                    let focusMode: AVCaptureDevice.FocusMode = device.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : .autoFocus
                    if device.isFocusModeSupported(focusMode) { device.focusMode = focusMode }
                }
                if meterExposure && device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
            } catch { /* Focus is best-effort; capture remains available. */ }
        }
    }

    func capture(options: CaptureOptions = CaptureOptions(), completion: @escaping (Result<CameraCapture, Error>) -> Void) {
        guard isRunning, !isCapturing, framingPhase != .zooming else {
            completion(.failure(CameraError.notRunning))
            return
        }
        isCapturing = true
        analysisQueue.async { self.analysisPaused = true }
        queue.async {
            guard self.session.isRunning, self.device?.isRampingVideoZoom != true else {
                DispatchQueue.main.async {
                    self.isCapturing = false
                    completion(.failure(CameraError.notRunning))
                }
                self.analysisQueue.async { self.analysisPaused = false }
                return
            }
            self.captureCompletion = completion
            self.pendingProcessed = nil
            self.pendingRAW = nil
            self.pendingError = nil
            let settings = self.photoSettings(options: options)
            self.pendingCaptureID = settings.uniqueID
            let captureID = settings.uniqueID
            self.output.capturePhoto(with: settings, delegate: self)
            self.queue.asyncAfter(deadline: .now() + 30) {
                guard self.pendingCaptureID == captureID, self.captureCompletion != nil else { return }
                self.finishCapture(.failure(CameraError.timeout))
            }
        }
    }

    private func resumeIfWanted() {
        queue.async { if self.wantsToRun { self.configureAndStart() } }
    }

    private func photoSettings(options: CaptureOptions = CaptureOptions()) -> AVCapturePhotoSettings {
        let format: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.jpeg]
        let settings: AVCapturePhotoSettings
        let rawFormat = output.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) })
            ?? output.availableRawPhotoPixelFormatTypes.first
        if options.raw, let rawFormat {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: format)
        } else { settings = AVCapturePhotoSettings(format: format) }
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        // Bayer RAW bypasses computational processing; ProRAW supports quality processing.
        let bayerRAW = options.raw && rawFormat.map { !AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) } == true
        settings.photoQualityPrioritization = bayerRAW ? .speed : .quality
        let flash = AVCaptureDevice.FlashMode(rawValue: options.flash.rawValue) ?? .off
        settings.flashMode = output.supportedFlashModes.contains(flash) ? flash : .off
        if #available(iOS 18.0, *), output.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = !options.shutterSound
        }
        return settings
    }

    private func configureAndStart() {
        guard wantsToRun else { return }
        if !configured { DispatchQueue.main.async { self.access = .checking } }
        do {
            if !configured {
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                session.sessionPreset = .photo
                let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera,
                                                         .builtInDualCamera, .builtInWideAngleCamera]
                let selectedTypes: [AVCaptureDevice.DeviceType] = position == .back ? types : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
                guard let camera = selectedTypes.compactMap({ AVCaptureDevice.default($0, for: .video, position: position) }).first else {
                    DispatchQueue.main.async { self.access = .unavailable }
                    return
                }
                let input = try AVCaptureDeviceInput(device: camera)
                guard session.canAddInput(input), session.canAddOutput(output), session.canAddOutput(videoOutput) else {
                    throw CameraError.configuration
                }
                session.addInput(input)
                session.addOutput(output)
                session.addOutput(videoOutput)
                try configurePreviewFormat(camera)
                output.maxPhotoQualityPrioritization = .quality
                if output.isAppleProRAWSupported { output.isAppleProRAWEnabled = true }
                if let dimensions = camera.activeFormat.supportedMaxPhotoDimensions.max(by: {
                    Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
                }) {
                    output.maxPhotoDimensions = dimensions
                    let megapixels = Double(dimensions.width) * Double(dimensions.height) / 1_000_000
                    DispatchQueue.main.async { self.photoResolution = String(format: "%.0f MP", megapixels) }
                }
                videoOutput.alwaysDiscardsLateVideoFrames = true
                // Native YUV avoids converting every full-size frame to a large RGB buffer.
                let pixelFormat: OSType = videoOutput.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                    ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
                videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
                for connection in [videoOutput.connection(with: .video), output.connection(with: .video)] {
                    if connection?.isVideoRotationAngleSupported(90) == true { connection?.videoRotationAngle = 90 }
                    if connection?.isVideoMirroringSupported == true {
                        connection?.automaticallyAdjustsVideoMirroring = false
                        connection?.isVideoMirrored = position == .front && connection === output.connection(with: .video)
                    }
                }
                device = camera
                try camera.lockForConfiguration()
                if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
                if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
                if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { camera.whiteBalanceMode = .continuousAutoWhiteBalance }
                if camera.isLowLightBoostSupported { camera.automaticallyEnablesLowLightBoostWhenAvailable = false }
                if camera.isSmoothAutoFocusSupported { camera.isSmoothAutoFocusEnabled = false }
                let hasUltraWide = camera.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
                zoomMultiplier = hasUltraWide ? CGFloat(camera.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 2) : 1
                camera.videoZoomFactor = min(camera.maxAvailableVideoZoomFactor, max(camera.minAvailableVideoZoomFactor, zoomMultiplier))
                camera.unlockForConfiguration()
                let lower = Double(camera.minAvailableVideoZoomFactor / zoomMultiplier)
                let upper = min(6, Double(camera.maxAvailableVideoZoomFactor / zoomMultiplier))
                var stops = [lower, 1.0, 2.0]
                stops += camera.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue / Double(zoomMultiplier) }
                let available = Array(Set(stops.filter { $0 >= lower && $0 <= upper })).sorted()
                let opticalLimit = camera.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue / Double(self.zoomMultiplier) }.max() ?? 1
                let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
                // Permit a modest crop while retaining enough pixels for the phone's display.
                // Native telephoto stops remain available beyond that preview pixel budget.
                let previewBudget = min(3, Double(min(dimensions.width, dimensions.height)) / self.previewPixelWidth)
                let detailLimit = max(1, max(previewBudget, Double(camera.activeFormat.videoZoomFactorUpscaleThreshold / self.zoomMultiplier)))
                let autoLimit = min(upper, max(opticalLimit, detailLimit))
                self.analysisQueue.async {
                    self.analysisFrontCamera = camera.position == .front
                    self.analysisZoom = 1
                    self.automaticZoomLimit = autoLimit
                    self.detailZoomLimit = max(1, detailLimit)
                    self.nativeZoomStops = [1] + camera.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue / Double(self.zoomMultiplier) }
                }
                DispatchQueue.main.async {
                    self.isFrontCamera = camera.position == .front; self.previewFPS = nil
                    self.exposureBias = camera.exposureTargetBias
                    self.exposureRange = max(-3, camera.minExposureTargetBias)...min(3, camera.maxExposureTargetBias)
                    self.motionAvailable = self.motion.isDeviceMotionAvailable
                    self.previewResolution = "\(dimensions.height) × \(dimensions.width) · \(self.configuredPreviewRate) fps target"
                    self.qualityZoomLimit = autoLimit
                    self.minimumZoom = lower
                    self.maximumZoom = upper
                    self.zoomStops = available
                    self.zoom = Double(camera.videoZoomFactor / self.zoomMultiplier)
                    self.supportsProRAW = self.output.isAppleProRAWSupported
                    self.supportsRAW = !self.output.availableRawPhotoPixelFormatTypes.isEmpty
                    self.supportsFlash = camera.hasFlash
                    if #available(iOS 18.0, *) { self.canMuteShutter = self.output.isShutterSoundSuppressionSupported }
                }
                configured = true
            }
            if !session.isRunning { session.startRunning() }
            output.setPreparedPhotoSettingsArray([photoSettings()], completionHandler: nil)
            if motion.isDeviceMotionAvailable {
                motion.deviceMotionUpdateInterval = 0.15
                motion.startDeviceMotionUpdates()
            }
            DispatchQueue.main.async {
                self.access = .available
                self.isRunning = self.session.isRunning
            }
        } catch {
            discardConfiguration()
            DispatchQueue.main.async {
                self.access = .unavailable
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func configurePreviewFormat(_ camera: AVCaptureDevice) throws {
        // A low-resolution or 16:9 stream enlarged into a 3:4 view looks soft/cropped.
        // Prefer a full 4:3 sensor preview with at least 1080 pixels on its short edge.
        let candidates = camera.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width >= 1920 && size.height >= 1080 && size.width <= 4096
                && abs(Double(size.width) / Double(size.height) - 4.0 / 3) < 0.03
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
                && !format.supportedMaxPhotoDimensions.isEmpty && format.isHighPhotoQualitySupported
        }
        let best = candidates.max { left, right in
            func score(_ format: AVCaptureDevice.Format) -> Int64 {
                let photoPixels = format.supportedMaxPhotoDimensions.map { Int64($0.width) * Int64($0.height) }.max() ?? 0
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return photoPixels * 100 + Int64(size.width) * Int64(size.height)
            }
            let leftPhotos = left.supportedMaxPhotoDimensions.map { Int64($0.width) * Int64($0.height) }.max() ?? 0
            let rightPhotos = right.supportedMaxPhotoDimensions.map { Int64($0.width) * Int64($0.height) }.max() ?? 0
            if leftPhotos != rightPhotos { return leftPhotos < rightPhotos }
            let leftFast = left.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 60 && $0.maxFrameRate >= 60 }
            let rightFast = right.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 60 && $0.maxFrameRate >= 60 }
            if leftFast != rightFast { return !leftFast && rightFast }
            return score(left) < score(right)
        }
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        if let best { camera.activeFormat = best }
        let supports60 = camera.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 60 && $0.maxFrameRate >= 60 }
        configuredPreviewRate = supports60 ? 60 : 30
        let rate = Double(configuredPreviewRate)
        if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= rate && $0.maxFrameRate >= rate }) {
            let duration = CMTime(value: 1, timescale: Int32(configuredPreviewRate))
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
        }

    }

    private func performAutomaticZoom(to target: Double, generation: Int) {
        queue.async {
            guard generation == self.zoomGeneration, self.guidanceSnapshot().enabled else { return }
            guard self.wantsToRun, self.captureCompletion == nil, let device = self.device else {
                self.analysisQueue.async { self.ignoreFramesUntil = 0; self.framing.reset(enabled: false); self.publishFraming() }
                return
            }
            let factor = min(device.maxAvailableVideoZoomFactor, max(device.minAvailableVideoZoomFactor, CGFloat(target) * self.zoomMultiplier))
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor: factor, withRate: Float(max(2, abs(Double(factor - device.videoZoomFactor)) / 0.85)))
                device.unlockForConfiguration()
                self.analysisQueue.async { self.ignoreFramesUntil = 0 }
                self.observeAutomaticZoom(generation: generation, deadline: ProcessInfo.processInfo.systemUptime + 3)
            } catch {
                self.analysisQueue.async { self.ignoreFramesUntil = 0; self.framing.reset(enabled: false); self.publishFraming() }
                DispatchQueue.main.async { self.errorMessage = "Automatic framing could not change zoom. Pinch to frame the shot." }
            }
        }
    }

    private func observeAutomaticZoom(generation: Int, deadline: TimeInterval) {
        guard generation == zoomGeneration, let device else { return }
        let actual = Double(device.videoZoomFactor / zoomMultiplier)
        DispatchQueue.main.async { self.zoom = actual }
        analysisQueue.async {
            guard self.analysisZoomGeneration == generation, self.framing.phase == .zooming else { return }
            self.analysisZoom = actual
        }
        if device.isRampingVideoZoom && ProcessInfo.processInfo.systemUptime < deadline {
            queue.asyncAfter(deadline: .now() + 0.05) {
                self.observeAutomaticZoom(generation: generation, deadline: deadline)
            }
            return
        }
        if device.isRampingVideoZoom {
            do {
                try device.lockForConfiguration()
                device.cancelVideoZoomRamp()
                device.unlockForConfiguration()
            } catch { /* Completion uses the actual achieved zoom. */ }
        }
        analysisQueue.async {
            guard self.analysisZoomGeneration == generation else { return }
            // Keep the same subject across the lens transition; do not run saliency anew.
            guard let current = self.latestNativeBounds else {
                self.framing.reset(enabled: false); self.ignoreFramesUntil = 0; self.publishFraming(); return
            }
            let seeded = FramingPlanner.zoomedRect(current, scale: actual / self.latestBoundsZoom)
            self.tracker.reseed(bounds: seeded, label: self.tracker.label, manual: self.tracker.manual)
            self.analysisZoom = actual
            self.engine.reset(); self.boxSmoother.reset()
            self.framing.finish()
            self.ignoreFramesUntil = ProcessInfo.processInfo.systemUptime + 0.25
            self.wantsScan = true
            self.publishFraming()
        }
    }

    enum CameraError: LocalizedError {
        case configuration, missingPhoto, notRunning, timeout
        var errorDescription: String? {
            switch self {
            case .configuration: return "This device could not configure a camera. You can still explore the demo."
            case .missingPhoto: return "The camera did not return a photo. Please try again."
            case .timeout: return "The camera did not finish the capture. Retry or restart Focal."
            case .notRunning: return "The camera is paused. Return to the camera and try again."
            }
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let snapshot = guidanceSnapshot()
        guard snapshot.source == .iPhone else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if let rate = previewCadence.observe(timestamp) {
            DispatchQueue.main.async { self.previewFPS = rate }
        }
        if now - lastVideoTelemetry >= 0.3 { lastVideoTelemetry = now; publishTelemetry() }
        guard snapshot.enabled else {
            if now - lastAnalysisLevelUpdate >= 0.2 {
                lastAnalysisLevelUpdate = now
                publishManualLevel(snapshot)
            }
            return
        }
        guard previewScheduler.admit(at: now, enabled: true) else { return }
        guard let native = CMSampleBufferGetImageBuffer(sampleBuffer), let copy = previewAnalysisCopy(native) else {
            previewScheduler.finish(); return
        }
        let aspect = Double(CVPixelBufferGetWidth(native)) / Double(CVPixelBufferGetHeight(native))
        analysisQueue.async {
            defer { self.videoQueue.async { self.previewScheduler.finish() } }
            guard self.guidanceSnapshot() == snapshot, self.analysisSource == .iPhone else { return }
            self.processFrame(copy, sourceAspect: aspect)
        }
        // No CMSampleBuffer/native pixel buffer is retained by the async closure.
    }

    private func publishManualLevel(_ snapshot: GuidanceActivation.Snapshot) {
        let gravity = motion.deviceMotion?.gravity
        let reliable = gravity.map { hypot($0.x, $0.y) > 0.2 } ?? false
        let roll = gravity.map { reliable ? atan2($0.x, -$0.y) * 180 / .pi : 0 } ?? 0
        let result = CompositionReading(rollDegrees: roll)
        DispatchQueue.main.async {
            guard !snapshot.enabled, self.guidanceSnapshot() == snapshot else { return }
            self.reading = result; self.levelReliable = reliable
        }
    }

    /// Copy once at admission, then release the capture pool's native buffer.
    /// The bounded copy preserves the existing 1600px scan references. Vision
    /// receives its own 640px buffer below; neither affects preview/photo pixels.
    private func previewAnalysisCopy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, 1600.0 / Double(max(w, h)))
        let width = max(1, Int(Double(w) * scale)), height = max(1, Int(Double(h) * scale))
        if videoAnalysisBuffer == nil || CVPixelBufferGetWidth(videoAnalysisBuffer!) != width || CVPixelBufferGetHeight(videoAnalysisBuffer!) != height {
            var created: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created) == kCVReturnSuccess else { return nil }
            videoAnalysisBuffer = created
        }
        guard let copy = videoAnalysisBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: source).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        previewCopyContext.render(image, to: copy, bounds: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), colorSpace: CGColorSpaceCreateDeviceRGB())
        return copy
    }

    private func processFrame(_ fullBuffer: CVPixelBuffer, sourceAspect: Double? = nil) {
        guard !analysisPaused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= ignoreFramesUntil,now-lastAnalysis > 0.2 else { return }
        lastAnalysis = now
        let snapshot = guidanceSnapshot()
        guard snapshot.source == analysisSource else { return }
        if !snapshot.enabled || !guidanceEnabled {
            let gravity = analysisSource == .iPhone ? motion.deviceMotion?.gravity : nil
            let roll = gravity.map { hypot($0.x, $0.y) > 0.2 ? atan2($0.x, -$0.y) * 180 / .pi : 0 } ?? 0
            let result = CompositionReading(rollDegrees: roll)
            let reliable = gravity.map { hypot($0.x,$0.y) > 0.2 } ?? false
            DispatchQueue.main.async {
                guard !snapshot.enabled, self.guidanceSnapshot() == snapshot else { return }
                self.reading = result; self.levelReliable = reliable
            }
            return
        }
        guard let buffer = smallAnalysisBuffer(from: fullBuffer) else { return }
        if let sourceAspect { imageAspect = sourceAspect }
        let zooming = framing.phase == .zooming
        let deviceMoving = analysisSource == .iPhone && motion.deviceMotion.map {
            !CameraStability.isStable(rotation: ($0.rotationRate.x, $0.rotationRate.y, $0.rotationRate.z),
                                      acceleration: ($0.userAcceleration.x, $0.userAcceleration.y, $0.userAcceleration.z))
        } == true
        if zooming, let native = latestNativeBounds, abs(analysisZoom - latestBoundsZoom) > 0.015 {
            tracker.reseed(bounds: FramingPlanner.zoomedRect(native, scale: analysisZoom / latestBoundsZoom), label: tracker.label, manual: tracker.manual)
        }
        if wantsScan {
            wantsScan = false
            let image = CIImage(cvPixelBuffer: fullBuffer)
            let scale = min(1, 1600 / max(image.extent.width, image.extent.height))
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cgImage = imageContext.createCGImage(scaled, from: scaled.extent),
               let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.93) {
                publishAnalysis(snapshot) { self.scanData = jpeg }
            }
        }
        var subject: UnitPoint2D?
        var bounds: CGRect?
        var imageBounds: CGRect?
        var confidence: Float = 0
        let visibleProjection = PreviewProjection(imageAspect:imageAspect,previewAspect:previewAspect)
        let topLeft = visibleProjection.imagePoint(.init(x:0,y:0))
        let bottomRight = visibleProjection.imagePoint(.init(x:1,y:1))
        let visibleRegion = CGRect(x:topLeft.x,y:1-bottomRight.y,width:bottomRight.x-topLeft.x,height:bottomRight.y-topLeft.y)
        if let object = tracker.observation(in: buffer, timestamp: now, visibleRegion: visibleRegion, trackingOnly: zooming || deviceMoving || now < manualInferenceResumeAfter,
                                            canContinue: { self.guidanceSnapshot() == snapshot }) {
            imageBounds = object.boundingBox
            latestNativeBounds = object.boundingBox; latestBoundsZoom = analysisZoom
            confidence = object.confidence
            let imagePoint = UnitPoint2D(x: object.boundingBox.midX, y: 1 - object.boundingBox.midY)
            let projection = PreviewProjection(imageAspect: imageAspect, previewAspect: previewAspect, mirrored: analysisFrontCamera)
            subject = projection.visiblePoint(imagePoint)
            let topLeftRect = CGRect(x: object.boundingBox.minX, y: 1 - object.boundingBox.maxY,
                                     width: object.boundingBox.width, height: object.boundingBox.height)
            bounds = projection.visibleRect(topLeftRect)
            if analysisSource == .iPhone, confidence >= 0.6, !deviceMoving, !zooming, now >= manualInferenceResumeAfter {
                updateAutomaticFocus(imagePoint, timestamp: now)
            }
        }
        if imageBounds == nil {
            latestNativeBounds = nil
            if zooming {
                framing.reset(enabled: false)
                queue.async { self.cancelZoomRamp() }
            }
        }
        guard guidanceSnapshot() == snapshot else { return }
        let evaluatedAt = ProcessInfo.processInfo.systemUptime
        let motionData = analysisSource == .iPhone ? motion.deviceMotion : nil
        let gravity = motionData?.gravity
        let stable = motionData.map {
            evaluatedAt-$0.timestamp >= 0 && evaluatedAt-$0.timestamp < 0.45 && CameraStability.isStable(rotation:($0.rotationRate.x,$0.rotationRate.y,$0.rotationRate.z),acceleration:($0.userAcceleration.x,$0.userAcceleration.y,$0.userAcceleration.z))
        } ?? (analysisSource == .sony)
        // When looking straight up/down, gravity cannot give a meaningful portrait roll.
        let roll = gravity.map { hypot($0.x, $0.y) > 0.2 ? atan2($0.x, -$0.y) * 180 / .pi : 0 } ?? 0
        if let targetZoom = framing.update(bounds: bounds, confidence: confidence, roll: roll, timestamp: evaluatedAt,
                                            currentZoom: analysisZoom, maximumZoom: automaticZoomLimit,
                                            detailZoomLimit: detailZoomLimit, nativeStops: nativeZoomStops, deviceStable:stable, holdDuration:holdDuration, previewAspect:previewAspect), imageBounds != nil {
            performAutomaticZoom(to: targetZoom, generation: analysisZoomGeneration)
        }
        var result = engine.update(subject: subject, rollDegrees: roll, mode: autoFrameEnabled && analysisSource == .iPhone ? .centered : mode, timestamp: evaluatedAt,
                                   preferredTarget: autoFrameEnabled && analysisSource == .iPhone ? nil : preferredTarget, previewAspect: previewAspect)
        let analysisReadingBounds = bounds
        result.subjectBounds = boxSmoother.update(bounds)
        result.subjectConfidence = confidence
        let reliable = gravity.map { hypot($0.x,$0.y) > 0.2 } ?? false
        if analysisSource == .iPhone && motionData == nil && (result.state == .ready || result.state == .settling) {
            result.state = .adjusting
            result.title = "Level unavailable. Frame manually"
        }
        if !stable && result.state == .ready { result.state = .settling }
        let scene = tracker.scene.flatMap { now - $0.timestamp <= 6 ? $0 : nil }
        if imageBounds == nil, scene?.isLandscape == true, now - lastSceneMeasurement >= 2 {
            lastSceneMeasurement = now; sceneMeasurements = PhotoMeasurements.from(buffer: buffer)
        }
        if coachEnabled && !zooming && !deviceMoving && now >= manualInferenceResumeAfter && now - lastCoach >= 2 {
            lastCoach = now
            let nativeRect = imageBounds.map { CGRect(x: $0.minX,y: 1 - $0.maxY,width: $0.width,height: $0.height) }
            let measurements = PhotoMeasurements.from(buffer: buffer,subject: nativeRect)
            var advice = [String]()
            if let text = measurements?.lightingAdvice { advice.append(text) }
            if let text = measurements?.clutterAdvice { advice.append(text) }
            if let bounds {
                if max(bounds.width,bounds.height) < 0.18 { advice.append("The subject is small in the frame. Move closer if it is safe.") }
                if bounds.width > 0.85 || bounds.height > 0.85 { advice.append("The subject fills the edges. Move farther back to leave space.") }
            }
            if now-lastScene >= 8 {
                lastScene = now
                let scene = VNClassifyImageRequest()
                do {
                    guard guidanceSnapshot() == snapshot else { return }
                    try tracker.performRequests([scene], canContinue: { self.guidanceSnapshot() == snapshot }) { try VNImageRequestHandler(cvPixelBuffer: buffer,orientation: .up).perform([scene]) }
                    guard guidanceSnapshot() == snapshot else { return }
                    let result = scene.results?.first
                    let name = (result?.confidence ?? 0) >= 0.55 ? result?.identifier.replacingOccurrences(of: "_",with: " ") : nil
                    publishAnalysis(snapshot) { self.sceneLabel = name }
                } catch { publishAnalysis(snapshot) { self.sceneLabel = nil } }
            }
            if tracker.label == "Person" {
                let pose = VNDetectHumanBodyPoseRequest()
                do {
                    guard guidanceSnapshot() == snapshot else { return }
                    try tracker.performRequests([pose], canContinue: { self.guidanceSnapshot() == snapshot }) { try VNImageRequestHandler(cvPixelBuffer: buffer,orientation: .up).perform([pose]) }
                    guard guidanceSnapshot() == snapshot else { return }
                    let bodies = (pose.results ?? []).compactMap { try? $0.recognizedPoints(.all) }
                    let target = imageBounds.map { CGPoint(x: $0.midX,y: $0.midY) }
                    let candidates = bodies.filter { points in
                        guard let target, let nose = points[.nose], nose.confidence > 0.4 else { return false }
                        return hypot(nose.x-Double(target.x),nose.y-Double(target.y)) < 0.25
                    }
                    let points = candidates.min { lhs,rhs in
                        guard let target,let a = lhs[.nose],let b = rhs[.nose] else { return false }
                        return hypot(a.x-Double(target.x),a.y-Double(target.y)) < hypot(b.x-Double(target.x),b.y-Double(target.y))
                    }
                    if let points, let left = points[.leftShoulder], let right = points[.rightShoulder], left.confidence > 0.5, right.confidence > 0.5 {
                        if abs(left.y-right.y) < 0.04 { advice.append("Nearly level shoulders detected. Try a slight three-quarter turn.") }
                        if (points[.leftWrist]?.confidence ?? 0) < 0.3 || (points[.rightWrist]?.confidence ?? 0) < 0.3 { advice.append("Hands are not confidently detected. Check the crop if you want them included.") }
                    }
                } catch { /* No pose advice without observed joints. */ }
            }
            publishAnalysis(snapshot) { self.liveMeasurements = measurements; self.coachAdvice = advice }
        }
        var measured = result; measured.subjectBounds = analysisReadingBounds
        let message = automaticGuidance.update(reading:measured,phase:framing.phase,stable:stable,
            rollReliable:reliable,autoEnabled:autoFrameEnabled && analysisSource == .iPhone,
            zoomAvailable:automaticZoomLimit > analysisZoom*1.12,timestamp:evaluatedAt,previewAspect:previewAspect,scene:scene,sceneMeasurements:sceneMeasurements)
        let label = tracker.label
        let phase = framing.phase
        publishAnalysis(snapshot) { self.reading = result; self.subjectLabel = label; self.framingPhase = phase; self.levelReliable = reliable; self.guidance = message }
    }

    private func smallAnalysisBuffer(from fullBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(fullBuffer)
        let height = CVPixelBufferGetHeight(fullBuffer)
        imageAspect = Double(width) / Double(height)
        let scale = min(1, 640.0 / Double(max(width, height)))
        let smallWidth = max(1, Int(Double(width) * scale))
        let smallHeight = max(1, Int(Double(height) * scale))
        if analysisBuffer == nil || CVPixelBufferGetWidth(analysisBuffer!) != smallWidth || CVPixelBufferGetHeight(analysisBuffer!) != smallHeight {
            var created: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
            guard CVPixelBufferCreate(kCFAllocatorDefault, smallWidth, smallHeight, kCVPixelFormatType_32BGRA,
                                      attributes as CFDictionary, &created) == kCVReturnSuccess else { return nil }
            analysisBuffer = created
        }
        guard let analysisBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: fullBuffer).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        imageContext.render(image, to: analysisBuffer,
                            bounds: CGRect(x: 0, y: 0, width: CGFloat(smallWidth), height: CGFloat(smallHeight)),
                            colorSpace: CGColorSpaceCreateDeviceRGB())
        return analysisBuffer
    }

    private func updateAutomaticFocus(_ point: UnitPoint2D, timestamp: TimeInterval) {
        guard guidanceSnapshot().enabled, !tracker.manual else { return } // Tap-to-focus keeps the user's exposure choice.
        if focusCandidate == nil || focusCandidate!.distance(to: point) > 0.08 {
            focusCandidate = point
            focusCandidateSince = timestamp
        }
        guard timestamp - focusCandidateSince > 0.6, timestamp - lastAutomaticFocus > 3 else { return }
        if let lastFocusedPoint, lastFocusedPoint.distance(to: point) < 0.12 { return }
        lastAutomaticFocus = timestamp
        lastFocusedPoint = point
        // Convert physically rotated portrait buffer coordinates to the sensor's landscape axes.
        focus(at: CGPoint(x: point.y, y: 1 - point.x), continuous: true, meterExposure: false)
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        // Some device failures occur before processing produces any image.
        queue.async {
            guard self.pendingCaptureID == resolvedSettings.uniqueID else { return }
            if let error { self.pendingError = error }
            if let error = self.pendingError { self.finishCapture(.failure(error)) }
            else if let processed = self.pendingProcessed {
                self.finishCapture(.success(CameraCapture(processed: processed, raw: self.pendingRAW)))
            } else { self.finishCapture(.failure(CameraError.missingPhoto)) }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let data = photo.fileDataRepresentation()
        let isRaw = photo.isRawPhoto
        let captureID = photo.resolvedSettings.uniqueID
        queue.async {
            guard self.pendingCaptureID == captureID else { return }
            if let error { self.pendingError = error }
            else if let data {
                if isRaw { self.pendingRAW = data } else { self.pendingProcessed = data }
            } else { self.pendingError = CameraError.missingPhoto }
        }
    }

    private func finishCapture(_ result: Result<CameraCapture, Error>) {
        queue.async {
            let completion = self.captureCompletion
            self.captureCompletion = nil
            self.pendingCaptureID = nil
            self.pendingProcessed = nil; self.pendingRAW = nil; self.pendingError = nil
            guard let completion else { return }
            self.analysisQueue.async { self.analysisPaused = false }
            DispatchQueue.main.async {
                self.isCapturing = false
                completion(result)
            }
        }
    }
}
