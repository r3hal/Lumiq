import Foundation

/// Unit coordinates use the top-left as the origin, matching the portrait preview.
struct UnitPoint2D: Equatable {
    var x: Double
    var y: Double

    func distance(to other: Self) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

enum CompositionMode: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case thirds = "Thirds"
    case centered = "Center"
    var id: Self { self }
}

struct CompositionReading {
    enum State: Equatable { case searching, adjusting, settling, ready }
    var state: State = .searching
    var subject: UnitPoint2D?
    var subjectBounds: CGRect?
    var subjectConfidence: Float = 0
    var target = UnitPoint2D(x: 2.0 / 3, y: 1.0 / 3)
    var rollDegrees: Double = 0
    var title = "Find something worth a second look"
    var detail = "Point at a clear subject to get a little guidance."
    func alignmentPercent(previewAspect: Double) -> Double? {
        guard state != .searching, let subject, subject.x.isFinite, subject.y.isFinite, rollDegrees.isFinite else { return nil }
        let distance = hypot(subject.x-target.x,(subject.y-target.y)/max(0.1,previewAspect))
        return 100 * max(0,1-max(distance/0.35,abs(rollDegrees)/15))
    }
}

struct CompositionEngine {
    private var alignedSince: TimeInterval?
    private var smoothedSubject: UnitPoint2D?
    private var lockedTarget: UnitPoint2D?
    private var previousMode: CompositionMode?
    private var lastSeen: TimeInterval?

    static let thirdsTargets = [UnitPoint2D(x: 1.0 / 3, y: 1.0 / 3),
                                UnitPoint2D(x: 2.0 / 3, y: 1.0 / 3),
                                UnitPoint2D(x: 2.0 / 3, y: 2.0 / 3),
                                UnitPoint2D(x: 1.0 / 3, y: 2.0 / 3)]

    static func target(for subject: UnitPoint2D, mode: CompositionMode) -> UnitPoint2D {
        guard mode == .thirds else { return UnitPoint2D(x: 0.5, y: 0.5) }
        return UnitPoint2D(x: subject.x < 0.5 ? 1.0 / 3 : 2.0 / 3,
                           y: subject.y < 0.5 ? 1.0 / 3 : 2.0 / 3)
    }

    mutating func reset() {
        alignedSince = nil
        smoothedSubject = nil
        lockedTarget = nil
        previousMode = nil
        lastSeen = nil
    }

    mutating func update(subject: UnitPoint2D?, rollDegrees: Double,
                         mode: CompositionMode, timestamp: TimeInterval,
                         preferredTarget: UnitPoint2D? = nil, previewAspect: Double = 0.75) -> CompositionReading {
        if previousMode != mode { reset(); previousMode = mode }
        guard let subject, subject.x.isFinite, subject.y.isFinite,
              (0...1).contains(subject.x), (0...1).contains(subject.y) else {
            // A single missed frame must not choose a new corner or flash a ready check.
            alignedSince = nil
            if let lastSeen, timestamp - lastSeen < 0.4, let point = smoothedSubject {
                return CompositionReading(state: .searching, subject: point,
                                          target: lockedTarget ?? Self.target(for: point, mode: mode),
                                          rollDegrees: rollDegrees,
                                          title: "Keeping track of your subject",
                                          detail: "Hold steady, or tap the subject to select it.")
            }
            reset()
            var reading = CompositionReading()
            reading.rollDegrees = rollDegrees
            return reading
        }
        lastSeen = timestamp
        let old = smoothedSubject ?? subject
        // A new subject must settle independently; do not interpolate across a scene cut.
        if old.distance(to: subject) > 0.3 {
            smoothedSubject = subject
            lockedTarget = nil
            alignedSince = nil
        } else {
            smoothedSubject = UnitPoint2D(x: old.x * 0.45 + subject.x * 0.55,
                                         y: old.y * 0.45 + subject.y * 0.55)
        }
        let point = smoothedSubject ?? subject
        let target = mode == .centered ? UnitPoint2D(x: 0.5, y: 0.5)
            : preferredTarget ?? lockedTarget ?? Self.target(for: point, mode: mode)
        if lockedTarget != target { alignedSince = nil }
        lockedTarget = target
        // Check both the raw observation and filtered position so smoothing cannot fake readiness.
        // Measure actual screen distance for the selected preview aspect ratio.
        let verticalScale = 1 / max(0.1, previewAspect)
        let distance = max(hypot(point.x - target.x, (point.y - target.y) * verticalScale),
                           hypot(subject.x - target.x, (subject.y - target.y) * verticalScale))
        var reading = CompositionReading(subject: point, target: target, rollDegrees: rollDegrees)
        if abs(rollDegrees) > 4 {
            alignedSince = nil
            reading.state = .adjusting
            reading.title = "Level things out"
            reading.detail = "Gently rotate your phone until the line is level."
        } else if distance > 0.065 {
            alignedSince = nil
            reading.state = .adjusting
            let dx = point.x - target.x
            let dy = point.y - target.y
            let direction = abs(dx) > abs(dy) * verticalScale ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")
            reading.title = "Move your phone \(direction)"
            reading.detail = "Pan your phone \(direction) until the subject reaches the guide."
        } else {
            if alignedSince == nil { alignedSince = timestamp }
            if timestamp - (alignedSince ?? timestamp) >= 0.65 {
                reading.state = .ready
                reading.title = "That’s your frame"
                reading.detail = "Balanced and ready. Make it yours."
            } else {
                reading.state = .settling
                reading.title = "Looking good. Hold steady."
                reading.detail = "Let your composition settle for a moment."
            }
        }
        return reading
    }
}
