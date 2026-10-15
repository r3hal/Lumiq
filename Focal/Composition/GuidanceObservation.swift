import Foundation

/// A confidence filter can delay trust, never make a weak raw observation strong.
struct GuidanceConfidenceFilter {
    private var value: Double?
    private var subject: String?
    private var previousTime: TimeInterval?
    mutating func reset() { self = Self() }
    mutating func update(_ raw: Double, label: String, at time: TimeInterval) -> Double {
        guard raw.isFinite, (0...1).contains(raw), time.isFinite else { reset(); return 0 }
        if subject != label || previousTime.map({ time <= $0 || time-$0 > 1.5 }) == true { reset() }
        let smoothed = value.map { $0*0.35+raw*0.65 } ?? raw
        value = smoothed; subject = label; previousTime = time
        return min(raw,smoothed)
    }
}

/// Maximum observation age is a guidance policy, not a preview frame limit.
enum GuidanceObservationPolicy {
    static let maximumAge: TimeInterval = 0.9
    static func fresh(capturedAt: TimeInterval, evaluatedAt: TimeInterval) -> Bool {
        capturedAt.isFinite && evaluatedAt.isFinite && evaluatedAt >= capturedAt && evaluatedAt-capturedAt <= maximumAge
    }
    static func permitsZoom(stable: Bool, relativeSpeed: Double?, fresh: Bool) -> Bool {
        guard stable, fresh, let relativeSpeed, relativeSpeed.isFinite else { return false }
        return relativeSpeed >= 0 && relativeSpeed <= 0.35
    }
}

/// Immutable, measured scene state. Coordinates are normalized visible-preview
/// coordinates (top-left origin); it owns no capture buffer or photographs.
struct GuidanceSceneSnapshot {
    var observedAt: TimeInterval
    var evaluatedAt: TimeInterval
    var label: String
    var intent: PhotographyIntent
    var selectedBounds: CGRect?
    var confidence: Double
    var surroundingSubjects: [CompositionContextSubject]
    var anatomy: SubjectAnatomy?
    var measurements: PhotoMeasurements?
    var imageEvidence: SceneCompositionEvidence?
    var relativeSpeed: Double?
    var deviceStable: Bool
    var petStyle: PetFramingStyle = .balanced
    var fresh: Bool { GuidanceObservationPolicy.fresh(capturedAt:observedAt,evaluatedAt:evaluatedAt) }
    var assessment: CompositionAssessment {
        CompositionAssessment.evaluate(bounds:selectedBounds,confidence:confidence,label:label,intent:intent,
            stable:deviceStable && relativeSpeed.map { $0 <= 0.25 } != false,exposure:measurements,
            evidence:imageEvidence,others:surroundingSubjects,anatomy:anatomy,timestamp:evaluatedAt,petStyle:petStyle)
    }
}

#if DEBUG || FOCAL_EVALUATION
import OSLog

/// Local developer logs only. No pixels, file names, network or telemetry SDK.
struct GuidanceDiagnostics {
    private let logger = Logger(subsystem:"app.focal",category:"Guidance")
    private var lastLog: TimeInterval = -.infinity
    private(set) var timings = GuidanceTimingAccumulator()
    mutating func rejectStale() { timings.staleRejections += 1 }
    mutating func record(scene:GuidanceSceneSnapshot, plan:SceneCompositionPlan?, message:GuidanceMessage,
                         previous:GuidanceAction?, memoryOutcome:String, phase:FramingPhase,
                         reasoning:PhotographicDecision?,inferenceMS:Double,decisionMS:Double,finishedAt:TimeInterval) {
        timings.record(inferenceMS:inferenceMS,decisionMS:decisionMS,latencyMS:(finishedAt-scene.observedAt)*1000,at:finishedAt)
        guard scene.evaluatedAt-lastLog >= 1 else { return }
        lastLog = scene.evaluatedAt
        let facts = scene.assessment
        let candidates = ([plan?.selected].compactMap { $0 }+(plan?.alternatives ?? [])).map { candidate in
            let reason = candidate.isCurrentFrame ? "keep observed frame" : candidate.measuredImprovement < IntentCompositionSearch.minimumImprovement ? "rejected: gain below threshold" : "measured useful candidate"
            return "\(candidate.technique.rawValue): gain=\(candidate.measuredImprovement), scale=\(candidate.zoomScale), \(reason)"
        }.joined(separator:"; ")
        let summary = "subject=\(scene.label), confidence=\(scene.confidence), intent=\(scene.intent.rawValue), fresh=\(scene.fresh), ageMs=\((scene.evaluatedAt-scene.observedAt)*1000), area=\(String(describing:facts.subjectArea)), margin=\(String(describing:facts.minimumMargin)), headroom=\(String(describing:facts.headroom)), motion=\(String(describing:scene.relativeSpeed)), context=\(scene.surroundingSubjects.count), positionPenalty=\(facts.positionPenalty), sizePenalty=\(facts.sizePenalty), candidates=[\(candidates)], previous=\(String(describing:previous)), current=\(String(describing:message.action)), phase=\(phase), outcome=\(memoryOutcome), reason=\(message.text)"
        let candidateReasons = reasoning?.candidates.map { "\($0.guidance.action.rawValue):support=\($0.support.value),gain=\($0.expectedGain),\($0.rejection ?? $0.evidence)" }.joined(separator:"; ") ?? ""
        let timing = "state=\(message.reasoningState.rawValue), inferenceMeanMS=\(timings.inferenceMean), decisionMeanMS=\(timings.decisionMean), ageMeanMS=\(timings.latencyMean), updateHz=\(String(describing:timings.updateHz)), stale=\(timings.staleRejections), candidates=\(candidateReasons)"
        logger.debug("\(summary, privacy: .private); \(timing, privacy: .private)")
    }
}
#endif
