import Foundation

/// One-frame view of the existing director and the scene planner. Only the
/// director owns the selected shot; a fresh candidate is useful for diagnostics.
struct FramingExecutionContext {
    let selected: AutomaticShotPlan?
    let candidate: SceneCompositionPlan?
    var requiresZoom: Bool { selected?.requiresZoom == true }
    var candidateMatchesSelected: Bool { selected != nil && selected?.id == candidate?.id }
    func permitsZoom(settingsAllow:Bool,cropPermitted:Bool) -> Bool {
        settingsAllow && requiresZoom && cropPermitted
    }
}

/// Reasons belong to the existing director, not to a second camera controller.
enum FramingBlockReason: String {
    case aiming, cameraMotion, motionUnavailable, subjectMotion, tracking, staleFrame, telemetry, quality, missingPlan
    case manualControl, disabled, thermal, inactive, interrupted, unsafeCrop, configuration, zoomNotMoving, deadline, recoveryExpired
    var instruction: String {
        switch self {
        case .aiming: return "Aim toward the marked position"
        case .cameraMotion: return "Slow the camera movement to keep the subject tracked"
        case .motionUnavailable: return "Motion measurements unavailable. Frame manually or restart the camera"
        case .subjectMotion: return "Keep following the subject while it settles"
        case .tracking: return "Keep the selected subject in view"
        case .staleFrame: return "Waiting for a fresh camera frame"
        case .telemetry: return "Waiting for the camera zoom reading"
        case .quality: return "Current light or crop limits automatic framing"
        case .missingPlan: return "No safe tighter composition yet"
        case .manualControl: return "Manual control active. Select a subject to start a new AI shot"
        case .disabled: return "Automatic Zoom is disabled"
        case .thermal: return "Phone is too hot for automatic framing. Let it cool"
        case .inactive: return "Return to the live camera to start framing"
        case .interrupted: return "Recovering the planned framing…"
        case .unsafeCrop: return "Rechecking the subject and crop…"
        case .configuration: return "Camera zoom could not start. Retrying…"
        case .zoomNotMoving: return "Camera zoom did not respond. Retrying…"
        case .deadline: return "Rechecking the framing from the current zoom…"
        case .recoveryExpired: return "Finding a new composition…"
        }
    }
}

/// Phone motion is measured by Core Motion, independently of the tracked cat.
/// These are handheld framing gates, not a claim of blur-free shutter timing.
struct FramingMotionMeasurement {
    let rotation: Double // radians/second
    let acceleration: Double // g
    let age: TimeInterval
    var usable: Bool { [rotation,acceleration,age].allSatisfy(\.isFinite) && age >= 0 && age < 0.45 }
    var stable: Bool { usable && rotation < 0.22 && acceleration < 0.08 }
    // Gross-motion filter, not a hold-still requirement. Alignment and actual
    // tracked crop safety remain independent gates. Tune on physical hardware.
    var permitsFraming: Bool { usable && rotation < 0.9 && acceleration < 0.35 }
}

/// A commanded zoom is not proof the device moved. Used by the real camera poll.
struct ZoomProgressWatchdog {
    private var startedAt: TimeInterval = 0
    private var startZoom: Double = 1
    private var target: Double = 1
    private(set) var observedMovement = false
    mutating func start(zoom:Double,target:Double,at time:TimeInterval) {
        startedAt = time; startZoom = zoom; self.target = target; observedMovement = false
    }
    mutating func failure(actual:Double,at time:TimeInterval,paused:Bool) -> FramingBlockReason? {
        guard actual.isFinite, actual > 0, time.isFinite, time >= startedAt else { return .telemetry }
        if abs(actual-startZoom) > max(0.005,startZoom*0.003) { observedMovement = true }
        if !paused, !observedMovement, abs(target-actual)/max(0.01,target) > 0.02, time-startedAt > 0.85 { return .zoomNotMoving }
        return nil
    }
}
