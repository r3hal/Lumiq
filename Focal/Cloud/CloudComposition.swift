import Foundation

// Cloud output is a proposal. It has no READY, focus or capture capability.
enum CloudTechnique: String, Codable, CaseIterable {
    case ruleOfThirds, centered, leadingLines, symmetry, negativeSpace, depthFraming, landscapeLayers, forestPath
    var local: CompositionTechnique {
        switch self {
        case .ruleOfThirds: return .thirds
        case .centered: return .centered
        case .leadingLines: return .leadingLines
        case .symmetry: return .symmetry
        case .negativeSpace: return .negativeSpace
        case .depthFraming, .forestPath: return .framing
        case .landscapeLayers: return .layers
        }
    }
}
enum CloudSceneCategory: String, Codable, CaseIterable { case portrait, pet, product, architecture, landscape, forest, other }
struct CloudPoint: Codable, Equatable {
    var x: Double; var y: Double
    var valid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
    var local: UnitPoint2D { .init(x:x,y:y) }
}
struct CloudBox: Codable {
    var x: Double; var y: Double; var width: Double; var height: Double
    var rect: CGRect { .init(x:x,y:y,width:width,height:height) }
    var valid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x+width <= 1 && y+height <= 1 }
}
struct CloudZoomRange: Codable {
    var minimum: Double; var maximum: Double
    var valid: Bool { minimum.isFinite && maximum.isFinite && minimum >= 0.5 && maximum >= minimum && maximum <= 20 }
}
struct CloudRollSuggestion: Codable { var degrees: Double; var justification: String }
struct CloudAlternative: Codable { var technique: CloudTechnique; var targetPosition: CloudPoint; var explanation: String }
struct CloudCompositionResult: Codable {
    var sceneCategory: CloudSceneCategory
    var photographicIntent: PhotographyIntent
    var primarySubjectDescription: String
    var localSubjectID: String?
    var subjectBoundingBox: CloudBox?
    var recommendedCompositionTechnique: CloudTechnique
    var normalizedTargetPosition: CloudPoint
    var recommendedZoomRange: CloudZoomRange
    var rollSuggestion: CloudRollSuggestion?
    var explanation: String
    var confidence: Double
    var alternatives: [CloudAlternative]

    static func decode(_ data:Data) throws -> Self {
        guard data.count <= 24_000 else { throw CloudCompositionError.invalidResponse }
        guard let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw CloudCompositionError.invalidResponse }
        func keys(_ object:Any?,_ names:[String]) throws {
            guard let object = object as? [String:Any], Set(object.keys) == Set(names) else { throw CloudCompositionError.invalidResponse }
        }
        try keys(root,["sceneCategory","photographicIntent","primarySubjectDescription","localSubjectID","subjectBoundingBox","recommendedCompositionTechnique","normalizedTargetPosition","recommendedZoomRange","rollSuggestion","explanation","confidence","alternatives"])
        try keys(root["normalizedTargetPosition"],["x","y"])
        try keys(root["recommendedZoomRange"],["minimum","maximum"])
        if !(root["subjectBoundingBox"] is NSNull) { try keys(root["subjectBoundingBox"],["x","y","width","height"]) }
        if !(root["rollSuggestion"] is NSNull) { try keys(root["rollSuggestion"],["degrees","justification"]) }
        guard let alternatives = root["alternatives"] as? [[String:Any]], alternatives.count <= 3 else { throw CloudCompositionError.invalidResponse }
        for alternative in alternatives { try keys(alternative,["technique","targetPosition","explanation"]); try keys(alternative["targetPosition"],["x","y"]) }
        guard let result = try? JSONDecoder().decode(Self.self,from:data) else { throw CloudCompositionError.invalidResponse }
        try result.validate()
        return result
    }
    func validate() throws {
        guard normalizedTargetPosition.valid, recommendedZoomRange.valid, subjectBoundingBox?.valid != false,
              confidence.isFinite, (0.65...1).contains(confidence), Self.safeText(primarySubjectDescription,maximum:120),
              Self.safeText(explanation,maximum:240), alternatives.count <= 3,
              localSubjectID == nil || localSubjectID == "selected",
              alternatives.allSatisfy({ $0.targetPosition.valid && Self.safeText($0.explanation,maximum:160) }) else { throw CloudCompositionError.invalidResponse }
        if let rollSuggestion {
            guard rollSuggestion.degrees.isFinite, abs(rollSuggestion.degrees) <= 15, Self.safeText(rollSuggestion.justification,maximum:160) else { throw CloudCompositionError.invalidResponse }
        }
    }
    static func safeText(_ text:String,maximum:Int) -> Bool {
        !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && text.count <= maximum && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

enum CloudCompositionError: Error, Equatable {
    case notConfigured, unsupportedSource, unavailableFrame, timeout, offline, quota, unauthorized, unavailableModel, invalidResponse, subjectMismatch, impossiblePlan, stale, cancelled, serviceUnavailable
    var message: String {
        switch self {
        case .notConfigured: return "Cloud Scan is not configured. Local AI Guide is still available."
        case .unsupportedSource: return "Experimental Cloud Scan supports the iPhone camera in Automatic composition mode."
        case .unavailableFrame: return "No fresh camera frame is available. Local guidance continues."
        case .timeout: return "Cloud Scan timed out. Local guidance continues."
        case .offline: return "No internet connection. Local guidance continues."
        case .quota: return "Cloud Scan quota reached. Try again later; local guidance continues."
        case .unauthorized: return "Cloud Scan authorization failed. Check the local developer configuration."
        case .unavailableModel: return "The configured model is unavailable. Check current Google model documentation."
        case .invalidResponse: return "The cloud suggestion could not be validated. Local guidance continues."
        case .subjectMismatch: return "The suggestion does not match a reliably tracked subject. Select your subject or rescan."
        case .impossiblePlan: return "This suggestion cannot be verified safely in the current view. Local guidance continues."
        case .stale: return "The camera context changed. Request a new scan when ready."
        case .cancelled: return "Cloud Scan cancelled. Local guidance continues."
        case .serviceUnavailable: return "Cloud Scan is unavailable. Local guidance continues."
        }
    }
}

struct CloudLocalEvidence {
    var observedAt: TimeInterval
    var sessionRevision: Int
    var isIPhone: Bool
    var mode: CompositionMode
    var trackingReference: String?
    var label: String
    var bounds: CGRect?
    var confidence: Double
    var zoom: Double
    var minimumZoom: Double
    var maximumZoom: Double // Already capped by the local detail/device budget.
    var previewAspect: Double
    var scene: SceneCompositionEvidence?
    var rollReliable: Bool
    var rollDegrees: Double
    var intent: PhotographyIntent = .auto
    var freshTrack: Bool { trackingReference != nil && bounds.map(AutomaticShotPlan.valid) == true && confidence.isFinite && confidence >= 0.65 }
}
struct CloudScanTicket { let id: UUID; let sessionRevision: Int }
struct CloudScanCapture {
    let requestID: UUID
    let jpeg: Data
    let evidence: CloudLocalEvidence
}
protocol CloudCompositionService {
    func scan(_ capture:CloudScanCapture) async throws -> CloudCompositionResult
}

/// Main/analysis-queue crossing guard. Context invalidation also cancels transport
/// in the UI, but correctness never depends on cooperative cancellation.
final class CloudScanRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var request: UUID?
    func begin() -> UUID { lock.lock(); defer { lock.unlock() }; let id = UUID(); request = id; return id }
    func invalidate() { lock.lock(); defer { lock.unlock() }; request = nil }
    func accepts(_ id:UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return request == id }
    func finish(_ id:UUID) -> Bool { lock.lock(); defer { lock.unlock() }; guard request == id else { return false }; request = nil; return true }
}

struct CloudCompositionLock {
    enum Observation: Equatable { case retained, recovering, invalid }
    let id: String
    let result: CloudCompositionResult
    let trackingReference: String?
    let subjectLabel: String
    let acquiredAt: TimeInterval
    let initialZoom: Double
    private var lostSince: TimeInterval?
    private var lastZoom: Double
    private var sceneContinuity = ReadySceneContinuity()
    private(set) var manualZoomOverride = false
    private var measuredMotorOption: CompositionOption?
    var isWholeScene: Bool { trackingReference == nil }
    var target: UnitPoint2D { result.normalizedTargetPosition.local }
    init(result:CloudCompositionResult,evidence:CloudLocalEvidence,at time:TimeInterval) {
        self.result = result; id = UUID().uuidString; trackingReference = evidence.trackingReference
        subjectLabel = evidence.label; acquiredAt = time; initialZoom = evidence.zoom; lastZoom = evidence.zoom
        _ = sceneContinuity.changed(evidence:evidence.scene,identity:id,at:time)
    }
    mutating func preserveManualZoom() { manualZoomOverride = true; measuredMotorOption = nil; sceneContinuity.reset() }
    @discardableResult mutating func useMeasuredMotorOption(_ option:CompositionOption) -> Bool {
        guard !isWholeScene, !manualZoomOverride, option.measuredImprovement.isFinite,
              option.measuredImprovement >= IntentCompositionSearch.minimumImprovement,
              option.target.distance(to:target) <= 0.04, option.zoomScale.isFinite, option.zoomScale > 1.12,
              option.technique == result.recommendedCompositionTechnique.local else { return false }
        let candidate = SceneCompositionPlan(selected:option,alternatives:[],subjectLabel:subjectLabel,timestamp:acquiredAt)
        guard candidate.permitsZoom else { return false }
        measuredMotorOption = option; return true
    }
    mutating func observe(_ local:CloudLocalEvidence,at time:TimeInterval) -> Observation {
        guard local.isIPhone, local.mode == .automatic, time.isFinite, time >= acquiredAt, time-acquiredAt <= 300 else { return .invalid }
        let fresh = GuidanceObservationPolicy.fresh(capturedAt:local.observedAt,evaluatedAt:time)
        let matches = isWholeScene ? true : local.freshTrack && local.trackingReference == trackingReference && local.label == subjectLabel
        guard fresh, matches else {
            if lostSince == nil { lostSince = time }
            return time-(lostSince ?? time) < 1.5 ? .recovering : .invalid
        }
        lostSince = nil
        if abs(local.zoom/max(0.01,lastZoom)-1) > 0.02 { sceneContinuity.reset(); lastZoom = local.zoom }
        if sceneContinuity.changed(evidence:local.scene,identity:id,at:time) { return .invalid }
        return .retained
    }
    func plan(at time:TimeInterval,zoom:Double) -> SceneCompositionPlan {
        var option = CompositionOption(technique:result.recommendedCompositionTechnique.local,target:target,
            crop:CGRect(x:0,y:0,width:1,height:1),score:0,explanation:isWholeScene ? "Keep the selected wide view; local observations verify the frame" : "Track the selected subject toward the locked composition",zoomScale:1,isCurrentFrame:true)
        if !manualZoomOverride, let measuredMotorOption {
            option = measuredMotorOption
            option.zoomScale = max(1,initialZoom*measuredMotorOption.zoomScale/max(0.01,zoom))
            option.isCurrentFrame = option.zoomScale <= 1.12
        }
        if isWholeScene { option.sceneAnchor = .init(x:0.5,y:0.5) } // Full-frame center, never a claimed path/object detector.
        return .init(selected:option,alternatives:[],subjectLabel:subjectLabel,timestamp:time,id:id)
    }
}

enum CloudCompositionMatcher {
    static func match(_ result:CloudCompositionResult,capture:CloudScanCapture,live:CloudLocalEvidence,at time:TimeInterval) throws -> CloudCompositionLock {
        try result.validate()
        let old = capture.evidence
        guard old.isIPhone, live.isIPhone, old.mode == .automatic, live.mode == .automatic else { throw CloudCompositionError.unsupportedSource }
        guard old.sessionRevision == live.sessionRevision, time >= old.observedAt, time-old.observedAt <= 40,
              GuidanceObservationPolicy.fresh(capturedAt:live.observedAt,evaluatedAt:time), abs(live.zoom/old.zoom-1) <= 0.02 else { throw CloudCompositionError.stale }
        guard result.recommendedZoomRange.minimum >= live.minimumZoom, result.recommendedZoomRange.maximum <= live.maximumZoom,
              live.zoom <= result.recommendedZoomRange.maximum+0.01 else { throw CloudCompositionError.impossiblePlan }
        guard old.scene?.isFresh(at:old.observedAt) == true, live.scene?.isFresh(at:time) == true else { throw CloudCompositionError.stale }
        guard old.intent == .auto || old.intent == result.photographicIntent else { throw CloudCompositionError.impossiblePlan }
        if result.rollSuggestion != nil, !live.rollReliable && (live.scene?.lines.isEmpty ?? true) { throw CloudCompositionError.invalidResponse }
        var continuity = ReadySceneContinuity()
        _ = continuity.changed(evidence:old.scene,identity:"scan",at:old.observedAt)
        if continuity.changed(evidence:live.scene,identity:"scan",at:time) { throw CloudCompositionError.stale }
        if let box = result.subjectBoundingBox {
            guard old.freshTrack, live.freshTrack, old.trackingReference == live.trackingReference,
                  old.label == live.label, result.localSubjectID == "selected",
                  result.primarySubjectDescription.lowercased() == old.label.lowercased(), let oldBounds = old.bounds,
                  overlap(box.rect,oldBounds) >= 0.45 else { throw CloudCompositionError.subjectMismatch }
            guard let bounds = live.bounds else { throw CloudCompositionError.subjectMismatch }
            let target = result.normalizedTargetPosition
            let placed = CGRect(x:target.x-Double(bounds.width)/2,y:target.y-Double(bounds.height)/2,width:bounds.width,height:bounds.height)
            guard CGRect(x:0.025,y:0.025,width:0.95,height:0.95).contains(placed) else { throw CloudCompositionError.impossiblePlan }
        } else {
            // A model-described path/line is not a local detector. Wide advice
            // can retain the current view; unsupported pan/zoom anchors fail closed.
            guard old.bounds == nil, live.bounds == nil, result.localSubjectID == nil,
                  result.primarySubjectDescription == "Whole scene", result.normalizedTargetPosition.local.distance(to:.init(x:0.5,y:0.5)) < 0.001,
                  result.recommendedZoomRange.minimum <= live.zoom, live.scene?.isFresh(at:time) == true,
                  [.landscape,.forest,.architecture].contains(result.sceneCategory) else { throw CloudCompositionError.subjectMismatch }
        }
        var evidence = live
        if result.subjectBoundingBox == nil { evidence.trackingReference = nil; evidence.label = "Scene" }
        return CloudCompositionLock(result:result,evidence:evidence,at:time)
    }
    static func overlap(_ a:CGRect,_ b:CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let area = a.width*a.height+b.width*b.height-intersection.width*intersection.height
        return area > 0 ? Double(intersection.width*intersection.height/area) : 0
    }
}
