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
    @Published private(set) var framingHoldProgress: Double = 0
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
    @Published private(set) var compositionPlan: SceneCompositionPlan?
    @Published private(set) var controls = CameraControlSnapshot()
    @Published private(set) var precisionReading: PrecisionReading?
    @Published private(set) var autoTuneRecommendations: [AutoTuneRecommendation] = []
    @Published var errorMessage: String?

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.focal.camera", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "app.focal.vision", qos: .utility, autoreleaseFrequency: .workItem)
    private let videoQueue = DispatchQueue(label: "app.focal.video", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let precisionQueue = DispatchQueue(label:"app.focal.precision",qos:.utility,autoreleaseFrequency:.workItem)
    private let precisionLock = NSLock()
    private var precisionContext = PrecisionContext() // Protected by precisionLock.
    private var precisionScheduler = PreviewAnalysisScheduler(interval:0.35) // Video queue.
    private var precisionExternalScheduler = PreviewAnalysisScheduler(interval:0.35) // Protected by precisionLock.
    private var precisionVideoBuffer: CVPixelBuffer? // Video queue; held until precision finishes.
    private var precisionExternalBuffer: CVPixelBuffer? // Precision queue.
    private let precisionVideoContext = CIContext(options:[.cacheIntermediates:false,.priorityRequestLow:true])
    private let precisionExternalContext = CIContext(options:[.cacheIntermediates:false,.priorityRequestLow:true])
    #if DEBUG || FOCAL_EVALUATION
    private var guidanceDiagnostics = GuidanceDiagnostics() // Analysis queue only.
    @Published private(set) var guidancePerformance: GuidancePerformanceReport?
    #endif
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
    private var manualState = ManualCameraState() // Camera queue only.
    private var manualApplyScheduled = false
    private var selectedCameraID: String?
    private var cameraLensOptions: [CameraLensOption] = []
    private var advicePresentation = AutoTunePresentation() // Main queue only.
    private var currentAutoTuneRecommendations: [AutoTuneRecommendation] = [] // Main queue only.
    private var wantsToRun = false // Camera queue only.
    private var engine = CompositionEngine() // Analysis queue only.
    private var mode: CompositionMode = .automatic
    private var compositionPlanning = true
    private var photographyIntent: PhotographyIntent = .auto
    private var petFraming: PetFramingStyle = .balanced
    private var scenePlanner = SceneCompositionPlanner()
    private var directZoomPlan: SceneCompositionPlan?
    private var compositionEvidence: SceneCompositionEvidence?
    private var lastCompositionEvidence: TimeInterval = -.infinity
    private var guidanceEnabled = false
    private let guidanceLock = NSLock()
    private var activation = GuidanceActivation()
    private var subjectMeasurements: PhotoMeasurements?
    private var subjectMeasurementLabel: String?
    private var lastSubjectMeasurement: TimeInterval = -.infinity
    private var sceneMeasurements: PhotoMeasurements?
    private var lastSceneMeasurement: TimeInterval = -.infinity
    private var autoFrameEnabled = true
    private var framing = FramingPlanner()
    private var automaticGuidance = AutomaticGuidance()
    private var boxSmoother = SubjectBoxSmoother()
    private var holdDuration = 0.9
    private var analysisSource: CameraSource = .iPhone
    private var latestNativeBounds: CGRect?
    private var previousMotionSubject:(bounds:CGRect,label:String,time:TimeInterval,zoom:Double)?
    private var latestBoundsZoom: Double = 1
    private var lastTelemetry: TimeInterval = 0
    private let externalLock = NSLock()
    private var externalScheduler = PreviewAnalysisScheduler() // Protected by externalLock.
    private var externalAnalysisBuffer: CVPixelBuffer? // Analysis queue only.
    private var analysisZoom: Double = 1
    private var automaticZoomLimit: Double = 1
    private var detailZoomLimit: Double = 1
    private var nativeZoomStops: [Double] = [1]
    private var previewPixelWidth: Double = 1080 // Camera queue only.
    private var zoomGeneration = 0 // Camera queue only.
    private var autoZoomPreference = true // Camera queue; preserves explicit opt-out.
    private var automaticZoomBlocked = false // Camera queue; manual override survives settings resets.
    private var automaticShotArmed = true // Analysis queue; explicit new shot releases the override.
    private var rampStartZoom = 1.0 // Camera queue, hardware units.
    private var rampTargetZoom = 1.0
    private var rampPaused = false // Temporary recovery keeps the same shot and target.
    private var zoomWatchdog = ZoomProgressWatchdog()
    private var lastDirectorLogTime: TimeInterval = -.infinity
    private var rampHolding = false // Camera queue; no restart once desired geometry is reached.
    private var rampStage = -1
    private var lastRampVerification: TimeInterval = 0
    private let zoomObservationLock = NSLock()
    private var observedPhoneZoom = CameraZoomObservation(hardwareFactor:1,multiplier:1,ramping:false,timestamp:0)
    private var lastDirectorDiagnostic = "" // Analysis queue.
    private var analysisZoomGeneration = 0 // Analysis queue only.
    private var lastAnalysis: TimeInterval = 0
    private let tracker = SubjectTracker()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var analysisBuffer: CVPixelBuffer?
    private var imageAspect = 0.75
    private var previewAspect = 0.75
    private var wantsScan = true
    private var preferredTarget: UnitPoint2D?
    private var manualTargetLock: UnitPoint2D?
    private var analysisPaused = false
    private var interfacePaused = false
    private var manualInferenceResumeAfter: TimeInterval = 0 // Analysis queue only.
    private var ignoreFramesUntil: TimeInterval = 0
    private var focusCandidate: UnitPoint2D?
    private var focusCandidateSince: TimeInterval = 0
    private var lastAutomaticFocus: TimeInterval = 0
    private var lastFocusedPoint: UnitPoint2D?
    private var zoomMultiplier: CGFloat = 1 // Capture zoom that corresponds to the wide lens's 1×.
    private var shotCapture = ShotCaptureSession() // Analysis queue.
    private var pendingFramingCapture: FramedCapture? // Camera queue, frozen on shutter press.
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
        ) { [weak self] notification in
            self?.isRunning = false
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            if error?.code == .mediaServicesWereReset {
                self?.queue.async { [weak self] in
                    guard let self, self.wantsToRun else { return }
                    self.discardConfiguration(); self.configureAndStart()
                }
            } else { self?.errorMessage = "Camera session interrupted. Use Retry camera when it is available again." }
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
        precisionLock.lock(); precisionContext.generation += 1; precisionLock.unlock()
        DispatchQueue.main.async { self.precisionReading = nil; self.autoTuneRecommendations = []; self.currentAutoTuneRecommendations = []; self.advicePresentation.reset() }
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
            self.cancelZoomRamp(manualOverride:true)
            self.position = previous == .back ? .front : .back
            self.selectedCameraID = nil
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
            guard self.captureCompletion == nil, !self.manualState.hasManualExposure, bias.isFinite else { return }
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
        let transition = CameraControlSnapshot.transitioning(mode: manualState.mode, lenses: cameraLensOptions)
        precisionLock.lock(); precisionContext.generation += 1; precisionContext.controls = transition; precisionLock.unlock()
        cameraLensOptions = []
        DispatchQueue.main.async {
            self.isRunning = false; self.controls = transition
            self.precisionReading = nil; self.autoTuneRecommendations = []; self.currentAutoTuneRecommendations = []; self.advicePresentation.reset()
        }
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
        analysisQueue.async { self.holdDuration = max(0.5,min(3,duration)); self.framing.reset(enabled:self.automaticShotArmed && self.autoFrameEnabled && self.guidanceEnabled && self.analysisSource == .iPhone) }
    }

    func setSubjectFeatures(pets: Bool, tracking: Bool, smartSelection: Bool) {
        guidanceLock.lock(); _ = activation.set(activation.snapshot.enabled); guidanceLock.unlock()
        tracker.cancelInference()
        queue.async {
            self.cancelZoomRamp()
            self.analysisQueue.async {
                self.tracker.configure(pets: pets, tracking: tracking, smartSelection: smartSelection)
                self.autoFrameEnabled = self.tracker.features.allowsAutomaticZoom(requested: self.autoFrameEnabled)
                self.resetAnalysis()
            }
        }
    }

    func setInterfacePaused(_ paused: Bool) {
        precisionLock.lock(); precisionContext.paused = paused; precisionContext.generation += 1; precisionLock.unlock()
        queue.async {
            self.cancelZoomRamp()
            self.analysisQueue.async {
                self.interfacePaused = paused
                if !paused {
                    // Closing a menu must not override manual pinch priority or
                    // repeatedly zoom a shot that has already been framed.
                    let shouldRearm = self.framing.phase.isPreparing
                    self.resetAnalysis(armFraming: shouldRearm)
                }
            }
        }
    }

    func setAnalysisSource(_ source: CameraSource) {
        precisionLock.lock(); precisionContext.source = source; precisionContext.generation += 1; precisionLock.unlock()
        DispatchQueue.main.async { self.precisionReading = nil; self.autoTuneRecommendations = []; self.currentAutoTuneRecommendations = []; self.advicePresentation.reset() }
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
    func analyzeExternalFrame(_ image: CGImage) {
        analyzeExternalPrecision(image)
        let snapshot = guidanceSnapshot()
        guard snapshot.enabled, snapshot.source == .sony else { return }
        externalLock.lock()
        guard externalScheduler.admit(at: ProcessInfo.processInfo.systemUptime, enabled: true) else { externalLock.unlock(); return }
        externalLock.unlock()
        analysisQueue.async {
            defer { self.externalLock.lock(); self.externalScheduler.finish(); self.externalLock.unlock() }
            guard self.guidanceSnapshot() == snapshot, self.guidanceEnabled, self.analysisSource == .sony else { return }
            let source = CIImage(cgImage: image)
            let scale = min(1,1280/max(source.extent.width,source.extent.height))
            let scaled = source.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            let width = max(1, Int(scaled.extent.width)), height = max(1, Int(scaled.extent.height))
            if self.externalAnalysisBuffer == nil || CVPixelBufferGetWidth(self.externalAnalysisBuffer!) != width || CVPixelBufferGetHeight(self.externalAnalysisBuffer!) != height {
                var created: CVPixelBuffer?
                let attributes: [CFString:Any] = [kCVPixelBufferIOSurfacePropertiesKey:[String:Any]()]
                guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created) == kCVReturnSuccess else { return }
                self.externalAnalysisBuffer = created
            }
            guard let buffer = self.externalAnalysisBuffer else { return }
            self.imageContext.render(scaled,to:buffer)
            self.processFrame(buffer, sourceAspect: Double(image.width) / Double(image.height))
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
            self.publishControls()
        }
    }

    func setMode(_ mode: CompositionMode, userInitiated:Bool = true) {
        queue.async {
            self.cancelZoomRamp(manualOverride:userInitiated)
            self.analysisQueue.async {
                self.mode = mode; self.engine.reset(); self.scenePlanner.reset(); self.directZoomPlan = nil; self.manualTargetLock = nil
                self.framing.reset(enabled:self.automaticShotArmed && self.autoFrameEnabled && self.guidanceEnabled && self.analysisSource == .iPhone)
                self.publishFraming()
            }
        }
    }

    func setCompositionPlanning(_ enabled: Bool) {
        queue.async {
            self.cancelZoomRamp()
            self.analysisQueue.async {
                self.compositionPlanning = enabled; self.scenePlanner.reset(); self.directZoomPlan = nil; self.engine.reset()
                self.compositionEvidence = nil; self.lastCompositionEvidence = -.infinity
                self.framing.reset(enabled:self.automaticShotArmed && self.autoFrameEnabled && self.guidanceEnabled && self.analysisSource == .iPhone)
                self.publishFraming()
                if !enabled { DispatchQueue.main.async { self.compositionPlan = nil } }
            }
        }
    }
    func setPetFraming(_ style:PetFramingStyle) {
        tracker.cancelInference()
        queue.async {
            self.cancelZoomRamp()
            self.analysisQueue.async {
                self.petFraming = style; self.resetAnalysis()
                if self.photographyIntent == .pet && !style.permitsAutomaticZoom { self.framing.reset(enabled:false); self.publishFraming() }
            }
        }
    }
    func setIntent(_ intent: PhotographyIntent, userInitiated:Bool = true) {
        tracker.cancelInference()
        queue.async {
            self.cancelZoomRamp(manualOverride:userInitiated)
            self.analysisQueue.async {
                self.photographyIntent = intent; self.tracker.setIntent(intent); self.resetAnalysis()
                if !intent.permitsZoom || (intent == .pet && !self.petFraming.permitsAutomaticZoom) { self.framing.reset(enabled:false); self.publishFraming() }
            }
        }
    }

    func setGuidance(_ enabled: Bool) {
        guidanceLock.lock(); let newSession = enabled && !activation.snapshot.enabled; let snapshot = activation.set(enabled); guidanceLock.unlock()
        tracker.cancelInference()
        if !enabled {
            DispatchQueue.main.async {
                guard self.guidanceSnapshot() == snapshot else { return }
                self.reading = CompositionReading(); self.guidance = GuidanceMessage(); self.compositionPlan = nil
                self.framingPhase = .off; self.scanData = nil
                self.coachAdvice = []; self.liveMeasurements = nil; self.sceneLabel = nil
            }
        }
        queue.async {
            self.cancelZoomRamp(manualOverride:!enabled,reason:.disabled)
            if newSession { self.beginAutomaticShot() }
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
            let newSession = enabled && !self.autoZoomPreference
            self.autoZoomPreference = enabled
            self.cancelZoomRamp(manualOverride:!enabled,reason:.disabled)
            if newSession { self.beginAutomaticShot() }
            self.analysisQueue.async {
                self.autoFrameEnabled = self.tracker.features.allowsAutomaticZoom(requested: enabled)
                self.framing.reset(enabled: self.automaticShotArmed && self.autoFrameEnabled && self.guidanceEnabled && self.analysisSource == .iPhone)
                self.ignoreFramesUntil = 0
                self.publishFraming()
            }
        }
    }

    func cancelAutoFraming() {
        queue.async {
            self.cancelZoomRamp(manualOverride:true)
            self.analysisQueue.async {
                self.framing.reset(enabled: false)
                self.ignoreFramesUntil = 0
                self.publishFraming()
            }
        }
    }

    private func beginAutomaticShot() {
        automaticZoomBlocked = false
        analysisQueue.async { self.automaticShotArmed = true }
    }
    private func cancelZoomRamp(manualOverride:Bool = false, preserveVerifiedShot:Bool = false, reason:FramingBlockReason = .interrupted) {
        let interruptedShot = rampStage >= 0
        if manualOverride || interruptedShot {
            ShotFramingDiagnostics.log("ZOOM_CANCEL","manual=\(manualOverride) interrupted=\(interruptedShot) verified=\(preserveVerifiedShot) reason=\(reason.rawValue) hardware=\(device?.videoZoomFactor ?? 0)")
        }
        rampStage = -1; rampPaused = false
        if manualOverride || interruptedShot {
            automaticZoomBlocked = true
            analysisQueue.async {
                self.automaticShotArmed = false
                if !preserveVerifiedShot { self.framing.stop(reason:manualOverride && reason == .interrupted ? .manualControl : reason); self.shotCapture.cancel(); self.publishFraming() }
            }
        }
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
            recordObservedZoom()
            analysisQueue.async { self.analysisZoom = actual }
            DispatchQueue.main.async { self.zoom = actual }
        }
    }

    private func publishFraming() {
        let phase = framing.phase
        let progress = framing.holdProgress
        DispatchQueue.main.async { self.framingPhase = phase; self.framingHoldProgress = progress }
    }

    func setTarget(_ target: UnitPoint2D?) {
        queue.async {
            self.cancelZoomRamp(manualOverride:true)
            self.analysisQueue.async {
                self.preferredTarget = target; self.engine.reset(); self.scenePlanner.reset(); self.directZoomPlan = nil; self.manualTargetLock = nil
                self.framing.reset(enabled:self.automaticShotArmed && self.autoFrameEnabled && self.guidanceEnabled && self.analysisSource == .iPhone)
                self.publishFraming()
            }
        }
    }

    func setPreviewAspect(_ aspect: Double) {
        precisionLock.lock(); precisionContext.previewAspect = aspect; precisionContext.generation += 1; precisionLock.unlock()
        analysisQueue.async {
            if abs(self.previewAspect-aspect) > 0.005, self.framing.phase.isAutoFraming {
                self.automaticShotArmed = false; self.framing.reset(enabled:false)
                self.queue.async { self.cancelZoomRamp(manualOverride:true) }
            }
            self.previewAspect = aspect; self.engine.reset(); self.scenePlanner.reset()
            self.compositionEvidence = nil; self.lastCompositionEvidence = -.infinity
        }
    }

    func findSubject() {
        guidanceLock.lock()
        guard activation.snapshot.enabled else { guidanceLock.unlock(); return }
        let snapshot = activation.set(true)
        guidanceLock.unlock()
        tracker.cancelInference()
        queue.async {
            self.cancelZoomRamp()
            self.beginAutomaticShot()
            self.analysisQueue.async {
                guard self.guidanceSnapshot() == snapshot else { return }
                self.resetAnalysis()
                self.ignoreFramesUntil = 0
                self.publishAnalysis(snapshot) {
                    self.subjectLabel = "Auto subject"; self.reading = CompositionReading()
                    self.guidance = GuidanceMessage(kind: .searching, text: "Scanning the scene…")
                }
            }
        }
    }

    func selectSubject(at previewPoint: UnitPoint2D) {
        guard guidanceSnapshot().enabled else { return }
        tracker.cancelInference()
        queue.async {
            self.cancelZoomRamp(manualOverride:true)
            self.analysisQueue.async {
                self.ignoreFramesUntil = 0
                guard self.guidanceEnabled, self.guidanceSnapshot().enabled else { return }
                let projection = PreviewProjection(imageAspect: self.imageAspect, previewAspect: self.previewAspect, mirrored: self.analysisFrontCamera)
                self.tracker.select(at: projection.imagePoint(previewPoint))
                self.engine.reset(); self.boxSmoother.reset(); self.automaticGuidance.reset()
                self.scenePlanner.reset(); self.directZoomPlan = nil; self.manualTargetLock = nil; self.previousMotionSubject = nil
                self.precisionLock.lock(); self.precisionContext.relativeSubjectMotion = nil; self.precisionContext.subjectMotionTimestamp = nil; self.precisionLock.unlock()
                self.latestNativeBounds = nil
                self.framing.reset(enabled: self.automaticShotArmed && self.autoFrameEnabled && self.guidanceEnabled && self.analysisSource == .iPhone)
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
            self.cancelZoomRamp(manualOverride:true)
            self.analysisQueue.async {
                self.framing.reset(enabled: false); self.ignoreFramesUntil = 0
                self.manualInferenceResumeAfter = ProcessInfo.processInfo.systemUptime + 0.5
                self.publishFraming()
            }
        }
        queue.asyncAfter(deadline: .now() + 1.0 / 30.0) {
            self.zoomRequestLock.lock(); let requested = self.zoomRequests.take(); self.zoomRequestLock.unlock()
            guard let requested, self.wantsToRun, self.captureCompletion == nil, let device = self.device else { return }
            self.cancelZoomRamp(manualOverride:true)
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
                self.recordObservedZoom()
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
        shotCapture.cancel()
        #if DEBUG || FOCAL_EVALUATION
        guidanceDiagnostics = GuidanceDiagnostics()
        DispatchQueue.main.async { self.guidancePerformance = nil }
        #endif
        framing.reset(enabled: armFraming && automaticShotArmed && autoFrameEnabled && guidanceEnabled && analysisSource == .iPhone)
        automaticGuidance.reset(); boxSmoother.reset(); latestNativeBounds = nil
        previousMotionSubject = nil
        precisionLock.lock(); precisionContext.relativeSubjectMotion = nil; precisionContext.subjectMotionTimestamp = nil; precisionLock.unlock()
        publishFraming()
        engine.reset()
        manualTargetLock = nil
        scenePlanner.reset(); directZoomPlan = nil; compositionEvidence = nil; lastCompositionEvidence = -.infinity
        tracker.reset()
        focusCandidate = nil
        focusCandidateSince = 0
        lastFocusedPoint = nil
        wantsScan = true
        lastCoach = -.infinity; lastScene = -.infinity
        subjectMeasurements = nil; subjectMeasurementLabel = nil; lastSubjectMeasurement = -.infinity
        sceneMeasurements = nil; lastSceneMeasurement = -.infinity; manualInferenceResumeAfter = 0
        DispatchQueue.main.async {
            self.scanData = nil; self.reading = CompositionReading(); self.subjectLabel = "Auto subject"; self.guidance = GuidanceMessage(); self.compositionPlan = nil
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
                if self.manualState.permitsFocus(automatic:continuous), device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    // Tap selects the focus location, not a permanently locked
                    // lens distance. Continue refocusing as the camera moves.
                    let focusMode: AVCaptureDevice.FocusMode = device.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : .autoFocus
                    if device.isFocusModeSupported(focusMode) { device.focusMode = focusMode }
                }
                if meterExposure && self.manualState.permitsAutoMetering && device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
            } catch { /* Focus is best-effort; capture remains available. */ }
        }
    }

    func capture(options: CaptureOptions = CaptureOptions(), completion: @escaping (Result<CameraCapture, Error>) -> Void) {
        guard isRunning, !isCapturing, !framingPhase.isAutoFraming else {
            completion(.failure(CameraError.notRunning))
            return
        }
        isCapturing = true
        analysisQueue.async {
            // Recheck authoritative state: the published UI phase can lag this queue.
            guard !self.framing.phase.isAutoFraming else {
                DispatchQueue.main.async {
                    self.isCapturing = false
                    completion(.failure(CameraError.notRunning))
                }
                return
            }
            let capturedFraming = self.shotCapture.userCapture(at:ProcessInfo.processInfo.systemUptime,
                guidanceEnabled:self.guidanceSnapshot().enabled && self.analysisSource == .iPhone)
            self.analysisPaused = true
            self.queue.async {
                guard self.session.isRunning, self.device?.isRampingVideoZoom != true else {
                    DispatchQueue.main.async {
                        self.isCapturing = false
                        completion(.failure(CameraError.notRunning))
                    }
                    self.analysisQueue.async { self.analysisPaused = false }
                    return
                }
                self.captureCompletion = completion
                let actualZoom = self.device.map { Double($0.videoZoomFactor/self.zoomMultiplier) } ?? 0
                let eligible = capturedFraming?.matchesCamera(zoom:actualZoom,enabled:self.guidanceSnapshot().enabled && self.guidanceSnapshot().source == .iPhone,
                    ramping:self.device?.isRampingVideoZoom ?? true) ?? false
                self.pendingFramingCapture = eligible ? capturedFraming : nil
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
    }

    private func resumeIfWanted() {
        queue.async { if self.wantsToRun { self.configureAndStart() } }
    }

    private func photoSettings(options: CaptureOptions = CaptureOptions()) -> AVCapturePhotoSettings {
        let rawFormat = output.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) })
            ?? output.availableRawPhotoPixelFormatTypes.first
        let bayerRAW = options.raw && rawFormat.map { !AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) } == true
        let codec: AVVideoCodecType = !bayerRAW && options.encoding == .heif && output.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
        let format: [String: Any] = [AVVideoCodecKey: codec]
        let settings: AVCapturePhotoSettings
        if options.raw, let rawFormat {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: format)
        } else { settings = AVCapturePhotoSettings(format: format) }
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        // Bayer RAW bypasses computational processing; ProRAW supports quality processing.
        settings.photoQualityPrioritization = bayerRAW ? .speed : .quality
        let flash = AVCaptureDevice.FlashMode(rawValue: options.flash.rawValue) ?? .off
        settings.flashMode = output.supportedFlashModes.contains(flash) ? flash : .off
        if #available(iOS 18.0, *), output.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = !options.shutterSound
        }
        return settings
    }

    private func configureAndStart(allowFallback: Bool = true) {
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
                let discovered = selectedTypes.compactMap { AVCaptureDevice.default($0,for:.video,position:position) }
                let explicit = selectedCameraID.flatMap { id in
                    AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInWideAngleCamera,.builtInUltraWideCamera,.builtInTelephotoCamera,.builtInTrueDepthCamera,.builtInTripleCamera,.builtInDualWideCamera,.builtInDualCamera],mediaType:.video,position:position).devices.first { $0.uniqueID == id }
                }
                let fallback = !allowFallback ? AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:position) : nil
                guard let camera = explicit ?? fallback ?? discovered.first else {
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
                try applyManualControls(camera)
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
                let existingDetail = max(1,max(previewBudget,Double(camera.activeFormat.videoZoomFactorUpscaleThreshold/self.zoomMultiplier)))
                let photoPixels = Double(self.output.maxPhotoDimensions.width)*Double(self.output.maxPhotoDimensions.height)
                let detailLimit = AutomaticZoomQualityBudget.detailLimit(existing:existingDetail,
                    previewShortSide:Double(min(dimensions.width,dimensions.height)),photoPixels:photoPixels)
                let autoLimit = min(upper, max(opticalLimit, detailLimit))
                self.recordObservedZoom()
                self.analysisQueue.async {
                    self.analysisFrontCamera = camera.position == .front
                    self.analysisZoom = Double(camera.videoZoomFactor/self.zoomMultiplier)
                    self.automaticZoomLimit = autoLimit
                    self.detailZoomLimit = max(1, detailLimit)
                    self.nativeZoomStops = [1] + camera.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue / Double(self.zoomMultiplier) }
                }
                DispatchQueue.main.async {
                    self.isFrontCamera = camera.position == .front; self.previewFPS = nil
                    self.exposureBias = camera.exposureTargetBias
                    self.exposureRange = camera.minExposureTargetBias...camera.maxExposureTargetBias
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
                publishControls()
            }
            if !session.isRunning {
                session.startRunning()
                // A new session after capture review needs a fresh scan. An
                // already-running session retains manual zoom/cancel intent.
                self.analysisQueue.async { self.resetAnalysis() }
            }
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
            if allowFallback && selectedCameraID == nil {
                configureAndStart(allowFallback:false)
                return
            }
            DispatchQueue.main.async {
                self.access = .unavailable
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func setControlMode(_ mode: CameraControlMode) {
        queue.async {
            guard self.captureCompletion == nil else { return }
            if self.manualState.mode != mode { self.cancelZoomRamp(manualOverride:true) }
            if mode == .auto { self.manualState.reset() } else { self.manualState.mode = .pro }
            self.updateManualControls()
        }
    }
    func setManualISO(_ value: Double?) {
        queue.async {
            guard self.captureCompletion == nil, self.manualState.mode == .pro else { return }
            if let value {
                guard value.isFinite, let device = self.device, device.isExposureModeSupported(.custom) else { return }
                self.manualState.iso = value
                if self.manualState.seconds == nil { self.manualState.seconds = CMTimeGetSeconds(device.exposureDuration) }
            } else { self.manualState.automaticExposure() }
            self.scheduleManualControls()
        }
    }
    func setManualShutter(_ value: Double?) {
        queue.async {
            guard self.captureCompletion == nil, self.manualState.mode == .pro else { return }
            if let value {
                guard value.isFinite, let device = self.device, device.isExposureModeSupported(.custom) else { return }
                self.manualState.seconds = value
                if self.manualState.iso == nil { self.manualState.iso = Double(device.iso) }
            } else { self.manualState.automaticExposure() }
            self.scheduleManualControls()
        }
    }
    func setManualWhiteBalance(_ temperature: Double?, tint: Double = 0) {
        queue.async {
            guard self.captureCompletion == nil, self.manualState.mode == .pro, tint.isFinite, temperature?.isFinite != false else { return }
            self.manualState.temperature = temperature; self.manualState.tint = tint
            self.scheduleManualControls()
        }
    }
    func setManualFocus(_ position: Double?) {
        queue.async {
            guard self.captureCompletion == nil, self.manualState.mode == .pro, position?.isFinite != false else { return }
            self.manualState.focus = position
            self.scheduleManualControls()
        }
    }
    func selectLens(_ id: String?) {
        guard !isCapturing, !isSwitchingCamera, isRunning else { return }
        if id == nil && controls.usesAutomaticLenses { return }
        if let id, id == controls.lensID && !controls.usesAutomaticLenses { return }
        isSwitchingCamera = true
        guidanceLock.lock(); _ = activation.set(activation.snapshot.enabled); guidanceLock.unlock()
        tracker.cancelInference()
        queue.async {
            defer { DispatchQueue.main.async { self.isSwitchingCamera = false } }
            guard self.captureCompletion == nil, self.wantsToRun, self.selectedCameraID != id else { return }
            let devices = AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInWideAngleCamera,.builtInUltraWideCamera,.builtInTelephotoCamera,.builtInTrueDepthCamera,.builtInTripleCamera,.builtInDualWideCamera,.builtInDualCamera],mediaType:.video,position:self.position).devices
            if let id { guard devices.contains(where:{ $0.uniqueID == id }) else { return } }
            let previous = self.selectedCameraID
            self.cancelZoomRamp(manualOverride:true); self.selectedCameraID = id; self.discardConfiguration(); self.configureAndStart(allowFallback:id == nil)
            if !self.configured {
                self.selectedCameraID = previous; self.discardConfiguration(); self.configureAndStart()
                DispatchQueue.main.async { self.errorMessage = "Lens could not start. The previous camera was restored." }
            }
            // An explicit lens choice has the same priority as manual pinch.
            // Keep guidance running, but do not immediately override that zoom.
            self.analysisQueue.async { self.framing.reset(enabled:false); self.publishFraming() }
        }
    }
    private func updateManualControls() {
        guard let device else { return }
        do { try applyManualControls(device); publishControls() }
        catch { DispatchQueue.main.async { self.errorMessage = "The camera could not apply that control. Current hardware values are shown." } }
    }
    private func scheduleManualControls() {
        guard !manualApplyScheduled else { return }
        manualApplyScheduled = true
        queue.asyncAfter(deadline:.now()+0.04) {
            self.manualApplyScheduled = false
            guard self.captureCompletion == nil else { return }
            self.updateManualControls()
        }
    }
    private func applyManualControls(_ camera: AVCaptureDevice) throws {
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        if manualState.hasManualExposure, camera.isExposureModeSupported(.custom) {
            let minISO = Double(camera.activeFormat.minISO), maxISO = Double(camera.activeFormat.maxISO)
            let minTime = CMTimeGetSeconds(camera.activeFormat.minExposureDuration), maxTime = CMTimeGetSeconds(camera.activeFormat.maxExposureDuration)
            if minISO <= maxISO, minTime > 0, minTime <= maxTime,
               let iso = ManualCameraState.clamp(manualState.iso ?? Double(camera.iso),to:minISO...maxISO),
               let seconds = ManualCameraState.clamp(manualState.seconds ?? CMTimeGetSeconds(camera.exposureDuration),to:minTime...maxTime) {
                manualState.iso = iso; manualState.seconds = seconds
                let requested = CMTime(seconds:seconds,preferredTimescale:1_000_000_000)
                let duration = CMTimeMaximum(camera.activeFormat.minExposureDuration,CMTimeMinimum(camera.activeFormat.maxExposureDuration,requested))
                camera.setExposureModeCustom(duration:duration,iso:Float(iso),completionHandler:nil)
            }
        } else {
            manualState.automaticExposure()
            if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
        }
        if let temperature = manualState.temperature, camera.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature:Float(min(10000,max(2000,temperature))),tint:Float(min(150,max(-150,manualState.tint))))
            var gains = camera.deviceWhiteBalanceGains(for:values)
            gains.redGain = max(1,min(camera.maxWhiteBalanceGain,gains.redGain))
            gains.greenGain = max(1,min(camera.maxWhiteBalanceGain,gains.greenGain))
            gains.blueGain = max(1,min(camera.maxWhiteBalanceGain,gains.blueGain))
            camera.setWhiteBalanceModeLocked(with:gains,completionHandler:nil)
        } else {
            manualState.temperature = nil
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { camera.whiteBalanceMode = .continuousAutoWhiteBalance }
        }
        if let value = manualState.focus, camera.isLockingFocusWithCustomLensPositionSupported {
            let position = min(1,max(0,value)); manualState.focus = position
            camera.setFocusModeLocked(lensPosition:Float(position),completionHandler:nil)
        } else {
            manualState.focus = nil
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
        }
    }
    private func publishControls() {
        guard let device else { return }
        var value = CameraControlSnapshot()
        value.mode = manualState.mode; value.iso = Double(device.iso)
        let seconds = CMTimeGetSeconds(device.exposureDuration)
        value.seconds = seconds.isFinite && seconds > 0 ? seconds : nil
        let wb = device.temperatureAndTintValues(for:device.deviceWhiteBalanceGains)
        value.temperature = wb.temperature.isFinite ? Double(wb.temperature) : nil
        value.tint = wb.tint.isFinite ? Double(wb.tint) : nil
        value.lensPosition = Double(device.lensPosition)
        if device.isExposureModeSupported(.custom) {
            let lo = Double(device.activeFormat.minISO), hi = Double(device.activeFormat.maxISO)
            if lo > 0, hi >= lo { value.isoRange = lo...hi }
            let a = CMTimeGetSeconds(device.activeFormat.minExposureDuration), b = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
            if a.isFinite, b.isFinite, a > 0, b >= a { value.durationRange = a...b }
        }
        value.manualExposure = device.exposureMode == .custom
        value.manualWhiteBalance = manualState.temperature != nil && device.whiteBalanceMode == .locked
        value.manualFocus = manualState.focus != nil && device.focusMode == .locked
        value.canWhiteBalance = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        value.canFocus = device.isLockingFocusWithCustomLensPositionSupported
        value.canTapFocus = device.isFocusPointOfInterestSupported && (device.isFocusModeSupported(.autoFocus) || device.isFocusModeSupported(.continuousAutoFocus))
        value.evAdjustable = !value.manualExposure && device.minExposureTargetBias < device.maxExposureTargetBias
        value.lensID = device.uniqueID
        value.usesAutomaticLenses = selectedCameraID == nil
        if cameraLensOptions.isEmpty {
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInWideAngleCamera,.builtInUltraWideCamera,.builtInTelephotoCamera,.builtInTrueDepthCamera,.builtInTripleCamera,.builtInDualWideCamera,.builtInDualCamera],mediaType:.video,position:position)
            cameraLensOptions = discovery.devices.map { lens in
            let label: String
            switch lens.deviceType {
            case .builtInUltraWideCamera: label = "Ultra wide"
            case .builtInTelephotoCamera: label = "Telephoto"
            case .builtInWideAngleCamera: label = "Wide"
            case .builtInTrueDepthCamera: label = "Front depth"
            case .builtInTripleCamera: label = "Triple camera"
            case .builtInDualWideCamera: label = "Wide + ultra wide"
            case .builtInDualCamera: label = "Dual camera"
            default: label = lens.localizedName
            }
            return CameraLensOption(id:lens.uniqueID,label:label)
            }
        }
        value.lenses = cameraLensOptions
        value.encodings = output.availablePhotoCodecTypes.contains(.hevc) ? [.jpeg,.heif] : [.jpeg]
        precisionLock.lock()
        precisionContext.controls = value; precisionContext.ev = Double(device.exposureTargetBias)
        precisionContext.evRange = Double(device.minExposureTargetBias)...Double(device.maxExposureTargetBias)
        precisionContext.zoom = Double(device.videoZoomFactor/zoomMultiplier)
        precisionContext.minimumZoom = Double(device.minAvailableVideoZoomFactor/zoomMultiplier)
        precisionContext.mirrored = device.position == .front
        precisionLock.unlock()
        DispatchQueue.main.async { self.controls = value }
    }

    func setPrecisionOptions(_ options: PrecisionOptions) {
        precisionLock.lock(); precisionContext.options = options; precisionContext.generation += 1; precisionLock.unlock()
        DispatchQueue.main.async { self.precisionReading = nil; self.autoTuneRecommendations = []; self.currentAutoTuneRecommendations = []; self.advicePresentation.reset() }
    }
    private func precisionSnapshot() -> PrecisionContext {
        precisionLock.lock(); defer { precisionLock.unlock() }; return precisionContext
    }
    private func analyzePhonePrecision(_ sample: CMSampleBuffer) {
        let context = precisionSnapshot(), now = ProcessInfo.processInfo.systemUptime
        guard context.source == .iPhone, !context.paused, let native = CMSampleBufferGetImageBuffer(sample),
              precisionScheduler.admit(at:now,enabled:context.options.enabled) else { return }
        guard let copied = precisionCopy(CIImage(cvPixelBuffer:native),storage:&precisionVideoBuffer,renderer:precisionVideoContext) else { precisionScheduler.finish(); return }
        let aspect = Double(CVPixelBufferGetWidth(native))/Double(CVPixelBufferGetHeight(native))
        precisionQueue.async {
            defer { self.videoQueue.async { self.precisionScheduler.finish() } }
            self.processPrecision(copied,aspect:aspect,context:context,timestamp:now)
        }
    }
    private func analyzeExternalPrecision(_ image:CGImage) {
        let context = precisionSnapshot(), now = ProcessInfo.processInfo.systemUptime
        guard context.source == .sony, !context.paused, context.options.enabled else { return }
        precisionLock.lock(); let admitted = precisionExternalScheduler.admit(at:now,enabled:true); precisionLock.unlock()
        guard admitted else { return }
        precisionQueue.async {
            defer { self.precisionLock.lock(); self.precisionExternalScheduler.finish(); self.precisionLock.unlock() }
            guard let buffer = self.precisionCopy(CIImage(cgImage:image),storage:&self.precisionExternalBuffer,renderer:self.precisionExternalContext) else { return }
            self.processPrecision(buffer,aspect:Double(image.width)/Double(image.height),context:context,timestamp:now)
        }
    }
    private func precisionCopy(_ image:CIImage,storage:inout CVPixelBuffer?,renderer:CIContext) -> CVPixelBuffer? {
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }
        let scale = min(1,600/max(image.extent.width,image.extent.height))
        let width = max(1,Int(image.extent.width*scale)), height = max(1,Int(image.extent.height*scale))
        if storage == nil || CVPixelBufferGetWidth(storage!) != width || CVPixelBufferGetHeight(storage!) != height {
            var created:CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[String:Any]()] as CFDictionary,&created) == kCVReturnSuccess else { return nil }
            storage = created
        }
        guard let buffer = storage else { return nil }
        renderer.render(image.transformed(by:CGAffineTransform(scaleX:scale,y:scale)),to:buffer,bounds:CGRect(x:0,y:0,width:CGFloat(width),height:CGFloat(height)),colorSpace:CGColorSpaceCreateDeviceRGB())
        return buffer
    }
    private func processPrecision(_ buffer:CVPixelBuffer,aspect:Double,context:PrecisionContext,timestamp:TimeInterval) {
        guard precisionSnapshot().generation == context.generation else { return }
        let projection = PreviewProjection(imageAspect:aspect,previewAspect:context.previewAspect,mirrored:context.source == .iPhone && context.mirrored)
        guard let reading = PrecisionAnalyzer.analyze(buffer,projection:projection,options:context.options,timestamp:timestamp) else { return }
        let motionValue = context.source == .iPhone ? motion.deviceMotion : nil
        let current = ProcessInfo.processInfo.systemUptime
        let rotation = motionValue.flatMap { value -> Double? in
            guard current-value.timestamp >= 0, current-value.timestamp < 0.45 else { return nil }
            return sqrt(pow(value.rotationRate.x,2)+pow(value.rotationRate.y,2)+pow(value.rotationRate.z,2))
        }
        let controls = context.source == .iPhone ? context.controls : CameraControlSnapshot()
        let recommendations = context.options.autoTune ? AutoTune.recommendations(measured:reading.measurements,controls:controls,
            ev:context.source == .iPhone ? context.ev : nil,evRange:context.source == .iPhone ? context.evRange : nil,
            motion:rotation,zoom:context.source == .iPhone ? context.zoom : 1,minimumZoom:context.source == .iPhone ? context.minimumZoom : 1,timestamp:timestamp,
            subjectMotion:context.subjectMotionTimestamp.flatMap { timestamp >= $0 && timestamp-$0 < 1.5 ? context.relativeSubjectMotion : nil }) : []
        DispatchQueue.main.async {
            guard self.precisionSnapshot().generation == context.generation else { return }
            self.precisionReading = reading
            self.currentAutoTuneRecommendations = recommendations
            self.autoTuneRecommendations = self.advicePresentation.update(recommendations, at: reading.timestamp)
        }
    }
    func isCurrentAutoTuneRecommendation(_ recommendation: AutoTuneRecommendation) -> Bool {
        let context = precisionSnapshot()
        return context.options.autoTune && currentAutoTuneRecommendations.contains(recommendation) && precisionReading != nil
            && AutoTune.permitsApplication(recommendation,source:context.source,mode:controls.mode,manualExposure:controls.manualExposure,
                                          paused:context.paused,busy:isCapturing || isSwitchingCamera,now:ProcessInfo.processInfo.systemUptime)
    }
    func applyAutoTune(_ recommendation:AutoTuneRecommendation) {
        guard isCurrentAutoTuneRecommendation(recommendation) else { return }
        queue.async {
            let context = self.precisionSnapshot(), now = ProcessInfo.processInfo.systemUptime
            guard context.options.autoTune,
                  AutoTune.permitsApplication(recommendation,source:context.source,mode:self.manualState.mode,manualExposure:self.manualState.hasManualExposure,paused:context.paused,busy:self.captureCompletion != nil,now:now),
                  let bias = recommendation.exposureBias,
                  let device = self.device, device.exposureMode == .continuousAutoExposure else { return }
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                let value = max(device.minExposureTargetBias,min(device.maxExposureTargetBias,Float(bias)))
                device.setExposureTargetBias(value,completionHandler:nil)
                DispatchQueue.main.async { self.exposureBias = value }
            } catch { DispatchQueue.main.async { self.errorMessage = "AutoTune could not change exposure. Current settings were retained." } }
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

    private func recordObservedZoom() {
        guard let device else { return }
        let observation = CameraZoomObservation(hardwareFactor:Double(device.videoZoomFactor),multiplier:Double(zoomMultiplier),
            ramping:device.isRampingVideoZoom,timestamp:ProcessInfo.processInfo.systemUptime)
        zoomObservationLock.lock(); observedPhoneZoom = observation; zoomObservationLock.unlock()
    }
    private func performAutomaticZoom(to target: Double, generation: Int, observedAt:TimeInterval,shotID:String) {
        queue.async {
            ShotFramingDiagnostics.log("ZOOM_REQUEST","displayedTarget=\(target) generation=\(generation) activeGeneration=\(self.zoomGeneration) blocked=\(self.automaticZoomBlocked) enabled=\(self.guidanceSnapshot().enabled)")
            guard generation == self.zoomGeneration, !self.automaticZoomBlocked,
                  self.guidanceSnapshot().enabled, self.guidanceSnapshot().source == .iPhone else {
                ShotFramingDiagnostics.log("ZOOM_REJECTED","reason=stale_generation_override_or_ai_off shot=\(shotID)")
                let reason:FramingBlockReason = self.automaticZoomBlocked ? .manualControl : .interrupted
                self.analysisQueue.async {
                    guard self.framing.shotPlan?.id == shotID else { return }
                    self.framing.stop(reason:reason); self.shotCapture.cancel(); self.publishFraming()
                }
                return
            }
            guard self.wantsToRun, self.captureCompletion == nil, let device = self.device,
                  GuidanceObservationPolicy.fresh(capturedAt:observedAt,evaluatedAt:ProcessInfo.processInfo.systemUptime),
                  ProcessInfo.processInfo.thermalState != .critical else {
                ShotFramingDiagnostics.log("ZOOM_REJECTED","reason=inactive_capture_stale_observation_or_thermal")
                self.abortAutomaticZoom(generation:generation,reason:ProcessInfo.processInfo.thermalState == .critical ? .thermal : !self.wantsToRun || self.captureCompletion != nil ? .inactive : .staleFrame); return
            }
            let upper = min(Double(device.maxAvailableVideoZoomFactor),Double(device.activeFormat.videoMaxZoomFactor))
            guard let factor = CameraZoomObservation.hardwareTarget(displayed:target,multiplier:Double(self.zoomMultiplier),
                    minimum:Double(device.minAvailableVideoZoomFactor),maximum:upper),
                  factor > Double(device.videoZoomFactor)*1.01 else {
                ShotFramingDiagnostics.log("ZOOM_REJECTED","reason=device_factor_limit target=\(target) multiplier=\(self.zoomMultiplier) hardware=\(device.videoZoomFactor) max=\(upper)")
                self.abortAutomaticZoom(generation:generation,reason:.quality); return
            }
            self.rampStartZoom = Double(device.videoZoomFactor); self.rampTargetZoom = factor; self.rampStage = 0; self.rampHolding = false; self.rampPaused = false
            self.zoomWatchdog.start(zoom:self.rampStartZoom,target:factor,at:ProcessInfo.processInfo.systemUptime)
            self.lastRampVerification = ProcessInfo.processInfo.systemUptime
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor:CGFloat(factor),withRate:AutomaticZoomRampProfile.rate(stage:0,hardwareDistance:factor-self.rampStartZoom))
                device.unlockForConfiguration()
                self.recordObservedZoom()
                ShotFramingDiagnostics.log("ZOOM_ACCEPTED","device=\(device.localizedName) type=\(device.deviceType.rawValue) displayedTarget=\(target) nativeTarget=\(factor) hardware=\(device.videoZoomFactor) multiplier=\(self.zoomMultiplier) ramping=\(device.isRampingVideoZoom)")
                self.observeAutomaticZoom(generation:generation,deadline:ProcessInfo.processInfo.systemUptime+7)
            } catch {
                ShotFramingDiagnostics.log("ZOOM_FAILED","reason=configuration_lock error=\(error)")
                self.abortAutomaticZoom(generation:generation)
            }
        }
    }
    private func pauseAutomaticZoom(generation:Int,at time:TimeInterval,reason:FramingBlockReason) {
        guard generation == zoomGeneration, !automaticZoomBlocked, rampStage >= 0, let device else { return }
        lastRampVerification = time
        guard !rampPaused else { return }
        do {
            try device.lockForConfiguration(); device.cancelVideoZoomRamp(); device.unlockForConfiguration()
            rampPaused = true; recordObservedZoom()
            ShotFramingDiagnostics.log("ZOOM_PAUSE","reason=\(reason.rawValue) hardware=\(device.videoZoomFactor) target=\(rampTargetZoom)")
        } catch { abortAutomaticZoom(generation:generation,reason:.configuration) }
    }
    private func resumeAutomaticZoom(generation:Int,at time:TimeInterval) {
        guard generation == zoomGeneration, !automaticZoomBlocked, guidanceSnapshot().enabled,
              guidanceSnapshot().source == .iPhone, rampPaused, let device else { return }
        lastRampVerification = time
        guard Double(device.videoZoomFactor) < rampTargetZoom*0.98 else { rampPaused = false; return }
        do {
            try device.lockForConfiguration()
            let distance = rampTargetZoom-Double(device.videoZoomFactor)
            device.ramp(toVideoZoomFactor:CGFloat(rampTargetZoom),withRate:AutomaticZoomRampProfile.rate(stage:0,hardwareDistance:distance))
            device.unlockForConfiguration(); rampPaused = false; rampHolding = false
            recordObservedZoom()
            ShotFramingDiagnostics.log("ZOOM_RESUME","hardware=\(device.videoZoomFactor) target=\(rampTargetZoom) generation=\(generation)")
        } catch { abortAutomaticZoom(generation:generation,reason:.configuration) }
    }
    private func abortAutomaticZoom(generation:Int,reason:FramingBlockReason = .configuration) {
        guard generation == zoomGeneration else { return }
        ShotFramingDiagnostics.log("ZOOM_ABORT","reason=\(reason.rawValue) hardware=\(device?.videoZoomFactor ?? 0) target=\(rampTargetZoom)")
        cancelZoomRamp(reason:reason)
        analysisQueue.async {
            self.automaticShotArmed = false; self.framing.stop(reason:reason); self.shotCapture.cancel(); self.publishFraming()
            self.automaticGuidance.reset()
        }
        automaticZoomBlocked = true
    }
    private func observeAutomaticZoom(generation: Int, deadline: TimeInterval) {
        guard generation == zoomGeneration, let device else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard !automaticZoomBlocked, guidanceSnapshot().enabled, guidanceSnapshot().source == .iPhone,
              now < deadline, now-lastRampVerification <= 1.1, ProcessInfo.processInfo.thermalState != .critical,
              rampTargetZoom <= min(Double(device.maxAvailableVideoZoomFactor),Double(device.activeFormat.videoMaxZoomFactor)) else {
            ShotFramingDiagnostics.log("ZOOM_ABORT","reason=watchdog_device_or_thermal_gate age=\(now-lastRampVerification) hardware=\(device.videoZoomFactor) target=\(rampTargetZoom)")
            abortAutomaticZoom(generation:generation,reason:now >= deadline ? .deadline : ProcessInfo.processInfo.thermalState == .critical ? .thermal : .staleFrame); return
        }
        let hardwareZoom = Double(device.videoZoomFactor)
        let actual = hardwareZoom/Double(zoomMultiplier)
        if let failure = zoomWatchdog.failure(actual:hardwareZoom,at:now,paused:rampPaused || rampHolding) {
            abortAutomaticZoom(generation:generation,reason:failure); return
        }
        recordObservedZoom()
        DispatchQueue.main.async { self.zoom = actual }
        // Change rate only at two milestones, always toward the original target.
        let progress = (hardwareZoom-rampStartZoom)/max(0.01,rampTargetZoom-rampStartZoom)
        let stage = AutomaticZoomRampProfile.stage(progress:progress)
        if !rampHolding, !rampPaused, device.isRampingVideoZoom, stage > rampStage {
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor:CGFloat(rampTargetZoom),withRate:AutomaticZoomRampProfile.rate(stage:stage,hardwareDistance:rampTargetZoom-rampStartZoom))
                device.unlockForConfiguration(); rampStage = stage
                ShotFramingDiagnostics.log("ZOOM_PROGRESS","stage=\(stage) hardware=\(hardwareZoom) displayed=\(actual) target=\(rampTargetZoom) ramping=\(device.isRampingVideoZoom)")
            } catch { abortAutomaticZoom(generation:generation); return }
        }
        // Motor completion alone is never Shot ready. Fresh tracked frames must
        // verify size, position and protected regions before releasing the ramp.
        queue.asyncAfter(deadline:.now()+0.05) { self.observeAutomaticZoom(generation:generation,deadline:deadline) }
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
        analyzePhonePrecision(sampleBuffer)
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
        previewScheduler.interval = PreviewAnalysisScheduler.thermalInterval(ProcessInfo.processInfo.thermalState)
        guard previewScheduler.admit(at: now, enabled: true) else { return }
        guard let native = CMSampleBufferGetImageBuffer(sampleBuffer), let copy = previewAnalysisCopy(native) else {
            previewScheduler.finish(); return
        }
        let aspect = Double(CVPixelBufferGetWidth(native)) / Double(CVPixelBufferGetHeight(native))
        queue.async {
            self.recordObservedZoom()
            self.zoomObservationLock.lock(); let frameZoom = self.observedPhoneZoom; self.zoomObservationLock.unlock()
            self.analysisQueue.async {
                defer { self.videoQueue.async { self.previewScheduler.finish() } }
                guard self.guidanceSnapshot() == snapshot, self.analysisSource == .iPhone else { return }
                self.processFrame(copy, sourceAspect: aspect, observedAt: now, capturedZoom:frameZoom)
            }
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

    private func processFrame(_ fullBuffer: CVPixelBuffer, sourceAspect: Double? = nil, observedAt: TimeInterval? = nil, capturedZoom:CameraZoomObservation? = nil) {
        guard !analysisPaused, !interfacePaused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let observationTime = observedAt ?? now
        let snapshot = guidanceSnapshot()
        guard snapshot.source == analysisSource else { return }
        guard GuidanceObservationPolicy.fresh(capturedAt:observationTime,evaluatedAt:now) else {
            discardStaleGuidance(snapshot); return
        }
        guard now >= ignoreFramesUntil,now-lastAnalysis > min(1.5,PreviewAnalysisScheduler.thermalInterval(ProcessInfo.processInfo.thermalState)*0.8) else { return }
        lastAnalysis = now
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
        if analysisSource == .iPhone, let capturedZoom { analysisZoom = capturedZoom.displayedFactor }
        let zooming = framing.phase.isAutoFraming
        let deviceMoving = analysisSource == .iPhone && motion.deviceMotion.map {
            !CameraStability.isStable(rotation: ($0.rotationRate.x, $0.rotationRate.y, $0.rotationRate.z),
                                      acceleration: ($0.userAcceleration.x, $0.userAcceleration.y, $0.userAcceleration.z))
        } == true
        let rapidMovement = analysisSource == .iPhone && motion.deviceMotion.map {
            !CameraStability.permitsDetection(rotation: ($0.rotationRate.x, $0.rotationRate.y, $0.rotationRate.z),
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
        var automaticFocusPoint: UnitPoint2D?
        let visibleProjection = PreviewProjection(imageAspect:imageAspect,previewAspect:previewAspect)
        let topLeft = visibleProjection.imagePoint(.init(x:0,y:0))
        let bottomRight = visibleProjection.imagePoint(.init(x:1,y:1))
        let visibleRegion = CGRect(x:topLeft.x,y:1-bottomRight.y,width:bottomRight.x-topLeft.x,height:bottomRight.y-topLeft.y)
        let keepFramedSubject = analysisSource == .iPhone && latestNativeBounds != nil
            && (framing.phase == .aligning || framing.phase == .settling || zooming || framing.phase == .framed)
        let inferenceStarted = ProcessInfo.processInfo.systemUptime
        if let object = tracker.observation(in: buffer, timestamp: now, visibleRegion: visibleRegion, detailBuffer: fullBuffer, trackingOnly: zooming || rapidMovement || now < manualInferenceResumeAfter || ProcessInfo.processInfo.thermalState == .critical, retainSelection:keepFramedSubject,
                                            canContinue: { self.guidanceSnapshot() == snapshot }) {
            imageBounds = object.boundingBox
            latestNativeBounds = object.boundingBox; latestBoundsZoom = analysisZoom
            confidence = object.confidence
            let imagePoint = UnitPoint2D(x: object.boundingBox.midX, y: 1 - object.boundingBox.midY)
            let projection = PreviewProjection(imageAspect: imageAspect, previewAspect: previewAspect, mirrored: analysisFrontCamera)
            subject = projection.visiblePoint(imagePoint)
            bounds = projection.visibleVisionRect(object.boundingBox)
            if analysisSource == .iPhone, confidence >= 0.6, !deviceMoving, !zooming, now >= manualInferenceResumeAfter {
                let anatomy = tracker.anatomy(for:object.boundingBox,projection:projection,at:now)
                let focusPoint = anatomy?.face.map { head in projection.imagePoint(.init(x:head.midX,y:head.midY)) } ?? imagePoint
                automaticFocusPoint = focusPoint
            }
        }
        let inferenceMilliseconds = (ProcessInfo.processInfo.systemUptime-inferenceStarted)*1000
        // Preserve the last measured seed through a bounded pause, never display it
        // as a fresh observation. The director handles confidence/loss below.
        if imageBounds == nil, !zooming, !tracker.isRecovering { latestNativeBounds = nil }
        guard guidanceSnapshot() == snapshot else { return }
        let evaluatedAt = ProcessInfo.processInfo.systemUptime
        guard GuidanceObservationPolicy.fresh(capturedAt:observationTime,evaluatedAt:evaluatedAt) else {
            discardStaleGuidance(snapshot); return
        }
        if let automaticFocusPoint { updateAutomaticFocus(automaticFocusPoint,timestamp:evaluatedAt) }
        let motionData = analysisSource == .iPhone ? motion.deviceMotion : nil
        let gravity = motionData?.gravity
        let framingMotion = motionData.map {
            FramingMotionMeasurement(rotation:sqrt($0.rotationRate.x*$0.rotationRate.x+$0.rotationRate.y*$0.rotationRate.y+$0.rotationRate.z*$0.rotationRate.z),
                acceleration:sqrt($0.userAcceleration.x*$0.userAcceleration.x+$0.userAcceleration.y*$0.userAcceleration.y+$0.userAcceleration.z*$0.userAcceleration.z),
                age:evaluatedAt-$0.timestamp)
        }
        let stable = framingMotion?.stable ?? (analysisSource == .sony)
        let captureStable = motionData.map {
            framingMotion?.usable == true && CameraStability.isStable(rotation:($0.rotationRate.x,$0.rotationRate.y,$0.rotationRate.z),
                acceleration:($0.userAcceleration.x,$0.userAcceleration.y,$0.userAcceleration.z))
        } ?? (analysisSource == .sony)
        // When looking straight up/down, gravity cannot give a meaningful portrait roll.
        let roll = gravity.map { hypot($0.x, $0.y) > 0.2 ? atan2($0.x, -$0.y) * 180 / .pi : 0 } ?? 0
        var relativeMotion:Double?
        if analysisSource == .iPhone, framingMotion?.usable == true, !zooming, now >= manualInferenceResumeAfter, confidence >= 0.65, let bounds {
            if let old = previousMotionSubject, old.label == tracker.label, evaluatedAt > old.time,
               evaluatedAt-old.time < 1.5, abs(analysisZoom/old.zoom-1) < 0.02 {
                relativeMotion = hypot(Double(bounds.midX-old.bounds.midX),Double(bounds.midY-old.bounds.midY))/(evaluatedAt-old.time)
            }
            previousMotionSubject = (bounds,tracker.label,evaluatedAt,analysisZoom)
        } else { previousMotionSubject = nil }
        precisionLock.lock(); precisionContext.relativeSubjectMotion = relativeMotion; precisionContext.subjectMotionTimestamp = relativeMotion == nil ? nil : evaluatedAt; precisionLock.unlock()
        let planning = compositionPlanning && mode == .automatic
        let projection = PreviewProjection(imageAspect:imageAspect,previewAspect:previewAspect,mirrored:analysisFrontCamera)
        if (planning || autoFrameEnabled || coachEnabled || photographyIntent == .landscape || photographyIntent == .architecture), !zooming, !rapidMovement, now >= manualInferenceResumeAfter, evaluatedAt-lastCompositionEvidence >= 0.8 {
            lastCompositionEvidence = evaluatedAt
            compositionEvidence = SubjectImageEvidence.sample(buffer).flatMap {
                SceneCompositionEvidence(image:$0,projection:projection,timestamp:observationTime)
            }
        }
        let contextSubjects = tracker.compositionSubjects(at:evaluatedAt).map { c in
            let topLeft = CGRect(x:c.bounds.minX,y:1-c.bounds.maxY,width:c.bounds.width,height:c.bounds.height)
            return CompositionContextSubject(bounds:projection.visibleRect(topLeft),label:c.label,confidence:c.confidence)
        }
        let frames = tracker.compositionFrames(at:evaluatedAt).map {
            projection.visibleRect(CGRect(x:$0.minX,y:1-$0.maxY,width:$0.width,height:$0.height))
        }
        if let imageBounds {
            if subjectMeasurementLabel != tracker.label || now - lastSubjectMeasurement >= 1 {
                lastSubjectMeasurement = now; subjectMeasurementLabel = tracker.label
                let rect = CGRect(x: imageBounds.minX, y: 1 - imageBounds.maxY, width: imageBounds.width, height: imageBounds.height)
                subjectMeasurements = PhotoMeasurements.fromSubject(buffer: buffer, region: rect)
            }
        } else { subjectMeasurements = nil; subjectMeasurementLabel = nil }
        let observedAnatomy = tracker.anatomy(for:imageBounds,projection:projection,at:evaluatedAt)
        let geometricScale = bounds.map { TargetRectangleGeometry.preferredScale(subject:$0,label:tracker.label,intent:photographyIntent) }
        let availableScales = FramingPlanner.availableScales(currentZoom:analysisZoom,maximumZoom:automaticZoomLimit,detailZoomLimit:detailZoomLimit,nativeStops:nativeZoomStops,maximumScale:photographyIntent.maximumCropScale,desiredScale:geometricScale)
        let freezeTighterPlan = (framing.phase == .aligning || framing.phase == .settling) && scenePlanner.plan?.permitsZoom == true
        let freezeShot = zooming || freezeTighterPlan || (framing.phase == .framed && framing.shotVerified)
        let plannedScene = planning ? scenePlanner.update(subject:bounds,confidence:confidence,label:tracker.label,evidence:compositionEvidence,
            others:contextSubjects,enclosingFrames:frames,timestamp:evaluatedAt,
            maximumScale:analysisSource == .iPhone ? max(1,automaticZoomLimit/max(0.01,analysisZoom)) : 1,
            freeze:freezeShot,intent:photographyIntent,availableScales:availableScales,anatomy:observedAnatomy) : nil
        let plan: SceneCompositionPlan?
        if planning { plan = plannedScene }
        else if (framing.phase == .aligning || framing.phase == .settling || framing.phase.isAutoFraming || framing.phase == .framed),
                directZoomPlan?.subjectLabel == tracker.label { plan = directZoomPlan }
        else if !planning, autoFrameEnabled, mode != .thirds, analysisSource == .iPhone,
           let bounds, let evidence = compositionEvidence, evidence.isFresh(at:evaluatedAt) {
            plan = TargetRectangleSearch.plan(subject:bounds,label:tracker.label,intent:photographyIntent,evidence:evidence,
                others:contextSubjects,scales:availableScales,forceCenter:mode == .centered,anatomy:observedAnatomy,enclosingFrames:frames)
                ?? IntentCompositionSearch.zoomPlan(subject:bounds,label:tracker.label,intent:photographyIntent,evidence:evidence,
                    others:contextSubjects,frames:frames,scales:availableScales,forceCenter:mode == .centered)
            directZoomPlan = plan
        } else { plan = nil; directZoomPlan = nil }
        if subject == nil && !tracker.isRecovering { manualTargetLock = nil }
        let manualTarget = preferredTarget ?? manualTargetLock ?? subject.map { CompositionEngine.target(for:$0,mode:mode) } ?? UnitPoint2D(x:0.5,y:0.5)
        if mode == .thirds, subject != nil { manualTargetLock = manualTarget }
        let appliedPetStyle: PetFramingStyle = photographyIntent == .pet ? petFraming : .balanced
        let zoomAnatomy: SubjectAnatomy?
        if zooming, let shot = framing.shotPlan, let bounds {
            zoomAnatomy = shot.trackedAnatomy(bounds:bounds,timestamp:evaluatedAt)
        } else { zoomAnatomy = observedAnatomy ?? bounds.flatMap { framing.shotPlan?.trackedAnatomy(bounds:$0,timestamp:evaluatedAt) } }
        if analysisSource == .iPhone, automaticShotArmed, autoFrameEnabled, !zooming,
           let bounds, let plan, framing.phase.isPreparing {
            if let selected = framing.shotPlan, let reference = selected.trackingReference,
               tracker.trackingReference != reference, !tracker.isRecovering {
                framing.stop(reason:.tracking); shotCapture.cancel()
            } else {
                let context = plan.selected.protectedContext ?? (SceneCompositionPlanner.distinctSubjects(contextSubjects,selected:bounds).map(\.bounds)
                    + frames.filter { $0.contains(bounds) })
                if let selected = AutomaticShotPlan.propose(bounds:bounds,label:tracker.label,confidence:confidence,
                    trackingReference:tracker.trackingReference,composition:plan,currentZoom:analysisZoom,
                    maximumZoom:automaticZoomLimit,detailLimit:detailZoomLimit,nativeStops:nativeZoomStops,
                    regions:context,anatomy:zoomAnatomy,projection:projection) {
                    framing.selectShot(selected)
                }
            }
        }
        let zoomFacts = CompositionAssessment.evaluate(bounds:bounds,confidence:Double(confidence),label:tracker.label,intent:photographyIntent,
            stable:stable,exposure:subjectMeasurements,evidence:compositionEvidence,others:contextSubjects,anatomy:zoomAnatomy,timestamp:evaluatedAt,petStyle:appliedPetStyle)
        let allowPlannedZoom = photographyIntent.permitsZoom && appliedPetStyle.permitsAutomaticZoom && mode != .thirds
            && (plan?.permitsZoom ?? false) && zoomFacts.permitsAutomaticCrop
        if !appliedPetStyle.permitsAutomaticZoom && framing.phase != .off {
            framing.reset(enabled:false)
            if zooming { queue.async { self.cancelZoomRamp() } }
        }
        if zooming, framing.phase.isAutoFraming {
            let fresh = GuidanceObservationPolicy.fresh(capturedAt:observationTime,evaluatedAt:ProcessInfo.processInfo.systemUptime)
            let currentRegions: [CGRect] = [] // Frozen head/joints are reprojected inside the shot plan.
            let progress = framing.verifyShot(bounds:bounds,label:tracker.label,confidence:confidence,zoom:analysisZoom,
                stable:stable,fresh:fresh,timestamp:evaluatedAt,previewAspect:previewAspect,regions:currentRegions,cameraRamping:capturedZoom?.ramping ?? true,
                cameraFresh:capturedZoom?.fresh(at:evaluatedAt) ?? false,cropPermitted:zoomFacts.permitsAutomaticCrop,captureStable:captureStable,trackingReference:tracker.trackingReference)
            let generation = analysisZoomGeneration
            switch progress {
            case .continuing:
                queue.async { if self.zoomGeneration == generation { self.lastRampVerification = evaluatedAt } }
            case .recovering:
                let reason = framing.blockReason ?? .tracking
                queue.async { self.pauseAutomaticZoom(generation:generation,at:evaluatedAt,reason:reason) }
            case .resuming:
                queue.async { self.resumeAutomaticZoom(generation:generation,at:evaluatedAt) }
            case .holding:
                queue.async {
                    guard self.zoomGeneration == generation, !self.automaticZoomBlocked, let device = self.device else { return }
                    self.lastRampVerification = evaluatedAt
                    guard !self.rampHolding else { return }
                    self.rampHolding = true
                    do {
                        try device.lockForConfiguration()
                        device.cancelVideoZoomRamp()
                        device.unlockForConfiguration()
                        self.recordObservedZoom()
                    } catch { self.abortAutomaticZoom(generation:generation) }
                }
            case .achieved:
                ShotFramingDiagnostics.log("ZOOM_COMPLETE","shot=\(framing.shotPlan?.id ?? "none") displayed=\(analysisZoom) native=\(capturedZoom?.hardwareFactor ?? 0) ramping=\(capturedZoom?.ramping ?? true) bounds=\(String(describing:bounds))")
                automaticShotArmed = false
                queue.async {
                    guard self.zoomGeneration == generation else { return }
                    self.automaticZoomBlocked = true; self.cancelZoomRamp(preserveVerifiedShot:true)
                }
                engine.reset(); automaticGuidance.reset(); publishFraming()
            case .cancel:
                let reason = framing.blockReason ?? .unsafeCrop
                automaticShotArmed = false; framing.stop(reason:reason); shotCapture.cancel()
                queue.async { self.abortAutomaticZoom(generation:generation,reason:reason) }
            }
        }
        if analysisSource == .iPhone {
            framing.revalidateCompletedShot(bounds:bounds,label:tracker.label,confidence:confidence,zoom:analysisZoom,aspect:previewAspect)
        }
        let currentFrameEligible = ShotReadiness.measuredCurrentFrame(plan:plan,assessment:zoomFacts,label:tracker.label,timestamp:evaluatedAt,stable:captureStable)
        if analysisSource == .iPhone {
            let scene = tracker.scene
            let sceneEligible = ShotReadiness.measuredSceneFrame(scene:scene,evidence:compositionEvidence,measurements:sceneMeasurements,
                stable:captureStable,timestamp:evaluatedAt)
            if bounds == nil, let scene, let evidence = compositionEvidence, sceneEligible, framing.shotPlan == nil {
                framing.selectShot(AutomaticShotPlan.scene(label:scene.label,evidence:evidence,zoom:analysisZoom,projection:projection))
            }
            framing.confirmCurrentFrame(eligible:currentFrameEligible || (bounds == nil && framing.shotPlan?.sceneAnchor == true && sceneEligible),timestamp:evaluatedAt,holdDuration:holdDuration)
        }
        let preparingZoom = automaticShotArmed && autoFrameEnabled && analysisSource == .iPhone && framing.phase.isPreparing && !zooming && plan?.permitsZoom == true
        let keepUnplannedFrame = mode == .automatic && !planning && plan == nil
        let selectedShot = framing.shotPlan
        let executionScale = bounds.flatMap { box in selectedShot.map { $0.scaleForCurrentBounds(box) } } ?? plan?.selected.zoomScale
        let aimingTarget = bounds.flatMap { box in selectedShot.map { $0.aimingTarget(bounds:box) } } ?? plan?.zoomAlignmentTarget
        let finalTarget = selectedShot?.desiredPosition ?? plan?.target
        let layoutTarget = (preparingZoom ? aimingTarget : finalTarget) ?? (keepUnplannedFrame ? subject : nil) ?? (mode == .centered ? UnitPoint2D(x:0.5,y:0.5) : manualTarget)
        let observationFresh = GuidanceObservationPolicy.fresh(capturedAt:observationTime,evaluatedAt:ProcessInfo.processInfo.systemUptime)
        let zoomMotionAllowed = GuidanceObservationPolicy.permitsZoom(stable:stable,relativeSpeed:relativeMotion,fresh:observationFresh)
        let zoomBlock: FramingBlockReason?
        if !observationFresh { zoomBlock = .staleFrame }
        else if analysisSource == .iPhone, framingMotion?.usable != true { zoomBlock = .motionUnavailable }
        else if !stable { zoomBlock = .cameraMotion }
        else if !zoomMotionAllowed { zoomBlock = .subjectMotion }
        else if !allowPlannedZoom { zoomBlock = .quality }
        else { zoomBlock = nil }
        if analysisSource == .iPhone, framing.phase.isPreparing, !zooming, plan == nil {
            framing.noteBlock(.missingPlan,at:evaluatedAt)
        }
        if (!planning || plan != nil || bounds == nil), let targetZoom = framing.update(bounds: bounds, confidence: confidence, roll: roll, timestamp: evaluatedAt,
                                            currentZoom: analysisZoom, maximumZoom: automaticZoomLimit,
                                            detailZoomLimit: detailZoomLimit, nativeStops: nativeZoomStops, deviceStable:zoomMotionAllowed, holdDuration:holdDuration, previewAspect:previewAspect,
                                            alignmentTarget:layoutTarget,allowZoom:allowPlannedZoom,plannedScale:executionScale,zoomDestination:preparingZoom ? finalTarget : nil,requiresShotPlan:true,blockedBy:zoomBlock), imageBounds != nil {
            let protectedContext = plan?.selected.protectedContext ?? (SceneCompositionPlanner.distinctSubjects(contextSubjects,selected:bounds ?? .zero).map(\.bounds)
                + frames.filter { $0.contains(bounds ?? .zero) })
            if let bounds, let selected = framing.shotPlan,
               selected.trackingReference == nil || selected.trackingReference == tracker.trackingReference,
               let shot = selected.prepared(bounds:bounds,zoom:analysisZoom,detailLimit:detailZoomLimit,nativeStops:nativeZoomStops,
                    regions:protectedContext,anatomy:zoomAnatomy,aspect:previewAspect),
               abs(shot.targetZoom-targetZoom) < 0.01 {
                framing.commitShot(shot)
                performAutomaticZoom(to:shot.targetZoom,generation:analysisZoomGeneration,observedAt:observationTime,shotID:shot.id)
                let previewDate = Date().addingTimeInterval(observationTime-ProcessInfo.processInfo.systemUptime)
                let wide = PhotoRenderer.widePreview(CIImage(cvPixelBuffer:fullBuffer),aspect:previewAspect,mirrored:analysisFrontCamera,
                    observedAt:previewDate,context:imageContext)
                shotCapture.select(shot,preview:wide)
                ShotFramingDiagnostics.log("WIDE_PREVIEW_RETAINED","shot=\(shot.id) available=\(wide != nil) width=\(wide?.pixelWidth ?? 0) height=\(wide?.pixelHeight ?? 0)")
            } else {
                ShotFramingDiagnostics.log("PLAN_REJECTED","subject=\(tracker.label) reason=protected_geometry_or_target_mismatch zoom=\(analysisZoom)")
                framing.stop(reason:.unsafeCrop)
            }
        }
        if analysisSource == .iPhone {
            shotCapture.observe(plan:framing.shotPlan,verified:framing.shotVerified,bounds:bounds,label:tracker.label,
                confidence:confidence,zoom:analysisZoom,stable:captureStable,timestamp:evaluatedAt,aspect:previewAspect)
        }
        let tolerance = autoFrameEnabled && analysisSource == .iPhone && framing.phase.isPreparing ? FramingPlanner.alignmentTolerance(plannedScale:executionScale,destination:preparingZoom ? finalTarget : nil) : 0.065
        var result = engine.update(subject: subject, rollDegrees: roll, mode: mode, timestamp: evaluatedAt,
                                   preferredTarget: layoutTarget, previewAspect: previewAspect,alignmentTolerance:tolerance,acceptCurrentFrame:plan?.selected.isCurrentFrame == true || keepUnplannedFrame)
        let analysisReadingBounds = bounds
        result.subjectBounds = boxSmoother.update(bounds)
        result.guidanceBounds = bounds
        result.subjectConfidence = confidence
        if framing.currentFrameVerified, framing.shotPlan?.sceneAnchor == true { result.state = .ready }
        result.mirrored = analysisSource == .iPhone && analysisFrontCamera
        if let selected = framing.shotPlan, let bounds {
            result.targetCompositionRect = selected.currentTargetRectangle(bounds:bounds,zoom:analysisZoom)
            result.plannedSubjectBounds = selected.desiredBounds
            result.shotPlanID = selected.id
            result.shotStatus = framing.directorState(hasPlan:true)
        }
        let reliable = gravity.map { hypot($0.x,$0.y) > 0.2 } ?? false
        if analysisSource == .iPhone && motionData == nil && (result.state == .ready || result.state == .settling) {
            result.state = .adjusting
            result.title = "Level unavailable. Frame manually"
        }
        if !captureStable && result.state == .ready { result.state = .settling }
        if analysisSource == .iPhone && !ShotReadiness.permitsReady(required:true,shotVerified:framing.shotVerified,currentFrameVerified:framing.currentFrameVerified), result.state == .ready {
            result.state = .settling; result.title = "Evaluating the selected shot"
        }
        let scene = tracker.scene.flatMap { now - $0.timestamp <= 6 ? $0 : nil }
        if imageBounds == nil, now - lastSceneMeasurement >= 2 {
            lastSceneMeasurement = now; sceneMeasurements = PhotoMeasurements.from(buffer: buffer)
        }
        if coachEnabled && !zooming && !deviceMoving && now >= manualInferenceResumeAfter && now - lastCoach >= 2 {
            lastCoach = now
            let nativeRect = imageBounds.map { CGRect(x:$0.minX,y:1-$0.maxY,width:$0.width,height:$0.height) }
            let measurements = nativeRect.flatMap { PhotoMeasurements.fromSubject(buffer:buffer,region:$0) } ?? PhotoMeasurements.from(buffer:buffer)
            let assessment = CompositionAssessment.evaluate(bounds:bounds,confidence:Double(confidence),label:tracker.label,intent:photographyIntent,
                stable:stable,exposure:measurements,evidence:compositionEvidence,others:contextSubjects,
                anatomy:tracker.anatomy(for:imageBounds,projection:projection,at:evaluatedAt),timestamp:evaluatedAt,petStyle:appliedPetStyle)
            var coachReading = result; coachReading.subjectBounds = bounds
            let decision = ActionFeasibility.recommend(assessment:assessment,reading:coachReading,intent:photographyIntent,plan:plan,
                rollReliable:reliable,previewAspect:previewAspect,manualComposition:mode != .automatic,
                autoPreparing:autoFrameEnabled && framing.phase.isPreparing && plan?.permitsZoom == true)
            let advice = decision.action.isAdjustment ? [decision.text] : []
            let sceneName = tracker.scene?.label
            publishAnalysis(snapshot) { self.liveMeasurements = measurements; self.coachAdvice = advice; self.sceneLabel = sceneName }
        }
        let decisionStarted = ProcessInfo.processInfo.systemUptime
        guard GuidanceObservationPolicy.fresh(capturedAt:observationTime,evaluatedAt:decisionStarted) else { discardStaleGuidance(snapshot); return }
        var measured = result; measured.subjectBounds = analysisReadingBounds
        let observedScene = GuidanceSceneSnapshot(observedAt:observationTime,evaluatedAt:decisionStarted,label:tracker.label,intent:photographyIntent,
            selectedBounds:bounds,confidence:Double(confidence),surroundingSubjects:contextSubjects,
            anatomy:zoomAnatomy,measurements:subjectMeasurements,
            imageEvidence:compositionEvidence,relativeSpeed:relativeMotion,deviceStable:stable,petStyle:appliedPetStyle)
        #if DEBUG || FOCAL_EVALUATION
        let previousGuidance = automaticGuidance.previousAction
        #endif
        if analysisSource == .iPhone, framing.phase == .off, framing.blockReason == nil {
            framing.noteBlock(!autoFrameEnabled ? .disabled : .manualControl,at:evaluatedAt)
        }
        let message = automaticGuidance.update(reading:measured,phase:framing.phase,stable:stable,
            rollReliable:reliable,autoEnabled:autoFrameEnabled && analysisSource == .iPhone,
            zoomAvailable:allowPlannedZoom && automaticZoomLimit > analysisZoom*1.12,timestamp:evaluatedAt,previewAspect:previewAspect,scene:scene,sceneMeasurements:sceneMeasurements,subjectLabel:tracker.label,subjectMeasurements:subjectMeasurements,recovering:tracker.isRecovering,
            compositionPlan:plan,sceneEvidence:compositionEvidence,intent:photographyIntent,manualSubject:tracker.manual,
            manualComposition:mode != .automatic,anatomy:observedScene.anatomy,others:contextSubjects,observedScene:observedScene,shotVerified:framing.shotVerified,requireShotCompletion:analysisSource == .iPhone,currentFrameVerified:framing.currentFrameVerified,framingInstruction:analysisSource == .iPhone ? framing.progressInstruction : nil)
        #if DEBUG || FOCAL_EVALUATION
        if analysisSource == .iPhone {
            let state = framing.directorState(hasPlan:plan != nil)
            let reason = framing.shotVerified ? "verified_actual_zoom_and_crop" : framing.currentFrameVerified ? "measured_current_frame" : !automaticShotArmed ? "manual_or_interruption_override" : !autoFrameEnabled ? "automatic_zoom_disabled" : plan == nil ? "no_measured_shot" : !allowPlannedZoom ? "crop_quality_or_tracking_gate" : !stable ? "waiting_for_stability" : "aim_hold_or_verify"
            let key = "\(state.rawValue)|\(reason)|\(message.kind)|\(message.text)"
            if key != lastDirectorDiagnostic || evaluatedAt-lastDirectorLogTime >= 1 {
                lastDirectorLogTime = evaluatedAt
                lastDirectorDiagnostic = key
                let camera = capturedZoom
                let desiredBounds = framing.shotPlan?.desiredBounds ?? bounds.map { FramingPlanner.zoomedRect($0,scale:plan?.selected.zoomScale ?? 1) }
                let shotID = framing.shotPlan?.id ?? plan?.id ?? "none"
                let framingError = bounds.flatMap { box in framing.shotPlan.map { $0.error(bounds:box,zoom:analysisZoom,aspect:previewAspect) } }
                let nativeTarget = (framing.shotPlan?.targetZoom ?? analysisZoom*(plan?.selected.zoomScale ?? 1))*(camera?.multiplier ?? 1)
                ShotFramingDiagnostics.log("STATE","state=\(state.rawValue) reason=\(framing.blockReason?.rawValue ?? reason) subject=\(tracker.label) tracker=\(tracker.trackingReference ?? "none") lockedTracker=\(framing.shotPlan?.trackingReference ?? "none") shot=\(shotID) verified=\(framing.shotVerified) currentVerified=\(framing.currentFrameVerified) bounds=\(String(describing:bounds)) desired=\(String(describing:desiredBounds)) zoom=\(analysisZoom) target=\(framing.shotPlan?.targetZoom ?? analysisZoom*(plan?.selected.zoomScale ?? 1)) targetHardware=\(nativeTarget) widthError=\(framingError?.width ?? -1) heightError=\(framingError?.height ?? -1) zoomError=\(framingError?.zoom ?? -1) hardware=\(camera?.hardwareFactor ?? 0) multiplier=\(camera?.multiplier ?? 0) ramping=\(camera?.ramping ?? false) confidence=\(confidence) error=\(bounds.map { hypot(Double($0.midX)-layoutTarget.x,(Double($0.midY)-layoutTarget.y)/previewAspect) } ?? -1) aligned=\(framing.phase == .settling || framing.phase.isAutoFraming) stable=\(stable) rotation=\(framingMotion?.rotation ?? -1) acceleration=\(framingMotion?.acceleration ?? -1) motionAge=\(framingMotion?.age ?? -1) relativeSpeed=\(relativeMotion ?? -1) frameAge=\(evaluatedAt-observationTime) captureStable=\(captureStable) composition=\(String(describing:framing.shotPlan?.imageGeometry?.composition)) score=\(framing.shotPlan?.qualityScore ?? plan?.selected.score ?? 0) kind=\(framing.shotPlan?.kind.rawValue ?? "unplanned") protected=\(framing.shotPlan?.protectedRegions.count ?? 0) hold=\(framing.holdProgress) wait=\(framing.waitDuration) recovering=\(framing.recovering) allowed=\(automaticShotArmed && autoFrameEnabled && allowPlannedZoom) limit=\(automaticZoomLimit) detailLimit=\(detailZoomLimit) guidance=\(message.text)")
            }
        }
        #endif
        let finished = ProcessInfo.processInfo.systemUptime
        guard GuidanceObservationPolicy.fresh(capturedAt:observationTime,evaluatedAt:finished) else { discardStaleGuidance(snapshot); return }
        #if DEBUG || FOCAL_EVALUATION
        guidanceDiagnostics.record(scene:observedScene,plan:plan,message:message,previous:previousGuidance,memoryOutcome:automaticGuidance.memoryOutcome,phase:framing.phase,
            reasoning:automaticGuidance.reasoning,inferenceMS:inferenceMilliseconds,decisionMS:(finished-decisionStarted)*1000,finishedAt:finished)
        let timingReport = GuidancePerformanceReport(guidanceDiagnostics.timings,source:analysisSource.rawValue,thermalState:String(describing:ProcessInfo.processInfo.thermalState))
        publishAnalysis(snapshot) { self.guidancePerformance = timingReport }
        #endif
        let label = tracker.label
        let phase = framing.phase
        let progress = framing.holdProgress
        publishAnalysis(snapshot) { self.reading = result; self.subjectLabel = label; self.framingPhase = phase; self.framingHoldProgress = progress; self.levelReliable = reliable; self.guidance = message; self.compositionPlan = plan }
    }

    private func discardStaleGuidance(_ snapshot:GuidanceActivation.Snapshot) {
        guard snapshot.enabled, guidanceSnapshot() == snapshot, snapshot.source == analysisSource else { return }
        let zooming = framing.phase.isAutoFraming
        let armed = automaticShotArmed && framing.phase.isPreparing && !zooming && autoFrameEnabled && analysisSource == .iPhone
        let time = ProcessInfo.processInfo.systemUptime
        if zooming {
            let recovery = framing.recover(reason:.staleFrame,at:time)
            let generation = analysisZoomGeneration
            if recovery == .cancel { queue.async { self.abortAutomaticZoom(generation:generation,reason:.recoveryExpired) } }
            else { queue.async { self.pauseAutomaticZoom(generation:generation,at:time,reason:.staleFrame) } }
        } else if armed { framing.noteBlock(.staleFrame,at:time) }
        automaticGuidance.reset(); engine.reset(); previousMotionSubject = nil
        #if DEBUG || FOCAL_EVALUATION
        guidanceDiagnostics.rejectStale()
        #endif
        publishAnalysis(snapshot) {
            self.reading = CompositionReading(); self.guidance = .init(kind:.steady,text:FramingBlockReason.staleFrame.instruction,action:.hold)
            self.framingHoldProgress = 0; self.coachAdvice = []
        }
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
                self.finishCapture(.success(CameraCapture(processed: processed, raw: self.pendingRAW,framing:self.pendingFramingCapture)))
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
            self.pendingProcessed = nil; self.pendingRAW = nil; self.pendingError = nil; self.pendingFramingCapture = nil
            guard let completion else { return }
            self.analysisQueue.async { self.analysisPaused = false }
            DispatchQueue.main.async {
                self.isCapturing = false
                completion(result)
            }
        }
    }
}
