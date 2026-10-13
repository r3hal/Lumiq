import Foundation

struct PrintedTextLine {
    let text: String
    let confidence: Double
    let bounds: CGRect // Vision origin, bottom left.
}

struct PrintedSubjectEvidence {
    let name: String
    let confidence: Double
    let namesCards: Bool
    static func identify(_ lines: [PrintedTextLine], inside rectangle: CGRect) -> Self? {
        let readable = lines.filter { line in
            let overlap = line.bounds.intersection(rectangle)
            let area = line.bounds.width * line.bounds.height
            return line.confidence.isFinite && line.confidence >= 0.65 && area > 0 && !overlap.isNull
                && overlap.width * overlap.height / area >= 0.8
        }.sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
        guard let heading = readable.first(where: { validHeading($0.text) }) else { return nil }
        let text = readable.map(\.text).joined(separator: " ").lowercased()
        let words = Set(text.split { !$0.isLetter }.map(String.init))
        let cards = words.contains("cards") || words.contains("poker") || words.contains("belot") || words.contains("belote") || words.contains("uno")
        if cards {
            let confidence = readable.filter { line in
                let parts = Set(line.text.lowercased().split { !$0.isLetter }.map(String.init))
                return !parts.isDisjoint(with: ["cards", "poker", "belot", "belote", "uno"])
            }.map(\.confidence).max() ?? heading.confidence
            let name = words.contains("belot") || words.contains("belote") ? "Belot cards" : words.contains("uno") ? "Uno cards" : "Playing cards"
            return Self(name: name, confidence: confidence, namesCards: true)
        }
        let title = heading.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A real printed title is useful even without knowing the product.
        // Never turn arbitrary OCR into a made-up object or brand identity.
        return Self(name: "“\(title.prefix(28))” print", confidence: heading.confidence, namesCards: false)
    }
    private static func validHeading(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = cleaned.lowercased().filter(\.isLetter)
        return cleaned.count >= 3 && cleaned.count <= 40 && Set(letters).count >= 2
            && SubjectIdentity.name(cleaned) != nil && !cleaned.lowercased().contains("http")
    }
}
