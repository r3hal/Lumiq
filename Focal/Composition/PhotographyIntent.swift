import Foundation

enum PhotographyIntent: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "Auto", portrait = "Portrait", pet = "Pet", product = "Product", architecture = "Architecture", landscape = "Landscape"
    var id: Self { self }
    func accepts(_ category: SubjectCategory) -> Bool {
        switch self {
        case .auto: return true
        case .portrait: return category == .person || category == .face
        case .pet: return category == .pet
        case .product: return category == .object || category == .nature
        case .architecture: return category == .architecture
        case .landscape: return false
        }
    }
    var permitsZoom: Bool { self != .architecture && self != .landscape }
    var maximumCropScale: Double { self == .portrait ? 1.6 : permitsZoom ? 3 : 1 }
    func bonus(for technique: CompositionTechnique) -> Double {
        switch self {
        case .portrait: return [CompositionTechnique.thirds,.goldenRatio,.centered,.negativeSpace].contains(technique) ? 0.04 : 0
        case .pet: return [CompositionTechnique.thirds,.negativeSpace,.centered].contains(technique) ? 0.04 : 0
        case .product: return [CompositionTechnique.fillFrame,.simplicity,.contrast,.centered].contains(technique) ? 0.10 : 0
        case .architecture: return [CompositionTechnique.symmetry,.leadingLines,.diagonals,.framing].contains(technique) ? 0.10 : 0
        default: return 0
        }
    }
    var description: String {
        switch self {
        case .auto: return "Select a relevant named subject from measured scene evidence."
        case .portrait: return "Prioritize people/faces; preserve space and restrained crops."
        case .pet: return "Prioritize supported cats/dogs. Pet Detection must be on."
        case .product: return "Prioritize isolated objects and simplify their surroundings."
        case .architecture: return "Prioritize recognized landmarks and observed geometry; preserve context without automatic zoom."
        case .landscape: return "Analyze the whole scene, without a forced subject box or automatic zoom."
        }
    }
}
