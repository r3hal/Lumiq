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
    @Published var errorMessage: String?

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.focal.camera", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "app.focal.vision", qos: .userInitiated)
    private let motion = CMMotionManager()
    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var configured = false
    private var wantsToRun = false // Camera queue only.
    private var engine = CompositionEngine() // Analysis queue only.
    private var mode: CompositionMode = .thirds
    private var guidanceEnabled = true
    private var lastAnalysis: TimeInterval = 0
    private let tracker = SubjectTracker()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var analysisBuffer: CVPixelBuffer?
    private var imageAspect = 0.75
    private var preferredTarget: UnitPoint2D?
    private var analysisPaused = false
    private var ignoreFramesUntil: TimeInterval = 0
    private var focusCandidate: UnitPoint2D?
    private var focusCandidateSince: TimeInterval = 0
    private var lastAutomaticFocus: TimeInterval = 0
    private var lastFocusedPoint: UnitPoint2D?
    private var zoomMultiplier: CGFloat = 1 // Capture zoom that corresponds to the wide lens's 1×.
    private var captureCompletion: ((Result<Data, Error>) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
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
            self?.errorMessage = "The camera stopped unexpectedly. Leave the Camera tab and return to try again."
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
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsToRun = false
            if self.session.isRunning { self.session.stopRunning() }
            self.motion.stopDeviceMotionUpdates()
            self.analysisQueue.async { self.resetAnalysis() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    func setMode(_ mode: CompositionMode) {
        analysisQueue.async { self.mode = mode; self.engine.reset() }
    }

    func setGuidance(_ enabled: Bool) {
        analysisQueue.async { self.guidanceEnabled = enabled; self.resetAnalysis() }
    }

    func setTarget(_ target: UnitPoint2D?) {
        analysisQueue.async { self.preferredTarget = target; self.engine.reset() }
    }

    func findSubject() {
        analysisQueue.async {
            self.resetAnalysis()
            DispatchQueue.main.async { self.subjectLabel = "Auto subject"; self.reading = CompositionReading() }
        }
    }

    func selectSubject(at previewPoint: UnitPoint2D) {
        analysisQueue.async {
            let projection = PreviewProjection(imageAspect: self.imageAspect, previewAspect: 0.75)
            self.tracker.select(at: projection.imagePoint(previewPoint))
            self.engine.reset()
            DispatchQueue.main.async { self.subjectLabel = "Your subject" }
        }
    }

    func setZoom(_ displayedZoom: Double) {
        queue.async {
            guard let device = self.device else { return }
            let upper = min(device.maxAvailableVideoZoomFactor, self.zoomMultiplier * 6)
            let factor = max(device.minAvailableVideoZoomFactor,
                             min(upper, CGFloat(displayedZoom) * self.zoomMultiplier))
            guard abs(device.videoZoomFactor - factor) > 0.015 else { return }
            do {
                try device.lockForConfiguration()
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = factor
                device.unlockForConfiguration()
                let value = Double(factor / self.zoomMultiplier)
                self.analysisQueue.async {
                    self.resetAnalysis()
                    self.ignoreFramesUntil = ProcessInfo.processInfo.systemUptime + 0.25
                }
                DispatchQueue.main.async { self.zoom = value; self.reading = CompositionReading() }
            } catch { DispatchQueue.main.async { self.errorMessage = "Zoom could not be changed. Please try again." } }
        }
    }

    private func resetAnalysis() {
        engine.reset()
        tracker.reset()
        focusCandidate = nil
        focusCandidateSince = 0
        lastFocusedPoint = nil
    }

    func focus(at point: CGPoint, continuous: Bool = false) {
        queue.async { [weak self] in
            guard let device = self?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    let focusMode: AVCaptureDevice.FocusMode = continuous ? .continuousAutoFocus : .autoFocus
                    if device.isFocusModeSupported(focusMode) { device.focusMode = focusMode }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
            } catch { /* Focus is best-effort; capture remains available. */ }
        }
    }

    func capture(completion: @escaping (Result<Data, Error>) -> Void) {
        guard isRunning, !isCapturing else {
            completion(.failure(CameraError.notRunning))
            return
        }
        isCapturing = true
        analysisQueue.async { self.analysisPaused = true }
        queue.async {
            guard self.session.isRunning else {
                DispatchQueue.main.async {
                    self.isCapturing = false
                    completion(.failure(CameraError.notRunning))
                }
                self.analysisQueue.async { self.analysisPaused = false }
                return
            }
            self.captureCompletion = completion
            let settings = self.photoSettings()
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func resumeIfWanted() {
        queue.async { if self.wantsToRun { self.configureAndStart() } }
    }

    private func photoSettings() -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        settings.photoQualityPrioritization = .quality
        settings.flashMode = .off
        return settings
    }

    private func configureAndStart() {
        guard wantsToRun else { return }
        do {
            if !configured {
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                session.sessionPreset = .photo
                let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera,
                                                         .builtInDualCamera, .builtInWideAngleCamera]
                guard let camera = types.compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) }).first else {
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
                videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)
                for connection in [videoOutput.connection(with: .video), output.connection(with: .video)] {
                    if connection?.isVideoRotationAngleSupported(90) == true { connection?.videoRotationAngle = 90 }
                }
                device = camera
                try camera.lockForConfiguration()
                if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
                if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
                if camera.isSmoothAutoFocusSupported { camera.isSmoothAutoFocusEnabled = true }
                let hasUltraWide = camera.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
                zoomMultiplier = hasUltraWide ? CGFloat(camera.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 2) : 1
                camera.videoZoomFactor = min(camera.maxAvailableVideoZoomFactor, max(camera.minAvailableVideoZoomFactor, zoomMultiplier))
                camera.unlockForConfiguration()
                let lower = Double(camera.minAvailableVideoZoomFactor / zoomMultiplier)
                let upper = min(6, Double(camera.maxAvailableVideoZoomFactor / zoomMultiplier))
                var stops = [lower, 1.0, 2.0]
                stops += camera.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue / Double(zoomMultiplier) }
                let available = Array(Set(stops.filter { $0 >= lower && $0 <= upper })).sorted()
                DispatchQueue.main.async {
                    self.minimumZoom = lower
                    self.maximumZoom = upper
                    self.zoomStops = available
                    self.zoom = Double(camera.videoZoomFactor / self.zoomMultiplier)
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
            DispatchQueue.main.async {
                self.access = .unavailable
                self.errorMessage = error.localizedDescription
            }
        }
    }

    enum CameraError: LocalizedError {
        case configuration, missingPhoto, notRunning
        var errorDescription: String? {
            switch self {
            case .configuration: return "This device could not configure a camera. You can still explore the demo."
            case .missingPhoto: return "The camera did not return a photo. Please try again."
            case .notRunning: return "The camera is paused. Return to the Camera tab and try again."
            }
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard guidanceEnabled, !analysisPaused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= ignoreFramesUntil, now - lastAnalysis > 0.12,
              let fullBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let buffer = smallAnalysisBuffer(from: fullBuffer) else { return }
        lastAnalysis = now
        var subject: UnitPoint2D?
        var bounds: CGRect?
        if let object = tracker.observation(in: buffer, timestamp: now) {
            let imagePoint = UnitPoint2D(x: object.boundingBox.midX, y: 1 - object.boundingBox.midY)
            let projection = PreviewProjection(imageAspect: imageAspect, previewAspect: 0.75)
            subject = projection.visiblePoint(imagePoint)
            let topLeftRect = CGRect(x: object.boundingBox.minX, y: 1 - object.boundingBox.maxY,
                                     width: object.boundingBox.width, height: object.boundingBox.height)
            bounds = projection.visibleRect(topLeftRect)
            updateAutomaticFocus(imagePoint, timestamp: now)
        }
        let gravity = motion.deviceMotion?.gravity
        // When looking straight up/down, gravity cannot give a meaningful portrait roll.
        let roll = gravity.map { hypot($0.x, $0.y) > 0.2 ? atan2($0.x, -$0.y) * 180 / .pi : 0 } ?? 0
        var result = engine.update(subject: subject, rollDegrees: roll, mode: mode, timestamp: now,
                                   preferredTarget: preferredTarget)
        result.subjectBounds = bounds
        let label = tracker.label
        DispatchQueue.main.async { self.reading = result; self.subjectLabel = label }
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
        guard !tracker.manual else { return } // Tap-to-focus keeps the user's exposure choice.
        if focusCandidate == nil || focusCandidate!.distance(to: point) > 0.08 {
            focusCandidate = point
            focusCandidateSince = timestamp
        }
        guard timestamp - focusCandidateSince > 0.6, timestamp - lastAutomaticFocus > 3 else { return }
        if let lastFocusedPoint, lastFocusedPoint.distance(to: point) < 0.12 { return }
        lastAutomaticFocus = timestamp
        lastFocusedPoint = point
        // Convert physically rotated portrait buffer coordinates to the sensor's landscape axes.
        focus(at: CGPoint(x: point.y, y: 1 - point.x), continuous: true)
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        // Some device failures occur before processing produces any image.
        if let error { finishCapture(.failure(error)) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let result: Result<Data, Error>
        if let error { result = .failure(error) }
        else if let data = photo.fileDataRepresentation() { result = .success(data) }
        else { result = .failure(CameraError.missingPhoto) }
        finishCapture(result)
    }

    private func finishCapture(_ result: Result<Data, Error>) {
        queue.async {
            let completion = self.captureCompletion
            self.captureCompletion = nil
            guard let completion else { return }
            self.analysisQueue.async { self.analysisPaused = false }
            DispatchQueue.main.async {
                self.isCapturing = false
                completion(result)
            }
        }
    }
}
