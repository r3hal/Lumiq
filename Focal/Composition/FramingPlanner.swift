import Foundation

enum FramingPhase: Equatable {
    case off, searching, aligning, settling, zooming, verifying, framed, reacquiring, recoveringZoom, rediscovering
    var isAutoFraming: Bool { self == .zooming || self == .verifying }
    var isRecovering: Bool { self == .reacquiring || self == .recoveringZoom || self == .rediscovering }
    var isPreparing: Bool { self == .searching || self == .aligning || self == .settling || isAutoFraming || isRecovering }
}

/// The phone opts into continuous recovery. Legacy layout-only callers retain
/// their hold contract; both paths use this same director and camera controller.
struct FramingPlanner {
    let continuousRecovery: Bool
    init(continuousRecovery:Bool = false) { self.continuousRecovery = continuousRecovery }
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
    private var alignedPreparationSince: TimeInterval?
    private(set) var retryAt: TimeInterval?
    private(set) var retryCount = 0
    private var recoveryStartedAt: TimeInterval?
    enum RecoveryStep: Equatable { case waiting, aiming, verifying, rediscovered }
    enum ShotProgress: Equatable { case continuing, holding, recovering, resuming, achieved, cancel }
    mutating func noteBlock(_ reason:FramingBlockReason,at time:TimeInterval) {
        if blockReason != reason { blockedSince = time }
        blockReason = reason
        lastHoldEligible = false
    }
    mutating func stop(reason:FramingBlockReason) { reset(enabled:false); blockReason = reason }
    var waitDuration: TimeInterval { max(0,(lastHoldTime ?? blockedSince ?? 0)-(blockedSince ?? lastHoldTime ?? 0)) }
    var progressInstruction: String? {
        if continuousRecovery {
            if phase == .reacquiring { return "Reacquiring the selected subject…" }
            if phase == .recoveringZoom { return "Recovering the planned framing…" }
            if phase == .rediscovering { return "Finding your shot…" }
            if phase == .settling { return "Framing your shot…" }
            if blockReason == .cameraMotion || blockReason == .subjectMotion { return blockReason?.instruction }
        }
        guard let blockReason else { return nil }
        if blockReason == .aiming { return nil } // Keep geometry-based pan/tilt guidance.
        if recovering { return "\(blockReason.instruction). Recovering this shot…" }
        if phase == .off || [.quality,.missingPlan,.motionUnavailable,.telemetry,.staleFrame].contains(blockReason) || waitDuration >= 4 { return blockReason.instruction }
        return nil
    }
    mutating func recover(reason:FramingBlockReason,at time:TimeInterval) -> ShotProgress {
        if continuousRecovery { requestRecovery(reason:reason,at:time); return .recovering }
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
    /// Every ordinary interruption has a timed exit. Manual control and AI off
    /// are the only latches; retry exhaustion returns to discovery, never OFF.
    mutating func requestRecovery(reason:FramingBlockReason,at time:TimeInterval) {
        guard continuousRecovery, time.isFinite, phase != .off else { return }
        guard reason != .manualControl && reason != .disabled else { stop(reason:reason); return }
        guard !phase.isRecovering else { return } // Do not restart grace/backoff on each frame.
        shotVerified = false; currentFrameVerified = false; completionSince = nil; lastVerification = nil
        eligibleHold = 0; lastHoldEligible = false; alignedPreparationSince = nil
        retryCount += 1; recoveryStartedAt = time; noteBlock(reason,at:time)
        if shotPlan == nil || retryCount > 3 { beginRediscovery(at:time); return }
        phase = [.tracking,.unsafeCrop].contains(reason) ? .reacquiring : .recoveringZoom
        retryAt = time + [0.4,0.9,1.8][min(2,retryCount-1)]
        ShotFramingDiagnostics.log("RECOVERY_SCHEDULED","shot=\(shotPlan?.id ?? "none") reason=\(reason.rawValue) attempt=\(retryCount) retryAt=\(retryAt ?? time)")
    }
    private mutating func beginRediscovery(at time:TimeInterval) {
        phase = .rediscovering; shotPlan = nil; shotVerified = false; currentFrameVerified = false
        retryAt = time+2; recoveryStartedAt = time; completionSince = nil; currentFrameSince = nil
        ShotFramingDiagnostics.log("REDISCOVERY_SCHEDULED","reason=\(blockReason?.rawValue ?? "unknown") attempts=\(retryCount) retryAt=\(time+2)")
    }
    mutating func advanceRecovery(bounds:CGRect?,label:String,trackingReference:String?,confidence:Float,zoom:Double,
                                  aspect:Double,fresh:Bool,motionPermitted:Bool,timestamp:TimeInterval) -> RecoveryStep {
        guard continuousRecovery, phase.isRecovering, timestamp.isFinite else { return .waiting }
        if phase == .rediscovering {
            guard timestamp >= (retryAt ?? timestamp) else { return .waiting }
            reset(enabled:true)
            ShotFramingDiagnostics.log("DISCOVERY_RESUMED","time=\(timestamp)")
            return .rediscovered
        }
        let age = timestamp-(recoveryStartedAt ?? timestamp)
        let sameSubject = shotPlan.map { $0.subjectLabel == label && ($0.trackingReference == nil || $0.trackingReference == trackingReference) } ?? false
        guard sameSubject, fresh, confidence >= 0.65, let bounds, AutomaticShotPlan.valid(bounds) else {
            if age >= 1.5 { beginRediscovery(at:timestamp) }
            return .waiting
        }
        guard motionPermitted else {
            if age >= 4 { beginRediscovery(at:timestamp) }
            return .waiting
        }
        guard timestamp >= (retryAt ?? timestamp), let shotPlan else { return .waiting }
        // Read actual zoom/geometry after cancellation. A completed motor alone
        // cannot turn an unachieved composition into READY.
        if shotPlan.achieved(bounds:bounds,zoom:zoom,previewAspect:aspect),
           shotPlan.safeRemainingCrop(bounds:bounds,zoom:zoom,observedRegions:[],projectToTarget:false,allowTrackedMovement:true) {
            phase = .verifying; retryAt = nil; blockReason = nil; blockedSince = nil
            return .verifying
        }
        if shotPlan.scaleForCurrentBounds(bounds) <= 1.01 {
            let error = shotPlan.error(bounds:bounds,zoom:zoom,aspect:aspect)
            if error.width > 0.08 || error.height > 0.08 || error.zoom > 0.02 {
                // This plan needs a wider view or different proportions. Keep
                // actual zoom and discover a new measured composition.
                beginRediscovery(at:timestamp); return .waiting
            }
            // Only position changed: guide aim at the achieved scale. Do not
            // discard the composition or zoom again just to fix a pan error.
        }
        phase = .aligning; retryAt = nil; blockReason = .aiming; blockedSince = timestamp
        lastHoldTime = nil; stableSince = nil; anchor = nil
        ShotFramingDiagnostics.log("RECOVERY_REAIM","shot=\(shotPlan.id) actualZoom=\(zoom) remainingScale=\(shotPlan.scaleForCurrentBounds(bounds)) attempt=\(retryCount)")
        return .aiming
    }
    mutating func verifyExistingTargetIfAligned(bounds:CGRect?,label:String,confidence:Float,zoom:Double,aspect:Double,
                                                trackingReference:String?,fresh:Bool,motionPermitted:Bool) -> Bool {
        guard continuousRecovery, phase == .aligning, let shotPlan, let bounds,
              confidence >= 0.65, fresh, motionPermitted, label == shotPlan.subjectLabel,
              shotPlan.trackingReference == nil || shotPlan.trackingReference == trackingReference,
              shotPlan.achieved(bounds:bounds,zoom:zoom,previewAspect:aspect),
              shotPlan.safeRemainingCrop(bounds:bounds,zoom:zoom,observedRegions:[],projectToTarget:false,allowTrackedMovement:true) else { return false }
        phase = .verifying; blockReason = nil; blockedSince = nil; completionSince = nil; lastVerification = nil
        return true // A fresh stopped-motor/capture dwell is still required.
    }
    @discardableResult mutating func selectShot(_ plan:AutomaticShotPlan) -> Bool {
        guard phase.isPreparing, !phase.isAutoFraming, !phase.isRecovering, !shotVerified else { return false }
        if let current = shotPlan, current.requiresZoom { return false }
        shotPlan = plan
        retryCount = 0
        return true
    }
    mutating func commitShot(_ plan:AutomaticShotPlan) { shotPlan = plan; shotVerified = false; completionSince = nil; lastVerification = nil }
    mutating func verifyShot(bounds:CGRect?,label:String,confidence:Float,zoom:Double,stable:Bool,fresh:Bool,
                             timestamp:TimeInterval,previewAspect:Double,regions:[CGRect] = [], cameraRamping:Bool = false,
                             cameraFresh:Bool = true,cropPermitted:Bool = true,captureStable:Bool = true,trackingReference:String? = nil,
                             captureHoldDuration:TimeInterval = 0.2,liveZoom:Double? = nil) -> ShotProgress {
        guard phase.isAutoFraming, let shotPlan, timestamp.isFinite else { return .cancel }
        guard shotPlan.trackingReference == nil || shotPlan.trackingReference == trackingReference else { return rejectVerification(.tracking,at:timestamp) }
        guard label == shotPlan.subjectLabel else { return rejectVerification(.tracking,at:timestamp) }
        guard fresh else { return recover(reason:.staleFrame,at:timestamp) }
        guard cameraFresh else { return recover(reason:.telemetry,at:timestamp) }
        guard let bounds, confidence.isFinite, confidence >= 0.65 else { return recover(reason:.tracking,at:timestamp) }
        let achieved = shotPlan.achieved(bounds:bounds,zoom:zoom,previewAspect:previewAspect)
        guard shotPlan.safeRemainingCrop(bounds:bounds,zoom:zoom,observedRegions:regions,projectToTarget:!achieved,allowTrackedMovement:continuousRecovery) else {
            return rejectVerification(.unsafeCrop,at:timestamp)
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
            let motorAtTarget = liveZoom.map { $0.isFinite && abs($0/shotPlan.targetZoom-1) <= 0.02 } ?? true
            if cameraRamping || !captureStable || !motorAtTarget { completionSince = nil; return .holding }
            if completionSince == nil { completionSince = timestamp }
            let dwell = captureHoldDuration.isFinite ? max(0.2,min(3,captureHoldDuration)) : 3
            if timestamp-(completionSince ?? timestamp) >= dwell { shotVerified = true; finish(); return .achieved }
            return .holding
        }
        completionSince = nil
        // Being at the motor target with wrong composition cannot become READY.
        // The camera watchdog bounds this wait; it never reports a fake success.
        return .continuing
    }
    private mutating func rejectVerification(_ reason:FramingBlockReason,at time:TimeInterval) -> ShotProgress {
        if continuousRecovery { requestRecovery(reason:reason,at:time); return .recovering }
        blockReason = reason; return .cancel
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
        alignedPreparationSince = nil
        retryAt = nil; retryCount = 0; recoveryStartedAt = nil
        previous = nil; anchor = nil
        holdProgress = 0
    }
    mutating func finish() { phase = .framed; blockReason = nil; blockedSince = nil }
    mutating func revalidateCompletedShot(bounds:CGRect?,label:String,confidence:Float,zoom:Double,aspect:Double,timestamp:TimeInterval = 0,trackingReference:String? = nil) {
        guard shotVerified, let shotPlan else { return }
        guard let bounds, label == shotPlan.subjectLabel, confidence >= 0.65,
              (!continuousRecovery || shotPlan.trackingReference == nil || shotPlan.trackingReference == trackingReference),
              (continuousRecovery ? shotPlan.retainsAchieved(bounds:bounds,zoom:zoom,previewAspect:aspect) : shotPlan.achieved(bounds:bounds,zoom:zoom,previewAspect:aspect)),
              shotPlan.safeRemainingCrop(bounds:bounds,zoom:zoom,observedRegions:[],projectToTarget:false,allowTrackedMovement:continuousRecovery) else {
            if continuousRecovery { requestRecovery(reason:bounds == nil ? .tracking : .unsafeCrop,at:timestamp); return }
            stop(reason:.unsafeCrop); return
        }
    }
    mutating func confirmCurrentFrame(eligible:Bool,timestamp:TimeInterval,holdDuration:Double) {
        guard !phase.isAutoFraming, !phase.isRecovering, !shotVerified, phase != .off, shotPlan?.requiresZoom != true else { return }
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
        if recovering { return .recovering }
        switch phase {
        case .reacquiring: return .reacquiring
        case .recoveringZoom: return .recoveringZoom
        case .rediscovering: return .rediscovering
        case .off:
            if blockReason == .manualControl || blockReason == .disabled { return .canceled }
            if [.configuration,.zoomNotMoving,.deadline,.recoveryExpired,.unsafeCrop].contains(blockReason) { return .failed }
            return .paused
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
                         alignmentTarget: UnitPoint2D = .init(x:0.5,y:0.5), allowZoom: Bool = true, plannedScale: Double? = nil, zoomDestination: UnitPoint2D? = nil, requiresShotPlan:Bool = false, blockedBy:FramingBlockReason? = nil, startConfirmationDuration:TimeInterval? = nil) -> Double? {
        guard [roll,timestamp,currentZoom,maximumZoom,holdDuration,previewAspect].allSatisfy(\.isFinite), currentZoom > 0, maximumZoom >= currentZoom, previewAspect > 0 else { return nil }
        guard phase != .off, phase != .framed, !phase.isAutoFraming, !phase.isRecovering else { return nil }
        let requiredHold:TimeInterval
        if requiresShotPlan, let duration = startConfirmationDuration {
            guard duration.isFinite, duration > 0 else { noteBlock(.configuration,at:timestamp); return nil }
            requiredHold = continuousRecovery ? 0 : max(0.15,min(0.5,duration))
            if let since = alignedPreparationSince, timestamp-since >= 8 {
                if continuousRecovery { requestRecovery(reason:.deadline,at:timestamp); return nil }
                stop(reason:.deadline); return nil
            }
        } else { requiredHold = max(0.5,min(3,holdDuration)) }
        let previousHoldTime = lastHoldTime
        if let previousHoldTime, timestamp <= previousHoldTime { return nil }
        if requiresShotPlan, let previousHoldTime, timestamp-previousHoldTime > 1.25 {
            eligibleHold = 0; lastHoldEligible = false; stableSince = nil; anchor = nil
        }
        let elapsed = previousHoldTime.map { min(1.1,max(0,timestamp-$0)) } ?? 0
        lastHoldTime = timestamp
        holdProgress = requiresShotPlan && requiredHold > 0 ? min(1,eligibleHold/requiredHold) : 0
        guard let bounds, valid(bounds), confidence >= (continuousRecovery ? 0.65 : 0.6) else {
            if continuousRecovery, shotPlan != nil { requestRecovery(reason:.tracking,at:timestamp); return nil }
            phase = .searching; stableSince = nil; previous = nil; anchor = nil; noteBlock(.tracking,at:timestamp)
            return nil
        }
        defer { previous = bounds }
        guard alignmentTarget.x.isFinite, alignmentTarget.y.isFinite,
              (0...1).contains(alignmentTarget.x), (0...1).contains(alignmentTarget.y) else { stableSince = nil; return nil }
        let dx = Double(bounds.midX) - alignmentTarget.x
        let dy = Double(bounds.midY) - alignmentTarget.y
        let tolerance = Self.alignmentTolerance(plannedScale: plannedScale, destination: zoomDestination)
        guard hypot(dx,dy/max(0.1,previewAspect)) <= tolerance, continuousRecovery || abs(roll) <= 4 else {
            phase = .aligning; stableSince = nil; eligibleHold = 0; noteBlock(.aiming,at:timestamp)
            return nil
        }
        if !requiresShotPlan, let previous, abs(previous.midX - bounds.midX) > 0.035 || abs(previous.midY - bounds.midY) > 0.035
            || abs(previous.width - bounds.width) > 0.05 || abs(previous.height - bounds.height) > 0.05 {
            stableSince = nil
        }
        phase = continuousRecovery ? .aligning : .settling
        if requiresShotPlan, startConfirmationDuration != nil, alignedPreparationSince == nil { alignedPreparationSince = timestamp }
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
        if requiresShotPlan {
            // Subject motion inside the safe alignment envelope is not phone shake.
            // A short ineligible sample pauses accumulated hold rather than restarting it.
            if let blockedSince, timestamp-blockedSince > 1.25 { eligibleHold = 0 }
            if lastHoldEligible { eligibleHold += elapsed }
            lastHoldEligible = true; blockReason = nil; blockedSince = nil
            holdProgress = requiredHold == 0 ? 1 : min(1,eligibleHold/requiredHold)
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
            guard preZoom.distance(to:alignmentTarget) < 0.001, TargetRectangleGeometry.contains(margin,projected),
                  hypot(Double(projected.midX)-destination.x,(Double(projected.midY)-destination.y)/max(0.1,previewAspect)) <= 0.065,
                  supported.contains(where: { abs($0-scale) < 0.001 }), target > currentZoom*(continuousRecovery ? 1.01 : 1.12), target <= maximumZoom+0.001 else {
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
        let proposals = [1.0,1.15,1.35,1.6,2.0,2.5,3.0,detailZoomLimit/currentZoom] + native + [desiredScale].compactMap { $0 }
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
