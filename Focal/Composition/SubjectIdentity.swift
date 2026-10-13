import Foundation

/// Names come from Vision evidence, never from a canned scene label. Reject
/// broad classifier labels that do not identify a photographic subject.
enum SubjectIdentity {
    private static let generic = Set(["object", "objects", "structure", "structures", "subject", "selected subject", "auto subject", "your subject", "thing", "unknown", "furniture", "room", "interior", "wall", "floor", "ceiling", "texture", "pattern", "indoor", "outdoor", "office", "living room", "bedroom", "bathroom", "corridor", "hallway", "equipment", "device", "technology", "artifact", "clothing", "building", "architecture", "landscape", "background"])
    static func name(_ identifier: String) -> String? {
        let first = identifier.components(separatedBy: ",").first ?? identifier
        let cleaned = first.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 55, !generic.contains(cleaned.lowercased()),
              cleaned.rangeOfCharacter(from: .letters) != nil else { return nil }
        return cleaned.prefix(1).uppercased() + String(cleaned.dropFirst())
    }
    static func recognized(_ predictions: [(identifier: String, confidence: Double)]) -> (name: String, confidence: Double)? {
        guard let best = predictions.first, best.confidence.isFinite, best.confidence >= 0.6,
              let name = name(best.identifier) else { return nil }
        if predictions.count > 1 {
            let next = predictions[1]
            // Synonyms do not create a false ambiguity penalty.
            if self.name(next.identifier)?.lowercased() != name.lowercased(), best.confidence - next.confidence < 0.08 { return nil }
        }
        return (name, best.confidence)
    }
    static func tip(for name: String) -> String {
        let words = name.lowercased()
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
