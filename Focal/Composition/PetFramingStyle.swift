import Foundation

enum PetFramingStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case balanced = "Automatic", closeUp = "Close-up", wholeBody = "Whole body", environmental = "Environmental", action = "Action"
    var id: Self { self }
    var permitsAutomaticZoom: Bool { self == .balanced || self == .wholeBody || self == .closeUp }
    var explanation: String {
        switch self {
        case .balanced: return "Keep comfortable framing and observed surroundings."
        case .closeUp: return "Automatically frame when the observed head and important regions can be preserved."
        case .wholeBody: return "Preserve visible body boundaries and confidently observed joints."
        case .environmental: return "Keep the pet's surroundings; automatic cropping pauses."
        case .action: return "Preserve movement space and tracking; automatic cropping pauses."
        }
    }
}
