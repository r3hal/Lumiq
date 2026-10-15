#if DEBUG || FOCAL_EVALUATION
import Foundation

enum EvaluationFeedbackLabel: String, Codable, CaseIterable, Identifiable, Sendable {
    case helpful = "Helpful"
    case incorrect = "Incorrect"
    case unnecessary = "Unnecessary"
    case impossible = "Impossible to follow"
    case worse = "Made composition worse"
    case wrongSubject = "Wrong subject selected"
    var id: String { rawValue }
}
/// Explicit feedback on a user-imported, evaluated image, not a secretly captured live frame.
struct EvaluationFeedback: Codable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var label: EvaluationFeedbackLabel
    var sampleID: UUID
    var imageSHA256: String
    var intent: PhotographyIntent
    var petStyle: PetFramingStyle?
    var result: EvaluationOutcome
    var source = "consented image evaluation"
    var appVersion = "2.7.1 (29)"
}
#endif
