import Foundation

/// Reasons belong to the existing director, not to a second camera controller.
enum FramingBlockReason: String {
    case aiming, cameraMotion, motionUnavailable, subjectMotion, tracking, staleFrame, telemetry, quality, missingPlan
    case manualControl, disabled, thermal, inactive, interrupted, unsafeCrop, configuration, zoomNotMoving, deadline, recoveryExpired
    var instruction: String {
        switch self {
        case .aiming: return "Aim toward the marked position"
        case .cameraMotion: return "Brace the phone to finish framing"
        case .motionUnavailable: return "Motion measurements unavailable. Frame manually or restart the camera"
        case .subjectMotion: return "Keep following the subject while it settles"
        case .tracking: return "Keep the selected subject in view"
        case .staleFrame: return "Waiting for a fresh camera frame"
        case .telemetry: return "Waiting for the camera zoom reading"
        case .quality: return "Current light or crop limits automatic framing"
        case .missingPlan: return "No safe tighter composition yet"
        case .manualControl: return "Manual control active. Tap AI off and on for a new shot"
        case .disabled: return "Automatic Zoom is disabled"
        case .thermal: return "Phone is too hot for automatic framing. Let it cool"
        case .inactive: return "Return to the live camera to start framing"
        case .interrupted: return "Framing interrupted. Tap AI off and on to retry"
        case .unsafeCrop: return "Subject left the safe crop. Aim again and start a new AI shot"
        case .configuration: return "Camera zoom could not start. Start a new AI shot to retry"
        case .zoomNotMoving: return "Camera zoom did not respond. Start a new AI shot to retry"
        case .deadline: return "Framing timed out. Start a new AI shot to retry"
        case .recoveryExpired: return "Tracking did not recover. Keep the subject visible and start a new AI shot"
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
