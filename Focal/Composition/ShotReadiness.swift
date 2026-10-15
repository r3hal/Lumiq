import Foundation

enum ShotDirectorState: String {
    case discovering = "DISCOVERING", shotSelected = "SHOT_SELECTED", aiming = "AIMING", aligned = "ALIGNED"
    case autoZooming = "AUTO_ZOOMING", verifyingFraming = "VERIFYING_FRAMING", ready = "READY", paused = "PAUSED", recovering = "RECOVERING", canceled = "CANCELED", failed = "FAILED"
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
    static func hardwareTarget(displayed:Double,multiplier:Double,minimum:Double,maximum:Double) -> Double? {
        guard [displayed,multiplier,minimum,maximum].allSatisfy(\.isFinite), displayed > 0, multiplier > 0 else { return nil }
        let target = displayed*multiplier
        return target >= minimum && target <= maximum ? target : nil
    }
}

enum ShotReadiness {
    static func measuredCurrentFrame(plan:SceneCompositionPlan?,assessment:CompositionAssessment,
                                     label:String,timestamp:TimeInterval,stable:Bool) -> Bool {
        guard let plan, plan.subjectLabel == label, plan.selected.isCurrentFrame, abs(plan.selected.zoomScale-1) < 0.001,
              timestamp >= plan.timestamp, timestamp-plan.timestamp <= 2.5,
              stable, assessment.assessmentReliable, assessment.confidence >= 0.65, assessment.subjectArea != nil,
              !assessment.touchesEdge, assessment.sizePenalty <= 0.15, assessment.positionPenalty <= 0.05,
              !assessment.cameraMoving else { return false }
        if let light = assessment.exposure, light.highlightFraction > 0.18 || (light.brightness < 0.12 && light.shadowFraction > 0.75) { return false }
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

/// Development console only; no production UI or per-frame unbounded logging.
enum ShotFramingDiagnostics {
    static func log(_ event:String,_ details:@autoclosure () -> String) {
        #if DEBUG || FOCAL_EVALUATION
        print("[Focal ShotDirector] \(event) \(details())")
        #endif
    }
}
