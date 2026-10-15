import Foundation

/// An earlier, bounded live-preview representation. Never a full-resolution still.
struct WideScenePreview {
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let observedAt: Date
}

struct FramingCaptureMetadata: Codable, Equatable {
    let sessionID: UUID
    let shotPlanID: String
    let shutterRequestedAt: Date
    let startingZoom: Double
    let targetZoom: Double
    let capturedZoom: Double
    let widePreviewObservedAt: Date?
    let widePreviewWidth: Int?
    let widePreviewHeight: Int?
    var hasWidePreview: Bool { widePreviewObservedAt != nil && widePreviewWidth != nil && widePreviewHeight != nil }
    var previewResolutionLabel: String? {
        guard let w = widePreviewWidth, let h = widePreviewHeight else { return nil }
        return "\(w) × \(h) · \(String(format:"%.1f",(Double(w)*Double(h))/1_000_000)) MP"
    }
}

struct FramedCapture {
    let metadata: FramingCaptureMetadata
    let widePreview: WideScenePreview?
    func matchesCamera(zoom:Double,enabled:Bool,ramping:Bool) -> Bool {
        enabled && !ramping && zoom.isFinite && abs(zoom/metadata.capturedZoom-1) <= 0.02
    }
}

/// Analysis-queue state only. Retains pixels at the aligned pre-zoom moment;
/// creates a save payload only in response to a user shutter request.
struct ShotCaptureSession {
    private var plan: AutomaticShotPlan?
    private var widePreview: WideScenePreview?
    private var wideStartingZoom: Double?
    private var lastEligible: TimeInterval?
    private var verifiedZoom: Double?
    mutating func select(_ plan:AutomaticShotPlan,preview:WideScenePreview?) {
        // A retry of the same composition keeps the original pre-zoom preview.
        if self.plan?.id != plan.id { widePreview = preview; wideStartingZoom = plan.startingZoom }
        self.plan = plan; lastEligible = nil; verifiedZoom = nil
    }
    mutating func invalidateVerification() { lastEligible = nil; verifiedZoom = nil }
    mutating func cancel() { self = Self() }
    mutating func observe(plan current:AutomaticShotPlan?,verified:Bool,bounds:CGRect?,label:String,
                          confidence:Float,zoom:Double,stable:Bool,timestamp:TimeInterval,aspect:Double) {
        guard let plan, current?.id == plan.id else { cancel(); return }
        guard verified else { lastEligible = nil; return }
        guard stable, timestamp.isFinite else { lastEligible = nil; verifiedZoom = nil; return }
        guard let bounds, label == plan.subjectLabel, confidence >= 0.65,
              plan.achieved(bounds:bounds,zoom:zoom,previewAspect:aspect),
              plan.safeRemainingCrop(bounds:bounds,zoom:zoom,observedRegions:[],projectToTarget:false) else {
            // This cannot produce a paired capture without fresh verification.
            // Retain the timestamped wide preview until this shot is discarded,
            // so a brief movement/recovery does not silently remove its pair.
            lastEligible = nil; verifiedZoom = nil; return
        }
        lastEligible = timestamp; verifiedZoom = zoom
    }
    func userCapture(at time:TimeInterval,date:Date = Date(),guidanceEnabled:Bool) -> FramedCapture? {
        guard guidanceEnabled, let plan, let lastEligible, let zoom = verifiedZoom,
              time.isFinite, time >= lastEligible, time-lastEligible <= 1 else { return nil }
        let metadata = FramingCaptureMetadata(sessionID:UUID(),shotPlanID:plan.id,shutterRequestedAt:date,
            startingZoom:wideStartingZoom ?? plan.startingZoom,targetZoom:plan.targetZoom,capturedZoom:zoom,
            widePreviewObservedAt:widePreview?.observedAt,widePreviewWidth:widePreview?.pixelWidth,widePreviewHeight:widePreview?.pixelHeight)
        return .init(metadata:metadata,widePreview:widePreview)
    }
}

enum UserShutterPolicy {
    static func count(guidanceEnabled:Bool,requestedSeries:Int) -> Int {
        guidanceEnabled ? 1 : max(1,min(5,requestedSeries))
    }
}
