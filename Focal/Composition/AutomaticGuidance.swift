import Foundation

struct GuidanceMessage: Equatable {
    enum Kind: Equatable { case searching, detected, adjustment, steady, framing, ready, scene }
    var kind: Kind = .searching
    var text = "Point at a subject"
}

/// A measured, debounced state machine; no cosmetic/random AI messages.
struct AutomaticGuidance {
    private var shown = GuidanceMessage()
    private var candidate = GuidanceMessage()
    private var candidateSince: TimeInterval = 0
    private var detectedSince: TimeInterval?
    private var previousBounds: CGRect?
    private var previousTime: TimeInterval?
    mutating func reset() { self = Self() }

    mutating func update(reading: CompositionReading, phase: FramingPhase, stable: Bool,
                         rollReliable: Bool, autoEnabled: Bool, zoomAvailable: Bool,
                         timestamp: TimeInterval, previewAspect: Double = 0.75, scene: SubjectScene? = nil, sceneMeasurements: PhotoMeasurements? = nil, subjectLabel: String? = nil, subjectMeasurements: PhotoMeasurements? = nil) -> GuidanceMessage {
        guard let bounds = reading.subjectBounds, reading.subjectConfidence >= 0.4,
              !bounds.isNull, bounds.width > 0, bounds.height > 0,
              [bounds.minX,bounds.minY,bounds.width,bounds.height].allSatisfy({ $0.isFinite }) else {
            reset()
            if let scene, scene.isLandscape, timestamp - scene.timestamp <= 6 {
                let text: String
                if rollReliable && abs(reading.rollDegrees) > 5 { text = "Keep the camera level" }
                else if let advice = sceneMeasurements?.lightingAdvice { text = advice }
                else { text = SubjectIdentity.name(scene.label).map { "\($0) scene · leave a clear foreground" } ?? "Leave a clear foreground in the scene" }
                shown = GuidanceMessage(kind: .scene, text: text)
            } else if let advice = sceneMeasurements?.lightingAdvice {
                shown = GuidanceMessage(kind: .searching, text: advice)
            }
            return shown
        }
        let speed: Double
        if let previousBounds, let previousTime, timestamp > previousTime {
            speed = hypot(Double(bounds.midX-previousBounds.midX),Double(bounds.midY-previousBounds.midY))/(timestamp-previousTime)
        } else { speed = 0 }
        previousBounds = bounds; previousTime = timestamp
        if detectedSince == nil { detectedSince = timestamp }
        let name = subjectLabel.flatMap(SubjectIdentity.name)
        let desired: GuidanceMessage
        if phase == .zooming { desired = GuidanceMessage(kind:.framing,text:"Adjusting framing…") }
        else if timestamp-(detectedSince ?? timestamp) < 0.45 { desired = GuidanceMessage(kind:.detected,text:name.map { "\($0) detected" } ?? "Subject detected") }
        else if speed > 0.25 { desired = GuidanceMessage(kind:.steady,text:"Keep the subject in view") }
        else if bounds.width > 0.85 || bounds.height > 0.85 || bounds.minX < -0.02 || bounds.maxX > 1.02 || bounds.minY < -0.02 || bounds.maxY > 1.02 {
            desired = GuidanceMessage(kind:.adjustment,text:name.map { "Step back · leave room around the \($0.lowercased())" } ?? "Move farther back")
        } else if rollReliable && abs(reading.rollDegrees) > 5 { desired = GuidanceMessage(kind:.adjustment,text:"Keep the camera level") }
        else {
            let point = UnitPoint2D(x:bounds.midX,y:bounds.midY)
            let dx = point.x-reading.target.x, dy = point.y-reading.target.y
            let tolerance = autoEnabled && phase.isPreparing ? 0.04 : 0.065
            if hypot(dx,dy/max(0.1,previewAspect)) > tolerance {
                let text = abs(dx) > abs(dy)/max(0.1,previewAspect) ? (dx > 0 ? "Move slightly right" : "Move slightly left") : (dy > 0 ? "Lower the camera" : "Raise the camera")
                let specific = name.flatMap { label in CompositionCue(reading: reading, previewAspect: previewAspect)?.instruction(subjectName: label) }
                desired = GuidanceMessage(kind:.adjustment,text:specific ?? text)
            } else if max(bounds.width,bounds.height) < 0.16 && (!autoEnabled || !zoomAvailable || phase == .framed) {
                desired = GuidanceMessage(kind:.adjustment,text:name.map { "Move closer to the \($0.lowercased())" } ?? "Move closer")
            } else if let measurements = subjectMeasurements, let advice = measuredAdvice(measurements, name: name) {
                desired = GuidanceMessage(kind: .adjustment, text: advice)
            } else if stable && reading.state == .ready && !phase.isPreparing {
                desired = GuidanceMessage(kind:.ready,text:name.map { "Great framing · \(SubjectIdentity.tip(for: $0))" } ?? "Great framing")
            } else { desired = GuidanceMessage(kind:.steady,text:"Hold steady") }
        }
        // Loss and actual zoom transitions are immediate; movement text must persist.
        if desired.kind == .framing || shown.kind == .searching || desired.kind == .detected || (desired.kind == .steady && shown.kind == .detected) {
            shown = desired; candidate = desired; candidateSince = timestamp
        } else {
            if desired != candidate { candidate = desired; candidateSince = timestamp }
            if desired == shown || timestamp-candidateSince >= 0.6 { shown = desired }
        }
        return shown
    }
    private func measuredAdvice(_ measurements: PhotoMeasurements, name: String?) -> String? {
        let subject = name?.lowercased() ?? "subject"
        if measurements.highlightFraction > 0.12 { return "Protect the \(subject) highlights · lower exposure" }
        if measurements.brightness < 0.18 || measurements.shadowFraction > 0.65 { return "Add soft light to the \(subject); hold steady" }
        if measurements.shadowFraction > 0.4 { return "Try softer light to reveal the \(subject)" }
        if let edges = measurements.backgroundEdges, edges > 0.23 { return "Change your angle to separate the \(subject)" }
        return nil
    }
}

struct SubjectBoxSmoother {
    private var previous: CGRect?
    mutating func reset() { previous = nil }
    mutating func update(_ detected: CGRect?) -> CGRect? {
        guard let detected, !detected.isNull, detected.width > 0, detected.height > 0 else { reset(); return nil }
        guard let previous, hypot(Double(previous.midX-detected.midX),Double(previous.midY-detected.midY)) < 0.25 else {
            self.previous = detected; return detected
        }
        let rect = CGRect(x:previous.minX*0.3+detected.minX*0.7,y:previous.minY*0.3+detected.minY*0.7,
                          width:previous.width*0.3+detected.width*0.7,height:previous.height*0.3+detected.height*0.7)
        self.previous = rect; return rect
    }
}

struct CameraStability {
    static func isStable(rotation: (Double,Double,Double), acceleration: (Double,Double,Double)) -> Bool {
        let values = [rotation.0,rotation.1,rotation.2,acceleration.0,acceleration.1,acceleration.2]
        guard values.allSatisfy(\.isFinite) else { return false }
        return sqrt(rotation.0*rotation.0+rotation.1*rotation.1+rotation.2*rotation.2) < 0.12
            && sqrt(acceleration.0*acceleration.0+acceleration.1*acceleration.1+acceleration.2*acceleration.2) < 0.04
    }
}
