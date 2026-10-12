import Foundation
import Combine

struct EditRecipe: Codable, Equatable, Hashable {
    var exposure: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var warmth: Double = 0
    var highlights: Double = 1
    var shadows: Double = 0
    var grain: Double = 0
    var vignette: Double = 0
    var quarterTurns: Int = 0
    var crop: PhotoAspect?
    static let original = EditRecipe()
    var normalized: Self {
        var copy = self
        copy.exposure = bounded(exposure, -3...3, fallback: 0)
        copy.contrast = bounded(contrast, 0.5...1.5, fallback: 1)
        copy.saturation = bounded(saturation, 0...2, fallback: 1)
        copy.warmth = bounded(warmth, -1...1, fallback: 0)
        copy.highlights = bounded(highlights, 0...2, fallback: 1)
        copy.shadows = bounded(shadows, 0...1, fallback: 0)
        copy.grain = bounded(grain, 0...1, fallback: 0)
        copy.vignette = bounded(vignette, 0...2, fallback: 0)
        copy.quarterTurns = ((quarterTurns % 4) + 4) % 4
        return copy
    }
    private func bounded(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? max(range.lowerBound, min(range.upperBound, value)) : fallback
    }
}

enum FilmPreset: String, CaseIterable, Identifiable {
    case original = "Original", amber = "Amber", soft = "Soft Film", silver = "Silver", faded = "Faded"
    var id: Self { self }
    var recipe: EditRecipe {
        switch self {
        case .original: return .original
        case .amber: return EditRecipe(contrast: 0.95, saturation: 0.9, warmth: 0.3, shadows: 0.15, grain: 0.12)
        case .soft: return EditRecipe(contrast: 0.85, saturation: 0.8, warmth: 0.1, highlights: 0.7, shadows: 0.2, grain: 0.08)
        case .silver: return EditRecipe(contrast: 1.15, saturation: 0, highlights: 0.85, grain: 0.2, vignette: 0.25)
        case .faded: return EditRecipe(contrast: 0.8, saturation: 0.75, warmth: -0.1, shadows: 0.3, grain: 0.15)
        }
    }
}

struct SavedRecipe: Identifiable, Codable {
    var id = UUID()
    let name: String
    let recipe: EditRecipe
}

@MainActor
final class RecipeStore: ObservableObject {
    @Published private(set) var recipes: [SavedRecipe] = []
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "editing.recipes"), let saved = try? JSONDecoder().decode([SavedRecipe].self, from: data) { recipes = saved }
    }
    func save(name: String, recipe: EditRecipe) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = recipes.filter { $0.name.caseInsensitiveCompare(trimmed) != .orderedSame }
        next.append(SavedRecipe(name: trimmed, recipe: recipe.normalized))
        defaults.set(try JSONEncoder().encode(next), forKey: "editing.recipes")
        recipes = next
    }
    func delete(_ id: UUID) throws {
        let next = recipes.filter { $0.id != id }
        defaults.set(try JSONEncoder().encode(next), forKey: "editing.recipes")
        recipes = next
    }
}
