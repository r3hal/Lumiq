import Foundation

/// Monotonic-clock diagnostic aggregates; does not store frames or claim device benchmarks.
struct GuidanceTimingAccumulator {
    private(set) var count = 0
    private(set) var inferenceMean = 0.0
    private(set) var decisionMean = 0.0
    private(set) var latencyMean = 0.0
    var staleRejections = 0
    private var firstTime: TimeInterval?
    private var lastTime: TimeInterval?
    var updateHz: Double? {
        guard count > 1, let firstTime, let lastTime, lastTime > firstTime else { return nil }
        return Double(count-1)/(lastTime-firstTime)
    }
    mutating func record(inferenceMS:Double,decisionMS:Double,latencyMS:Double,at time:TimeInterval) {
        guard [inferenceMS,decisionMS,latencyMS,time].allSatisfy({ $0.isFinite && $0 >= 0 }),
              lastTime.map({ time > $0 }) ?? true else { return }
        count += 1
        inferenceMean += (inferenceMS-inferenceMean)/Double(count)
        decisionMean += (decisionMS-decisionMean)/Double(count)
        latencyMean += (latencyMS-latencyMean)/Double(count)
        if firstTime == nil { firstTime = time }; lastTime = time
    }
}
