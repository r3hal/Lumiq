import Foundation

/// Names come from Vision evidence, never from a canned scene label. Reject
/// broad classifier labels that do not identify a photographic subject.
enum SubjectIdentity {
    private static let generic = Set(["object", "objects", "structure", "structures", "subject", "selected subject", "auto subject", "your subject", "thing", "unknown", "furniture", "room", "interior", "wall", "floor", "ceiling", "texture", "pattern", "indoor", "outdoor", "office", "living room", "bedroom", "bathroom", "corridor", "hallway", "equipment", "device", "technology", "artifact", "clothing", "building", "architecture", "landscape", "background"])
    static func name(_ identifier: String) -> String? {
        let first = identifier.hasPrefix("“") ? identifier : identifier.components(separatedBy: ",").first ?? identifier
        let cleaned = first.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 55, !generic.contains(cleaned.lowercased()),
              cleaned.rangeOfCharacter(from: .letters) != nil else { return nil }
        return cleaned.prefix(1).uppercased() + String(cleaned.dropFirst())
    }
    static func recognized(_ predictions: [(identifier: String, confidence: Double)]) -> (name: String, confidence: Double)? {
        var grouped = [String: Double]()
        for prediction in predictions {
            guard prediction.confidence.isFinite, (0...1).contains(prediction.confidence), let specific = name(prediction.identifier) else { continue }
            let canonical = canonicalName(specific)
            grouped[canonical] = max(grouped[canonical] ?? 0, prediction.confidence)
        }
        let ranked = grouped.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 0.45 else { return nil }
        if ranked.count > 1, best.value - ranked[1].value < (best.value >= 0.6 ? 0.08 : 0.15) { return nil }
        return (best.key, best.value)
    }
    private static func canonicalName(_ name: String) -> String {
        let value = name.lowercased()
        if ["keyboard", "computer keyboard", "keypad", "typewriter keyboard"].contains(value) { return "Computer keyboard" }
        if ["coffee cup", "coffee mug"].contains(value) { return "Coffee mug" }
        if ["playing card", "playing cards", "card deck", "deck of cards"].contains(value) { return "Playing cards" }
        if ["tv", "television", "television set"].contains(value) { return "Television" }
        return name
    }
    static func tip(for name: String) -> String {
        let words = name.lowercased()
        if words.contains("cards") { return "Keep the whole deck visible; show its printed face" }
        if words.contains("print") { return "Square up to the printed face" }
        if words.contains("keyboard") { return "Isolate the keys; catch the light" }
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
    init?(reading: CompositionReading, previewAspect: Double) {
        guard reading.subjectConfidence >= 0.4, let bounds = reading.subjectBounds,
              !bounds.isNull, bounds.width > 0, bounds.height > 0,
              [bounds.midX, bounds.midY, reading.target.x, reading.target.y].allSatisfy(\.isFinite),
              (0...1).contains(reading.target.x), (0...1).contains(reading.target.y) else { return nil }
        subject = UnitPoint2D(x: bounds.midX, y: bounds.midY); target = reading.target
        let dx = subject.x - target.x, dy = (subject.y - target.y) / max(0.1, previewAspect)
        aligned = hypot(dx, dy) <= 0.065
        direction = abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")
    }
    func instruction(subjectName: String) -> String {
        "Pan \(direction) · place the \(subjectName.lowercased()) on the mark"
    }
}
