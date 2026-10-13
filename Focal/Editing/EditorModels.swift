import Foundation

struct HSLAdjustment: Codable, Equatable, Hashable {
    var hue = 0.0
    var saturation = 0.0
    var lightness = 0.0
}
struct ColorGrade: Codable, Equatable, Hashable {
    var hue = 0.08
    var amount = 0.0
}
struct AdvancedColor: Codable, Equatable, Hashable {
    var hsl = [HSLAdjustment](repeating: .init(), count: 8)
    var shadows = ColorGrade()
    var midtones = ColorGrade()
    var highlights = ColorGrade()
    var balance = 0.0
    var redHue = 0.0, redSaturation = 0.0
    var greenHue = 0.0, greenSaturation = 0.0
    var blueHue = 0.0, blueSaturation = 0.0
    var normalized: Self {
        var value = self
        value.hsl = Array((hsl + [HSLAdjustment](repeating: .init(), count: 8)).prefix(8)).map {
            HSLAdjustment(hue: finiteClamp($0.hue, -1...1), saturation: finiteClamp($0.saturation, -1...1), lightness: finiteClamp($0.lightness, -1...1))
        }
        func grade(_ g: ColorGrade) -> ColorGrade { ColorGrade(hue: finiteClamp(g.hue, 0...1, fallback: 0.08), amount: finiteClamp(g.amount, 0...1)) }
        value.shadows = grade(shadows); value.midtones = grade(midtones); value.highlights = grade(highlights)
        value.balance = finiteClamp(balance, -1...1)
        value.redHue = finiteClamp(redHue, -1...1); value.redSaturation = finiteClamp(redSaturation, -1...1)
        value.greenHue = finiteClamp(greenHue, -1...1); value.greenSaturation = finiteClamp(greenSaturation, -1...1)
        value.blueHue = finiteClamp(blueHue, -1...1); value.blueSaturation = finiteClamp(blueSaturation, -1...1)
        return value
    }
}
struct FilmEffects: Codable, Equatable, Hashable {
    var grainSize = 0.5
    var motion = 0.0, motionAngle = 0.0
    var lightLeak = 0.0, scratches = 0.0, halation = 0.0
    var dust = 0.0, glow = 0.0, fringe = 0.0
    var seed: UInt64 = 19
    var normalized: Self {
        var value = self
        value.grainSize = finiteClamp(grainSize, 0...1, fallback: 0.5)
        value.motion = finiteClamp(motion, 0...1); value.motionAngle = finiteClamp(motionAngle, -Double.pi...Double.pi)
        value.lightLeak = finiteClamp(lightLeak, 0...1); value.scratches = finiteClamp(scratches, 0...1)
        value.halation = finiteClamp(halation, 0...1); value.dust = finiteClamp(dust, 0...1)
        value.glow = finiteClamp(glow, 0...1); value.fringe = finiteClamp(fringe, 0...1)
        return value
    }
}
enum PhotoFrame: String, Codable, CaseIterable, Identifiable {
    case none = "Original", plain = "Plain", white = "White", paper = "Paper", specs = "Specs", negative = "Negative", black = "Black", instant = "Instant"
    var id: Self { self }
    var bottomRatio: Double { self == .instant ? 0.18 : self == .specs ? 0.12 : self == .none ? 0 : 0.045 }
    var borderRatio: Double { self == .none ? 0 : self == .plain ? 0.018 : 0.045 }
}
func finiteClamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double = 0) -> Double {
    value.isFinite ? max(range.lowerBound, min(range.upperBound, value)) : fallback
}

/// Slider gestures commit once; undo/redo works across tabs and presets.
struct EditHistory {
    private(set) var current = EditRecipe.original
    private var undoStack = [EditRecipe]()
    private var redoStack = [EditRecipe]()
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    mutating func set(_ value: EditRecipe) {
        let next = value.normalized
        guard next != current else { return }
        undoStack.append(current); if undoStack.count > 60 { undoStack.removeFirst() }
        current = next; redoStack = []
    }
    mutating func undo() { guard let value = undoStack.popLast() else { return }; redoStack.append(current); current = value }
    mutating func redo() { guard let value = redoStack.popLast() else { return }; undoStack.append(current); current = value }
}
enum EditorTab: String, CaseIterable, Identifiable {
    case looks = "Looks", adjust = "Adjust", effects = "Effects", frames = "Frames"
    var id: Self { self }
}
enum EditorTool: String, CaseIterable, Identifiable {
    case exposure = "Exposure", warmth = "Warmth", contrast = "Contrast", highlights = "Highlights", shadows = "Shadows"
    case saturation = "Saturation", tint = "Tint", vibrance = "Vibrance", fade = "Fade", curve = "Curve", hsl = "HSL", grading = "Grading"
    case whites = "Whites", blacks = "Blacks", calibration = "Calibration", sharpness = "Sharpness"
    case grain = "Grain", motion = "Motion", lightLeak = "Light leak", scratches = "Scratches", halation = "Halation"
    case dust = "Dust", glow = "Glow", fringe = "Fringe", vignette = "Vignette"
    var id: Self { self }
    var isEffect: Bool { [.grain, .motion, .lightLeak, .scratches, .halation, .dust, .glow, .fringe, .vignette].contains(self) }
    var symbol: String {
        switch self {
        case .exposure: return "sun.max"
        case .warmth: return "thermometer.medium"
        case .contrast: return "circle.lefthalf.filled"
        case .highlights, .whites: return "sun.haze"
        case .shadows, .blacks: return "moon"
        case .saturation, .hsl: return "paintpalette"
        case .tint, .grading: return "circle.hexagongrid"
        case .vibrance: return "camera.filters"
        case .fade: return "cloud"
        case .curve: return "chart.xyaxis.line"
        case .calibration: return "slider.horizontal.3"
        case .sharpness: return "triangle"
        case .grain: return "circle.grid.3x3"
        case .motion: return "arrow.left.arrow.right"
        case .lightLeak: return "bolt"
        case .scratches: return "pencil"
        case .halation: return "flame"
        case .dust: return "leaf"
        case .glow: return "sparkles"
        case .fringe: return "camera.aperture"
        case .vignette: return "circle"
        }
    }
}

enum EditorParameter: CaseIterable {
    case exposure, warmth, contrast, highlights, shadows, saturation, tint, vibrance, fade, curve, whites, blacks, sharpness
    case hslHue, hslSaturation, hslLightness, gradeHue, gradeAmount, gradeBalance, calibrationHue, calibrationSaturation
    case grain, grainSize, motion, motionAngle, lightLeak, scratches, halation, dust, glow, fringe, vignette
    var title: String {
        switch self {
        case .hslHue, .gradeHue, .calibrationHue: return "Hue"
        case .hslSaturation, .calibrationSaturation: return "Saturation"
        case .hslLightness: return "Lightness"
        case .gradeAmount: return "Amount"
        case .gradeBalance: return "Balance"
        case .grainSize: return "Size"
        case .motionAngle: return "Direction"
        case .lightLeak: return "Light leak"
        default: return String(describing: self).prefix(1).uppercased() + String(String(describing: self).dropFirst())
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .exposure: return -3...3
        case .contrast: return 0.5...1.5
        case .highlights, .vignette, .sharpness: return 0...2
        case .warmth, .tint, .vibrance, .curve, .whites, .blacks, .hslHue, .hslSaturation, .hslLightness, .gradeBalance, .calibrationHue, .calibrationSaturation: return -1...1
        case .saturation: return 0...2
        case .motionAngle: return -Double.pi...Double.pi
        default: return 0...1
        }
    }
    static func choices(for tool: EditorTool) -> [Self] {
        switch tool {
        case .hsl: return [.hslHue, .hslSaturation, .hslLightness]
        case .grading: return [.gradeHue, .gradeAmount, .gradeBalance]
        case .calibration: return [.calibrationHue, .calibrationSaturation]
        case .grain: return [.grain, .grainSize]
        case .motion: return [.motion, .motionAngle]
        default: return [Self.allCases.first { String(describing: $0) == String(describing: tool) } ?? .exposure]
        }
    }
    private var keyPath: WritableKeyPath<EditRecipe, Double>? {
        switch self {
        case .exposure: return \.exposure
        case .warmth: return \.warmth
        case .contrast: return \.contrast
        case .highlights: return \.highlights
        case .shadows: return \.shadows
        case .saturation: return \.saturation
        case .tint: return \.tint
        case .vibrance: return \.vibrance
        case .fade: return \.fade
        case .curve: return \.curve
        case .whites: return \.whites
        case .blacks: return \.blacks
        case .sharpness: return \.sharpness
        case .grain: return \.grain
        case .grainSize: return \.effects.grainSize
        case .motion: return \.effects.motion
        case .motionAngle: return \.effects.motionAngle
        case .lightLeak: return \.effects.lightLeak
        case .scratches: return \.effects.scratches
        case .halation: return \.effects.halation
        case .dust: return \.effects.dust
        case .glow: return \.effects.glow
        case .fringe: return \.effects.fringe
        case .vignette: return \.vignette
        case .gradeBalance: return \.color.balance
        default: return nil
        }
    }
    func value(in recipe: EditRecipe, channel: Int) -> Double {
        if let keyPath { return recipe[keyPath: keyPath] }
        let c = max(0, min(7, channel))
        switch self {
        case .hslHue: return recipe.color.hsl[c].hue
        case .hslSaturation: return recipe.color.hsl[c].saturation
        case .hslLightness: return recipe.color.hsl[c].lightness
        case .gradeHue: return c == 0 ? recipe.color.shadows.hue : c == 1 ? recipe.color.midtones.hue : recipe.color.highlights.hue
        case .gradeAmount: return c == 0 ? recipe.color.shadows.amount : c == 1 ? recipe.color.midtones.amount : recipe.color.highlights.amount
        case .calibrationHue: return c == 0 ? recipe.color.redHue : c == 1 ? recipe.color.greenHue : recipe.color.blueHue
        case .calibrationSaturation: return c == 0 ? recipe.color.redSaturation : c == 1 ? recipe.color.greenSaturation : recipe.color.blueSaturation
        default: return 0
        }
    }
    func set(_ value: Double, in recipe: inout EditRecipe, channel: Int) {
        let value = finiteClamp(value, range), c = max(0, min(7, channel))
        if let keyPath { recipe[keyPath: keyPath] = value; return }
        switch self {
        case .hslHue: recipe.color.hsl[c].hue = value
        case .hslSaturation: recipe.color.hsl[c].saturation = value
        case .hslLightness: recipe.color.hsl[c].lightness = value
        case .gradeHue:
            if c == 0 { recipe.color.shadows.hue = value } else if c == 1 { recipe.color.midtones.hue = value } else { recipe.color.highlights.hue = value }
        case .gradeAmount:
            if c == 0 { recipe.color.shadows.amount = value } else if c == 1 { recipe.color.midtones.amount = value } else { recipe.color.highlights.amount = value }
        case .calibrationHue:
            if c == 0 { recipe.color.redHue = value } else if c == 1 { recipe.color.greenHue = value } else { recipe.color.blueHue = value }
        case .calibrationSaturation:
            if c == 0 { recipe.color.redSaturation = value } else if c == 1 { recipe.color.greenSaturation = value } else { recipe.color.blueSaturation = value }
        default: break
        }
    }
}
