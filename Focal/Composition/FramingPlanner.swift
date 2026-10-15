import Foundation

enum FramingPhase: Equatable {
    case off, searching, aligning, settling, zooming, verifying, framed
    var isAutoFraming: Bool { self == .zooming || self == .verifying }
    var isPreparing: Bool { self == .searching || self == .aligning || self == .settling || isAutoFraming }
}

/// A scan produces at most one zoom. Manual zoom cancels it until the next scan.
struct FramingPlanner {
    private(set) var phase: FramingPhase = .searching
    private(set) var shotPlan: AutomaticShotPlan?
    private(set) var shotVerified = false
    private(set) var currentFrameVerified = false
    private var currentFrameSince: TimeInterval?
    private var completionSince: TimeInterval?
    private var lastVerification: TimeInterval?
    private(set) var blockReason: FramingBlockReason?
    private(set) var blockedSince: TimeInterval?
    private(set) var recovering = false
    private var recoverySince: TimeInterval?
    private var recoveryGoodSince: TimeInterval?
    private var recoveryAttempts = 0
    private var recoveredSeconds: TimeInterval = 0
    private var eligibleHold: TimeInterval = 0
    private var lastHoldTime: TimeInterval?
    private var lastHoldEligible = false
    enum ShotProgress: Equatable { case continuing, holding, recovering, resuming, achieved, cancel }
    mutating func noteBlock(_ reason:FramingBlockReason,at time:TimeInterval) {
        if blockReason != reason { blockedSince = time }
        blockReason = reason
        lastHoldEligible = false
    }
    mutating func stop(reason:FramingBlockReason) { reset(enabled:false); blockReason = reason }
    var waitDuration: TimeInterval { max(0,(lastHoldTime ?? blockedSince ?? 0)-(blockedSince ?? lastHoldTime ?? 0)) }
    var progressInstruction: String? {
        guard let blockReason else { return nil }
        if blockReason == .aiming { return nil } // Keep geometry-based pan/tilt guidance.
        if recovering { return "\(blockReason.instruction). Recovering this shot…" }
        if phase == .off || [.quality,.missingPlan,.motionUnavailable,.telemetry,.staleFrame].contains(blockReason) || waitDuration >= 4 { return blockReason.instruction }
        return nil
    }
    mutating func recover(reason:FramingBlockReason,at time:TimeInterval) -> ShotProgress {
        guard time.isFinite, shotPlan != nil, phase.isAutoFraming else { return .cancel }
        if !recovering {
            recoveryAttempts += 1; recovering = true; recoverySince = time
        }
        completionSince = nil; recoveryGoodSince = nil
        noteBlock(reason,at:time)
        if recoveryAttempts > 2 || time-(recoverySince ?? time)+recoveredSeconds > 1.25 {
            blockReason = .recoveryExpired; return .cancel
        }
        return .recovering
    }
    mutating func commitShot(_ plan:AutomaticShotPlan) { shotPlan = plan; shotVerified = false; completionSince = nil; lastVerification = nil }
    mutating func verifyShot(bounds:CGRect?,label:String,confidence:Float,zoom:Double,stable:Bool,fresh:Bool,
                             timestamp:TimeInterval,previewAspect:Double,regions:[CGRect] = [], cameraRamping:Bool = false,
                             cameraFresh:Bool = true,cropPermitted:Bool = true) -> ShotProgress {
        guard phase.isAutoFraming, let shotPlan, timestamp.isFinite else { return .cancel }
        guard label == shotPlan.subjectLabel else { blockReason = .tracking; return .cancel }
        guard fresh else { return recover(reason:.staleFrame,at:timestamp) }
        guard cameraFresh else { return recover(reason:.telemetry,at:timestamp) }
        guard let bounds, confidence.isFinite, confidence >= 0.65 else { return recover(reason:.tracking,at:timestamp) }
        let achieved = shotPlan.achieved(bounds:bounds,zoom:zoom,previewAspect:previewAspect)
        guard shotPlan.safeRemainingCrop(bounds:bounds,zoom:zoom,observedRegions:regions,projectToTarget:!achieved) else {
            blockReason = .unsafeCrop; return .cancel
        }
        guard stable else { return recover(reason:.cameraMotion,at:timestamp) }
        guard cropPermitted else { return recover(reason:.quality,at:timestamp) }
        if recovering {
            if timestamp-(recoverySince ?? timestamp)+recoveredSeconds > 1.25 { blockReason = .recoveryExpired; return .cancel }
            if recoveryGoodSince == nil { recoveryGoodSince = timestamp }
            guard timestamp-(recoveryGoodSince ?? timestamp) >= 0.2 else { return .recovering }
            recoveredSeconds += timestamp-(recoverySince ?? timestamp)
            recovering = false; recoverySince = nil; recoveryGoodSince = nil
            blockReason = nil; blockedSince = nil; completionSince = nil
            if !achieved { phase = .zooming; return .resuming }
        }
        if let lastVerification, timestamp <= lastVerification { return completionSince == nil ? .continuing : .holding }
        lastVerification = timestamp
        if achieved {
            phase = .verifying
            if cameraRamping { completionSince = nil; return .holding }
            if completionSince == nil { completionSince = timestamp }
            if timestamp-(completionSince ?? timestamp) >= 0.2 { shotVerified = true; finish(); return .achieved }
            return .holding
        }
        completionSince = nil
        // Being at the motor target with wrong composition cannot become READY.
        // The camera watchdog bounds this wait; it never reports a fake success.
        return .continuing
    }
    private var stableSince: TimeInterval?
    private var previous: CGRect?
    private var anchor: CGRect?
    private(set) var holdProgress: Double = 0

    mutating func reset(enabled: Bool) {
        phase = enabled ? .searching : .off
        shotPlan = nil; shotVerified = false; currentFrameVerified = false; currentFrameSince = nil; completionSince = nil; lastVerification = nil
        stableSince = nil
        blockReason = nil; blockedSince = nil; recovering = false; recoverySince = nil; recoveryGoodSince = nil
        recoveryAttempts = 0; recoveredSeconds = 0; eligibleHold = 0; lastHoldTime = nil; lastHoldEligible = false
        previous = nil; anchor = nil
        holdProgress = 0
    }
    mutating func finish() { phase = .framed; blockReason = nil; blockedSince = nil }
    mutating func revalidateCompletedShot(bounds:CGRect?,label:String,confidence:Float,zoom:Double,aspect:Double) {
        guard shotVerified, let shotPlan else { return }
        guard let bounds, label == shotPlan.subjectLabel, confidence >= 0.65,
              shotPlan.achieved(bounds:bounds,zoom:zoom,previewAspect:aspect),
              shotPlan.safeRemainingCrop(bounds:bounds,zoom:zoom,observedRegions:[],projectToTarget:false) else {
            stop(reason:.unsafeCrop); return
        }
    }
    mutating func confirmCurrentFrame(eligible:Bool,timestamp:TimeInterval,holdDuration:Double) {
        guard !phase.isAutoFraming, !shotVerified, phase != .off else { return }
        guard eligible, timestamp.isFinite else {
            if currentFrameVerified { reset(enabled:true) }
            currentFrameSince = nil; currentFrameVerified = false
            return
        }
        if currentFrameSince == nil { currentFrameSince = timestamp }
        if timestamp-(currentFrameSince ?? timestamp) >= max(0.5,min(3,holdDuration)) {
            currentFrameVerified = true; finish()
        }
    }
    func directorState(hasPlan:Bool) -> ShotDirectorState {
        switch phase {
        case .off: return .paused
        case .searching: return hasPlan ? .shotSelected : .discovering
        case .aligning: return .aiming
        case .settling: return .aligned
        case .zooming: return .autoZooming
        case .verifying: return .verifyingFraming
        case .framed: return shotVerified || currentFrameVerified ? .ready : .paused
        }
    }

    mutating func update(bounds: CGRect?, confidence: Float, roll: Double, timestamp: TimeInterval,
                         currentZoom: Double, maximumZoom: Double, detailZoomLimit: Double? = nil, nativeStops: [Double] = [], deviceStable: Bool = true, holdDuration: Double = 0.75, previewAspect: Double = 0.75,
                         alignmentTarget: UnitPoint2D = .init(x:0.5,y:0.5), allowZoom: Bool = true, plannedScale: Double? = nil, zoomDestination: UnitPoint2D? = nil, requiresShotPlan:Bool = false, blockedBy:FramingBlockReason? = nil) -> Double? {
        guard [roll,timestamp,currentZoom,maximumZoom,holdDuration,previewAspect].allSatisfy(\.isFinite), currentZoom > 0, maximumZoom >= currentZoom, previewAspect > 0 else { return nil }
        guard phase != .off, phase != .framed, !phase.isAutoFraming else { return nil }
        let previousHoldTime = lastHoldTime
        if let previousHoldTime, timestamp <= previousHoldTime { return nil }
        if requiresShotPlan, let previousHoldTime, timestamp-previousHoldTime > 1.25 {
            eligibleHold = 0; lastHoldEligible = false; stableSince = nil; anchor = nil
        }
        let elapsed = previousHoldTime.map { min(1.1,max(0,timestamp-$0)) } ?? 0
        lastHoldTime = timestamp
        holdProgress = requiresShotPlan ? min(1,eligibleHold/max(0.5,min(3,holdDuration))) : 0
        guard let bounds, valid(bounds), confidence >= 0.6 else {
            phase = .searching; stableSince = nil; previous = nil; anchor = nil; noteBlock(.tracking,at:timestamp)
            return nil
        }
        defer { previous = bounds }
        guard alignmentTarget.x.isFinite, alignmentTarget.y.isFinite,
              (0...1).contains(alignmentTarget.x), (0...1).contains(alignmentTarget.y) else { stableSince = nil; return nil }
        let dx = Double(bounds.midX) - alignmentTarget.x
        let dy = Double(bounds.midY) - alignmentTarget.y
        let tolerance = Self.alignmentTolerance(plannedScale: plannedScale, destination: zoomDestination)
        guard hypot(dx,dy/max(0.1,previewAspect)) <= tolerance, abs(roll) <= 4 else {
            phase = .aligning; stableSince = nil; eligibleHold = 0; noteBlock(.aiming,at:timestamp)
            return nil
        }
        if !requiresShotPlan, let previous, abs(previous.midX - bounds.midX) > 0.035 || abs(previous.midY - bounds.midY) > 0.035
            || abs(previous.width - bounds.width) > 0.05 || abs(previous.height - bounds.height) > 0.05 {
            stableSince = nil
        }
        phase = .settling
        // A temporary quality/tracking/light/plan gate must never finish a shot.
        if requiresShotPlan && (!allowZoom || plannedScale == nil || zoomDestination == nil) {
            stableSince = nil; anchor = nil; noteBlock(blockedBy ?? (plannedScale == nil ? .missingPlan : .quality),at:timestamp); return nil
        }
        if !deviceStable {
            stableSince = nil; anchor = nil; noteBlock(blockedBy ?? .cameraMotion,at:timestamp); return nil
        }
        if !requiresShotPlan, let anchor, hypot(Double(anchor.midX-bounds.midX),Double(anchor.midY-bounds.midY)) > 0.04
            || abs(anchor.width-bounds.width) > 0.06 || abs(anchor.height-bounds.height) > 0.06 {
            stableSince = nil; self.anchor = nil
        }
        if stableSince == nil { stableSince = timestamp; anchor = bounds }
        let requiredHold = max(0.5,min(3,holdDuration))
        if requiresShotPlan {
            // Subject motion inside the safe alignment envelope is not phone shake.
            // A short ineligible sample pauses accumulated hold rather than restarting it.
            if let blockedSince, timestamp-blockedSince > 1.25 { eligibleHold = 0 }
            if lastHoldEligible { eligibleHold += elapsed }
            lastHoldEligible = true; blockReason = nil; blockedSince = nil
            holdProgress = min(1,eligibleHold/requiredHold)
        } else { holdProgress = min(1, max(0, (timestamp - (stableSince ?? timestamp)) / requiredHold)) }
        guard holdProgress >= 1 else { return nil }
        guard allowZoom else { phase = .framed; return nil }
        if let plannedScale, !plannedScale.isFinite || plannedScale < 1 { phase = .framed; return nil }
        if let destination = zoomDestination, let scale = plannedScale {
            guard [destination.x,destination.y].allSatisfy(\.isFinite), (0...1).contains(destination.x), (0...1).contains(destination.y) else { phase = .framed; return nil }
            let preZoom = UnitPoint2D(x:0.5+(destination.x-0.5)/scale,y:0.5+(destination.y-0.5)/scale)
            let target = currentZoom*scale
            let projected = Self.zoomedRect(bounds,scale:scale)
            let margin = CGRect(x:0.025,y:0.025,width:0.95,height:0.95)
            let supported = Self.availableScales(currentZoom:currentZoom,maximumZoom:maximumZoom,detailZoomLimit:detailZoomLimit ?? maximumZoom,nativeStops:nativeStops,maximumScale:scale,desiredScale:scale)
            guard preZoom.distance(to:alignmentTarget) < 0.001, margin.contains(projected),
                  hypot(Double(projected.midX)-destination.x,(Double(projected.midY)-destination.y)/max(0.1,previewAspect)) <= 0.065,
                  supported.contains(where: { abs($0-scale) < 0.001 }), target > currentZoom*1.12, target <= maximumZoom+0.001 else {
                phase = requiresShotPlan ? .aligning : .framed; stableSince = nil; anchor = nil; eligibleHold = 0; noteBlock(.unsafeCrop,at:timestamp); return nil
            }
            phase = .zooming
            return target
        }
        // Legacy/manual layouts require a centered target unless the planner
        // supplies a verified pre-zoom point and final destination above.
        guard alignmentTarget.distance(to:.init(x:0.5,y:0.5)) < 0.01 else { phase = .framed; return nil }
        // Account for the off-center extent, so zoom never cuts off the selected subject.
        let fit = min(0.72 / (Double(bounds.width) + 2 * abs(dx)),
                      0.62 / (Double(bounds.height) + 2 * abs(dy)))
        let centerDistance = hypot(dx,dy/max(0.1,previewAspect))
        let positionLimit = centerDistance > 0.01 ? 0.06/centerDistance : 5
        let scaleLimit = min(5,plannedScale ?? 5)
        let desired = max(currentZoom,min(maximumZoom,currentZoom*min(scaleLimit,min(fit,positionLimit))))
        // Above the preview pixel budget, prefer an actual lens position.
        // A telephoto lens does not make all intermediate digital zooms optical.
        let target: Double
        if let detailZoomLimit, desired > detailZoomLimit {
            target = max(currentZoom, max(detailZoomLimit, nativeStops.filter { $0 <= desired }.max() ?? currentZoom))
        } else { target = desired }
        guard target > currentZoom * 1.12 else { phase = .framed; return nil }
        phase = .zooming
        return target
    }

    static func zoomedRect(_ rect: CGRect, scale: Double) -> CGRect {
        CGRect(x: (rect.minX - 0.5) * scale + 0.5, y: (rect.minY - 0.5) * scale + 0.5,
               width: rect.width * scale, height: rect.height * scale)
    }
    static func alignmentTolerance(plannedScale: Double?, destination: UnitPoint2D?) -> Double {
        guard destination != nil, let scale = plannedScale, scale.isFinite, scale > 1 else { return 0.04 }
        return min(0.04,0.06/scale)
    }
    static func availableScales(currentZoom: Double, maximumZoom: Double, detailZoomLimit: Double, nativeStops: [Double], maximumScale: Double, desiredScale:Double? = nil) -> [Double] {
        guard [currentZoom,maximumZoom,detailZoomLimit,maximumScale].allSatisfy(\.isFinite), currentZoom > 0, maximumZoom >= currentZoom, maximumScale >= 1 else { return [1] }
        let native = nativeStops.filter { $0.isFinite && $0 > currentZoom }.map { $0/currentZoom }
        let proposals = [1.0,1.15,1.35,1.6,2.0,2.5,3.0] + native + [desiredScale].compactMap { $0 }
        return Array(Set(proposals.filter { scale in
            scale >= 1 && scale <= maximumScale && currentZoom*scale <= maximumZoom+0.001
                && (scale == 1 || currentZoom*scale <= detailZoomLimit+0.001 || native.contains(where: { abs($0-scale) < 0.001 }))
        })).sorted()
    }

    private func valid(_ rect: CGRect) -> Bool {
        let values = [rect.minX, rect.minY, rect.width, rect.height]
        return values.allSatisfy { $0.isFinite } && rect.width > 0.025 && rect.height > 0.025
            && rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1
    }
}

/// Contextual final advice without pretending a local classifier is a cloud scene model.
enum SubjectAdvice {
    static func text(for label: String) -> String {
        let name = label.lowercased()
        let words = Set(name.split { !$0.isLetter }.map(String.init))
        if words.contains("cat") { return "Isolate the cat, tighten the frame." }
        if words.contains("dog") { return "Isolate the dog, keep the eyes in focus." }
        if name.contains("person") || name.contains("face") { return "Focus on the eyes, leave a little breathing room." }
        if name.contains("flower") || name.contains("plant") { return "Isolate the details, simplify the background." }
        if name.contains("keyboard") { return "Isolate the keys, tighten the frame." }
        if name.contains("subject") { return "Isolate your subject, tighten the frame." }
        return "Isolate the \(name), tighten the frame."
    }
}
