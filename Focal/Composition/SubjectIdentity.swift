import Foundation

/// Names come from Vision evidence, never from a canned scene label. Reject
/// broad classifier labels that do not identify a photographic subject.
enum SubjectIdentity {
    private static let generic = Set(["object", "objects", "structure", "structures", "subject", "selected subject", "auto subject", "your subject", "thing", "unknown", "furniture", "room", "interior", "wall", "floor", "ceiling", "texture", "pattern", "indoor", "outdoor", "office", "living room", "bedroom", "bathroom", "corridor", "hallway", "equipment", "device", "technology", "artifact", "clothing", "building", "architecture", "landscape", "background"])
    static func name(_ identifier: String) -> String? {
        let first = identifier.hasPrefix("“") ? identifier : identifier.components(separatedBy: ",").first ?? identifier
        let cleaned = first.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Set(cleaned.lowercased().split { !$0.isLetter }.map(String.init))
        guard !cleaned.isEmpty, cleaned.count <= 55, !generic.contains(cleaned.lowercased()),
              words.isDisjoint(with: ["unknown", "unidentified", "imaginary", "thing", "object", "objects", "structure", "structures", "background"]),
              cleaned.rangeOfCharacter(from: .letters) != nil else { return nil }
        return cleaned.prefix(1).uppercased() + String(cleaned.dropFirst())
    }
    static func recognized(_ predictions: [(identifier: String, confidence: Double)], localized: Bool = false) -> (name: String, confidence: Double)? {
        var grouped = [String: Double]()
        for prediction in predictions {
            guard prediction.confidence.isFinite, (0...1).contains(prediction.confidence), let specific = name(prediction.identifier) else { continue }
            let canonical = canonicalName(specific)
            grouped[canonical] = max(grouped[canonical] ?? 0, prediction.confidence)
        }
        let ranked = grouped.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= (localized ? 0.25 : 0.45) else { return nil }
        // Moderate crop predictions require a clear competing-class margin,
        // a known photographic noun and subsequent spatial/temporal evidence.
        if best.value < 0.45 && best.value < minimumLocalizedConfidence(for:best.key) { return nil }
        let margin = best.value >= 0.6 ? 0.08 : best.value >= 0.45 ? 0.15 : 0.06
        if ranked.count > 1, best.value - ranked[1].value < margin { return nil }
        return (best.key, best.value)
    }
    static func minimumLocalizedConfidence(for label: String) -> Double {
        // Familiar aliases retain their existing sensitivity. Every other
        // specific Vision label is eligible with stronger crop evidence.
        isCommonPhotographicSubject(label) ? 0.25 : 0.35
    }
    static func isCommonPhotographicSubject(_ label: String) -> Bool {
        let words = Set(label.lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: ["desk", "table", "chair", "bench", "stool", "sofa", "couch", "armchair", "shelf", "bookcase", "lamp",
            "tree", "plant", "flower", "rose", "sunflower", "orchid", "palm", "bonsai", "oak", "pine", "maple", "birch", "willow", "fir",
            "book", "keyboard", "laptop", "computer", "monitor", "television", "camera", "phone", "clock", "watch",
            "cup", "mug", "bottle", "glass", "vase", "bowl", "plate", "food", "fruit", "cake", "pizza",
            "car", "truck", "bicycle", "bike", "motorcycle", "boat", "guitar", "piano", "shoe", "bag", "cards"])
    }
    private static func canonicalName(_ name: String) -> String {
        let value = name.lowercased()
        if ["keyboard", "computer keyboard", "keypad", "typewriter keyboard"].contains(value) { return "Computer keyboard" }
        if ["coffee cup", "coffee mug"].contains(value) { return "Coffee mug" }
        if ["playing card", "playing cards", "card deck", "deck of cards"].contains(value) { return "Playing cards" }
        if ["tv", "television", "television set"].contains(value) { return "Television" }
        if ["desk", "writing desk", "office desk", "work desk"].contains(value) { return "Desk" }
        if ["table", "dining table", "dinner table", "dining room table"].contains(value) { return "Table" }
        if ["chair", "armchair", "rocking chair", "folding chair", "office chair"].contains(value) { return "Chair" }
        if ["couch", "sofa", "settee"].contains(value) { return "Sofa" }
        if ["tree", "oak", "oak tree", "pine", "pine tree", "maple", "maple tree", "birch", "birch tree", "willow", "willow tree", "fir", "fir tree"].contains(value) { return "Tree" }
        if ["plant", "potted plant", "houseplant", "house plant", "pot plant"].contains(value) { return "Plant" }
        return name
    }
    static func tip(for name: String) -> String {
        let words = name.lowercased()
        if words.contains("cards") { return "Keep the whole deck visible; show its printed face" }
        if words.contains("print") { return "Square up to the printed face" }
        if words.contains("keyboard") { return "Isolate the keys; catch the light" }
        if words.contains("chair") { return "Isolate the chair’s shape; keep its edges clear" }
        if words.contains("desk") || words.contains("table") { return "Show the surface; keep its edges clear" }
        if words.contains("tree") || words.contains("palm") || words.contains("bonsai") { return "Keep the canopy clear; include space around the trunk" }
        if words.contains("person") { return "Leave space above the head" }
        if words.contains("dog") || words.contains("cat") { return "Get down to eye level" }
        if ["flower", "plant", "rose"].contains(where: { words.contains($0) }) { return "Separate the petals from the background" }
        if ["cup", "mug", "bottle", "glass"].contains(where: { words.contains($0) }) { return "Keep the rim clear of the background" }
        if ["food", "cake", "fruit", "pizza", "dish"].contains(where: { words.contains($0) }) { return "Leave a little space around the plate" }
        if SubjectCategory.classified(name) == .architecture { return "Keep the edges of the landmark clear" }
        return "Leave clean space around the \(name.lowercased())"
    }
}

/// Camera pan is the opposite of the subject's desired screen displacement.
/// Both text and overlay use this single geometry, including aspect scaling.
struct CompositionCue {
    let subject: UnitPoint2D
    let target: UnitPoint2D
    let aligned: Bool
    let direction: String
    let mirrored: Bool
    /// Aspect-scaled screen error and the tolerance it is judged against.
    let offsetX: Double
    let offsetY: Double
    let tolerance: Double
    init?(reading: CompositionReading, previewAspect: Double) {
        guard reading.subjectConfidence >= 0.4, let bounds = reading.guidanceBounds ?? reading.subjectBounds,
              !bounds.isNull, bounds.width > 0, bounds.height > 0,
              [bounds.midX, bounds.midY, reading.target.x, reading.target.y].allSatisfy(\.isFinite),
              (0...1).contains(reading.target.x), (0...1).contains(reading.target.y) else { return nil }
        subject = UnitPoint2D(x: bounds.midX, y: bounds.midY); target = reading.target; mirrored = reading.mirrored
        let dx = (subject.x - target.x) * (reading.mirrored ? -1 : 1), dy = (subject.y - target.y) / max(0.1, previewAspect)
        offsetX = dx; offsetY = dy
        tolerance = reading.alignmentTolerance.isFinite ? max(0.01, reading.alignmentTolerance) : 0.065
        aligned = hypot(dx, dy) <= reading.alignmentTolerance
        direction = abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")
    }
    /// Aiming advice that says which way and roughly how far. The dominant
    /// axis always matches `direction` (and therefore the overlay arrow); the
    /// other axis is named only when it is a real share of the remaining error,
    /// so a nearly horizontal correction does not read as a diagonal.
    var aimInstruction: String {
        let horizontalFirst = abs(offsetX) > abs(offsetY)
        let major = max(abs(offsetX), abs(offsetY)), minor = min(abs(offsetX), abs(offsetY))
        let secondary = horizontalFirst ? (offsetY > 0 ? "down" : "up") : (offsetX > 0 ? "right" : "left")
        let path = minor > max(tolerance * 0.6, 0.02) && minor >= major * 0.45 ? "\(direction) & \(secondary)" : direction
        return hypot(offsetX, offsetY) <= tolerance * 2.5 ? "Aim slightly \(path)" : "Aim your phone \(path)"
    }
    func instruction(subjectName: String) -> String {
        "Pan \(direction) · place the \(subjectName.lowercased()) on the mark"
    }
    var phoneInstruction: String {
        let dx = (subject.x - target.x) * (mirrored ? -1 : 1), dy = subject.y - target.y
        var directions = [String]()
        if abs(dx) > 0.03 { directions.append(dx > 0 ? "right" : "left") }
        if abs(dy) > 0.025 { directions.append(dy > 0 ? "down" : "up") }
        return directions.isEmpty ? "Hold your phone steady" : "Move your phone " + directions.joined(separator: " & ")
    }
}
