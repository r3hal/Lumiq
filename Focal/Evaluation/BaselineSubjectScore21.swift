#if DEBUG || FOCAL_EVALUATION
import Foundation

// Frozen build 18 subject scoring before the semantic-texture repair.
extension SubjectCandidate {
    func baselineScore21(configuration: SubjectSelectionConfiguration) -> Double? {
        guard configuration.intent.accepts(category) else { return nil }
        guard validBoundary, confidence >= configuration.minimumConfidence,
              [prominence, isolation, detail, textureDensity, classificationConfidence, textConfidence, compositionPotential].allSatisfy(\.isFinite) else { return nil }
        // Recognized people/pets should not need a high-contrast background.
        // A salient region needs a specific, confident name AND separation.
        if !category.semantic {
            guard category != .landscape, category != .background,
                  SubjectIdentity.name(label) != nil, classificationConfidence >= 0.25 else { return nil }
            let isolated = isolation >= 0.15 && prominence >= 0.35 && detail >= 0.005
            let printed = textConfidence >= 0.65 && prominence >= 0.2 && detail >= 0.008
            let localized = localizedProposal && confidence >= 0.75 && prominence >= 0.55 && centerPreference >= 0.4
                && visibleArea >= 0.02 && visibleArea <= 0.85 && detail >= 0.003
                && classificationConfidence >= SubjectIdentity.minimumLocalizedConfidence(for:label)
            if classificationConfidence < 0.6 && !printed && !localized {
                guard isolation >= 0.35, prominence >= 0.55, detail >= 0.01 else { return nil }
            }
            let architecture = category == .architecture && classificationConfidence >= 0.65
                && prominence >= 0.55 && centerPreference >= 0.6 && visibleArea >= 0.03 && visibleArea <= 0.75 && detail >= 0.01
            guard isolated || architecture || printed || localized else { return nil }
        }
        let area = visibleArea
        let sizeQuality = min(1, area / 0.035) * max(0, min(1, (0.85 - area) / 0.25))
        let texturePenalty = category == .nature ? 0.02 : textConfidence >= 0.65 ? 0.06 : 0.22
        let score = 0.35 * confidence + 0.12 * category.priority + 0.15 * classificationConfidence
            + 0.12 * prominence + 0.08 * isolation + 0.07 * sizeQuality + 0.11 * centerPreference - texturePenalty * textureDensity
        // Small peripheral people should not eclipse an isolated foreground
        // product. A central portrait keeps its normal semantic priority.
        let peripheralPenalty = category.semantic && area < 0.035 ? (1 - centerPreference) * 0.12 : 0
        return max(0, min(1, score - peripheralPenalty + max(0,min(1,compositionPotential))*0.10))
    }
}
#endif
