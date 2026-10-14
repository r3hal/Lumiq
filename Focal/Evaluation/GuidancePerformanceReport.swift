#if DEBUG || FOCAL_EVALUATION
import Foundation

/// Opt-in export of actual live timing aggregates; no photographs or device identifiers.
struct GuidancePerformanceReport: Codable, Sendable {
    var measuredAt = Date()
    var source: String
    var sampleCount: Int
    var meanInferenceMilliseconds: Double?
    var meanDecisionMilliseconds: Double?
    var meanObservationAgeMilliseconds: Double?
    var updatesPerSecond: Double?
    var staleRejections: Int
    var thermalState: String
    var notes = "Current analysis session aggregates. Vision timing includes detection/tracking; observation age includes queue, inference and reasoning but excludes final main-thread display delay. These are not before/after benchmarks or preview FPS."
    init(_ timing:GuidanceTimingAccumulator,source:String,thermalState:String) {
        self.source = source; sampleCount = timing.count
        meanInferenceMilliseconds = timing.count > 0 ? timing.inferenceMean : nil
        meanDecisionMilliseconds = timing.count > 0 ? timing.decisionMean : nil
        meanObservationAgeMilliseconds = timing.count > 0 ? timing.latencyMean : nil
        updatesPerSecond = timing.updateHz; staleRejections = timing.staleRejections
        self.thermalState = thermalState
    }
}
#endif
