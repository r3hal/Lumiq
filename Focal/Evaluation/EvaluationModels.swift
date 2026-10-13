#if DEBUG || FOCAL_EVALUATION
import Foundation

struct EvaluationRect: Codable, Equatable, Sendable {
    var x: Double; var y: Double; var width: Double; var height: Double
    var cgRect: CGRect { CGRect(x:x,y:y,width:width,height:height) }
    var valid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && width > 0 && height > 0 && x >= 0 && y >= 0 && x+width <= 1.000001 && y+height <= 1.000001 }
    init(_ rect: CGRect) { x = Double(rect.minX); y = Double(rect.minY); width = Double(rect.width); height = Double(rect.height) }
    func overlap(_ other: CGRect) -> Double {
        let intersection = cgRect.intersection(other)
        guard !intersection.isNull else { return 0 }
        let union = cgRect.width*cgRect.height+other.width*other.height-intersection.width*intersection.height
        return union > 0 ? Double(intersection.width*intersection.height/union) : 0
    }
}
struct EvaluationAnnotation: Codable, Equatable, Sendable {
    var reviewed = false
    var mainSubject = ""
    var expectsNoObject = false
    var intent: PhotographyIntent = .auto
    var expectedBounds: EvaluationRect?
    var acceptableComposition: Bool?
    var framingIssue = "Unlabeled"
    var preferredAction: GuidanceAction?
    var manualSelection: EvaluationRect?
    var sequenceID: String?
    var sequenceTime: Double?
    var notes = ""
}
struct EvaluationSample: Codable, Identifiable, Sendable {
    var id: UUID
    var imageFile: String
    var imageSHA256: String
    var provenance: String
    var annotation = EvaluationAnnotation()
    var imageData: Data? = nil // Self-contained export only; not the local manifest.
}
struct EvaluationOutcome: Codable, Sendable {
    var sampleID: UUID
    var algorithm: String
    var selected: AnalyzedSubject?
    var detections: [AnalyzedSubject]
    var action: GuidanceAction
    var text: String
    var inferenceMilliseconds: Double?
    var aestheticScore: Double?
    var fitness: Double?
    var assessment: AssessmentMeasurements? = nil
}
struct EvaluationRate: Codable, Sendable {
    var numerator = 0
    var denominator = 0
    var value: Double? { denominator > 0 ? Double(numerator)/Double(denominator) : nil }
    mutating func count(_ success: Bool) { denominator += 1; if success { numerator += 1 } }
}
struct EvaluationMetrics: Codable, Sendable {
    var detectionAgreement = EvaluationRate()
    var selectionAgreement = EvaluationRate()
    var recommendationAgreement = EvaluationRate()
    var unnecessaryRecommendations = EvaluationRate()
    var contradictions = EvaluationRate()
    var stability = EvaluationRate()
    var meanInferenceMilliseconds: Double?
    static func calculate(samples: [EvaluationSample], outcomes: [EvaluationOutcome]) -> Self {
        var result = Self(), times = [Double]()
        let byID = Dictionary(outcomes.map { ($0.sampleID,$0) },uniquingKeysWith:{ _,last in last })
        for sample in samples where sample.annotation.reviewed {
            guard let outcome = byID[sample.id] else { continue }
            let label = sample.annotation
            func matches(_ subject: AnalyzedSubject) -> Bool {
                let named = subject.label.localizedCaseInsensitiveCompare(label.mainSubject) == .orderedSame
                return named && (label.expectedBounds.map { $0.overlap(subject.bounds) >= 0.5 } ?? true)
            }
            if label.expectsNoObject {
                result.detectionAgreement.count(outcome.detections.isEmpty)
                result.selectionAgreement.count(outcome.selected == nil)
            } else if !label.mainSubject.isEmpty {
                result.detectionAgreement.count(outcome.detections.contains(where:matches))
                result.selectionAgreement.count(outcome.selected.map { primary in
                    if primary.origin != nil, let expected = label.expectedBounds { return expected.overlap(primary.bounds) >= 0.5 }
                    return matches(primary)
                } ?? false)
            }
            if let preferred = label.preferredAction { result.recommendationAgreement.count(outcome.action == preferred) }
            if label.acceptableComposition == true { result.unnecessaryRecommendations.count(outcome.action.isAdjustment) }
            if let milliseconds = outcome.inferenceMilliseconds, milliseconds.isFinite, milliseconds >= 0 { times.append(milliseconds) }
        }
        let groups = Dictionary(grouping:samples.filter { $0.annotation.reviewed && $0.annotation.sequenceID?.isEmpty == false && $0.annotation.sequenceTime != nil },by:{ $0.annotation.sequenceID! })
        for sequence in groups.values {
            let sorted = sequence.sorted { ($0.annotation.sequenceTime ?? 0) < ($1.annotation.sequenceTime ?? 0) }
            for pair in zip(sorted,sorted.dropFirst()) {
                guard let a = byID[pair.0.id], let b = byID[pair.1.id],
                      let t0 = pair.0.annotation.sequenceTime, let t1 = pair.1.annotation.sequenceTime, t1 > t0, t1-t0 <= 2 else { continue }
                result.contradictions.count(a.action.opposes(b.action))
                if pair.0.annotation.preferredAction == pair.1.annotation.preferredAction { result.stability.count(a.action == b.action) }
            }
        }
        result.meanInferenceMilliseconds = times.isEmpty ? nil : times.reduce(0,+)/Double(times.count)
        return result
    }
}
struct EvaluationReport: Codable, Sendable {
    var schemaVersion = 1
    var baselineCommit = "beaced8242f97531bb54812850c0cf8a11922632"
    var createdAt = Date()
    var baseline: [EvaluationOutcome]
    var updated: [EvaluationOutcome]
    var baselineMetrics: EvaluationMetrics
    var updatedMetrics: EvaluationMetrics
    var errors: [String]
    var notes = "Paired settled-state image decisions share native detections, with separately frozen/new subject scoring at the default 0.68 selection threshold. Inference time is the current shared analyzer time, not a measured historical runtime. Sequence metrics require distinct timestamped images; a still image does not measure tracking accuracy, gyro shake, autofocus, RAW quality or live frame cadence. Expected labels are never inputs to automatic detection/selection. Apple aesthetics is supplementary and never creates movement directions."
}
struct EvaluationDataset: Codable, Sendable {
    var schemaVersion = 1
    var samples: [EvaluationSample]
    var report: EvaluationReport?
}
#endif
