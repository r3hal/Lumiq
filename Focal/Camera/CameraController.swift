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
    @Published private(set) var photoCapabilities = PhotoCaptureCapabilities()
    var supportsRAW: Bool { photoCapabilities.supportsRAW }
    var supportsProRAW: Bool { photoCapabilities.supportsProRAW }
    var rawUnavailableReason: String {
        if isSwitchingCamera || access == .checking { return "Checking RAW support…" }
        if !isRunning { return "Start the camera to check RAW support." }
        return isFrontCamera ? "RAW is not available on this front camera." : "RAW is unavailable on this camera. Try another rear lens in Pro controls."
    }
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
    private let resultGate = GuidanceResultGate()
    private var requestedPreviewAspect = 0.75 // Protected by guidanceLock.
    private var activeAnalysisTicket: GuidanceResultGate.Ticket? // Analysis queue only.
    private var activeAnalysisSnapshot: GuidanceActivation.Snapshot? // Analysis queue only.
    private var analysisSubjectReference: String? // Analysis queue only.
    private var readySceneContinuity = ReadySceneContinuity()
    private let cloudScanGate = CloudScanRequestGate()
    private var pendingCloudCapture: (ticket:CloudScanTicket,completion:(Result<CloudScanCapture,Error>) -> Void)?
    private var cloudCompositionLock: CloudCompositionLock? // Analysis queue only.
    private var latestCloudEvidence: CloudLocalEvidence?
    private var cloudRecovering = false
    @Published private(set) var cloudCompositionStatus = "Local composition guidance"
    private var subjectMeasurements: PhotoMeasurements?
    private var subjectMeasurementLabel: String?
    private var lastSubjectMeasurement: TimeInterval = -.infinity
    private var sceneMeasurements: PhotoMeasurements?
    private var lastSceneMeasurement: TimeInterval = -.infinity
    private var autoFrameEnabled = true
    private var framing = FramingPlanner(continuousRecovery:true)
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
    private var automaticZoomBlocked = false // Camera queue; temporary motor override, not AI OFF.
    private var manualZoomGrace = ManualZoomGrace()
    private var analysisManualZoomUntil:TimeInterval = 0 // Analysis queue.
    private var automaticShotArmed = true // Analysis queue; explicit AI OFF ends guidance.
    private var rampStartZoom = 1.0 // Camera queue, hardware units.
    private var rampTargetZoom = 1.0
    private var rampPaused = false // Temporary recovery keeps the same shot and target.
    private var zoomWatchdog = ZoomProgressWatchdog()
    private var rampHolding = false // Camera queue; no restart once desired geometry is reached.
    private var rampStage = -1
    private var lastRampVerification: TimeInterval = 0
    private let zoomObservationLock = NSLock()
    private var observedPhoneZoom = CameraZoomObservation(hardwareFactor:1,multiplier:1,ramping:false,timestamp:0)
    private var directorTrace = FramingTransitionTrace() // Analysis queue.
    private var rampShotID: String? // Camera queue.
    private var rampObservedTarget = false // Camera queue.
    private var lastMotorTraceTime: TimeInterval = -.infinity // Camera queue.
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
    private var subjectAutofocus = SubjectAutofocus() // Existing analysis queue.
    private let autofocusRequests = AutofocusRequestGate()
    private weak var autofocusPreviewLayer: AVCaptureVideoPreviewLayer? // Main thread only.
    private var trackingFocusIdentity: String? // Camera queue below.
    private var lastTrackingFocusEvidence: TimeInterval = -.infinity
    private var trackingFocusWatchdogRunning = false
    private var trackingFocusWatchdogRevision = 0
    private var trackingFocusRetryAfter: TimeInterval = 0
    private var pendingTrackingFocusRestore = false
    private var trackingFocusPaused = false // Camera queue; sheets must not configure focus.
    private var zoomMultiplier: CGFloat = 1 // Capture zoom that corresponds to the wide lens's 1×.
    private var shotCapture = ShotCaptureSession() // Analysis queue.
    private var pendingFramingCapture: FramedCapture? // Camera queue, frozen on shutter press.
    private var captureCompletion: ((Result<CameraCapture, Error>) -> Void)?
    private var pendingProcessed: Data?
    private var pendingRAW: Data?
    private var pendingPhotoSelection: PhotoCaptureSelection?
    private var pendingError: Error?
    private var pendingCaptureID: Int64?
    private var observers: [NSObjectProtocol] = []
    private var photoSupportObservation: NSKeyValueObservation?
    private var photoFormatObservation: NSKeyValueObservation?

    override init() {
        super.init()
        // Support can change after commit/start or when AVFoundation changes
        // the active format. Never leave the UI with the pre-commit snapshot.
        photoSupportObservation = output.observe(\.isAppleProRAWSupported, options: [.new]) { [weak self] _, _ in
            self?.schedulePhotoCapabilityRefresh()
        }
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
        invalidateGuidanceResults()
        precisionLock.lock(); precisionContext.generation += 1; precisionLock.unlock()
        DispatchQueue.main.async { self.precisionReading = nil; self.autoTuneRecommendations = []; self.currentAutoTuneRecommendations = []; self.advicePresentation.reset() }
        zoomRequestLock.lock(); zoomRequests.clear(); zoomRequestLock.unlock()
        videoQueue.async { self.previewCadence = PreviewFrameCadence() }
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsToRun = false
            self.autofocusRequests.invalidate(); self.restoreNormalSubjectFocus()
            self.cancelZoomRamp()
            if self.session.isRunning { self.session.stopRunning() }
            self.motion.stopDeviceMotionUpdates()
            self.analysisQueue.async { self.ignoreFramesUntil = 0; self.resetAnalysis(armFraming: false) }
            DispatchQueue.main.async { self.isRunning = false; self.telemetry = CameraTelemetry() }
        }
    }

    func switchCamera() {
        guard !isCapturing, !isSwitchingCamera, isRunning else { return }
        invalidateGuidanceResults()
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
        autofocusRequests.invalidate(); restoreNormalSubjectFocus()
        photoFormatObservation = nil
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
            self.photoCapabilities = PhotoCaptureCapabilities()
            self.precisionReading = nil; self.autoTuneRecommendations = []; self.currentAutoTuneRecommendations = []; self.advicePresentation.reset()
        }
    }

    private func guidanceSnapshot() -> GuidanceActivation.Snapshot {
        guidanceLock.lock(); defer { guidanceLock.unlock() }
        return activation.snapshot
    }

    /// Invalidate before enqueueing configuration so in-flight work cannot publish
    /// over a newer user decision. This preserves the enabled AI Guide session.
    @discardableResult private func invalidateGuidanceResults(source:CameraSource? = nil,clearCloud:Bool = false) -> GuidanceActivation.Snapshot {
        guidanceLock.lock(); let snapshot = activation.set(activation.snapshot.enabled,source:source); guidanceLock.unlock()
        resultGate.invalidate(at:ProcessInfo.processInfo.systemUptime); autofocusRequests.invalidate(); cloudScanGate.invalidate()
        if clearCloud { analysisQueue.async { self.clearCloudCompositionState() } }
        DispatchQueue.main.async {
            guard self.guidanceSnapshot() == snapshot else { return }
            self.reading = CompositionReading(); self.compositionPlan = nil; self.framingHoldProgress = 0
            self.guidance = snapshot.enabled ? .init(kind:.framing,text:"Updating the composition…") : GuidanceMessage()
        }
        return snapshot
    }
    private func publishAnalysis(_ snapshot: GuidanceActivation.Snapshot, requiresFresh:Bool = true,
                                 expires:Bool = false, update: @escaping () -> Void) {
        let ticket = activeAnalysisTicket
        DispatchQueue.main.async {
            guard snapshot.enabled, self.guidanceSnapshot() == snapshot else { return }
            if let ticket {
                guard (requiresFresh ? self.resultGate.accepts(ticket,at:ProcessInfo.processInfo.systemUptime) : self.resultGate.isCurrent(ticket)) else { return }
                if expires, !self.resultGate.apply(ticket,at:ProcessInfo.processInfo.systemUptime) { return }
            }
            update()
            if expires, let ticket { self.scheduleGuidanceExpiry(ticket,snapshot:snapshot) }
        }
    }
    private func scheduleGuidanceExpiry(_ ticket:GuidanceResultGate.Ticket,snapshot:GuidanceActivation.Snapshot) {
        let delay = max(0.01,ticket.observedAt+GuidanceObservationPolicy.maximumAge-ProcessInfo.processInfo.systemUptime+0.01)
        DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [weak self] in
            guard let self, self.guidanceSnapshot() == snapshot,
                  self.resultGate.expire(ticket,at:ProcessInfo.processInfo.systemUptime) else { return }
            self.reading = CompositionReading(); self.compositionPlan = nil; self.framingHoldProgress = 0
            self.guidance = .init(kind:.framing,text:FramingBlockReason.staleFrame.instruction)
            self.analysisQueue.async {
                guard self.guidanceSnapshot() == snapshot else { return }
                if self.framing.expireReadiness(at:ProcessInfo.processInfo.systemUptime) {
                    self.shotCapture.invalidateVerification()
                }
            }
        }
    }

    func setSubjectThreshold(_ value: Double) {
        invalidateGuidanceResults(clearCloud:true)
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
        invalidateGuidanceResults()
        analysisQueue.async { self.holdDuration = max(0.5,min(3,duration)); self.framing.reset(enabled:self.automaticShotArmed && self.guidanceEnabled && self.analysisSource == .iPhone) }
    }

    func setSubjectFeatures(pets: Bool, tracking: Bool, smartSelection: Bool) {
        invalidateGuidanceResults(clearCloud:true)
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
        invalidateGuidanceResults()
        precisionLock.lock(); precisionContext.paused = paused; precisionContext.generation += 1; precisionLock.unlock()
        queue.async {
            self.trackingFocusPaused = paused; self.autofocusRequests.invalidate()
            if paused { self.restoreNormalSubjectFocus() }
            self.cancelZoomRamp()
            self.analysisQueue.async {
                self.interfacePaused = paused
                self.framing.invalidateReadiness(at:ProcessInfo.processInfo.systemUptime)
                self.resetSubjectAutofocus()
                if !paused {
                    // Preserve a valid shot or pending recovery across sheets.
                    // A manual override remains latched across this transition.
                    if self.framing.phase == .off && self.automaticShotArmed { self.resetAnalysis() }
                }
            }
        }
    }

    func setAnalysisSource(_ source: CameraSource) {
        precisionLock.lock(); precisionContext.source = source; precisionContext.generation += 1; precisionLock.unlock()
        DispatchQueue.main.async { self.precisionReading = nil; self.autoTuneRecommendations = []; self.currentAutoTuneRecommendations = []; self.advicePresentation.reset() }
        invalidateGuidanceResults(source:source,clearCloud:true)
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
        let observedAt = ProcessInfo.processInfo.systemUptime
        let ticket = resultGate.begin(observedAt:observedAt)
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
            self.processFrame(buffer, sourceAspect: Double(image.width) / Double(image.height),observedAt:observedAt,ticket:ticket)
        }
    }

    func beginManualZoom(completion: @escaping (Double) -> Void) {
        invalidateGuidanceResults()
        tracker.cancelInference(includeTracking: false)
        queue.async {
            guard self.captureCompletion == nil else { return }
            self.manualZoomGrace.begin(at:ProcessInfo.processInfo.systemUptime)
            ShotFramingDiagnostics.log("MANUAL_ZOOM_BEGIN","revision=\(self.manualZoomGrace.revision) motorPaused=true")
            self.cancelZoomRamp(manualOverride:true)
            let actual = self.device.map { Double($0.videoZoomFactor/self.zoomMultiplier) } ?? 1
            self.analysisQueue.async {
                if let bounds = self.latestNativeBounds {
                    if let mapped = ManualZoomGrace.trackedBounds(bounds,from:self.latestBoundsZoom,to:actual) {
                        self.tracker.reseed(bounds:mapped,label:self.tracker.label,manual:self.tracker.manual)
                        self.latestNativeBounds = mapped; self.latestBoundsZoom = actual
                    } else { self.tracker.reset(); self.latestNativeBounds = nil }
                }
                self.boxSmoother.reset(); self.engine.reset(); self.automaticGuidance.reset()
                self.replanAfterManualFraming(); self.ignoreFramesUntil = 0
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
        invalidateGuidanceResults(clearCloud:true)
        queue.async {
            self.cancelZoomRamp(manualOverride:userInitiated)
            self.analysisQueue.async {
                self.mode = mode; self.engine.reset(); self.scenePlanner.reset(); self.directZoomPlan = nil; self.manualTargetLock = nil
                self.framing.reset(enabled:self.automaticShotArmed && self.guidanceEnabled && self.analysisSource == .iPhone)
                self.publishFraming()
            }
        }
    }

    func setCompositionPlanning(_ enabled: Bool) {
        let snapshot = invalidateGuidanceResults()
        queue.async {
            self.cancelZoomRamp()
            self.analysisQueue.async {
                self.compositionPlanning = enabled; self.scenePlanner.reset(); self.directZoomPlan = nil; self.engine.reset()
                self.compositionEvidence = nil; self.lastCompositionEvidence = -.infinity
                self.framing.reset(enabled:self.automaticShotArmed && self.guidanceEnabled && self.analysisSource == .iPhone)
                self.publishFraming()
                if !enabled { self.publishAnalysis(snapshot) { self.compositionPlan = nil } }
            }
        }
    }
    func setPetFraming(_ style:PetFramingStyle) {
        invalidateGuidanceResults(clearCloud:true)
        tracker.cancelInference()
        queue.async {
            self.cancelZoomRamp()
            self.analysisQueue.async {
                self.petFraming = style; self.resetAnalysis()
            }
        }
    }
    func setIntent(_ intent: PhotographyIntent, userInitiated:Bool = true) {
        invalidateGuidanceResults(clearCloud:true)
        tracker.cancelInference()
        queue.async {
            self.cancelZoomRamp(manualOverride:userInitiated)
            self.analysisQueue.async {
                self.photographyIntent = intent; self.tracker.setIntent(intent); self.resetAnalysis()
            }
        }
    }

    func setGuidance(_ enabled: Bool) {
        guidanceLock.lock(); let newSession = enabled && !activation.snapshot.enabled; let snapshot = activation.set(enabled); guidanceLock.unlock()
        resultGate.invalidate(at:ProcessInfo.processInfo.systemUptime); cloudScanGate.invalidate()
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
            if !enabled { self.autofocusRequests.invalidate(); self.restoreNormalSubjectFocus() }
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
        invalidateGuidanceResults()
        queue.async {
            let newSession = enabled && !self.autoZoomPreference
            self.autoZoomPreference = enabled
            self.cancelZoomRamp(manualOverride:!enabled,reason:.disabled)
            if newSession { self.beginAutomaticShot() }
            self.analysisQueue.async {
                self.autoFrameEnabled = self.tracker.features.allowsAutomaticZoom(requested: enabled)
                self.framing.reset(enabled: self.automaticShotArmed && self.guidanceEnabled && self.analysisSource == .iPhone)
                self.ignoreFramesUntil = 0
                self.publishFraming()
            }
        }
    }

    func cancelAutoFraming() {
        // Cancelling a motor command is not an AI OFF action.
        queue.async { self.cancelZoomRamp(manualOverride:true) }
    }

    private func beginAutomaticShot() {
        manualZoomGrace.reset(); automaticZoomBlocked = false
        analysisQueue.async { self.automaticShotArmed = true; self.analysisManualZoomUntil = 0 }
    }
    private func cancelZoomRamp(manualOverride:Bool = false, preserveVerifiedShot:Bool = false, reason:FramingBlockReason = .interrupted) {
        let interruptedShot = rampStage >= 0
        let interruptedShotID = rampShotID
        if manualOverride || interruptedShot {
            ShotFramingDiagnostics.log("ZOOM_CANCEL","shot=\(rampShotID ?? "none") manual=\(manualOverride) interrupted=\(interruptedShot) verified=\(preserveVerifiedShot) reason=\(reason.rawValue) hardware=\(FramingTransitionTrace.number(device.map { Double($0.videoZoomFactor) }))")
        }
        rampStage = -1; rampPaused = false
        if manualOverride {
            automaticZoomBlocked = true
            if reason != .disabled {
                manualZoomGrace.changed(at:ProcessInfo.processInfo.systemUptime)
                let until = manualZoomGrace.active ? TimeInterval.infinity : manualZoomGrace.resumeAt
                analysisQueue.async {
                    self.analysisManualZoomUntil = until
                    if !preserveVerifiedShot { self.replanAfterManualFraming() }
                }
                scheduleAutomaticZoomResume()
            } else {
                manualZoomGrace.reset()
                analysisQueue.async { self.framing.reset(enabled:false); self.shotCapture.cancel(); self.publishFraming() }
            }
        } else if interruptedShot && !preserveVerifiedShot {
            analysisQueue.async {
                guard self.automaticShotArmed, self.autoFrameEnabled, self.guidanceEnabled, self.analysisSource == .iPhone else { return }
                guard !self.framing.shotVerified, self.framing.shotPlan?.id == interruptedShotID else { return }
                self.framing.requestRecovery(reason:reason,at:ProcessInfo.processInfo.systemUptime)
                self.shotCapture.invalidateVerification(); self.publishFraming()
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

    func endManualZoom() {
        invalidateGuidanceResults()
        queue.async {
            self.manualZoomGrace.end(at:ProcessInfo.processInfo.systemUptime)
            let until = self.manualZoomGrace.resumeAt
            ShotFramingDiagnostics.log("MANUAL_ZOOM_END","revision=\(self.manualZoomGrace.revision) resumeAt=\(until)")
            self.analysisQueue.async { self.analysisManualZoomUntil = until }
            self.scheduleAutomaticZoomResume()
        }
    }
    private func scheduleAutomaticZoomResume() {
        let revision = manualZoomGrace.revision
        let delay = max(0.05,manualZoomGrace.resumeAt-ProcessInfo.processInfo.systemUptime)
        queue.asyncAfter(deadline:.now()+delay) {
            guard revision == self.manualZoomGrace.revision,
                  self.manualZoomGrace.permitsAutomaticZoom(at:ProcessInfo.processInfo.systemUptime),
                  self.guidanceSnapshot().enabled else { return }
            self.automaticZoomBlocked = !self.autoZoomPreference
            self.analysisQueue.async {
                // Fresh evidence and a new safe plan are required after the grace.
                self.analysisManualZoomUntil = 0
                if !self.framing.currentFrameVerified && !self.framing.shotVerified { self.replanAfterManualFraming() }
            }
            ShotFramingDiagnostics.log("MANUAL_ZOOM_GRACE_ENDED","revision=\(revision) AI guidance continued")
        }
    }
    /// Analysis queue. Retain tracker identity/AF; discard only obsolete crop and
    /// verification geometry. A subject outside the new FOV is rediscovered.
    private func replanAfterManualFraming() {
        cloudCompositionLock?.preserveManualZoom()
        shotCapture.cancel(); scenePlanner.reset(); directZoomPlan = nil; readySceneContinuity.reset()
        if mode != .thirds { manualTargetLock = nil }
        compositionEvidence = nil; engine.reset()
        framing.reset(enabled:automaticShotArmed && guidanceEnabled && analysisSource == .iPhone)
        publishFraming()
    }

    private func publishFraming() {
        let phase = framing.phase
        let progress = framing.holdProgress
        let snapshot = activeAnalysisSnapshot ?? guidanceSnapshot()
        let ticket = activeAnalysisTicket
        DispatchQueue.main.async {
            guard self.guidanceSnapshot() == snapshot else { return }
            if let ticket, !self.resultGate.accepts(ticket,at:ProcessInfo.processInfo.systemUptime) { return }
            self.framingPhase = phase; self.framingHoldProgress = progress
        }
    }

    func setTarget(_ target: UnitPoint2D?) {
        invalidateGuidanceResults(clearCloud:true)
        queue.async {
            self.cancelZoomRamp(manualOverride:true)
            self.analysisQueue.async {
                self.preferredTarget = target; self.engine.reset(); self.scenePlanner.reset(); self.directZoomPlan = nil; self.manualTargetLock = nil
                self.framing.reset(enabled:self.automaticShotArmed && self.guidanceEnabled && self.analysisSource == .iPhone)
                self.publishFraming()
            }
        }
    }

    func setPreviewAspect(_ aspect: Double) {
        guard aspect.isFinite, aspect > 0 else { return }
        guidanceLock.lock()
        let changed = abs(requestedPreviewAspect-aspect) > 0.005
        if changed { requestedPreviewAspect = aspect }
        guidanceLock.unlock()
        guard changed else { return }
        invalidateGuidanceResults(clearCloud:true)
        precisionLock.lock(); precisionContext.previewAspect = aspect; precisionContext.generation += 1; precisionLock.unlock()
        analysisQueue.async {
            self.framing.invalidateReadiness(at:ProcessInfo.processInfo.systemUptime)
            if abs(self.previewAspect-aspect) > 0.005 {
                self.autofocusRequests.invalidate(); self.subjectAutofocus.reset()
            }
            if abs(self.previewAspect-aspect) > 0.005, self.framing.phase.isAutoFraming {
                self.replanAfterManualFraming()
                self.queue.async { self.cancelZoomRamp(manualOverride:true) }
            }
            self.previewAspect = aspect; self.engine.reset(); self.scenePlanner.reset()
            self.compositionEvidence = nil; self.lastCompositionEvidence = -.infinity
        }
    }

    func tryAnotherComposition() {
        invalidateGuidanceResults(clearCloud:true)
        guard guidanceSnapshot().enabled else { return }
        queue.async {
            self.cancelZoomRamp()
            self.analysisQueue.async {
                self.scenePlanner.requestAlternative(); self.directZoomPlan = nil; self.shotCapture.cancel()
                self.framing.reset(enabled:self.automaticShotArmed && self.guidanceEnabled && self.analysisSource == .iPhone)
                self.publishFraming()
            }
        }
    }

    func findSubject() {
        guard guidanceSnapshot().enabled else { return }
        let snapshot = invalidateGuidanceResults()
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
        invalidateGuidanceResults(clearCloud:true)
        tracker.cancelInference()
        queue.async {
            self.autofocusRequests.invalidate()
            self.cancelZoomRamp(manualOverride:true)
            self.beginAutomaticShot() // Selecting a subject explicitly initiates a new AI shot.
            self.analysisQueue.async {
                self.subjectAutofocus.reset()
                self.ignoreFramesUntil = 0
                guard self.guidanceEnabled, self.guidanceSnapshot().enabled else { return }
                let projection = PreviewProjection(imageAspect: self.imageAspect, previewAspect: self.previewAspect, mirrored: self.analysisFrontCamera)
                self.tracker.select(at: projection.imagePoint(previewPoint))
                self.engine.reset(); self.boxSmoother.reset(); self.automaticGuidance.reset()
                self.scenePlanner.reset(); self.directZoomPlan = nil; self.manualTargetLock = nil; self.previousMotionSubject = nil
                self.precisionLock.lock(); self.precisionContext.relativeSubjectMotion = nil; self.precisionContext.subjectMotionTimestamp = nil; self.precisionLock.unlock()
                self.latestNativeBounds = nil
                self.framing.reset(enabled: self.automaticShotArmed && self.guidanceEnabled && self.analysisSource == .iPhone)
                self.publishFraming()
                self.wantsScan = true
                self.publishAnalysis(self.guidanceSnapshot()) { self.subjectLabel = "Your subject"; self.reading = CompositionReading(); self.guidance = GuidanceMessage() }
            }
        }
    }

    func setZoom(_ displayedZoom: Double) {
        guard !isCapturing else { return }
        invalidateGuidanceResults()
        zoomRequestLock.lock(); let schedule = zoomRequests.enqueue(displayedZoom); zoomRequestLock.unlock()
        guard schedule else { return }
        tracker.cancelInference(includeTracking: false)
        queue.async {
            self.cancelZoomRamp(manualOverride:true)
            self.analysisQueue.async {
                self.replanAfterManualFraming(); self.ignoreFramesUntil = 0
                self.manualInferenceResumeAfter = ProcessInfo.processInfo.systemUptime + 0.5
                self.publishFraming()
            }
        }
        queue.asyncAfter(deadline: .now() + 1.0 / 30.0) {
            self.zoomRequestLock.lock(); let requested = self.zoomRequests.take(); self.zoomRequestLock.unlock()
            guard let requested, self.wantsToRun, self.captureCompletion == nil, let device = self.device else { return }
            self.cancelZoomRamp(manualOverride:true)
            self.analysisQueue.async { self.ignoreFramesUntil = 0; self.replanAfterManualFraming(); self.publishFraming() }
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
                        if let mapped = ManualZoomGrace.trackedBounds(bounds,from:self.latestBoundsZoom,to:value) {
                            self.tracker.reseed(bounds:mapped,label:self.tracker.label,manual:self.tracker.manual)
                            self.latestNativeBounds = mapped; self.latestBoundsZoom = value
                        } else { self.tracker.reset(); self.latestNativeBounds = nil }
                    }
                    self.boxSmoother.reset(); self.engine.reset(); self.scenePlanner.reset(); self.directZoomPlan = nil; self.compositionEvidence = nil
                    self.analysisZoom = value
                    self.ignoreFramesUntil = ProcessInfo.processInfo.systemUptime + 0.08
                    self.manualInferenceResumeAfter = ProcessInfo.processInfo.systemUptime + 0.15
                }
                DispatchQueue.main.async { self.zoom = value }
            } catch { DispatchQueue.main.async { self.errorMessage = "Zoom could not be changed. Please try again." } }
        }
    }

    private func resetAnalysis(armFraming: Bool = true) {
        clearCloudCompositionState(resetReadiness:false); latestCloudEvidence = nil
        shotCapture.cancel(); analysisSubjectReference = nil; readySceneContinuity.reset()
        #if DEBUG || FOCAL_EVALUATION
        guidanceDiagnostics = GuidanceDiagnostics()
        DispatchQueue.main.async { self.guidancePerformance = nil }
        #endif
        framing.reset(enabled: armFraming && automaticShotArmed && guidanceEnabled && analysisSource == .iPhone)
        automaticGuidance.reset(); boxSmoother.reset(); latestNativeBounds = nil
        previousMotionSubject = nil
        precisionLock.lock(); precisionContext.relativeSubjectMotion = nil; precisionContext.subjectMotionTimestamp = nil; precisionLock.unlock()
        publishFraming()
        engine.reset()
        manualTargetLock = nil
        scenePlanner.reset(); directZoomPlan = nil; compositionEvidence = nil; lastCompositionEvidence = -.infinity
        tracker.reset()
        resetSubjectAutofocus()
        wantsScan = true
        lastCoach = -.infinity; lastScene = -.infinity
        subjectMeasurements = nil; subjectMeasurementLabel = nil; lastSubjectMeasurement = -.infinity
        sceneMeasurements = nil; lastSceneMeasurement = -.infinity; manualInferenceResumeAfter = 0
        publishAnalysis(guidanceSnapshot()) {
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
                    self.analysisQueue.async {
                self.analysisPaused = false
                if self.guidanceEnabled,self.analysisSource == .iPhone {
                    self.replanAfterManualFraming(); self.automaticGuidance.reset()
                    self.wantsScan = true
                }
            }
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
                do {
                    let selection = try self.refreshPhotoCapabilities().selection(rawRequested:options.raw,encoding:options.encoding)
                    let settings = self.photoSettings(options:options,selection:selection)
                    self.pendingPhotoSelection = selection
                    self.pendingCaptureID = settings.uniqueID
                    let captureID = settings.uniqueID
                    self.output.capturePhoto(with: settings, delegate: self)
                    self.queue.asyncAfter(deadline: .now() + 30) {
                        guard self.pendingCaptureID == captureID, self.captureCompletion != nil else { return }
                        self.finishCapture(.failure(CameraError.timeout))
                    }
                } catch {
                    self.finishCapture(.failure(error))
                }
            }
        }
    }

    private func resumeIfWanted() {
        queue.async { if self.wantsToRun { self.configureAndStart() } }
    }

    private func photoSettings(options: CaptureOptions, selection: PhotoCaptureSelection) -> AVCapturePhotoSettings {
        let codec: AVVideoCodecType = selection.encoding == .heif ? .hevc : .jpeg
        let format: [String: Any] = [AVVideoCodecKey: codec]
        let settings: AVCapturePhotoSettings
        if let rawFormat = selection.raw {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat.pixelFormat, processedFormat: format)
        } else { settings = AVCapturePhotoSettings(format: format) }
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        // Bayer RAW bypasses computational processing; ProRAW supports quality processing.
        settings.photoQualityPrioritization = selection.isBayerRAW ? .speed : .quality
        let flash = AVCaptureDevice.FlashMode(rawValue: options.flash.rawValue) ?? .off
        settings.flashMode = output.supportedFlashModes.contains(flash) ? flash : .off
        if #available(iOS 18.0, *), output.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = !options.shutterSound
        }
        return settings
    }

    /// Called only on the camera queue after session configuration is committed.
    private func readPhotoCapabilities() -> PhotoCaptureCapabilities {
        if output.isAppleProRAWSupported {
            if !output.isAppleProRAWEnabled { output.isAppleProRAWEnabled = true }
        } else if output.isAppleProRAWEnabled { output.isAppleProRAWEnabled = false }
        let formats = output.availableRawPhotoPixelFormatTypes.compactMap { pixel -> RAWPhotoFormat? in
            if AVCapturePhotoOutput.isAppleProRAWPixelFormat(pixel) {
                return .init(pixelFormat:pixel,kind:.appleProRAW)
            }
            if AVCapturePhotoOutput.isBayerRAWPixelFormat(pixel) {
                return .init(pixelFormat:pixel,kind:.bayer)
            }
            return nil
        }
        return .init(rawFormats:formats,encodings:output.availablePhotoCodecTypes.contains(.hevc) ? [.jpeg,.heif] : [.jpeg])
    }
    @discardableResult private func refreshPhotoCapabilities() -> PhotoCaptureCapabilities {
        let capabilities = readPhotoCapabilities()
        DispatchQueue.main.async { self.photoCapabilities = capabilities }
        return capabilities
    }
    private func schedulePhotoCapabilityRefresh() {
        queue.async { [weak self] in
            guard let self, self.configured, self.wantsToRun, self.captureCompletion == nil else { return }
            self.refreshPhotoCapabilities()
        }
    }

    private func configureSessionInputs(allowFallback: Bool) throws -> AVCaptureDevice {
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
        guard let camera = explicit ?? fallback ?? discovered.first else { throw CameraError.configuration }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input), session.canAddOutput(output), session.canAddOutput(videoOutput) else {
            throw CameraError.configuration
        }
        session.addInput(input)
        session.addOutput(output)
        session.addOutput(videoOutput)
        return camera
    }

    private func configurePhotoPreview(_ camera: AVCaptureDevice) throws {
        // Establish genuine still-photo support before the preview optimizer
        // changes activeFormat (which switches the preset to inputPriority).
        let photoConfiguration = readPhotoCapabilities()
        session.beginConfiguration()
        do {
            if output.isAppleProRAWEnabled { output.isAppleProRAWEnabled = false }
            try configurePreviewFormat(camera)
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            throw error
        }
        guard !readPhotoCapabilities().preservesRAW(of:photoConfiguration) else { return }
        // A faster preview is not allowed to disable RAW/ProRAW. Let the photo
        // preset negotiate its supported sensor format, retaining real video
        // frames for the existing preview/analysis pipeline.
        session.beginConfiguration()
        if output.isAppleProRAWEnabled { output.isAppleProRAWEnabled = false }
        session.sessionPreset = .photo
        session.commitConfiguration()
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        configuredPreviewRate = 30
        if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
            camera.activeVideoMinFrameDuration = CMTime(value:1,timescale:30)
            camera.activeVideoMaxFrameDuration = CMTime(value:1,timescale:30)
        }
    }

    private func configureAndStart(allowFallback: Bool = true) {
        guard wantsToRun else { return }
        if !configured { DispatchQueue.main.async { self.access = .checking } }
        do {
            if !configured {
                let camera = try configureSessionInputs(allowFallback:allowFallback)
                try configurePhotoPreview(camera)
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                output.maxPhotoQualityPrioritization = .quality
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
                    self.supportsFlash = camera.hasFlash
                    if #available(iOS 18.0, *) { self.canMuteShutter = self.output.isShutterSoundSuppressionSupported }
                }
                configured = true
                photoFormatObservation = camera.observe(\.activeFormat, options:[.new]) { [weak self] _, _ in
                    self?.schedulePhotoCapabilityRefresh()
                }
                publishControls()
            }
            // Enable the negotiated RAW pipeline before startRunning; the
            // compatibility fallback may have disabled ProRAW during setup.
            _ = readPhotoCapabilities()
            if !session.isRunning {
                session.startRunning()
                // A new session after capture review needs a fresh scan. An
                // already-running session retains manual zoom/cancel intent.
                self.analysisQueue.async { self.resetAnalysis() }
            }
            let capabilities = refreshPhotoCapabilities()
            publishControls()
            let prepared = try capabilities.selection(rawRequested:false,encoding:.jpeg)
            output.setPreparedPhotoSettingsArray([photoSettings(options:CaptureOptions(),selection:prepared)], completionHandler: nil)
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
        invalidateGuidanceResults(clearCloud:true)
        queue.async {
            guard self.captureCompletion == nil else { return }
            if self.manualState.mode != mode { self.cancelZoomRamp(manualOverride:true) }
            if mode == .auto { self.manualState.reset() } else { self.manualState.mode = .pro }
            self.autofocusRequests.setManualFocus(self.manualState.focus != nil)
            self.analysisQueue.async { self.resetSubjectAutofocus() }
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
            self.autofocusRequests.setManualFocus(position != nil)
            self.autofocusRequests.invalidate()
            self.restoreNormalSubjectFocus() // Manual focus is already authoritative.
            self.analysisQueue.async { self.resetSubjectAutofocus() }
            self.scheduleManualControls()
        }
    }
    func selectLens(_ id: String?) {
        guard !isCapturing, !isSwitchingCamera, isRunning else { return }
        if id == nil && controls.usesAutomaticLenses { return }
        if let id, id == controls.lensID && !controls.usesAutomaticLenses { return }
        isSwitchingCamera = true
        invalidateGuidanceResults()
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
        autofocusRequests.setManualFocus(manualState.focus != nil)
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
    private func performAutomaticZoom(to target: Double, generation: Int, observedAt:TimeInterval,shotID:String,verificationOnly:Bool = false) {
        queue.async {
            ShotFramingDiagnostics.log("ZOOM_REQUEST","shot=\(shotID) displayedTarget=\(target) generation=\(generation) activeGeneration=\(self.zoomGeneration) blocked=\(self.automaticZoomBlocked) enabled=\(self.guidanceSnapshot().enabled)")
            guard generation == self.zoomGeneration else {
                ShotFramingDiagnostics.log("ZOOM_REJECTED","reason=obsolete_generation shot=\(shotID)")
                return // Its cancellation already owns recovery; do not disturb a newer attempt.
            }
            guard !self.automaticZoomBlocked,
                  self.guidanceSnapshot().enabled, self.guidanceSnapshot().source == .iPhone else {
                ShotFramingDiagnostics.log("ZOOM_REJECTED","reason=stale_generation_override_or_ai_off shot=\(shotID)")
                let reason:FramingBlockReason = self.automaticZoomBlocked ? .manualControl : .interrupted
                self.analysisQueue.async {
                    guard self.framing.shotPlan?.id == shotID else { return }
                    if self.automaticShotArmed { self.framing.requestRecovery(reason:.interrupted,at:ProcessInfo.processInfo.systemUptime) }
                    else { self.framing.stop(reason:reason) }
                    self.shotCapture.invalidateVerification(); self.publishFraming()
                }
                return
            }
            self.rampShotID = shotID
            guard self.wantsToRun, self.captureCompletion == nil, let device = self.device,
                  GuidanceObservationPolicy.fresh(capturedAt:observedAt,evaluatedAt:ProcessInfo.processInfo.systemUptime),
                  ProcessInfo.processInfo.thermalState != .critical else {
                ShotFramingDiagnostics.log("ZOOM_REJECTED","reason=inactive_capture_stale_observation_or_thermal")
                self.abortAutomaticZoom(generation:generation,reason:ProcessInfo.processInfo.thermalState == .critical ? .thermal : !self.wantsToRun || self.captureCompletion != nil ? .inactive : .staleFrame); return
            }
            let upper = min(Double(device.maxAvailableVideoZoomFactor),Double(device.activeFormat.videoMaxZoomFactor))
            guard let factor = CameraZoomObservation.hardwareTarget(displayed:target,multiplier:Double(self.zoomMultiplier),
                    minimum:Double(device.minAvailableVideoZoomFactor),maximum:upper),
                  verificationOnly ? abs(factor/Double(device.videoZoomFactor)-1) <= 0.02 : factor > Double(device.videoZoomFactor)*1.01 else {
                ShotFramingDiagnostics.log("ZOOM_REJECTED","reason=device_factor_limit target=\(target) multiplier=\(self.zoomMultiplier) hardware=\(device.videoZoomFactor) max=\(upper)")
                self.abortAutomaticZoom(generation:generation,reason:.quality); return
            }
            self.rampStartZoom = Double(device.videoZoomFactor); self.rampTargetZoom = factor; self.rampStage = 0; self.rampHolding = verificationOnly; self.rampPaused = false
            self.rampShotID = shotID; self.rampObservedTarget = false; self.lastMotorTraceTime = -.infinity
            self.zoomWatchdog.start(zoom:self.rampStartZoom,target:factor,at:ProcessInfo.processInfo.systemUptime)
            self.lastRampVerification = ProcessInfo.processInfo.systemUptime
            do {
                try device.lockForConfiguration()
                if !verificationOnly {
                    device.ramp(toVideoZoomFactor:CGFloat(factor),withRate:AutomaticZoomRampProfile.rate(stage:0,hardwareDistance:factor-self.rampStartZoom))
                }
                device.unlockForConfiguration()
                self.recordObservedZoom()
                ShotFramingDiagnostics.log("ZOOM_ACCEPTED","shot=\(shotID) verificationOnly=\(verificationOnly) lockSucceeded=YES rampStarted=\(device.isRampingVideoZoom) device=\(device.localizedName) type=\(device.deviceType.rawValue) displayedTarget=\(target) nativeTarget=\(factor) hardware=\(device.videoZoomFactor) multiplier=\(self.zoomMultiplier) nativeMinimum=\(device.minAvailableVideoZoomFactor) nativeMaximum=\(upper)")
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
        let abortedShotID = rampShotID
        ShotFramingDiagnostics.log("ZOOM_ABORT","reason=\(reason.rawValue) hardware=\(FramingTransitionTrace.number(device.map { Double($0.videoZoomFactor) })) target=\(rampTargetZoom)")
        cancelZoomRamp(reason:reason)
        analysisQueue.async {
            guard self.automaticShotArmed, self.autoFrameEnabled, self.guidanceEnabled, self.analysisSource == .iPhone else { return }
            guard !self.framing.shotVerified, abortedShotID == nil || self.framing.shotPlan?.id == abortedShotID else { return }
            self.framing.requestRecovery(reason:reason,at:ProcessInfo.processInfo.systemUptime)
            self.shotCapture.invalidateVerification(); self.publishFraming()
            self.automaticGuidance.reset()
        }
    }
    private func observeAutomaticZoom(generation: Int, deadline: TimeInterval) {
        guard generation == zoomGeneration, let device else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard !automaticZoomBlocked, guidanceSnapshot().enabled, guidanceSnapshot().source == .iPhone,
              now < deadline, now-lastRampVerification <= GuidanceObservationPolicy.maximumAge+0.6, ProcessInfo.processInfo.thermalState != .critical,
              rampTargetZoom <= min(Double(device.maxAvailableVideoZoomFactor),Double(device.activeFormat.videoMaxZoomFactor)) else {
            ShotFramingDiagnostics.log("ZOOM_ABORT","reason=watchdog_device_or_thermal_gate age=\(now-lastRampVerification) hardware=\(device.videoZoomFactor) target=\(rampTargetZoom)")
            abortAutomaticZoom(generation:generation,reason:now >= deadline ? .deadline : ProcessInfo.processInfo.thermalState == .critical ? .thermal : .staleFrame); return
        }
        let hardwareZoom = Double(device.videoZoomFactor)
        let actual = hardwareZoom/Double(zoomMultiplier)
        let hadMovement = zoomWatchdog.observedMovement
        if let failure = zoomWatchdog.failure(actual:hardwareZoom,at:now,paused:rampPaused || rampHolding) {
            abortAutomaticZoom(generation:generation,reason:failure); return
        }
        recordObservedZoom()
        if !hadMovement && zoomWatchdog.observedMovement {
            ShotFramingDiagnostics.log("MOTOR_MOVED","shot=\(rampShotID ?? "unknown") initialNative=\(rampStartZoom) actualNative=\(hardwareZoom) actualZoom=\(actual) targetNative=\(rampTargetZoom)")
        }
        if !rampObservedTarget, !device.isRampingVideoZoom, abs(hardwareZoom/rampTargetZoom-1) <= 0.02 {
            rampObservedTarget = true
            ShotFramingDiagnostics.log("MOTOR_AT_TARGET","shot=\(rampShotID ?? "unknown") actualNative=\(hardwareZoom) actualZoom=\(actual) ramping=NO compositionVerification=separate")
        }
        if now-lastMotorTraceTime >= 0.25 {
            lastMotorTraceTime = now
            ShotFramingDiagnostics.log("MOTOR_SAMPLE","shot=\(rampShotID ?? "unknown") actualNative=\(hardwareZoom) actualZoom=\(actual) targetNative=\(rampTargetZoom) ramping=\(device.isRampingVideoZoom) movementObserved=\(zoomWatchdog.observedMovement) paused=\(rampPaused) holding=\(rampHolding)")
        }
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
        let ticket = resultGate.begin(observedAt:now)
        let aspect = Double(CVPixelBufferGetWidth(native)) / Double(CVPixelBufferGetHeight(native))
        queue.async {
            self.recordObservedZoom()
            self.zoomObservationLock.lock(); let frameZoom = self.observedPhoneZoom; self.zoomObservationLock.unlock()
            self.analysisQueue.async {
                defer { self.videoQueue.async { self.previewScheduler.finish() } }
                guard self.guidanceSnapshot() == snapshot, self.analysisSource == .iPhone else { return }
                self.processFrame(copy, sourceAspect: aspect, observedAt: now, capturedZoom:frameZoom,ticket:ticket)
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

    private func processFrame(_ fullBuffer: CVPixelBuffer, sourceAspect: Double? = nil, observedAt: TimeInterval? = nil, capturedZoom:CameraZoomObservation? = nil,ticket:GuidanceResultGate.Ticket) {
        guard !analysisPaused, !interfacePaused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let observationTime = observedAt ?? now
        let snapshot = guidanceSnapshot()
        guard snapshot.source == analysisSource, resultGate.isCurrent(ticket) else { return }
        activeAnalysisTicket = ticket; activeAnalysisSnapshot = snapshot
        defer { activeAnalysisTicket = nil; activeAnalysisSnapshot = nil }
        if analysisSource == .iPhone { framing.expireReadiness(at:observationTime) }
        guard GuidanceObservationPolicy.fresh(capturedAt:observationTime,evaluatedAt:now) else {
            discardStaleGuidance(snapshot,observedAt:observationTime); return
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
        var zooming = framing.phase.isAutoFraming
        let deviceMoving = analysisSource == .iPhone && motion.deviceMotion.map {
            !CameraStability.isStable(rotation: ($0.rotationRate.x, $0.rotationRate.y, $0.rotationRate.z),
                                      acceleration: ($0.userAcceleration.x, $0.userAcceleration.y, $0.userAcceleration.z))
        } == true
        let rapidMovement = analysisSource == .iPhone && motion.deviceMotion.map {
            !CameraStability.permitsDetection(rotation: ($0.rotationRate.x, $0.rotationRate.y, $0.rotationRate.z),
                                             acceleration: ($0.userAcceleration.x, $0.userAcceleration.y, $0.userAcceleration.z))
        } == true
        if analysisSource == .iPhone, framing.shotPlan != nil, let native = latestNativeBounds, abs(analysisZoom - latestBoundsZoom) > 0.015 {
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
        let keepFramedSubject = analysisSource == .iPhone && latestNativeBounds != nil
            && (cloudCompositionLock != nil || framing.shotPlan != nil && framing.phase.isPreparing
                || framing.phase == .aligning || framing.phase == .settling || zooming || framing.phase == .framed
                || (subjectAutofocus.identity != nil && subjectAutofocus.identity == tracker.trackingReference))
        let inferenceStarted = ProcessInfo.processInfo.systemUptime
        if let object = tracker.observation(in: buffer, timestamp: now, visibleRegion: visibleRegion, detailBuffer: fullBuffer, trackingOnly: zooming || rapidMovement || ProcessInfo.processInfo.thermalState == .critical, retainSelection:keepFramedSubject,
                                            reacquisitionGrace:analysisSource == .iPhone && (cloudCompositionLock != nil || framing.shotPlan != nil || subjectAutofocus.identity != nil) ? 1.5 : 0,
                                            canContinue: { self.guidanceSnapshot() == snapshot }) {
            imageBounds = object.boundingBox
            latestNativeBounds = object.boundingBox; latestBoundsZoom = analysisZoom
            confidence = object.confidence
            let imagePoint = UnitPoint2D(x: object.boundingBox.midX, y: 1 - object.boundingBox.midY)
            let projection = PreviewProjection(imageAspect: imageAspect, previewAspect: previewAspect, mirrored: analysisFrontCamera)
            subject = projection.visiblePoint(imagePoint)
            bounds = projection.visibleVisionRect(object.boundingBox)
        }
        let inferenceMilliseconds = (ProcessInfo.processInfo.systemUptime-inferenceStarted)*1000
        // Preserve the last measured seed through a bounded pause, never display it
        // as a fresh observation. The director handles confidence/loss below.
        if imageBounds == nil, !zooming, !tracker.isRecovering { latestNativeBounds = nil }
        guard guidanceSnapshot() == snapshot, resultGate.isCurrent(ticket) else { return }
        if analysisSubjectReference != tracker.trackingReference {
            analysisSubjectReference = tracker.trackingReference
            framing.invalidateReadiness(at:ProcessInfo.processInfo.systemUptime)
            engine.reset(); automaticGuidance.reset(); autofocusRequests.invalidate(); boxSmoother.reset()
            subjectMeasurements = nil; subjectMeasurementLabel = nil; lastSubjectMeasurement = -.infinity; previousMotionSubject = nil
            readySceneContinuity.reset()
        }
        let evaluatedAt = ProcessInfo.processInfo.systemUptime
        guard GuidanceObservationPolicy.fresh(capturedAt:observationTime,evaluatedAt:evaluatedAt) else {
            discardStaleGuidance(snapshot,observedAt:observationTime); return
        }
        let motionData = analysisSource == .iPhone ? motion.deviceMotion : nil
        let motionMeasuredAt = ProcessInfo.processInfo.systemUptime
        let gravity = motionData?.gravity
        let framingMotion = motionData.map {
            FramingMotionMeasurement(rotation:sqrt($0.rotationRate.x*$0.rotationRate.x+$0.rotationRate.y*$0.rotationRate.y+$0.rotationRate.z*$0.rotationRate.z),
                acceleration:sqrt($0.userAcceleration.x*$0.userAcceleration.x+$0.userAcceleration.y*$0.userAcceleration.y+$0.userAcceleration.z*$0.userAcceleration.z),
                age:motionMeasuredAt-$0.timestamp)
        }
        let stable = framingMotion?.stable ?? (analysisSource == .sony)
        let framingMotionPermitted = framingMotion?.permitsFraming ?? (analysisSource == .sony)
        let captureStable = motionData.map {
            framingMotion?.usable == true && CameraStability.isStable(rotation:($0.rotationRate.x,$0.rotationRate.y,$0.rotationRate.z),
                acceleration:($0.userAcceleration.x,$0.userAcceleration.y,$0.userAcceleration.z))
        } ?? (analysisSource == .sony)
        var restartedVerification = false
        if analysisSource == .iPhone, automaticShotArmed, autoFrameEnabled, framing.phase.isRecovering {
            let recoveryStep = framing.advanceRecovery(bounds:bounds,label:tracker.label,trackingReference:tracker.trackingReference,
                confidence:confidence,zoom:analysisZoom,aspect:previewAspect,fresh:true,motionPermitted:framingMotionPermitted,timestamp:evaluatedAt)
            switch recoveryStep {
            case .rediscovered:
                clearCloudCompositionState()
                tracker.reset(); latestNativeBounds = nil; scenePlanner.reset(); directZoomPlan = nil
                shotCapture.cancel(); automaticGuidance.reset(); boxSmoother.reset(); previousMotionSubject = nil
                publishFraming()
                return // Never select an old observation as the newly discovered subject.
            case .verifying:
                if let shot = framing.shotPlan {
                    restartedVerification = true
                    performAutomaticZoom(to:shot.targetZoom,generation:analysisZoomGeneration,observedAt:observationTime,shotID:shot.id,verificationOnly:true)
                }
            case .aiming, .waiting: break
            }
            zooming = framing.phase.isAutoFraming
        }
        // When looking straight up/down, gravity cannot give a meaningful portrait roll.
        let roll = gravity.map { hypot($0.x, $0.y) > 0.2 ? atan2($0.x, -$0.y) * 180 / .pi : 0 } ?? 0
        var relativeMotion:Double?
        if analysisSource == .iPhone, framingMotion?.usable == true, !zooming, now >= manualInferenceResumeAfter, confidence >= 0.65, let bounds {
            if let old = previousMotionSubject, old.label == tracker.label, observationTime > old.time,
               observationTime-old.time < 1.5, abs(analysisZoom/old.zoom-1) < 0.02 {
                relativeMotion = hypot(Double(bounds.midX-old.bounds.midX),Double(bounds.midY-old.bounds.midY))/(observationTime-old.time)
            }
            previousMotionSubject = (bounds,tracker.label,observationTime,analysisZoom)
        } else { previousMotionSubject = nil }
        precisionLock.lock(); precisionContext.relativeSubjectMotion = relativeMotion; precisionContext.subjectMotionTimestamp = relativeMotion == nil ? nil : evaluatedAt; precisionLock.unlock()
        let planning = compositionPlanning && mode == .automatic && cloudCompositionLock == nil
        let projection = PreviewProjection(imageAspect:imageAspect,previewAspect:previewAspect,mirrored:analysisFrontCamera)
        if (planning || autoFrameEnabled || coachEnabled || pendingCloudCapture != nil || cloudCompositionLock != nil || photographyIntent == .landscape || photographyIntent == .architecture), !zooming, !rapidMovement, evaluatedAt-lastCompositionEvidence >= 0.8 {
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
        let motorEnabledForIntent = autoFrameEnabled && photographyIntent.permitsZoom && (photographyIntent != .pet || petFraming.permitsAutomaticZoom)
        let availableScales = motorEnabledForIntent ? FramingPlanner.availableScales(currentZoom:analysisZoom,maximumZoom:automaticZoomLimit,detailZoomLimit:detailZoomLimit,nativeStops:nativeZoomStops,maximumScale:photographyIntent.maximumCropScale,desiredScale:geometricScale) : [1]
        let freezeTighterPlan = framing.phase.isPreparing && framing.shotPlan?.requiresZoom == true
        let freezeShot = zooming || freezeTighterPlan || (framing.phase == .framed && framing.shotVerified)
        let observedLandscape = tracker.scene.map { $0.isLandscape && evaluatedAt >= $0.timestamp && evaluatedAt-$0.timestamp <= 6 } == true
        let landscapeIntent:PhotographyIntent = photographyIntent == .auto && observedLandscape && ![SubjectCategory.person,.face,.pet].contains(SubjectCategory.classified(tracker.label)) ? .landscape : photographyIntent
        updateCloudCompositionEvidence(bounds:bounds,confidence:Double(confidence),observedAt:observationTime,roll:roll,rollReliable:gravity.map { hypot($0.x,$0.y) > 0.2 } ?? false,snapshot:snapshot,at:evaluatedAt)
        zooming = framing.phase.isAutoFraming
        let plannedScene = planning && cloudCompositionLock == nil ? scenePlanner.update(subject:bounds,confidence:confidence,label:tracker.label,evidence:compositionEvidence,
            others:contextSubjects,enclosingFrames:frames,timestamp:evaluatedAt,
            maximumScale:analysisSource == .iPhone && motorEnabledForIntent ? max(1,automaticZoomLimit/max(0.01,analysisZoom)) : 1,
            freeze:freezeShot,intent:landscapeIntent,availableScales:availableScales,anatomy:observedAnatomy) : nil
        let plan: SceneCompositionPlan?
        if let locked = cloudCompositionLock { plan = locked.plan(at:evaluatedAt,zoom:analysisZoom) }
        else if planning { plan = plannedScene }
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
        if analysisSource == .iPhone, automaticShotArmed, autoFrameEnabled, !zooming, evaluatedAt >= analysisManualZoomUntil,
           let bounds, framing.phase.isPreparing {
            if let selected = framing.shotPlan, let reference = selected.trackingReference,
               tracker.trackingReference != reference, !tracker.isRecovering {
                framing.requestRecovery(reason:.tracking,at:evaluatedAt); shotCapture.invalidateVerification()
            } else if framing.shotPlan?.requiresZoom != true, let plan {
                let context = plan.selected.protectedContext ?? (SceneCompositionPlanner.distinctSubjects(contextSubjects,selected:bounds).map(\.bounds)
                    + frames.filter { $0.contains(bounds) })
                if let selected = AutomaticShotPlan.propose(bounds:bounds,label:tracker.label,confidence:confidence,
                    trackingReference:tracker.trackingReference,composition:plan,currentZoom:analysisZoom,
                    maximumZoom:automaticZoomLimit,detailLimit:detailZoomLimit,nativeStops:nativeZoomStops,
                    regions:context,anatomy:zoomAnatomy,projection:projection) {
                    if framing.selectShot(selected), selected.requiresZoom {
                        ShotFramingDiagnostics.log("SHOT_SELECTED","session=\(snapshot.revision) shot=\(selected.id) tracker=\(tracker.trackingReference ?? "unknown") currentZoom=\(analysisZoom) targetZoom=\(selected.targetZoom) desiredScale=\(selected.desiredScale) reason=\(selected.selectionReason)")
                    }
                }
            }
        }
        if framing.shotPlan?.sceneAnchor == true, plan?.selected.sceneAnchor == nil, !zooming {
            framing.reset(enabled:automaticShotArmed && guidanceEnabled && analysisSource == .iPhone)
        }
        let zoomFacts = CompositionAssessment.evaluate(bounds:bounds,confidence:Double(confidence),label:tracker.label,intent:photographyIntent,
            stable:stable,exposure:subjectMeasurements,evidence:compositionEvidence,others:contextSubjects,anatomy:zoomAnatomy,timestamp:evaluatedAt,petStyle:appliedPetStyle)
        let execution = FramingExecutionContext(selected:framing.shotPlan,candidate:plan)
        let framingSettingsAllow = !cloudRecovering && (cloudCompositionLock == nil || (plan?.permitsZoom == true && cloudCompositionLock?.manualZoomOverride != true)) && autoFrameEnabled && photographyIntent.permitsZoom && appliedPetStyle.permitsAutomaticZoom && mode != .thirds && evaluatedAt >= analysisManualZoomUntil
        let allowPlannedZoom = execution.permitsZoom(settingsAllow:framingSettingsAllow,cropPermitted:zoomFacts.permitsAutomaticCrop)
        if analysisSource == .iPhone, automaticShotArmed, autoFrameEnabled, framingSettingsAllow, !zooming, zoomFacts.permitsAutomaticCrop,
           framing.verifyExistingTargetIfAligned(bounds:bounds,label:tracker.label,confidence:confidence,zoom:analysisZoom,aspect:previewAspect,
                trackingReference:tracker.trackingReference,fresh:true,motionPermitted:framingMotionPermitted), let shot = framing.shotPlan {
            zooming = true; restartedVerification = true
            performAutomaticZoom(to:shot.targetZoom,generation:analysisZoomGeneration,observedAt:observationTime,shotID:shot.id,verificationOnly:true)
        }
        if zooming, framing.phase.isAutoFraming, !restartedVerification {
            zoomObservationLock.lock(); let liveCamera = observedPhoneZoom; zoomObservationLock.unlock()
            let verificationTime = ProcessInfo.processInfo.systemUptime
            let fresh = GuidanceObservationPolicy.fresh(capturedAt:observationTime,evaluatedAt:verificationTime)
            let pairedCameraFresh = capturedZoom?.matchesFrame(capturedAt:observationTime,evaluatedAt:verificationTime) ?? false
            let currentRegions: [CGRect] = [] // Frozen head/joints are reprojected inside the shot plan.
            let progress = framing.verifyShot(bounds:bounds,label:tracker.label,confidence:confidence,zoom:analysisZoom,
                stable:framingMotionPermitted,fresh:fresh,timestamp:verificationTime,previewAspect:previewAspect,regions:currentRegions,
                cameraRamping:(capturedZoom?.ramping ?? true) || liveCamera.ramping,
                cameraFresh:pairedCameraFresh && liveCamera.fresh(at:verificationTime),cropPermitted:zoomFacts.permitsAutomaticCrop,
                captureStable:captureStable,trackingReference:tracker.trackingReference,captureHoldDuration:holdDuration,liveZoom:liveCamera.displayedFactor)
            let generation = analysisZoomGeneration
            switch progress {
            case .continuing:
                queue.async { if self.zoomGeneration == generation { self.lastRampVerification = evaluatedAt } }
            case .recovering:
                let reason = framing.blockReason ?? .tracking
                queue.async { if self.zoomGeneration == generation { self.cancelZoomRamp(reason:reason) } }
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
                ShotFramingDiagnostics.log("ZOOM_COMPLETE","shot=\(framing.shotPlan?.id ?? "none") displayed=\(analysisZoom) native=\(FramingTransitionTrace.number(capturedZoom?.hardwareFactor)) ramping=\(capturedZoom?.ramping ?? true) bounds=\(String(describing:bounds))")
                queue.async {
                    guard self.zoomGeneration == generation else { return }
                    self.cancelZoomRamp(preserveVerifiedShot:true)
                }
                engine.reset(); automaticGuidance.reset(); publishFraming()
            case .cancel:
                let reason = framing.blockReason ?? .unsafeCrop
                framing.requestRecovery(reason:reason,at:evaluatedAt); shotCapture.invalidateVerification()
                queue.async { self.abortAutomaticZoom(generation:generation,reason:reason) }
            }
        }
        if analysisSource == .iPhone {
            framing.revalidateCompletedShot(bounds:bounds,label:tracker.label,confidence:confidence,zoom:analysisZoom,aspect:previewAspect,
                timestamp:evaluatedAt,trackingReference:tracker.trackingReference)
        }
        let outdoorReady = OutdoorCompositionPlanner.permitsReady(plan:plan,evidence:compositionEvidence,at:evaluatedAt,motionPermitted:framingMotionPermitted)
        let cloudObjectTarget = cloudCompositionLock.flatMap { $0.isWholeScene ? nil : $0.target }
        let currentFrameEligible = cloudObjectTarget.map { ShotReadiness.measuredManualFrame(mode:.thirds,bounds:bounds,target:$0,roll:roll,aspect:previewAspect,assessment:zoomFacts,stable:captureStable) } ?? (ShotReadiness.measuredCurrentFrame(plan:plan,assessment:zoomFacts,label:tracker.label,timestamp:evaluatedAt,stable:captureStable)
            || ShotReadiness.measuredManualFrame(mode:mode,bounds:bounds,target:manualTarget,roll:roll,aspect:previewAspect,assessment:zoomFacts,stable:captureStable))
        let retainCurrentFrame = cloudObjectTarget.map { ShotReadiness.measuredManualFrame(mode:.thirds,bounds:bounds,target:$0,roll:roll,aspect:previewAspect,assessment:zoomFacts,stable:stable,retaining:true) } ?? (ShotReadiness.measuredCurrentFrame(plan:plan,assessment:zoomFacts,label:tracker.label,timestamp:evaluatedAt,stable:stable,retaining:true)
            || ShotReadiness.measuredManualFrame(mode:mode,bounds:bounds,target:manualTarget,roll:roll,aspect:previewAspect,assessment:zoomFacts,stable:stable,retaining:true))
        if analysisSource == .iPhone {
            let scene = tracker.scene
            if bounds == nil || plan?.selected.sceneAnchor != nil {
                let category = scene?.isArchitecture == true ? "architecture" : scene?.isLandscape == true ? "landscape" : "scene"
                let sceneIdentity = "\(snapshot.revision):\(category):\(plan?.selected.technique.rawValue ?? "unplanned")"
                if readySceneContinuity.changed(evidence:compositionEvidence,identity:sceneIdentity,at:evaluatedAt) {
                    framing.invalidateReadiness(at:evaluatedAt); engine.reset(); automaticGuidance.reset()
                }
            } else { readySceneContinuity.reset() }
            let sceneEligible = outdoorReady || ShotReadiness.measuredSceneFrame(scene:scene,evidence:compositionEvidence,measurements:sceneMeasurements,
                stable:captureStable,timestamp:evaluatedAt)
            if (bounds == nil || plan?.selected.sceneAnchor != nil), let evidence = compositionEvidence, sceneEligible, framing.shotPlan == nil {
                framing.selectShot(AutomaticShotPlan.scene(label:scene?.label ?? "Scene",evidence:evidence,zoom:analysisZoom,projection:projection))
            }
            framing.confirmCurrentFrame(eligible:currentFrameEligible || ((bounds == nil || plan?.selected.sceneAnchor != nil) && framing.shotPlan?.sceneAnchor == true && sceneEligible),timestamp:observationTime,holdDuration:plan?.selected.sceneAnchor != nil ? min(0.7,holdDuration) : holdDuration,
                retaining:retainCurrentFrame || ((bounds == nil || plan?.selected.sceneAnchor != nil) && framing.shotPlan?.sceneAnchor == true && sceneEligible),
                identity:"\(snapshot.revision):\(tracker.trackingReference ?? "scene"):\(mode.rawValue)")
        }
        let preparingZoom = automaticShotArmed && autoFrameEnabled && analysisSource == .iPhone && framing.phase.isPreparing && !framing.phase.isRecovering && !zooming && execution.requiresZoom
        let keepUnplannedFrame = mode == .automatic && !planning && plan == nil
        let selectedShot = framing.shotPlan
        let executionScale = bounds.flatMap { box in selectedShot.map { $0.scaleForCurrentBounds(box) } } ?? plan?.selected.zoomScale
        let aimingTarget = bounds.flatMap { box in selectedShot.map { $0.aimingTarget(bounds:box) } } ?? plan?.zoomAlignmentTarget
        let finalTarget = selectedShot?.desiredPosition ?? plan?.target
        let layoutTarget = (preparingZoom ? aimingTarget : finalTarget) ?? (keepUnplannedFrame ? subject : nil) ?? (mode == .centered ? UnitPoint2D(x:0.5,y:0.5) : manualTarget)
        let observationFresh = GuidanceObservationPolicy.fresh(capturedAt:observationTime,evaluatedAt:ProcessInfo.processInfo.systemUptime)
        let reliableSelectedTrack = confidence >= 0.65 && bounds != nil && selectedShot != nil
            && (selectedShot?.trackingReference == nil || selectedShot?.trackingReference == tracker.trackingReference)
        let zoomMotionAllowed = GuidanceObservationPolicy.permitsZoom(stable:framingMotionPermitted,relativeSpeed:relativeMotion,
            fresh:observationFresh,trackedSubject:reliableSelectedTrack)
        let zoomBlock: FramingBlockReason?
        if !observationFresh { zoomBlock = .staleFrame }
        else if selectedShot == nil { zoomBlock = .missingPlan }
        else if analysisSource == .iPhone, framingMotion?.usable != true { zoomBlock = .motionUnavailable }
        else if !framingMotionPermitted { zoomBlock = .cameraMotion }
        else if !zoomMotionAllowed { zoomBlock = .subjectMotion }
        else if !allowPlannedZoom { zoomBlock = .quality }
        else { zoomBlock = nil }
        // Manual layouts and disabled Auto Zoom use measured verification alone.
        if analysisSource == .iPhone, automaticShotArmed, framingSettingsAllow, framing.phase.isPreparing, !zooming, selectedShot == nil {
            framing.noteBlock(.missingPlan,at:evaluatedAt)
        }
        // Whole-scene plans have no object bounds: do not send them into the
        // object-loss recovery gate while their measured wide-frame hold runs.
        // Manual zoom suspends this motor path, never the analysis/UI pipeline.
        if analysisSource == .iPhone, automaticShotArmed, framingSettingsAllow, evaluatedAt >= analysisManualZoomUntil,
           plan?.selected.sceneAnchor == nil, framing.shotPlan?.sceneAnchor != true,
           let targetZoom = framing.update(bounds: bounds, confidence: confidence, roll: roll, timestamp: evaluatedAt,
                                            currentZoom: analysisZoom, maximumZoom: automaticZoomLimit,
                                            detailZoomLimit: detailZoomLimit, nativeStops: nativeZoomStops, deviceStable:zoomMotionAllowed, holdDuration:holdDuration, previewAspect:previewAspect,
                                            alignmentTarget:layoutTarget,allowZoom:allowPlannedZoom,plannedScale:executionScale,zoomDestination:preparingZoom ? finalTarget : nil,
                                            requiresShotPlan:true,blockedBy:zoomBlock,startConfirmationDuration:0.2), imageBounds != nil {
            if let bounds, let selected = framing.shotPlan,
               selected.trackingReference == nil || selected.trackingReference == tracker.trackingReference,
               let shot = selected.prepared(bounds:bounds,zoom:analysisZoom,detailLimit:detailZoomLimit,nativeStops:nativeZoomStops,
                    regions:selected.trackedProtectedRegions(bounds:bounds),anatomy:zoomAnatomy,aspect:previewAspect,allowSmallCorrection:true),
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
                framing.requestRecovery(reason:.unsafeCrop,at:evaluatedAt)
            }
        }
        if analysisSource == .iPhone, framing.phase.isRecovering {
            shotCapture.invalidateVerification()
            let generation = analysisZoomGeneration
            let reason = framing.blockReason ?? .interrupted
            queue.async {
                if self.zoomGeneration == generation, self.rampStage >= 0 { self.cancelZoomRamp(reason:reason) }
            }
        }
        if analysisSource == .iPhone {
            shotCapture.observe(plan:framing.shotPlan,verified:framing.shotVerified,bounds:bounds,label:tracker.label,
                confidence:confidence,zoom:analysisZoom,stable:captureStable,timestamp:evaluatedAt,aspect:previewAspect)
            updateSubjectAutofocus(buffer:buffer,imageBounds:imageBounds,previewBounds:bounds,confidence:confidence,
                projection:projection,observedAt:observationTime,snapshot:snapshot,
                allowHeadInference:!framing.phase.isAutoFraming && !rapidMovement)
        }
        let tolerance = autoFrameEnabled && analysisSource == .iPhone && framing.phase.isPreparing ? FramingPlanner.alignmentTolerance(plannedScale:executionScale,destination:preparingZoom ? finalTarget : nil) : 0.065
        var result = engine.update(subject: subject, rollDegrees: roll, mode: mode, timestamp: evaluatedAt,
                                   preferredTarget: layoutTarget, previewAspect: previewAspect,alignmentTolerance:tolerance,acceptCurrentFrame:plan?.selected.isCurrentFrame == true || keepUnplannedFrame)
        let analysisReadingBounds = bounds
        result.subjectBounds = boxSmoother.update(bounds)
        result.guidanceBounds = bounds
        result.subjectConfidence = confidence
        result.sceneFrameVerified = framing.currentFrameVerified && framing.shotPlan?.sceneAnchor == true
        if result.sceneFrameVerified { result.state = .ready }
        result.mirrored = analysisSource == .iPhone && analysisFrontCamera
        if let selected = framing.shotPlan, let bounds {
            result.targetCompositionRect = selected.currentTargetRectangle(bounds:bounds,zoom:analysisZoom)
            result.plannedSubjectBounds = selected.desiredBounds
            result.shotPlanID = selected.id
            result.shotStatus = framing.directorState(hasPlan:true)
        }
        let reliable = gravity.map { hypot($0.x,$0.y) > 0.2 } ?? false
        if analysisSource == .iPhone && motionData == nil && plan?.selected.sceneAnchor == nil && (result.state == .ready || result.state == .settling) {
            result.state = .adjusting
            result.title = "Level unavailable. Frame manually"
        }
        if !captureStable && !outdoorReady && (!(framing.currentFrameVerified || framing.shotVerified) || !stable) && result.state == .ready { result.state = .settling }
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
        guard GuidanceObservationPolicy.fresh(capturedAt:observationTime,evaluatedAt:decisionStarted) else { discardStaleGuidance(snapshot,observedAt:observationTime); return }
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
            manualComposition:mode != .automatic || cloudObjectTarget != nil,anatomy:observedScene.anatomy,others:contextSubjects,observedScene:observedScene,shotVerified:framing.shotVerified,requireShotCompletion:analysisSource == .iPhone,currentFrameVerified:framing.currentFrameVerified,framingInstruction:analysisSource == .iPhone && evaluatedAt >= analysisManualZoomUntil ? framing.progressInstruction : nil,continuousFraming:analysisSource == .iPhone)
        #if DEBUG || FOCAL_EVALUATION
        if analysisSource == .iPhone {
            let state = framing.directorState(hasPlan:framing.shotPlan != nil || plan != nil)
            let shot = framing.shotPlan
            zoomObservationLock.lock(); let live = observedPhoneZoom; zoomObservationLock.unlock()
            let traceTime = ProcessInfo.processInfo.systemUptime
            let n = FramingTransitionTrace.number, flag = FramingTransitionTrace.flag
            let error = bounds.flatMap { box in shot.map { $0.error(bounds:box,zoom:analysisZoom,aspect:previewAspect) } }
            let aimingError = bounds.map { hypot(Double($0.midX)-layoutTarget.x,(Double($0.midY)-layoutTarget.y)/previewAspect) }
            let aligned = aimingError.map { $0 <= tolerance } ?? false
            var values = [String:String]()
            let reason:String
            if framing.shotVerified { reason = "verified_actual_zoom_and_geometry" }
            else if framing.currentFrameVerified { reason = "measured_current_frame_no_zoom_needed" }
            else if !automaticShotArmed { reason = "manual_override_or_disabled" }
            else if shot == nil { reason = "missing_selected_shot" }
            else if shot?.requiresZoom != true { reason = "verifying_existing_frame_no_zoom_needed" }
            else if !allowPlannedZoom { reason = "crop_or_settings_gate" }
            else if !zoomMotionAllowed { reason = "motion_or_tracking_gate" }
            else if !aligned && !framing.phase.isAutoFraming { reason = "aiming" }
            else if framing.phase == .settling { reason = "brief_alignment_confirmation" }
            else if !captureStable && framing.phase == .verifying { reason = "capture_stability" }
            else { reason = "motor_or_geometry_verification" }
            values["blockingReason"] = framing.blockReason?.rawValue ?? reason
            values["requirements"] = "selected shot; same track/confidence>=0.65; fresh frame; safe crop; aim<=tolerance; gross-motion filter. No prezoom stability dwell. READY additionally needs actual target, stopped motor, geometry and capture hold."
            values["retryCount"] = String(framing.retryCount)
            values["retryAt"] = n(framing.retryAt)
            values["framingMotionPermitted"] = flag(framingMotionPermitted)
            values["candidatePresent"] = flag(plan != nil)
            values["candidateMatchesSelected"] = flag(execution.candidateMatchesSelected)
            values["currentZoom"] = n(analysisZoom)
            values["actualLiveZoom"] = n(live.displayedFactor)
            values["targetZoom"] = n(shot?.targetZoom)
            values["targetNative"] = n(shot.map { $0.targetZoom*live.multiplier })
            values["actualNative"] = n(live.hardwareFactor)
            values["liveCameraFresh"] = flag(live.fresh(at:traceTime))
            values["frameCameraPaired"] = flag(capturedZoom?.matchesFrame(capturedAt:observationTime,evaluatedAt:traceTime) ?? false)
            values["requiresZoom"] = flag(shot?.requiresZoom == true)
            values["desiredScale"] = n(shot?.desiredScale)
            values["remainingScale"] = n(executionScale)
            values["subjectWidth"] = n(bounds.map { Double($0.width) })
            values["subjectHeight"] = n(bounds.map { Double($0.height) })
            values["desiredWidth"] = n(shot.map { Double($0.desiredBounds.width) })
            values["desiredHeight"] = n(shot.map { Double($0.desiredBounds.height) })
            values["subjectArea"] = n(bounds.map { Double($0.width*$0.height) })
            values["desiredArea"] = n(shot.map { Double($0.desiredBounds.width*$0.desiredBounds.height) })
            values["automaticZoomLimit"] = n(automaticZoomLimit)
            values["detailZoomLimit"] = n(detailZoomLimit)
            values["selectionReason"] = shot?.selectionReason ?? "no selected shot"
            values["aimingError"] = n(aimingError); values["aimingTolerance"] = n(tolerance)
            values["aligned"] = flag(aligned); values["rollDegrees"] = n(roll)
            values["trackingConfidence"] = n(Double(confidence))
            values["tracker"] = tracker.trackingReference ?? "unknown"
            values["lockedTracker"] = shot?.trackingReference ?? "unknown"
            values["sameReliableTrack"] = flag(reliableSelectedTrack)
            values["handheldMotionAllowed"] = flag(stable)
            values["captureStable"] = flag(captureStable)
            values["rotationRadPerSec"] = n(framingMotion?.rotation)
            values["accelerationG"] = n(framingMotion?.acceleration)
            values["motionAgeSeconds"] = n(framingMotion?.age)
            values["relativeSubjectSpeed"] = n(relativeMotion)
            values["frameAgeSeconds"] = n(traceTime-observationTime)
            values["safeCrop"] = flag(zoomFacts.permitsAutomaticCrop)
            values["cropAssessmentReliable"] = flag(zoomFacts.assessmentReliable)
            values["touchesEdgeOrJoint"] = flag(zoomFacts.touchesEdge)
            values["visibleFraction"] = n(zoomFacts.visibleFraction)
            values["minimumMargin"] = n(zoomFacts.minimumMargin)
            values["headroom"] = n(zoomFacts.headroom)
            values["subjectBrightness"] = n(zoomFacts.exposure?.brightness)
            values["highlightFraction"] = n(zoomFacts.exposure?.highlightFraction)
            values["shadowFraction"] = n(zoomFacts.exposure?.shadowFraction)
            values["zoomPermitted"] = flag(automaticShotArmed && autoFrameEnabled && allowPlannedZoom && zoomMotionAllowed && aligned)
            values["motorRamping"] = flag(live.ramping)
            values["positionError"] = n(error?.position); values["widthError"] = n(error?.width)
            values["heightError"] = n(error?.height); values["zoomError"] = n(error?.zoom)
            values["captureHoldSeconds"] = n(holdDuration)
            values["confirmationProgress"] = n(framing.holdProgress)
            values["finalCompositionVerified"] = flag(framing.shotVerified || framing.currentFrameVerified)
            if let entry = directorTrace.record(sessionID:snapshot.revision,shotID:shot?.id,state:state,at:traceTime,values:values) {
                ShotFramingDiagnostics.log("STATE",entry)
            }
        }
        #endif
        let finished = ProcessInfo.processInfo.systemUptime
        guard guidanceSnapshot() == snapshot, resultGate.isCurrent(ticket) else { return }
        guard GuidanceObservationPolicy.fresh(capturedAt:observationTime,evaluatedAt:finished) else { discardStaleGuidance(snapshot,observedAt:observationTime); return }
        #if DEBUG || FOCAL_EVALUATION
        guidanceDiagnostics.record(scene:observedScene,plan:plan,message:message,previous:previousGuidance,memoryOutcome:automaticGuidance.memoryOutcome,phase:framing.phase,
            reasoning:automaticGuidance.reasoning,inferenceMS:inferenceMilliseconds,decisionMS:(finished-decisionStarted)*1000,finishedAt:finished)
        let timingReport = GuidancePerformanceReport(guidanceDiagnostics.timings,source:analysisSource.rawValue,thermalState:String(describing:ProcessInfo.processInfo.thermalState))
        publishAnalysis(snapshot) { self.guidancePerformance = timingReport }
        #endif
        let label = tracker.label
        if cloudRecovering {
            result.state = .searching; result.subject = nil; result.subjectBounds = nil; result.guidanceBounds = nil
        }
        let presentedMessage = cloudRecovering ? GuidanceMessage(kind:.framing,text:"Reacquiring the cloud-selected subject…") : message
        fulfillCloudCapture(fullBuffer,projection:projection,snapshot:snapshot)
        framing.recordReadyEvidence(at:observationTime)
        let phase = framing.phase
        let progress = framing.holdProgress
        publishAnalysis(snapshot,expires:true) { self.reading = result; self.subjectLabel = label; self.framingPhase = phase; self.framingHoldProgress = progress; self.levelReliable = reliable; self.guidance = presentedMessage; self.compositionPlan = plan }
    }

    // MARK: - Experimental, explicitly requested cloud composition
    func beginCloudScan() -> CloudScanTicket? {
        let current = guidanceSnapshot()
        guard current.enabled, current.source == .iPhone else { return nil }
        let snapshot = invalidateGuidanceResults()
        return .init(id:cloudScanGate.begin(),sessionRevision:snapshot.revision)
    }
    func captureCloudScan(ticket:CloudScanTicket) async throws -> CloudScanCapture {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.cloudScanGate.accepts(ticket.id) else { continuation.resume(throwing:CloudCompositionError.stale); return }
                    self.cancelZoomRamp()
                    self.analysisQueue.async {
                        let snapshot = self.guidanceSnapshot()
                        guard self.cloudScanGate.accepts(ticket.id), snapshot.revision == ticket.sessionRevision,
                              snapshot.enabled, self.guidanceEnabled, self.analysisSource == .iPhone, self.mode == .automatic,
                              !self.analysisPaused, !self.interfacePaused else { continuation.resume(throwing:CloudCompositionError.unsupportedSource); return }
                        if let old = self.pendingCloudCapture { old.completion(.failure(CloudCompositionError.stale)) }
                        self.clearCloudCompositionState()
                        self.pendingCloudCapture = (ticket,{ continuation.resume(with:$0) })
                        self.analysisQueue.asyncAfter(deadline:.now()+3) {
                            guard let pending = self.pendingCloudCapture, pending.ticket.id == ticket.id else { return }
                            self.pendingCloudCapture = nil
                            let current = self.cloudScanGate.finish(ticket.id)
                            pending.completion(.failure(current ? CloudCompositionError.unavailableFrame : .stale))
                        }
                    }
                }
            }
        },onCancel:{ self.cancelCloudScan(requestID:ticket.id) })
    }
    func registerCloudScanCancellation(requestID:UUID,action:@escaping @Sendable () -> Void) {
        cloudScanGate.registerCancellation(requestID,action:action)
    }
    func cancelCloudScan(requestID:UUID) {
        _ = cloudScanGate.finish(requestID)
        analysisQueue.async {
            guard let pending = self.pendingCloudCapture, pending.ticket.id == requestID else { return }
            self.pendingCloudCapture = nil; pending.completion(.failure(CloudCompositionError.cancelled))
        }
    }
    func unlockCloudComposition() {
        invalidateGuidanceResults(clearCloud:true)
    }
    func applyCloudComposition(_ result:CloudCompositionResult,capture:CloudScanCapture) async throws {
        try result.validate()
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            queue.async {
                guard self.cloudScanGate.accepts(capture.requestID) else { continuation.resume(throwing:CloudCompositionError.stale); return }
                self.cancelZoomRamp()
                let actualZoom = self.device.map { Double($0.videoZoomFactor/self.zoomMultiplier) }
                self.analysisQueue.async {
                    do {
                        guard self.cloudScanGate.accepts(capture.requestID), let live = self.latestCloudEvidence,
                              self.guidanceSnapshot().revision == capture.evidence.sessionRevision,
                              let actualZoom, abs(actualZoom/live.zoom-1) <= 0.02 else { throw CloudCompositionError.stale }
                        let now = ProcessInfo.processInfo.systemUptime
                        var held = try CloudCompositionMatcher.match(result,capture:capture,live:live,at:now)
                        if let bounds = live.bounds, let evidence = live.scene, !held.isWholeScene {
                            // Only measured local gain can admit a motor plan. Cloud
                            // confidence and zoom advice never become a gain score.
                            let scales = FramingPlanner.availableScales(currentZoom:live.zoom,maximumZoom:live.maximumZoom,
                                detailZoomLimit:self.detailZoomLimit,nativeStops:self.nativeZoomStops,maximumScale:live.maximumZoom/live.zoom)
                            let choices = SceneCompositionPlanner.compare(subject:bounds,evidence:evidence,others:[],enclosingFrames:[],
                                maximumScale:live.maximumZoom/live.zoom,intent:self.photographyIntent,availableScales:scales,label:live.label)
                            if let option = choices.first(where:{ $0.technique == result.recommendedCompositionTechnique.local && $0.target.distance(to:held.target) <= 0.04 && $0.zoomScale > 1.12 && $0.measuredImprovement >= IntentCompositionSearch.minimumImprovement && live.zoom*$0.zoomScale >= result.recommendedZoomRange.minimum && live.zoom*$0.zoomScale <= result.recommendedZoomRange.maximum }) {
                                var candidate = SceneCompositionPlan(selected:option,alternatives:[],subjectLabel:live.label,timestamp:now,id:held.id)
                                candidate.selected.target = held.target
                                let projection = PreviewProjection(imageAspect:self.imageAspect,previewAspect:self.previewAspect,mirrored:self.analysisFrontCamera)
                                if AutomaticShotPlan.propose(bounds:bounds,label:live.label,confidence:Float(live.confidence),trackingReference:live.trackingReference,
                                    composition:candidate,currentZoom:live.zoom,maximumZoom:live.maximumZoom,detailLimit:self.detailZoomLimit,nativeStops:self.nativeZoomStops,
                                    regions:self.tracker.compositionSubjects(at:now).map { projection.visibleVisionRect($0.bounds) },anatomy:self.tracker.anatomy(for:self.latestNativeBounds,projection:projection,at:now),projection:projection) != nil {
                                    held.useMeasuredMotorOption(candidate.selected)
                                }
                            }
                        }
                        guard self.cloudScanGate.finish(capture.requestID) else { throw CloudCompositionError.stale }
                        let snapshot = self.invalidateGuidanceResults()
                        self.framing.reset(enabled:self.automaticShotArmed && self.guidanceEnabled && self.analysisSource == .iPhone)
                        self.shotCapture.invalidateVerification(); self.engine.reset(); self.automaticGuidance.reset(); self.scenePlanner.reset(); self.directZoomPlan = nil
                        self.cloudCompositionLock = held; self.cloudRecovering = false
                        self.publishCloudCompositionStatus("Cloud plan locked: \(held.result.recommendedCompositionTechnique.local.rawValue)",snapshot:snapshot)
                        continuation.resume()
                    } catch { continuation.resume(throwing:error) }
                }
            }
        }
    }
    private func publishCloudCompositionStatus(_ text:String,snapshot:GuidanceActivation.Snapshot) {
        DispatchQueue.main.async { guard self.guidanceSnapshot() == snapshot else { return }; if self.cloudCompositionStatus != text { self.cloudCompositionStatus = text } }
    }
    private func clearCloudCompositionState(resetReadiness:Bool = true) {
        let hadLock = cloudCompositionLock != nil
        cloudCompositionLock = nil; cloudRecovering = false
        if let pending = pendingCloudCapture, !cloudScanGate.accepts(pending.ticket.id) {
            pendingCloudCapture = nil; pending.completion(.failure(CloudCompositionError.stale))
        }
        guard hadLock else { return }
        if resetReadiness {
            framing.reset(enabled:automaticShotArmed && guidanceEnabled && analysisSource == .iPhone)
            shotCapture.invalidateVerification(); engine.reset(); automaticGuidance.reset(); scenePlanner.reset(); directZoomPlan = nil
            queue.async { self.cancelZoomRamp() }
        }
        publishCloudCompositionStatus("Cloud lock ended; local composition guidance",snapshot:guidanceSnapshot())
    }
    private func updateCloudCompositionEvidence(bounds:CGRect?,confidence:Double,observedAt:TimeInterval,roll:Double,rollReliable:Bool,snapshot:GuidanceActivation.Snapshot,at time:TimeInterval) {
        guard analysisSource == .iPhone else { latestCloudEvidence = nil; return }
        let local = CloudLocalEvidence(observedAt:observedAt,sessionRevision:snapshot.revision,isIPhone:true,mode:mode,
            trackingReference:tracker.trackingReference,label:tracker.label,bounds:bounds,confidence:confidence,zoom:analysisZoom,
            minimumZoom:max(0.5,nativeZoomStops.min() ?? 1),maximumZoom:min(20,max(analysisZoom,min(automaticZoomLimit,detailZoomLimit))),
            previewAspect:previewAspect,scene:compositionEvidence,rollReliable:rollReliable,rollDegrees:roll,intent:photographyIntent)
        latestCloudEvidence = local
        guard var held = cloudCompositionLock else { cloudRecovering = false; return }
        switch held.observe(local,at:time) {
        case .invalid: clearCloudCompositionState()
        case .recovering:
            cloudCompositionLock = held; cloudRecovering = true; framing.invalidateReadiness(at:time)
            publishCloudCompositionStatus("Reacquiring the cloud-selected subject; no directional guidance",snapshot:snapshot)
        case .retained:
            cloudCompositionLock = held; cloudRecovering = false
            publishCloudCompositionStatus("Cloud plan locked: \(held.result.recommendedCompositionTechnique.local.rawValue)",snapshot:snapshot)
        }
    }
    private func fulfillCloudCapture(_ buffer:CVPixelBuffer,projection:PreviewProjection,snapshot:GuidanceActivation.Snapshot) {
        guard let pending = pendingCloudCapture else { return }
        pendingCloudCapture = nil
        guard cloudScanGate.accepts(pending.ticket.id), pending.ticket.sessionRevision == snapshot.revision,
              snapshot.source == .iPhone, let evidence = latestCloudEvidence,
              let jpeg = CloudFrameEncoder.encode(CIImage(cvPixelBuffer:buffer),projection:projection,context:imageContext),
              GuidanceObservationPolicy.fresh(capturedAt:evidence.observedAt,evaluatedAt:ProcessInfo.processInfo.systemUptime) else {
            pending.completion(.failure(CloudCompositionError.unavailableFrame)); return
        }
        pending.completion(.success(.init(requestID:pending.ticket.id,jpeg:jpeg,evidence:evidence)))
    }

    private func discardStaleGuidance(_ snapshot:GuidanceActivation.Snapshot,observedAt:TimeInterval? = nil) {
        guard snapshot.enabled, guidanceSnapshot() == snapshot, snapshot.source == analysisSource else { return }
        if let ticket = activeAnalysisTicket, !resultGate.isCurrent(ticket) { return }
        framing.invalidateReadiness(at:ProcessInfo.processInfo.systemUptime)
        let zooming = framing.phase.isAutoFraming
        let armed = automaticShotArmed && framing.phase.isPreparing && !zooming && autoFrameEnabled && analysisSource == .iPhone
        let time = ProcessInfo.processInfo.systemUptime
        ShotFramingDiagnostics.log("STALE_FRAME","session=\(snapshot.revision) shot=\(framing.shotPlan?.id ?? "none") state=\(framing.directorState(hasPlan:framing.shotPlan != nil).rawValue) requiredMaximumAge=\(GuidanceObservationPolicy.maximumAge) actualFrameAge=\(FramingTransitionTrace.number(observedAt.map { time-$0 }))")
        if zooming {
            let recovery = framing.recover(reason:.staleFrame,at:time)
            let generation = analysisZoomGeneration
            if recovery == .cancel { queue.async { self.abortAutomaticZoom(generation:generation,reason:.recoveryExpired) } }
            else { queue.async { if self.zoomGeneration == generation { self.cancelZoomRamp(reason:.staleFrame) } } }
        } else if armed { framing.noteBlock(.staleFrame,at:time) }
        automaticGuidance.reset(); engine.reset(); previousMotionSubject = nil
        #if DEBUG || FOCAL_EVALUATION
        guidanceDiagnostics.rejectStale()
        #endif
        publishAnalysis(snapshot,requiresFresh:false) {
            self.reading = CompositionReading(); self.guidance = .init(kind:snapshot.source == .iPhone ? .framing : .steady,text:FramingBlockReason.staleFrame.instruction)
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

    /// Reuse the actual preview layer's sensor mapping rather than assuming a
    /// portrait rotation/mirror transform. Layer geometry is read on main only.
    func attachAutofocusPreviewLayer(_ layer:AVCaptureVideoPreviewLayer) {
        guard autofocusPreviewLayer !== layer else { return }
        autofocusPreviewLayer = layer; autofocusRequests.invalidate()
        analysisQueue.async { self.subjectAutofocus.reset() }
    }
    private func resetSubjectAutofocus() { // Analysis queue.
        subjectAutofocus.reset()
        let revision = autofocusRequests.invalidate()
        queue.async { if self.autofocusRequests.accepts(revision) { self.restoreNormalSubjectFocus() } }
    }
    private func updateSubjectAutofocus(buffer:CVPixelBuffer,imageBounds:CGRect?,previewBounds:CGRect?,confidence:Float,
                                       projection:PreviewProjection,observedAt:TimeInterval,snapshot:GuidanceActivation.Snapshot,
                                       allowHeadInference:Bool) {
        let enabled = SubjectAutofocus.permitted(guidance:snapshot.enabled && guidanceEnabled,
            tracking:tracker.features.subjectTracking,iPhone:analysisSource == .iPhone,manualFocus:autofocusRequests.manuallyControlled)
        // Manual zoom disarms zoom, not the existing subject tracker or AF.
        // A retained plan has priority over any transient tracker challenger.
        let expected = framing.phase == .rediscovering ? nil : framing.shotPlan?.trackingReference ?? tracker.trackingReference
        var head: (region:CGRect,observedAt:TimeInterval)?
        if enabled, confidence >= 0.65, let expected, expected == tracker.trackingReference, let imageBounds {
            head = tracker.focusRegion(in:buffer,subject:imageBounds,identity:expected,projection:projection,
                observedAt:observedAt,allowInference:allowHeadInference,canContinue:{ self.guidanceSnapshot() == snapshot })
        }
        let time = ProcessInfo.processInfo.systemUptime
        guard guidanceSnapshot() == snapshot else { return }
        let previousIdentity = subjectAutofocus.identity
        guard let update = subjectAutofocus.update(enabled:enabled,selectedIdentity:expected,observedIdentity:tracker.trackingReference,
            bounds:previewBounds,confidence:confidence,head:head?.region,headObservedAt:head?.observedAt,
            observedAt:observedAt,now:time,zoom:analysisZoom) else { return }
        switch update {
        case .normal:
            let revision = autofocusRequests.invalidate()
            queue.async { if self.autofocusRequests.accepts(revision) { self.restoreNormalSubjectFocus() } }
        case .maintain(let identity,let evidence):
            queue.async {
                guard self.guidanceSnapshot() == snapshot, self.wantsToRun, !self.trackingFocusPaused, !self.autofocusRequests.manuallyControlled,
                      self.trackingFocusIdentity == identity else { return }
                self.lastTrackingFocusEvidence = max(self.lastTrackingFocusEvidence,evidence)
            }
        case .target(let target):
            let revision = autofocusRequests.invalidate()
            if previousIdentity != target.identity {
                ShotFramingDiagnostics.log("AF_TARGET_SELECTED","shot=\(framing.shotPlan?.id ?? "pending") tracker=\(target.identity) observedHead=\(target.usesObservedHead) zoom=\(target.zoom)")
            }
            DispatchQueue.main.async {
                guard self.autofocusRequests.accepts(revision), self.guidanceSnapshot() == snapshot,
                      let layer = self.autofocusPreviewLayer, layer.session === self.session, layer.connection != nil,
                      layer.bounds.width > 0, layer.bounds.height > 0,
                      GuidanceObservationPolicy.fresh(capturedAt:target.observedAt,evaluatedAt:ProcessInfo.processInfo.systemUptime) else { return }
                self.zoomObservationLock.lock(); let camera = self.observedPhoneZoom; self.zoomObservationLock.unlock()
                guard camera.fresh(at:ProcessInfo.processInfo.systemUptime), let point = target.point(atZoom:camera.displayedFactor) else { return }
                let devicePoint = layer.captureDevicePointConverted(fromLayerPoint:CGPoint(x:layer.bounds.minX+point.x*layer.bounds.width,
                    y:layer.bounds.minY+point.y*layer.bounds.height))
                self.queue.async { self.applySubjectFocus(target,point:devicePoint,convertedAtZoom:camera.displayedFactor,revision:revision,snapshot:snapshot) }
            }
        }
    }
    private func applySubjectFocus(_ target:SubjectFocusTarget,point:CGPoint,convertedAtZoom:Double,revision:Int,snapshot:GuidanceActivation.Snapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        guard autofocusRequests.accepts(revision), guidanceSnapshot() == snapshot, snapshot.enabled, snapshot.source == .iPhone,
              wantsToRun, !trackingFocusPaused, captureCompletion == nil, !autofocusRequests.manuallyControlled,
              manualState.permitsFocus(automatic:true), GuidanceObservationPolicy.fresh(capturedAt:target.observedAt,evaluatedAt:now),
              [point.x,point.y].allSatisfy({ $0.isFinite && (0...1).contains($0) }), let device,
              abs(Double(device.videoZoomFactor/zoomMultiplier)/convertedAtZoom-1) <= 0.06 else { return }
        guard device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) else {
            // Leave unsupported/fixed-focus hardware in its existing normal mode.
            return
        }
        lastTrackingFocusEvidence = target.observedAt
        let changedIdentity = trackingFocusIdentity != target.identity
        trackingFocusIdentity = target.identity
        ensureTrackingFocusWatchdog()
        guard now >= trackingFocusRetryAfter else { return }
        let old = device.focusPointOfInterest
        guard changedIdentity || device.focusMode != .continuousAutoFocus || hypot(old.x-point.x,old.y-point.y) >= 0.008 else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.focusPointOfInterest = point
            // Keep continuous AF active even while it is adjusting. Point of
            // interest is not lens distance; AVFoundation controls lens motion.
            if device.focusMode != .continuousAutoFocus { device.focusMode = .continuousAutoFocus }
            ShotFramingDiagnostics.log("AF_POINT_APPLIED","tracker=\(target.identity) x=\(point.x) y=\(point.y) observedHead=\(target.usesObservedHead) adjusting=\(device.isAdjustingFocus) actualLensPosition=\(device.lensPosition) actualZoom=\(Double(device.videoZoomFactor/zoomMultiplier))")
        } catch {
            trackingFocusRetryAfter = now+1
            ShotFramingDiagnostics.log("AF_LOCK_FAILED","tracker=\(target.identity) error=\(error)")
        }
    }
    private func ensureTrackingFocusWatchdog() {
        guard !trackingFocusWatchdogRunning else { return }
        trackingFocusWatchdogRunning = true; trackingFocusWatchdogRevision += 1
        observeTrackingFocus(revision:trackingFocusWatchdogRevision)
    }
    private func observeTrackingFocus(revision:Int) {
        guard revision == trackingFocusWatchdogRevision, trackingFocusWatchdogRunning else { return }
        let snapshot = guidanceSnapshot()
        guard snapshot.enabled, snapshot.source == .iPhone, wantsToRun, !trackingFocusPaused,
              !autofocusRequests.manuallyControlled, ProcessInfo.processInfo.systemUptime-lastTrackingFocusEvidence <= 1.5 else {
            autofocusRequests.invalidate(); restoreNormalSubjectFocus(); return
        }
        queue.asyncAfter(deadline:.now()+0.3) { self.observeTrackingFocus(revision:revision) }
    }
    private func restoreNormalSubjectFocus() { // Camera queue, preserves manual focus/exposure.
        trackingFocusWatchdogRunning = false; trackingFocusWatchdogRevision += 1
        guard captureCompletion == nil else { pendingTrackingFocusRestore = true; return }
        pendingTrackingFocusRestore = false
        let wasTracking = trackingFocusIdentity != nil
        trackingFocusIdentity = nil; lastTrackingFocusEvidence = -.infinity; trackingFocusRetryAfter = 0
        guard wasTracking, let device, manualState.permitsFocus(automatic:true), device.isFocusModeSupported(.continuousAutoFocus) else { return }
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x:0.5,y:0.5) }
            if device.focusMode != .continuousAutoFocus { device.focusMode = .continuousAutoFocus }
            ShotFramingDiagnostics.log("AF_NORMAL","reason=disabled_lost_or_reset device=\(device.localizedName)")
        } catch { ShotFramingDiagnostics.log("AF_RESTORE_FAILED","error=\(error)") }
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
                do {
                    try self.pendingPhotoSelection?.validateDelivery(rawData:self.pendingRAW)
                    self.finishCapture(.success(CameraCapture(processed: processed, raw: self.pendingRAW,framing:self.pendingFramingCapture)))
                } catch { self.finishCapture(.failure(error)) }
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
            if self.pendingTrackingFocusRestore { self.restoreNormalSubjectFocus() }
            self.pendingCaptureID = nil
            self.pendingProcessed = nil; self.pendingRAW = nil; self.pendingError = nil; self.pendingFramingCapture = nil
            self.pendingPhotoSelection = nil
            guard let completion else { return }
            if self.configured { self.refreshPhotoCapabilities() }
            self.analysisQueue.async {
                self.analysisPaused = false
                if self.guidanceEnabled,self.analysisSource == .iPhone {
                    self.replanAfterManualFraming(); self.automaticGuidance.reset()
                    self.wantsScan = true
                }
            }
            DispatchQueue.main.async {
                self.isCapturing = false
                completion(result)
            }
        }
    }
}
