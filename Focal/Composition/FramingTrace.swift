import Foundation

/// Observes the existing director; owns no plan, camera, or transition policy.
struct FramingTransitionTrace {
    private var session: Int?
    private var beganAt: TimeInterval = 0
    private var state: ShotDirectorState?
    private var stateBeganAt: TimeInterval = 0
    private var lastRecord: TimeInterval = -.infinity
    private var lastReason: String?
    mutating func record(sessionID:Int,shotID:String?,state next:ShotDirectorState,at time:TimeInterval,
                         values:[String:String]) -> String? {
        guard time.isFinite else { return nil }
        if session != sessionID || time < beganAt {
            session = sessionID; beganAt = time; state = nil; lastRecord = -.infinity; lastReason = nil
        }
        let changed = state != next
        let previousState = state
        let previousDuration = state.map { _ in max(0,time-stateBeganAt) }
        if changed { state = next; stateBeganAt = time }
        let reason = values["blockingReason"]
        guard changed || reason != lastReason || time-lastRecord >= 0.75 else { return nil }
        lastRecord = time; lastReason = reason
        let fields = values.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(reflecting:$0.value))" }.joined(separator:" ")
        let transition = changed ? " previousState=\(previousState?.rawValue ?? "none") previousStateSeconds=\(Self.number(previousDuration))" : ""
        return "session=\(sessionID) shot=\(shotID ?? "none") state=\(next.rawValue) sessionSeconds=\(Self.number(time-beganAt)) stateSeconds=\(Self.number(time-stateBeganAt))\(transition) \(fields)"
    }
    static func number(_ value:Double?) -> String {
        guard let value, value.isFinite else { return "unknown" }
        return String(format:"%.4f",value)
    }
    static func flag(_ value:Bool) -> String { value ? "YES" : "NO" }
}

/// Bounded in-memory developer trace, explicitly exported by the photographer.
/// Stores text measurements/events only, never camera frames or photographs.
final class FramingTraceBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var lines = [String]()
    init(limit:Int = 512) { self.limit = max(1,limit) }
    func append(_ line:String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(String(line.prefix(6000)))
        if lines.count > limit { lines.removeFirst(lines.count-limit) }
    }
    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator:"\n")
    }
}
