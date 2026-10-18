import Foundation

enum ShotDirectorState: String {
    case discovering = "DISCOVERING", shotSelected = "SHOT_SELECTED", aiming = "AIMING", aligned = "ALIGNED"
    case autoZooming = "AUTO_ZOOMING", verifyingFraming = "VERIFYING_FRAMING", ready = "READY", paused = "PAUSED", recovering = "RECOVERING", canceled = "CANCELED", failed = "FAILED"
    case reacquiring = "REACQUIRING", recoveringZoom = "RECOVERING_ZOOM", rediscovering = "REDISCOVERING"
}

struct CameraZoomObservation {
    var hardwareFactor: Double
    var multiplier: Double
    var ramping: Bool
    var timestamp: TimeInterval
    var displayedFactor: Double { hardwareFactor / multiplier }
    func fresh(at time:TimeInterval) -> Bool {
        hardwareFactor.isFinite && hardwareFactor > 0 && multiplier.isFinite && multiplier > 0
            && timestamp.isFinite && time >= timestamp && time-timestamp <= 0.3
    }
    func matchesFrame(capturedAt:TimeInterval,evaluatedAt:TimeInterval) -> Bool {
        hardwareFactor.isFinite && hardwareFactor > 0 && multiplier.isFinite && multiplier > 0
            && timestamp.isFinite && timestamp <= evaluatedAt && abs(timestamp-capturedAt) <= 0.3
            && GuidanceObservationPolicy.fresh(capturedAt:capturedAt,evaluatedAt:evaluatedAt)
    }
    static func hardwareTarget(displayed:Double,multiplier:Double,minimum:Double,maximum:Double) -> Double? {
        guard [displayed,multiplier,minimum,maximum].allSatisfy(\.isFinite), displayed > 0, multiplier > 0 else { return nil }
        let target = displayed*multiplier
        return target >= minimum && target <= maximum ? target : nil
    }
}

enum ShotReadiness {
    static func measuredCurrentFrame(plan:SceneCompositionPlan?,assessment:CompositionAssessment,
                                     label:String,timestamp:TimeInterval,stable:Bool,retaining:Bool = false) -> Bool {
        guard let plan, plan.subjectLabel == label, plan.selected.isCurrentFrame, abs(plan.selected.zoomScale-1) < 0.001,
              timestamp >= plan.timestamp, timestamp-plan.timestamp <= 2.5,
              stable, assessment.assessmentReliable, assessment.confidence >= 0.65, assessment.subjectArea != nil,
              !assessment.touchesEdge, assessment.sizePenalty <= (retaining ? 0.20 : 0.15), assessment.positionPenalty <= (retaining ? 0.075 : 0.05),
              !assessment.cameraMoving else { return false }
        if let light = assessment.exposure, light.highlightFraction > 0.18 || (light.brightness < 0.12 && light.shadowFraction > 0.75) { return false }
        return true
    }
    /// Manual layout completion never grants or requires motor permission.
    static func measuredManualFrame(mode:CompositionMode,bounds:CGRect?,target:UnitPoint2D,
                                    roll:Double,aspect:Double,assessment:CompositionAssessment,
                                    stable:Bool,retaining:Bool = false) -> Bool {
        guard mode != .automatic, let bounds, AutomaticShotPlan.valid(bounds),
              [target.x,target.y,roll,aspect].allSatisfy(\.isFinite), aspect > 0,
              (0...1).contains(target.x), (0...1).contains(target.y), stable,
              assessment.assessmentReliable, assessment.confidence.isFinite, assessment.confidence >= 0.65,
              assessment.subjectArea != nil, !assessment.touchesEdge,
              assessment.sizePenalty <= (retaining ? 0.20 : 0.15), !assessment.cameraMoving,
              abs(roll) <= (retaining ? 5 : 4),
              hypot(Double(bounds.midX)-target.x,(Double(bounds.midY)-target.y)/aspect) <= (retaining ? 0.0845 : 0.065) else { return false }
        if let light = assessment.exposure {
            guard [light.brightness,light.shadowFraction,light.highlightFraction].allSatisfy(\.isFinite),
                  light.highlightFraction <= 0.18, !(light.brightness < 0.12 && light.shadowFraction > 0.75) else { return false }
        }
        return true
    }
    static func measuredSceneFrame(scene:SubjectScene?,evidence:SceneCompositionEvidence?,measurements:PhotoMeasurements?,
                                   stable:Bool,timestamp:TimeInterval) -> Bool {
        guard let scene, scene.isLandscape || scene.isArchitecture, timestamp >= scene.timestamp, timestamp-scene.timestamp <= 6,
              stable, let evidence, evidence.isFresh(at:timestamp), evidence.region(SceneCompositionEvidence.full).variance > 0.008,
              let light = measurements, light.highlightFraction <= 0.18,
              !(light.brightness < 0.12 && light.shadowFraction > 0.75) else { return false }
        return true
    }
    static func permitsReady(required:Bool,shotVerified:Bool,currentFrameVerified:Bool) -> Bool {
        !required || shotVerified || currentFrameVerified
    }
}

/// Bounded developer diagnostics; export is explicit and contains no images.
enum ShotFramingDiagnostics {
    #if DEBUG || FOCAL_EVALUATION
    private static let trace = FramingTraceBuffer()
    static func export() throws -> URL {
        let header = "Focal AI framing trace — recorded measurements, not a hardware-test claim.\nMissing readings are unknown. No images included.\n\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Focal-framing-\(UUID().uuidString).txt")
        try (header+trace.text()).write(to:url,atomically:true,encoding:.utf8)
        return url
    }
    #endif
    static func log(_ event:String,_ details:@autoclosure () -> String) {
        #if DEBUG || FOCAL_EVALUATION
        let line = "[Focal ShotDirector] uptime=\(FramingTransitionTrace.number(ProcessInfo.processInfo.systemUptime)) \(event) \(details())"
        trace.append(line)
        print(line)
        #endif
    }
}
