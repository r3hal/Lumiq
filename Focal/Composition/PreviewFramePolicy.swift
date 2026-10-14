import Foundation

/// The preview never waits on Vision, and Vision never holds its camera buffer.
struct PreviewAnalysisScheduler {
    init(interval: TimeInterval = 0.25) { self.interval = max(0.1,interval) }
    var interval: TimeInterval = 0.25
    private(set) var busy = false
    private var lastAdmission: TimeInterval = -.infinity
    mutating func admit(at timestamp: TimeInterval, enabled: Bool) -> Bool {
        guard enabled, timestamp.isFinite, !busy, timestamp - lastAdmission >= interval else { return false }
        busy = true; lastAdmission = timestamp; return true
    }
    mutating func finish() { busy = false }
    static func thermalInterval(_ state:ProcessInfo.ThermalState) -> TimeInterval {
        switch state {
        case .nominal: return 0.25
        case .fair: return 0.4
        case .serious: return 0.8
        case .critical: return 1.5
        @unknown default: return 0.8
        }
    }
}

/// Camera configuration receives the newest gesture value rather than a queue
/// of obsolete pinch positions. Caller supplies the synchronization/dispatch.
struct ZoomRequestCoalescer {
    private var pending: Double?
    private var scheduled = false
    mutating func enqueue(_ value: Double) -> Bool {
        guard value.isFinite, value > 0 else { return false }
        pending = value
        if scheduled { return false }
        scheduled = true; return true
    }
    mutating func take() -> Double? {
        defer { pending = nil; scheduled = false }
        return pending
    }
    mutating func clear() { pending = nil; scheduled = false }
}

struct PreviewFrameCadence {
    private var start: TimeInterval?
    private var previous: TimeInterval?
    private var intervals = 0
    mutating func observe(_ timestamp: TimeInterval) -> Double? {
        guard timestamp.isFinite else { return nil }
        if let previous, timestamp <= previous { return nil }
        previous = timestamp
        guard let start else { self.start = timestamp; return nil }
        intervals += 1
        let elapsed = timestamp - start
        guard elapsed >= 1 else { return nil }
        let rate = Double(intervals) / elapsed
        self.start = timestamp; intervals = 0
        return rate
    }
}
