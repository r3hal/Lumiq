import Foundation

struct RecommendationMemory {
    private var shown: FeasibleGuidance?
    private var shownAt: TimeInterval = 0
    private var pending: FeasibleGuidance?
    private var pendingAt: TimeInterval = 0
    private var pendingSamples = 0
    private var previousBounds: CGRect?
    private var previousIssue: Double?
    private var subject: String?
    private var intent: PhotographyIntent?
    private var previousTime: TimeInterval?
    private var reconsiderUntil: TimeInterval = 0
    private var worseningSamples = 0
    mutating func reset() { self = Self() }
    mutating func update(_ decision: FeasibleGuidance, bounds: CGRect?, label: String, intent: PhotographyIntent, timestamp: TimeInterval) -> FeasibleGuidance {
        guard timestamp.isFinite else { reset(); return .init(action:.none,text:"No reliable adjustment identified",confidence:0,issue:0) }
        if subject != label || self.intent != intent || previousTime.map({ timestamp < $0 || timestamp-$0 > 2.5 }) == true { reset() }
        defer { previousBounds = bounds; previousIssue = decision.issue; previousTime = timestamp; subject = label; self.intent = intent }
        let changed = previousBounds.flatMap { old in bounds.map { box in
            hypot(Double(old.midX-box.midX),Double(old.midY-box.midY)) > 0.025 || abs(Double(old.width-box.width)) > 0.06
        } } ?? false
        if changed, shown?.action == decision.action, decision.showsDirection, let previousIssue, decision.issue > previousIssue+0.08 {
            worseningSamples += 1
        } else { worseningSamples = 0 }
        if worseningSamples >= 2 { reconsiderUntil = timestamp+1.5; shown = nil; pending = nil; worseningSamples = 0 }
        if timestamp < reconsiderUntil { return .init(action:.hold,text:"Keep this frame while guidance reassesses",confidence:decision.confidence,issue:0) }
        if decision.action == .none || decision.action == .hold || decision.action == .makeRoom || shown == nil {
            shown = decision; shownAt = timestamp; pending = nil; return decision
        }
        if shown?.action == decision.action { shown = decision; return decision }
        if pending?.action != decision.action { pending = decision; pendingAt = timestamp; pendingSamples = 1 }
        else { pending = decision; pendingSamples += 1 }
        let opposite = shown.map { decision.action.opposes($0.action) } ?? false
        let delay = opposite ? 1.4 : 0.7
        if timestamp-shownAt >= 1.8, timestamp-pendingAt >= delay, pendingSamples >= 2 {
            shown = decision; shownAt = timestamp; pending = nil
        }
        return shown ?? decision
    }
}
