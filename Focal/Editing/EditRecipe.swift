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
    var lookName: String?
    var tint = 0.0, vibrance = 0.0, whites = 0.0, blacks = 0.0, fade = 0.0, curve = 0.0, sharpness = 0.0
    var color = AdvancedColor()
    var effects = FilmEffects()
    var frame: PhotoFrame = .none
    var dateStamp = false
    var stampDate: Date?
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
        copy.tint = bounded(tint, -1...1, fallback: 0); copy.vibrance = bounded(vibrance, -1...1, fallback: 0)
        copy.whites = bounded(whites, -1...1, fallback: 0); copy.blacks = bounded(blacks, -1...1, fallback: 0)
        copy.fade = bounded(fade, 0...1, fallback: 0); copy.curve = bounded(curve, -1...1, fallback: 0)
        copy.sharpness = bounded(sharpness, 0...2, fallback: 0)
        copy.color = color.normalized; copy.effects = effects.normalized
        if !dateStamp { copy.stampDate = nil }
        return copy
    }
    private func bounded(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? max(range.lowerBound, min(range.upperBound, value)) : fallback
    }
}

extension EditRecipe {
    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, saturation, warmth, highlights, shadows, grain, vignette, quarterTurns, crop
        case lookName, tint, vibrance, whites, blacks, fade, curve, sharpness, color, effects, frame, dateStamp, stampDate
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 1
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? 0
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        quarterTurns = try c.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0
        crop = try c.decodeIfPresent(PhotoAspect.self, forKey: .crop)
        lookName = try c.decodeIfPresent(String.self, forKey: .lookName)
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? 0
        blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
        fade = try c.decodeIfPresent(Double.self, forKey: .fade) ?? 0
        curve = try c.decodeIfPresent(Double.self, forKey: .curve) ?? 0
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        color = try c.decodeIfPresent(AdvancedColor.self, forKey: .color) ?? .init()
        effects = try c.decodeIfPresent(FilmEffects.self, forKey: .effects) ?? .init()
        frame = try c.decodeIfPresent(PhotoFrame.self, forKey: .frame) ?? .none
        dateStamp = try c.decodeIfPresent(Bool.self, forKey: .dateStamp) ?? false
        stampDate = try c.decodeIfPresent(Date.self, forKey: .stampDate)
    }
}

enum FilmPreset: String, CaseIterable, Identifiable {
    case original = "Original", cine = "Cine", honey = "Honey", sienna = "Sienna", arc = "Arc", archive = "Archive"
    case clean = "Clean", harbor = "Harbor", dusk = "Dusk", press = "Press", album = "Album", relic = "Relic", mono = "Mono"
    case amber = "Amber", soft = "Soft Film", silver = "Silver", faded = "Faded"
    var id: Self { self }
    var recipe: EditRecipe {
        switch self {
        case .original: return .original
        case .cine: return EditRecipe(contrast: 1.08, saturation: 0.85, warmth: -0.08, shadows: 0.12, grain: 0.08)
        case .honey: return EditRecipe(exposure: 0.12, contrast: 0.96, saturation: 0.9, warmth: 0.4, highlights: 0.8)
        case .sienna: return EditRecipe(contrast: 1.12, saturation: 0.78, warmth: 0.3, grain: 0.1, vignette: 0.12)
        case .arc: return EditRecipe(contrast: 1.18, saturation: 0.72, warmth: -0.12, highlights: 0.8, shadows: 0.1)
        case .archive: return EditRecipe(contrast: 0.88, saturation: 0.62, warmth: 0.25, grain: 0.14, fade: 0.15)
        case .clean: return EditRecipe(contrast: 1.03, saturation: 1.03, highlights: 0.95, sharpness: 0.15)
        case .harbor: return EditRecipe(contrast: 0.94, saturation: 0.82, warmth: -0.32, highlights: 0.85, shadows: 0.12)
        case .dusk: return EditRecipe(exposure: -0.12, contrast: 1.07, saturation: 0.8, warmth: -0.2, tint: 0.1)
        case .press: return EditRecipe(contrast: 1.2, saturation: 0, grain: 0.22)
        case .album: return EditRecipe(contrast: 0.9, saturation: 0.78, warmth: 0.14, grain: 0.09, fade: 0.1)
        case .relic: return EditRecipe(contrast: 0.92, saturation: 0.7, warmth: 0.3, grain: 0.2, fade: 0.18)
        case .mono: return EditRecipe(contrast: 1.12, saturation: 0)
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
