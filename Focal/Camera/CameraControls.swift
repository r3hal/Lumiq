import Foundation

enum CameraControlMode: String, CaseIterable, Identifiable { case auto = "AUTO", pro = "PRO"; var id: Self { self } }
enum PhotoEncoding: String, CaseIterable, Identifiable { case jpeg = "JPEG", heif = "HEIF"; var id: Self { self } }
enum CameraParameter: String, CaseIterable, Identifiable {
    case iso = "ISO", shutter = "SHUTTER", ev = "EV", whiteBalance = "WB", focus = "FOCUS"
    var id: Self { self }
}
struct CameraLensOption: Identifiable, Equatable { let id: String; let label: String }

struct ManualCameraState: Equatable {
    var mode: CameraControlMode = .auto
    var iso: Double?
    var seconds: Double?
    var temperature: Double?
    var tint: Double = 0
    var focus: Double?
    var hasManualExposure: Bool { iso != nil || seconds != nil }
    mutating func automaticExposure() { iso = nil; seconds = nil }
    mutating func reset() { self = Self() }
    func permitsFocus(automatic: Bool) -> Bool { focus == nil }
    var permitsAutoMetering: Bool { !hasManualExposure }
    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double? {
        guard value.isFinite, range.lowerBound.isFinite, range.upperBound.isFinite else { return nil }
        return min(range.upperBound,max(range.lowerBound,value))
    }
}

/// Values below come from the active device, never guessed capabilities.
struct CameraControlSnapshot: Equatable {
    var mode: CameraControlMode = .auto
    var iso: Double?
    var seconds: Double?
    var temperature: Double?
    var tint: Double?
    var lensPosition: Double?
    var isoRange: ClosedRange<Double>?
    var durationRange: ClosedRange<Double>?
    var canWhiteBalance = false
    var canFocus = false
    var canTapFocus = false
    var manualExposure = false
    var manualWhiteBalance = false
    var manualFocus = false
    var evAdjustable = false
    var lensID: String?
    var usesAutomaticLenses = true
    var lenses: [CameraLensOption] = []
    var encodings: [PhotoEncoding] = [.jpeg]
    static func transitioning(mode: CameraControlMode, lenses: [CameraLensOption]) -> Self {
        var snapshot = Self()
        snapshot.mode = mode; snapshot.lenses = lenses
        return snapshot
    }
    func supports(_ parameter: CameraParameter) -> Bool {
        switch parameter {
        case .iso: return isoRange != nil
        case .shutter: return durationRange != nil
        case .ev: return evAdjustable
        case .whiteBalance: return canWhiteBalance
        case .focus: return canFocus
        }
    }
}
