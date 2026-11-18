import AVFoundation
import CoreImage
import UIKit
import Vision

/// Follows the AI-chosen frame between preview frames with Vision object
/// tracking. All rectangles here are normalized, top-left origin, in the
/// coordinates of the (upright) video buffer — not the visible viewfinder.
final class AIShotTracker: @unchecked Sendable {
    struct Observation { let rect: CGRect; let confidence: Float; let imageAspect: Double }

    private let queue = DispatchQueue(label:"app.lumiq.aishot.tracker",qos:.userInitiated)
    private let lock = NSLock()
    private let context = CIContext(options:[.cacheIntermediates:false])
    private let longEdge = 720.0
    private let minimumInterval = 1.0/24.0

    // Video queue + lock.
    private var busy = false
    private var lastAdmitted: TimeInterval = 0
    private var pool: [CVPixelBuffer] = []

    // Tracker queue only.
    private var sequence = VNSequenceRequestHandler()
    private var request: VNTrackObjectRequest?
    private var pendingSnapshot: ((CVPixelBuffer?) -> Void)?
    private var generation = 0

    /// Called on the main queue for every tracked frame.
    var onObservation: ((Observation?,Int) -> Void)?

    // MARK: Video queue entry point
    func ingest(_ sample:CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !busy, now-lastAdmitted >= minimumInterval else { lock.unlock(); return }
        busy = true; lastAdmitted = now
        lock.unlock()
        guard let source = CMSampleBufferGetImageBuffer(sample), let small = downscale(source) else { finish(); return }
        // The capture pool buffer is released here; only our own copy travels on.
        queue.async { self.process(small); self.finish() }
    }
    private func finish() { lock.lock(); busy = false; lock.unlock() }

    private func downscale(_ source:CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1,longEdge/Double(max(w,h)))
        let width = max(1,Int(Double(w)*scale)), height = max(1,Int(Double(h)*scale))
        lock.lock()
        // Two alternating buffers: one may still be referenced by a pending snapshot.
        pool.removeAll { CVPixelBufferGetWidth($0) != width || CVPixelBufferGetHeight($0) != height }
        var target: CVPixelBuffer?
        if pool.count < 3 {
            var created: CVPixelBuffer?
            let attributes:[CFString:Any] = [kCVPixelBufferIOSurfacePropertiesKey:[String:Any]()]
            if CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32BGRA,attributes as CFDictionary,&created) == kCVReturnSuccess, let created {
                pool.append(created); target = created
            }
        } else {
            target = pool.removeFirst(); pool.append(target!)
        }
        lock.unlock()
        guard let target else { return nil }
        let image = CIImage(cvPixelBuffer:source).transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        context.render(image,to:target,bounds:CGRect(x:0,y:0,width:width,height:height),colorSpace:CGColorSpaceCreateDeviceRGB())
        return target
    }

    // MARK: Tracker queue
    private func process(_ buffer:CVPixelBuffer) {
        if let snapshot = pendingSnapshot { pendingSnapshot = nil; snapshot(copy(buffer)) }
        guard let request else { return }
        let aspect = Double(CVPixelBufferGetWidth(buffer))/Double(max(1,CVPixelBufferGetHeight(buffer)))
        let generation = self.generation
        do {
            try sequence.perform([request],on:buffer,orientation:.up)
            guard let result = request.results?.first as? VNDetectedObjectObservation else { publish(nil,generation); return }
            request.inputObservation = result
            let box = result.boundingBox
            publish(.init(rect:CGRect(x:box.minX,y:1-box.maxY,width:box.width,height:box.height),confidence:result.confidence,imageAspect:aspect),generation)
        } catch {
            self.request = nil; publish(nil,generation)
        }
    }
    private func publish(_ observation:Observation?,_ generation:Int) {
        DispatchQueue.main.async { self.onObservation?(observation,generation) }
    }
    private func copy(_ buffer:CVPixelBuffer) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        let attributes:[CFString:Any] = [kCVPixelBufferIOSurfacePropertiesKey:[String:Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault,CVPixelBufferGetWidth(buffer),CVPixelBufferGetHeight(buffer),kCVPixelFormatType_32BGRA,attributes as CFDictionary,&created) == kCVReturnSuccess,
              let created else { return nil }
        context.render(CIImage(cvPixelBuffer:buffer),to:created)
        return created
    }

    // MARK: Control (any thread)

    /// Delivers a private copy of the next preview frame.
    func nextFrame() async -> CVPixelBuffer? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.pendingSnapshot?(nil)
                var resumed = false
                self.pendingSnapshot = { buffer in guard !resumed else { return }; resumed = true; continuation.resume(returning:buffer) }
                self.queue.asyncAfter(deadline:.now()+2) {
                    guard let pending = self.pendingSnapshot else { return }
                    self.pendingSnapshot = nil; pending(nil)
                }
            }
        }
    }

    /// Starts tracking `rect` (buffer coordinates). If `reference` is given the
    /// template is taken from that earlier frame, so camera motion while the AI
    /// was thinking is followed instead of tracking the wrong content.
    func track(_ rect:CGRect,reference:CVPixelBuffer? = nil) -> Int {
        let clamped = rect.intersection(CGRect(x:0,y:0,width:1,height:1))
        var token = 0
        queue.sync {
            generation += 1; token = generation
            guard !clamped.isNull, clamped.width > 0.01, clamped.height > 0.01 else { request = nil; return }
            sequence = VNSequenceRequestHandler()
            let seed = VNDetectedObjectObservation(boundingBox:CGRect(x:clamped.minX,y:1-clamped.maxY,width:clamped.width,height:clamped.height))
            let request = VNTrackObjectRequest(detectedObjectObservation:seed)
            request.trackingLevel = .accurate
            if let reference {
                try? sequence.perform([request],on:reference,orientation:.up)
                if let first = request.results?.first as? VNDetectedObjectObservation { request.inputObservation = first }
            }
            self.request = request
        }
        return token
    }

    func stop() {
        queue.async { self.generation += 1; self.request = nil; self.pendingSnapshot?(nil); self.pendingSnapshot = nil }
    }

    /// Fresh JPEG of what the viewfinder shows, ≤768 px, metadata-free.
    func jpeg(_ buffer:CVPixelBuffer,projection:PreviewProjection) -> Data? {
        CloudFrameEncoder.encode(CIImage(cvPixelBuffer:buffer),projection:projection,context:context)
    }
}
