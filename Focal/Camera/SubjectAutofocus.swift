import Foundation

/// A short-lived geometric projection of an actually observed face/head. This
/// neither detects an eye nor introduces another subject tracker.
struct TrackedFocusRegion {
    let identity: String
    let subject: CGRect
    let region: CGRect
    let observedAt: TimeInterval
    func projected(in bounds:CGRect,identity:String,at time:TimeInterval) -> CGRect? {
        guard self.identity == identity, time.isFinite, observedAt.isFinite, time >= observedAt, time-observedAt <= 1.5,
              AutomaticShotPlan.valid(subject), AutomaticShotPlan.valid(bounds), AutomaticShotPlan.valid(region) else { return nil }
        let r = CGRect(x:bounds.minX+(region.minX-subject.minX)*bounds.width/subject.width,
            y:bounds.minY+(region.minY-subject.minY)*bounds.height/subject.height,
            width:region.width*bounds.width/subject.width,height:region.height*bounds.height/subject.height)
        guard SubjectAutofocus.contains(bounds,r) else { return nil }
        return r
    }
}

struct SubjectFocusTarget: Equatable {
    let identity: String
    let point: UnitPoint2D // Visible preview coordinates; AVFoundation converts to device coordinates.
    let region: CGRect
    let usesObservedHead: Bool
    let observedAt: TimeInterval
    let zoom: Double
    func point(atZoom current:Double) -> UnitPoint2D? {
        guard zoom.isFinite, zoom > 0, current.isFinite, current > 0 else { return nil }
        let scale = current/zoom
        let p = UnitPoint2D(x:0.5+(point.x-0.5)*scale,y:0.5+(point.y-0.5)*scale)
        return [p.x,p.y].allSatisfy { $0.isFinite && (0...1).contains($0) } ? p : nil
    }
}

/// Focus-only smoothing/rate/loss policy. Identity and rectangles are supplied
/// by the existing ShotPlan/Vision tracker; this cannot select another subject.
struct SubjectAutofocus {
    enum Update: Equatable {
        case target(SubjectFocusTarget)
        case maintain(identity:String,observedAt:TimeInterval)
        case normal
    }
    private(set) var identity: String?
    private(set) var lastReliableAt: TimeInterval?
    private var lostSince: TimeInterval?
    private var filtered: UnitPoint2D?
    private var lastSent: UnitPoint2D?
    private var lastSentAt: TimeInterval = -.infinity
    private var filterTime: TimeInterval?
    private var released = true
    mutating func reset() { self = Self() }
    mutating func update(enabled:Bool,selectedIdentity:String?,observedIdentity:String?,bounds:CGRect?,confidence:Float,
                         head:CGRect? = nil,headObservedAt:TimeInterval? = nil,observedAt:TimeInterval,now:TimeInterval,zoom:Double = 1) -> Update? {
        guard now.isFinite else { return nil }
        guard enabled else { return release() }
        let reliable = selectedIdentity != nil && selectedIdentity == observedIdentity && confidence.isFinite && confidence >= 0.65
            && zoom.isFinite && zoom > 0
            && GuidanceObservationPolicy.fresh(capturedAt:observedAt,evaluatedAt:now)
        guard reliable, let selectedIdentity, let bounds, Self.validVisible(bounds) else {
            if lostSince == nil { lostSince = now }
            return now-(lostSince ?? now) >= 1.5 ? release() : nil
        }
        let reacquired = lostSince != nil || lastReliableAt.map { now-$0 > 1.5 } == true
        if identity != selectedIdentity || reacquired {
            filtered = nil; lastSent = nil; lastSentAt = -.infinity; filterTime = nil
        }
        identity = selectedIdentity; lastReliableAt = observedAt; lostSince = nil; released = false
        let visible = bounds.intersection(CGRect(x:0,y:0,width:1,height:1))
        let headFresh = headObservedAt.map { $0.isFinite && now >= $0 && now-$0 <= 1.5 } ?? false
        let useHead = headFresh && head.map { Self.contains(bounds,$0) && Self.validVisible($0) } == true
        let region = useHead ? (head ?? visible).intersection(visible) : visible
        let raw = UnitPoint2D(x:region.midX,y:region.midY)
        let dt = max(0,now-(filterTime ?? now))
        let alpha = 1-exp(-dt/0.14)
        let next:UnitPoint2D
        if let filtered, filtered.distance(to:raw) < 0.2 {
            next = .init(x:filtered.x+(raw.x-filtered.x)*alpha,y:filtered.y+(raw.y-filtered.y)*alpha)
        } else { next = raw }
        // Smoothing cannot leave the current head/body region and meter a background.
        let inset = region.insetBy(dx:region.width*0.1,dy:region.height*0.1)
        let point = UnitPoint2D(x:min(inset.maxX,max(inset.minX,next.x)),y:min(inset.maxY,max(inset.minY,next.y)))
        filtered = point; filterTime = now
        guard now-lastSentAt >= 0.2 else { return .maintain(identity:selectedIdentity,observedAt:observedAt) }
        // A stationary subject still uses continuous AF for depth changes. The
        // once-per-second refresh audits device mode; it need not lock/change it.
        guard lastSent == nil || lastSent!.distance(to:point) >= 0.008 || now-lastSentAt >= 1 else {
            return .maintain(identity:selectedIdentity,observedAt:observedAt)
        }
        lastSent = point; lastSentAt = now
        return .target(.init(identity:selectedIdentity,point:point,region:region,usesObservedHead:useHead,observedAt:observedAt,zoom:zoom))
    }
    private mutating func release() -> Update? {
        let shouldRelease = !released
        reset()
        return shouldRelease ? .normal : nil
    }
    static func validVisible(_ r:CGRect) -> Bool {
        AutomaticShotPlan.valid(r) && r.intersection(CGRect(x:0,y:0,width:1,height:1)).width > 0
            && r.intersection(CGRect(x:0,y:0,width:1,height:1)).height > 0
    }
    static func contains(_ bounds:CGRect,_ r:CGRect) -> Bool {
        guard AutomaticShotPlan.valid(bounds), AutomaticShotPlan.valid(r) else { return false }
        return TargetRectangleGeometry.contains(bounds.insetBy(dx:-0.001,dy:-0.001),r)
    }
}

/// Reject delayed main-thread coordinate conversions after a new subject,
/// source, device, manual-focus action or AI-off. It owns no tracking decisions.
final class AutofocusRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    private var manualFocus = false
    @discardableResult func invalidate() -> Int {
        lock.lock(); defer { lock.unlock() }; revision += 1; return revision
    }
    func accepts(_ value:Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == revision }
    func setManualFocus(_ enabled:Bool) {
        lock.lock(); defer { lock.unlock() }
        if manualFocus != enabled { manualFocus = enabled; revision += 1 }
    }
    var manuallyControlled: Bool { lock.lock(); defer { lock.unlock() }; return manualFocus }
}
