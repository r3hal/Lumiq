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
    case thirds = "Thirds"
    case centered = "Center"
    var id: Self { self }
}

struct CompositionReading {
    enum State: Equatable { case searching, adjusting, settling, ready }
    var state: State = .searching
    var subject: UnitPoint2D?
    var target = UnitPoint2D(x: 2.0 / 3, y: 1.0 / 3)
    var rollDegrees: Double = 0
    var title = "Find something worth a second look"
    var detail = "Point at a clear subject to get a little guidance."
}

struct CompositionEngine {
    private var alignedSince: TimeInterval?
    private var smoothedSubject: UnitPoint2D?
    private var lockedTarget: UnitPoint2D?
    private var previousMode: CompositionMode?

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
    }

    mutating func update(subject: UnitPoint2D?, rollDegrees: Double,
                         mode: CompositionMode, timestamp: TimeInterval) -> CompositionReading {
        if previousMode != mode { reset(); previousMode = mode }
        guard let subject, subject.x.isFinite, subject.y.isFinite,
              (0...1).contains(subject.x), (0...1).contains(subject.y) else {
            reset()
            var reading = CompositionReading()
            reading.rollDegrees = rollDegrees
            return reading
        }
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
        let target = lockedTarget ?? Self.target(for: point, mode: mode)
        lockedTarget = target
        let distance = point.distance(to: target)
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
            let direction = abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")
            reading.title = "Aim a little \(direction)"
            reading.detail = "Bring the white dot into the green ring."
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
