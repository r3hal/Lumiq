import Foundation

struct RecommendationMemory {
    private var shown: FeasibleGuidance?
    private var shownAt: TimeInterval = 0
    private var pending: FeasibleGuidance?
    private var pendingAt: TimeInterval = 0
    private var pendingSamples = 0
    private var previousBounds: CGRect?
    private var issueAtShown: Double?
    private var factsAtShown: CompositionAssessment?
    private var collateralSamples = 0
    private(set) var outcome = "unobserved"
    var currentAction: GuidanceAction? { shown?.action }
    private var subject: String?
    private var intent: PhotographyIntent?
    private var previousTime: TimeInterval?
    private var reconsiderUntil: TimeInterval = 0
    private var worseningSamples = 0
    mutating func reset() { self = Self() }
    mutating func update(_ decision: FeasibleGuidance, bounds: CGRect?, label: String, intent: PhotographyIntent, timestamp: TimeInterval, assessment: CompositionAssessment? = nil) -> FeasibleGuidance {
        guard timestamp.isFinite else { reset(); return .init(action:.none,text:"No reliable adjustment identified",confidence:0,issue:0) }
        let replaced = previousBounds.flatMap { old in bounds.map { box in
            hypot(Double(old.midX-box.midX),Double(old.midY-box.midY)) > 0.55
        } } ?? false
        if replaced || subject != label || self.intent != intent || previousTime.map({ timestamp < $0 || timestamp-$0 > 2.5 }) == true { reset() }
        if let previousTime, timestamp == previousTime { return shown ?? decision }
        defer { previousBounds = bounds; previousTime = timestamp; subject = label; self.intent = intent }
        if let initial = factsAtShown, let current = assessment, shown?.action.isAdjustment == true {
            let newClipping = !initial.touchesEdge && current.touchesEdge
            let newHighlights = (current.exposure?.highlightFraction ?? 0)-(initial.exposure?.highlightFraction ?? 0) > 0.12
            let lostHead = initial.protectedHead != nil && current.protectedHead == nil
            collateralSamples = newClipping || newHighlights || lostHead ? collateralSamples+1 : 0
            if collateralSamples >= 2 {
                outcome = "another observed factor worsened; no causal claim"
                reconsiderUntil = timestamp+1.5; shown = nil; pending = nil; factsAtShown = nil; collateralSamples = 0
            }
        }
        let changed = previousBounds.flatMap { old in bounds.map { box in
            hypot(Double(old.midX-box.midX),Double(old.midY-box.midY)) > 0.025 || abs(Double(old.width-box.width)) > 0.06
        } } ?? false
        if shown?.action == decision.action, let issueAtShown {
            if decision.issue < issueAtShown-0.08 { outcome = "measured issue improved" }
            else if decision.issue > issueAtShown+0.08 { outcome = "measured issue worsened" }
            else { outcome = "no significant measured change" }
        }
        if changed, shown?.action == decision.action, decision.action.isAdjustment, let issueAtShown, decision.issue > issueAtShown+0.08 {
            worseningSamples += 1
        } else { worseningSamples = 0 }
        if worseningSamples >= 2 { reconsiderUntil = timestamp+1.5; shown = nil; pending = nil; worseningSamples = 0 }
        if timestamp < reconsiderUntil { return .init(action:.hold,text:"Keep this frame while guidance reassesses",confidence:decision.confidence,issue:0) }
        let opposite = shown.map { decision.action.opposes($0.action) } ?? false
        let cropReversal = opposite && [.makeRoom,.tighterCrop].contains(decision.action)
        if decision.action == .none || decision.action == .hold || (decision.action == .makeRoom && !cropReversal) || shown == nil {
            outcome = decision.action == .none && shown?.action.isAdjustment == true ? "adjustment no longer needed" : outcome
            shown = decision; issueAtShown = decision.issue; factsAtShown = assessment; shownAt = timestamp; pending = nil; return decision
        }
        if shown?.action == decision.action { shown = decision; return decision }
        if pending?.action != decision.action { pending = decision; pendingAt = timestamp; pendingSamples = 1 }
        else { pending = decision; pendingSamples += 1 }
        let delay = opposite ? 1.4 : 0.7
        if timestamp-shownAt >= 1.8, timestamp-pendingAt >= delay, pendingSamples >= 2 {
            shown = decision; issueAtShown = decision.issue; factsAtShown = assessment; shownAt = timestamp; pending = nil
        }
        // A sudden crop reversal never continues the unsafe old crop advice.
        if cropReversal, shown?.action != decision.action {
            return .init(action:.hold,text:"Hold this frame while guidance reassesses",confidence:decision.confidence,issue:0)
        }
        if shown?.action != decision.action && !opposite {
            return .init(action:.hold,text:"Hold this frame while guidance reassesses",confidence:decision.confidence,issue:0)
        }
        return shown ?? decision
    }
}
