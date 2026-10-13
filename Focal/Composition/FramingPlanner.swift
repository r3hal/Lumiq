import Foundation

enum FramingPhase: Equatable {
    case off, searching, aligning, settling, zooming, framed
    var isPreparing: Bool { self == .searching || self == .aligning || self == .settling || self == .zooming }
}

/// A scan produces at most one zoom. Manual zoom cancels it until the next scan.
struct FramingPlanner {
    private(set) var phase: FramingPhase = .searching
    private var stableSince: TimeInterval?
    private var previous: CGRect?
    private var anchor: CGRect?
    private(set) var holdProgress: Double = 0

    mutating func reset(enabled: Bool) {
        phase = enabled ? .searching : .off
        stableSince = nil
        previous = nil; anchor = nil
        holdProgress = 0
    }
    mutating func finish() { phase = .framed }

    mutating func update(bounds: CGRect?, confidence: Float, roll: Double, timestamp: TimeInterval,
                         currentZoom: Double, maximumZoom: Double, detailZoomLimit: Double? = nil, nativeStops: [Double] = [], deviceStable: Bool = true, holdDuration: Double = 0.75, previewAspect: Double = 0.75) -> Double? {
        guard [roll,timestamp,currentZoom,maximumZoom,holdDuration,previewAspect].allSatisfy(\.isFinite), currentZoom > 0, maximumZoom >= currentZoom, previewAspect > 0 else { return nil }
        guard phase != .off, phase != .framed, phase != .zooming else { return nil }
        holdProgress = 0
        guard let bounds, valid(bounds), confidence >= 0.6 else {
            phase = .searching; stableSince = nil; previous = nil; anchor = nil
            return nil
        }
        defer { previous = bounds }
        let dx = Double(bounds.midX) - 0.5
        let dy = Double(bounds.midY) - 0.5
        guard hypot(dx,dy/max(0.1,previewAspect)) <= 0.04, abs(roll) <= 4 else {
            phase = .aligning; stableSince = nil
            return nil
        }
        if let previous, abs(previous.midX - bounds.midX) > 0.035 || abs(previous.midY - bounds.midY) > 0.035
            || abs(previous.width - bounds.width) > 0.05 || abs(previous.height - bounds.height) > 0.05 {
            stableSince = nil
        }
        phase = .settling
        if !deviceStable { stableSince = nil; anchor = nil; return nil }
        if let anchor, hypot(Double(anchor.midX-bounds.midX),Double(anchor.midY-bounds.midY)) > 0.04
            || abs(anchor.width-bounds.width) > 0.06 || abs(anchor.height-bounds.height) > 0.06 {
            stableSince = nil; self.anchor = nil
        }
        if stableSince == nil { stableSince = timestamp; anchor = bounds }
        let requiredHold = max(0.5,min(3,holdDuration))
        holdProgress = min(1, max(0, (timestamp - (stableSince ?? timestamp)) / requiredHold))
        guard holdProgress >= 1 else { return nil }
        // Account for the off-center extent, so zoom never cuts off the selected subject.
        let fit = min(0.72 / (Double(bounds.width) + 2 * abs(dx)),
                      0.62 / (Double(bounds.height) + 2 * abs(dy)))
        let centerDistance = hypot(dx,dy/max(0.1,previewAspect))
        let positionLimit = centerDistance > 0.01 ? 0.06/centerDistance : 5
        let desired = max(currentZoom,min(maximumZoom,currentZoom*min(5,min(fit,positionLimit))))
        // Above the preview pixel budget, prefer an actual lens position.
        // A telephoto lens does not make all intermediate digital zooms optical.
        let target: Double
        if let detailZoomLimit, desired > detailZoomLimit {
            target = max(currentZoom, max(detailZoomLimit, nativeStops.filter { $0 <= desired }.max() ?? currentZoom))
        } else { target = desired }
        guard target > currentZoom * 1.12 else { phase = .framed; return nil }
        phase = .zooming
        return target
    }

    static func zoomedRect(_ rect: CGRect, scale: Double) -> CGRect {
        CGRect(x: (rect.minX - 0.5) * scale + 0.5, y: (rect.minY - 0.5) * scale + 0.5,
               width: rect.width * scale, height: rect.height * scale)
    }

    private func valid(_ rect: CGRect) -> Bool {
        let values = [rect.minX, rect.minY, rect.width, rect.height]
        return values.allSatisfy { $0.isFinite } && rect.width > 0.025 && rect.height > 0.025
            && rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1
    }
}

/// Contextual final advice without pretending a local classifier is a cloud scene model.
enum SubjectAdvice {
    static func text(for label: String) -> String {
        let name = label.lowercased()
        let words = Set(name.split { !$0.isLetter }.map(String.init))
        if words.contains("cat") { return "Isolate the cat, tighten the frame." }
        if words.contains("dog") { return "Isolate the dog, keep the eyes in focus." }
        if name.contains("person") || name.contains("face") { return "Focus on the eyes, leave a little breathing room." }
        if name.contains("flower") || name.contains("plant") { return "Isolate the details, simplify the background." }
        if name.contains("keyboard") { return "Isolate the keys, tighten the frame." }
        if name.contains("subject") { return "Isolate your subject, tighten the frame." }
        return "Isolate the \(name), tighten the frame."
    }
}
