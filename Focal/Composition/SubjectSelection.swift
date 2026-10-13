import Foundation

struct SubjectSelectionConfiguration {
    var threshold: Double = 0.68
    var minimumConfidence: Double = 0.55
    var semanticDwell: TimeInterval = 0.35
    var objectDwell: TimeInterval = 1.2
    var switchMargin: Double = 0.14
    var switchDwell: TimeInterval = 1.5
}

enum SubjectCategory: Equatable {
    case person, face, pet, object, architecture, background, landscape
    var priority: Double {
        switch self {
        case .person, .pet: return 0.95
        case .face: return 0.9
        case .architecture: return 0.65
        case .object: return 0.75
        case .landscape: return 0.25
        case .background: return 0.15
        }
    }
    var semantic: Bool { self == .person || self == .face || self == .pet }
    static func classified(_ label: String) -> Self {
        let words = Set(label.lowercased().split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: ["person", "human", "man", "woman", "boy", "girl"]) { return .person }
        if !words.isDisjoint(with: ["cat", "dog"]) { return .pet }
        if !words.isDisjoint(with: ["mountain", "landscape", "lake", "ocean", "beach", "seashore", "forest", "valley", "sunset", "river", "waterfall", "canyon", "meadow", "desert", "coast"]) { return .landscape }
        if !words.isDisjoint(with: ["building", "architecture", "castle", "cathedral", "tower", "bridge", "monument", "skyscraper", "church", "temple", "mosque", "palace", "house", "stadium", "landmark", "sculpture", "statue"]) { return .architecture }
        if !words.isDisjoint(with: ["wall", "floor", "ceiling", "door", "doorframe", "room", "bedroom", "interior", "corridor", "hallway", "texture", "pattern"]) { return .background }
        return .object
    }
}

struct SubjectCandidate {
    /// Native Vision coordinates: normalized, origin at bottom left.
    var bounds: CGRect
    var confidence: Double
    var category: SubjectCategory
    var label: String
    var classificationConfidence: Double = 0
    var textConfidence: Double = 0
    var prominence: Double = 0
    var isolation: Double = 0
    var detail: Double = 0
    var textureDensity: Double = 0
    var visibleRegion = CGRect(x: 0, y: 0, width: 1, height: 1)

    var visibleArea: Double {
        let visible = bounds.intersection(visibleRegion)
        guard !visible.isNull, visibleRegion.width > 0, visibleRegion.height > 0 else { return 0 }
        return Double(visible.width * visible.height / (visibleRegion.width * visibleRegion.height))
    }
    var centerPreference: Double {
        guard visibleRegion.width > 0, visibleRegion.height > 0 else { return 0 }
        let x = Double((bounds.midX - visibleRegion.midX) / visibleRegion.width)
        let y = Double((bounds.midY - visibleRegion.midY) / visibleRegion.height)
        return max(0, 1 - hypot(x, y) / 0.6)
    }
    var validBoundary: Bool {
        let values = [bounds.minX, bounds.minY, bounds.width, bounds.height]
        return values.allSatisfy(\.isFinite) && confidence.isFinite && bounds.width > 0.015 && bounds.height > 0.015
            && bounds.minX >= 0 && bounds.minY >= 0 && bounds.maxX <= 1 && bounds.maxY <= 1
            && visibleArea >= 0.004 && visibleArea <= 0.92
    }
    func score(configuration: SubjectSelectionConfiguration) -> Double? {
        guard validBoundary, confidence >= configuration.minimumConfidence,
              [prominence, isolation, detail, textureDensity, classificationConfidence, textConfidence].allSatisfy(\.isFinite) else { return nil }
        // Recognized people/pets should not need a high-contrast background.
        // A salient region needs a specific, confident name AND separation.
        if !category.semantic {
            guard category != .landscape, category != .background,
                  SubjectIdentity.name(label) != nil, classificationConfidence >= 0.45 else { return nil }
            let isolated = isolation >= 0.15 && prominence >= 0.35 && detail >= 0.005
            let printed = textConfidence >= 0.65 && prominence >= 0.2 && detail >= 0.008
            if classificationConfidence < 0.6 && !printed {
                guard isolation >= 0.35, prominence >= 0.55, detail >= 0.01 else { return nil }
            }
            let architecture = category == .architecture && classificationConfidence >= 0.65
                && prominence >= 0.55 && centerPreference >= 0.6 && visibleArea >= 0.03 && visibleArea <= 0.75 && detail >= 0.01
            guard isolated || architecture || printed else { return nil }
        }
        let area = visibleArea
        let sizeQuality = min(1, area / 0.035) * max(0, min(1, (0.85 - area) / 0.25))
        let score = 0.35 * confidence + 0.2 * category.priority + 0.15 * classificationConfidence
            + 0.12 * prominence + 0.08 * isolation + 0.07 * sizeQuality + 0.03 * centerPreference - (textConfidence >= 0.65 ? 0.06 : 0.22) * textureDensity
        return max(0, min(1, score))
    }
    var manuallySelectable: Bool {
        validBoundary && confidence >= 0.5 && (category.semantic || (detail >= 0.015 && (isolation >= 0.15 || prominence >= 0.5)))
    }
    func matches(_ other: Self) -> Bool {
        let overlap = bounds.intersection(other.bounds)
        guard !overlap.isNull else { return false }
        let area = bounds.width * bounds.height + other.bounds.width * other.bounds.height - overlap.width * overlap.height
        return area > 0 && overlap.width * overlap.height / area >= 0.4
    }
}

/// Acquisition and challenger hysteresis. Nil means no new selection; an
/// existing healthy tracked subject remains retained by SubjectTracker.
struct SubjectSelector {
    var configuration = SubjectSelectionConfiguration()
    private var pending: SubjectCandidate?
    private var pendingSince: TimeInterval = 0
    private var pendingSamples = 0
    private var lastUpdate: TimeInterval?
    mutating func reset() { pending = nil; pendingSamples = 0; lastUpdate = nil }
    mutating func select(_ candidates: [SubjectCandidate], timestamp: TimeInterval,
                         current: SubjectCandidate? = nil, manualPoint: CGPoint? = nil) -> Int? {
        guard timestamp.isFinite else { reset(); return nil }
        if let manualPoint {
            reset()
            return candidates.indices.filter { candidates[$0].manuallySelectable && candidates[$0].bounds.insetBy(dx: -0.015, dy: -0.015).contains(manualPoint) }
                .min { candidates[$0].visibleArea < candidates[$1].visibleArea }
        }
        if let lastUpdate, timestamp < lastUpdate || timestamp - lastUpdate > 4 { reset() }
        lastUpdate = timestamp
        let scored: [(index: Int, score: Double)] = candidates.indices.compactMap { index in
            guard let score = candidates[index].score(configuration: configuration), score >= configuration.threshold else { return nil }
            return (index, score)
        }
        guard let best = scored.max(by: { $0.score < $1.score }) else { pending = nil; pendingSamples = 0; return nil }
        let candidate = candidates[best.index]
        if let current {
            if candidate.matches(current) { pending = nil; pendingSamples = 0; return nil }
            let currentScore = current.score(configuration: configuration) ?? configuration.threshold
            guard best.score >= currentScore + configuration.switchMargin else { pending = nil; pendingSamples = 0; return nil }
        }
        if let pending, pending.matches(candidate), pending.label.lowercased() == candidate.label.lowercased() { pendingSamples += 1 }
        else { pendingSince = timestamp; pendingSamples = 1 }
        pending = candidate
        let dwell = current != nil ? configuration.switchDwell : candidate.category.semantic ? configuration.semanticDwell : configuration.objectDwell
        let minimumSamples = candidate.category.semantic && current == nil ? 2 : 3
        guard pendingSamples >= minimumSamples, timestamp - pendingSince >= dwell else { return nil }
        reset(); return best.index
    }
}

struct SubjectTrackingHealth {
    private var firstMiss: TimeInterval?
    private var misses = 0
    mutating func reset() { firstMiss = nil; misses = 0 }
    mutating func lost(reliable: Bool, timestamp: TimeInterval) -> Bool {
        if reliable { reset(); return false }
        if firstMiss == nil { firstMiss = timestamp }
        misses += 1
        return misses >= 3 || timestamp - (firstMiss ?? timestamp) >= 0.45
    }
}

struct SubjectScene {
    var label: String
    var confidence: Float
    var timestamp: TimeInterval
    var isLandscape: Bool { confidence >= 0.65 && SubjectCategory.classified(label) == .landscape }
}

/// A small image sample, not a depth model or an aesthetic/intention oracle.
struct SubjectImageEvidence {
    struct Pixel { var red: Double; var green: Double; var blue: Double
        var luma: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    }
    let pixels: [Pixel]
    let width: Int
    let height: Int
    func features(for nativeRect: CGRect, saliencyProminence: Double?) -> (isolation: Double, prominence: Double, detail: Double, texture: Double) {
        guard width > 2, height > 2, pixels.count == width * height else { return (0, 0, 0, 0) }
        let rect = CGRect(x: nativeRect.minX, y: 1 - nativeRect.maxY, width: nativeRect.width, height: nativeRect.height)
        let ring = rect.insetBy(dx: -0.1, dy: -0.1)
        var inside = [Double](repeating: 0, count: 3), outside = inside
        var n = 0.0, m = 0.0, detail = 0.0, pairs = 0.0, backgroundDetail = 0.0, backgroundPairs = 0.0, edges = 0.0
        for y in 1..<height {
            for x in 1..<width {
                let point = CGPoint(x: Double(x) / Double(width), y: Double(y) / Double(height))
                let pixel = pixels[y * width + x]
                let difference = (abs(pixel.luma - pixels[y * width + x - 1].luma) + abs(pixel.luma - pixels[(y - 1) * width + x].luma)) / 2
                if rect.contains(point) {
                    inside[0] += pixel.red; inside[1] += pixel.green; inside[2] += pixel.blue; n += 1
                    detail += difference; pairs += 1; if difference > 0.15 { edges += 1 }
                } else if ring.contains(point) {
                    outside[0] += pixel.red; outside[1] += pixel.green; outside[2] += pixel.blue; m += 1
                    backgroundDetail += difference; backgroundPairs += 1
                }
            }
        }
        guard n >= 4, m >= 4 else { return (0, 0, 0, 0) }
        var colorSquared = 0.0
        for channel in 0..<3 {
            let delta = inside[channel] / n - outside[channel] / m
            colorSquared += delta * delta
        }
        let colorDistance = sqrt(colorSquared) / sqrt(3)
        let contrast = min(1, colorDistance / 0.25)
        let meanDetail = detail / max(1, pairs)
        let detailContrast = min(1, max(0, meanDetail - backgroundDetail / max(1, backgroundPairs)) / 0.08)
        let isolation = min(1, 0.7 * contrast + 0.3 * detailContrast)
        let prominence = max(saliencyProminence ?? 0, min(1, 0.6 * contrast + 0.4 * detailContrast))
        let texture = max(0, min(1, (edges / max(1, pairs) - 0.22) / 0.4))
        return (isolation, prominence, meanDetail, texture)
    }
}

/// Revisions reject in-flight results from before an off/on or source change.
struct GuidanceActivation {
    struct Snapshot: Equatable { var enabled: Bool; var revision: Int; var source: CameraSource }
    private(set) var snapshot = Snapshot(enabled: false, revision: 0, source: .iPhone)
    mutating func set(_ enabled: Bool, source: CameraSource? = nil) -> Snapshot {
        snapshot = Snapshot(enabled: enabled, revision: snapshot.revision + 1, source: source ?? snapshot.source)
        return snapshot
    }
    func accepts(_ result: Snapshot) -> Bool { snapshot.enabled && snapshot == result }
}
