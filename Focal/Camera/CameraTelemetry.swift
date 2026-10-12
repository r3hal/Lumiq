import Foundation

enum CameraSource: String, CaseIterable, Identifiable {
    case iPhone = "iPhone", sony = "Sony"
    var id: Self { self }
}

struct CameraTelemetry: Equatable {
    var mode: String?
    var shutter: String?
    var iso: String?
    var ev: Double?
    var aperture: String?
    static func shutterLabel(seconds: Double) -> String? {
        guard seconds.isFinite,seconds > 0 else { return nil }
        return seconds < 1 ? String(format:"1/%.0f",1/seconds) : String(format:"%.1f s",seconds)
    }
    var evLabel: String { ev.map { String(format:"%+.1f",$0) } ?? "—" }
}
