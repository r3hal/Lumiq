import SwiftUI
import UIKit

/// Framed-style one-tap AI shot:
/// tap ✦ → "Finding your shot…" → one AI pick (subject, tip, frame) →
/// a tracked target box → center it → automatic zoom → "Ready".
/// One decision per tap: nothing re-plans or flickers while you aim.
@MainActor final class AIShotModel: ObservableObject {
    enum Phase: Equatable {
        case idle, finding, aiming, zooming, ready
        case failed(String)
        var isActive: Bool { self != .idle }
        var isLocked: Bool { self == .aiming || self == .zooming || self == .ready }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var suggestion: AIShotSuggestion?
    /// The tracked shot in viewfinder coordinates (normalized, top-left).
    @Published private(set) var frame: CGRect?
    @Published private(set) var instruction = ""
    /// Unit direction the camera should move (x right, y down) while aiming.
    @Published private(set) var direction: CGVector?

    private let tracker = AIShotTracker()
    private weak var camera: CameraController?
    private var previewAspect = 0.75
    private var mirrored = false
    private var task: Task<Void,Never>?
    private var token = 0
    private var trackedZoom = 1.0
    private var zoomRequested = false
    private var zoomSettleUntil: TimeInterval = 0
    private var zoomStartedAt: TimeInterval = 0
    private var lowConfidenceSince: TimeInterval?
    private var centeredSince: TimeInterval?
    private var lastGuidanceChange: TimeInterval = 0

    // Tunables
    private let readyEnter = 0.045, readyExit = 0.085, zoomWhenWithin = 0.12, readyHold = 0.35

    init() {
        tracker.onObservation = { [weak self] observation, generation in
            // The tracker always delivers on the main queue.
            MainActor.assumeIsolated { self?.observe(observation,generation:generation) }
        }
    }

    // MARK: Public

    func start(camera:CameraController,previewAspect:Double,mirrored:Bool) {
        cancelWork()
        self.camera = camera; self.previewAspect = previewAspect; self.mirrored = mirrored
        guard AIShotConfiguration.isConfigured else { fail(AIShotError.notConfigured.message); return }
        let handlerTracker = tracker
        camera.setAIShotFrameHandler { handlerTracker.ingest($0) }
        phase = .finding; instruction = "Finding your shot…"; suggestion = nil; frame = nil; direction = nil
        UIImpactFeedbackGenerator(style:.soft).impactOccurred()
        let request = (zoom:camera.zoom,minimum:camera.minimumZoom,maximum:min(camera.maximumZoom,6))
        task = Task { [weak self] in
            guard let self else { return }
            guard let buffer = await self.tracker.nextFrame() else { self.fail(AIShotError.noFrame.message); return }
            let projection = PreviewProjection(imageAspect:Double(CVPixelBufferGetWidth(buffer))/Double(max(1,CVPixelBufferGetHeight(buffer))),
                                               previewAspect:previewAspect,mirrored:mirrored)
            guard let jpeg = self.tracker.jpeg(buffer,projection:projection) else { self.fail(AIShotError.noFrame.message); return }
            do {
                let suggestion = try await AIShotService.suggest(.init(jpeg:jpeg,aspect:previewAspect,zoom:request.zoom,
                    minimumZoom:request.minimum,maximumZoom:max(request.zoom,request.maximum)))
                try Task.checkCancellation()
                self.lock(suggestion,reference:buffer,projection:projection,zoom:request.zoom)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.fail((error as? AIShotError ?? .invalidResponse).message)
            }
        }
    }

    /// Leaves AI Shot completely (classic guidance may resume).
    func stop() {
        cancelWork()
        camera?.setAIShotFrameHandler(nil)
        phase = .idle; suggestion = nil; frame = nil; instruction = ""; direction = nil
    }

    // MARK: Locking the AI decision

    private func lock(_ suggestion:AIShotSuggestion,reference:CVPixelBuffer,projection:PreviewProjection,zoom:Double) {
        self.suggestion = suggestion
        trackedZoom = zoom; zoomRequested = false; centeredSince = nil; lowConfidenceSince = nil
        frame = suggestion.frame
        phase = .aiming; instruction = suggestion.tip
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        token = tracker.track(projection.imageRect(Self.trackedPart(of:suggestion.frame)),reference:reference)
    }

    /// Vision tracks the middle of the shot; a box that fills the whole view
    /// after zooming cannot be tracked itself.
    static func trackedPart(of frame:CGRect) -> CGRect {
        let w = max(0.08,frame.width*0.5), h = max(0.08,frame.height*0.5)
        return CGRect(x:frame.midX-w/2,y:frame.midY-h/2,width:w,height:h)
    }
    static func shot(fromTracked part:CGRect,like frame:CGRect) -> CGRect {
        let w = frame.width, h = frame.height
        return CGRect(x:part.midX-w/2,y:part.midY-h/2,width:w,height:h)
    }
    /// Optical/digital zoom scales the view about its center.
    static func rescale(_ rect:CGRect,by ratio:Double) -> CGRect {
        let r = CGFloat(ratio)
        return CGRect(x:0.5+(rect.minX-0.5)*r,y:0.5+(rect.minY-0.5)*r,width:rect.width*r,height:rect.height*r)
    }

    // MARK: Per-frame guidance

    private func observe(_ observation:AIShotTracker.Observation?,generation:Int) {
        guard generation == token, phase.isLocked, let suggestion, let current = frame, let camera else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let projection = PreviewProjection(imageAspect:observation?.imageAspect ?? 0.75,previewAspect:previewAspect,mirrored:mirrored)

        // Zoom changed (ours or a pinch): rescale the shot and restart tracking.
        let zoomRatio = camera.zoom/max(0.01,trackedZoom)
        if abs(zoomRatio-1) > 0.02 {
            if zoomSettleUntil == 0 { zoomSettleUntil = now+0.3 }
            guard now >= zoomSettleUntil else { return }
            zoomSettleUntil = 0
            let scaled = Self.rescale(current,by:zoomRatio)
            trackedZoom = camera.zoom; frame = scaled
            token = tracker.track(projection.imageRect(Self.trackedPart(of:scaled)))
            if phase == .zooming { phase = .aiming }
            return
        }

        guard let observation, observation.confidence >= 0.3 else {
            if lowConfidenceSince == nil { lowConfidenceSince = now }
            if now-(lowConfidenceSince ?? now) > 1.5 { fail("Lost the shot. Tap ↻ to find a new one.") }
            return
        }
        lowConfidenceSince = nil

        // Smooth the tracked box a little so the overlay does not jitter.
        let measured = Self.shot(fromTracked:projection.visibleRect(observation.rect),like:current)
        let alpha: CGFloat = 0.55
        let smoothed = CGRect(x:current.minX+(measured.minX-current.minX)*alpha,y:current.minY+(measured.minY-current.minY)*alpha,
                              width:current.width,height:current.height)
        frame = smoothed

        let dx = Double(smoothed.midX)-0.5, dy = Double(smoothed.midY)-0.5
        let offset = max(abs(dx),abs(dy))
        let needsZoom = suggestion.zoom/max(0.01,camera.zoom) > 1.1 && camera.zoom < camera.maximumZoom-0.05

        // Zoom multiplies the remaining offset by the zoom step, so only zoom once it will stay centered.
        let zoomStep = min(suggestion.zoom,camera.maximumZoom)/max(0.01,camera.zoom)
        let zoomWithin = max(0.025,min(zoomWhenWithin,readyExit*0.8/max(1,zoomStep)))
        if needsZoom && !zoomRequested && offset < zoomWithin {
            zoomRequested = true; zoomStartedAt = now; phase = .zooming; direction = nil
            camera.setZoom(min(suggestion.zoom,camera.maximumZoom))
            return
        }

        let zoomDone = !needsZoom || zoomRequested
        if phase == .zooming && now-zoomStartedAt > 1.2 { phase = .aiming } // Zoom could not change further.
        if phase == .ready {
            if offset > readyExit { phase = .aiming; centeredSince = nil }
        } else if zoomDone && offset < readyEnter {
            if centeredSince == nil { centeredSince = now }
            if now-(centeredSince ?? now) >= readyHold {
                phase = .ready; instruction = suggestion.tip; direction = nil
                UIImpactFeedbackGenerator(style:.medium).impactOccurred()
            }
        } else { centeredSince = nil }

        if phase == .aiming { updateDirection(dx:dx,dy:dy,now:now) }
    }

    /// Like Framed, the text stays the AI's tip; direction is only the arrow (plus the box and
    /// dashed line on the image). The arrow turns at most ~4×/s so it does not flicker.
    private func updateDirection(dx:Double,dy:Double,now:TimeInterval) {
        let length = hypot(dx,dy)
        guard length > 0.025 else { direction = nil; return }
        if now-lastGuidanceChange <= 0.25 && direction != nil { return }
        direction = CGVector(dx:dx/length,dy:dy/length)
        lastGuidanceChange = now
    }

    private func fail(_ message:String) {
        tracker.stop(); token = -1
        camera?.setAIShotFrameHandler(nil) // Rescan re-attaches it.
        phase = .failed(message); instruction = message; direction = nil; frame = nil
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    private func cancelWork() {
        task?.cancel(); task = nil; tracker.stop(); token = -1
        zoomRequested = false; zoomSettleUntil = 0; centeredSince = nil; lowConfidenceSince = nil
    }
}
