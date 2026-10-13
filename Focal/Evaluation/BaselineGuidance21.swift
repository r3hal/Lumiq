#if DEBUG || FOCAL_EVALUATION
import Foundation

// Frozen build 18 baseline, commit beaced8242f97531bb54812850c0cf8a11922632.
struct BaselineGuidance21 {
    private var shown = GuidanceMessage()
    private var candidate = GuidanceMessage()
    private var candidateSince: TimeInterval = 0
    private var detectedSince: TimeInterval?
    private var previousBounds: CGRect?
    private var previousTime: TimeInterval?
    mutating func reset() { self = Self() }

    mutating func update(reading: CompositionReading, phase: FramingPhase, stable: Bool,
                         rollReliable: Bool, autoEnabled: Bool, zoomAvailable: Bool,
                         timestamp: TimeInterval, previewAspect: Double = 0.75, scene: SubjectScene? = nil, sceneMeasurements: PhotoMeasurements? = nil, subjectLabel: String? = nil, subjectMeasurements: PhotoMeasurements? = nil, recovering: Bool = false,
                         compositionPlan: SceneCompositionPlan? = nil, sceneEvidence: SceneCompositionEvidence? = nil) -> GuidanceMessage {
        guard let bounds = reading.subjectBounds, reading.subjectConfidence >= 0.4,
              !bounds.isNull, bounds.width > 0, bounds.height > 0,
              [bounds.minX,bounds.minY,bounds.width,bounds.height].allSatisfy({ $0.isFinite }) else {
            if recovering, detectedSince != nil {
                shown = GuidanceMessage(kind: .steady, text: "Keep the subject in view")
                candidate = shown; candidateSince = timestamp
                return shown
            }
            reset()
            if autoEnabled { shown = GuidanceMessage(kind: .searching, text: "Scanning the scene…") }
            if let scene, scene.isLandscape, timestamp - scene.timestamp <= 6 {
                let text: String
                if rollReliable && abs(reading.rollDegrees) > 5 { text = "Keep the camera level" }
                else if let advice = sceneMeasurements?.lightingAdvice { text = advice }
                else if let evidence = sceneEvidence, evidence.isFresh(at:timestamp), let line = evidence.horizontalBoundary() {
                    let y = (line.start.y+line.end.y)/2
                    let desired = y < 0.5 ? 1.0/3 : 2.0/3
                    text = abs(y-desired) < 0.06 ? "Horizon placement · keep the sky and foreground balanced" : (y > desired ? "Lower the camera slightly · give the foreground room" : "Raise the camera slightly · give the sky room")
                }
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
        if phase == .zooming { desired = GuidanceMessage(kind:.framing,text:"Refining the crop…") }
        else if timestamp-(detectedSince ?? timestamp) < 0.45 { desired = GuidanceMessage(kind:.detected,text:name.map { "\($0) detected" } ?? "Subject detected") }
        else if speed > 0.25 { desired = GuidanceMessage(kind:.steady,text:"Keep the subject in view") }
        else if bounds.width > 0.85 || bounds.height > 0.85 || bounds.minX < -0.02 || bounds.maxX > 1.02 || bounds.minY < -0.02 || bounds.maxY > 1.02 {
            desired = GuidanceMessage(kind:.adjustment,text:name.map { "Step back · leave room around the \($0.lowercased())" } ?? "Move farther back")
        } else if rollReliable && abs(reading.rollDegrees) > 5 { desired = GuidanceMessage(kind:.adjustment,text:"Keep the camera level") }
        else {
            let point = UnitPoint2D(x:bounds.midX,y:bounds.midY)
            let dx = point.x-reading.target.x, dy = point.y-reading.target.y
            let tolerance = reading.alignmentTolerance
            if hypot(dx,dy/max(0.1,previewAspect)) > tolerance {
                let text = abs(dx) > abs(dy)/max(0.1,previewAspect) ? (dx > 0 ? "Move slightly right" : "Move slightly left") : (dy > 0 ? "Lower the camera" : "Raise the camera")
                let specific = name.flatMap { label in CompositionCue(reading: reading, previewAspect: previewAspect)?.instruction(subjectName: label) }
                let phoneText = autoEnabled && phase.isPreparing ? CompositionCue(reading: reading, previewAspect: previewAspect)?.phoneInstruction : nil
                desired = GuidanceMessage(kind:.adjustment,text:compositionPlan?.movementInstruction(reading:reading,previewAspect:previewAspect) ?? phoneText ?? specific ?? text)
            } else if max(bounds.width,bounds.height) < 0.16 && compositionPlan == nil && (!autoEnabled || !zoomAvailable || phase == .framed) {
                desired = GuidanceMessage(kind:.adjustment,text:name.map { "Move closer to the \($0.lowercased())" } ?? "Move closer")
            } else if stable && reading.state == .ready && !phase.isPreparing {
                let exposure = subjectMeasurements.flatMap { measuredExposureAdvice($0,name:name) }
                desired = GuidanceMessage(kind:.ready,text:exposure.map { "Composition aligned · \($0)" } ?? compositionPlan.map { "Composition aligned · \($0.selected.explanation)" } ?? name.map { "Composition aligned · \(SubjectIdentity.tip(for: $0))" } ?? "Composition aligned")
            } else if phase.isPreparing {
                desired = GuidanceMessage(kind:.steady,text:compositionPlan.map { "Hold steady · \($0.selected.technique.rawValue.lowercased())" } ?? (autoEnabled && phase == .settling && stable ? "Placement stable · preparing crop" : "Hold steady"))
            } else if let measurements = subjectMeasurements, let advice = measuredAdvice(measurements, name: name) {
                desired = GuidanceMessage(kind: .adjustment, text: advice)
            } else { desired = GuidanceMessage(kind:.steady,text:compositionPlan.map { "Hold steady · \($0.selected.technique.rawValue.lowercased())" } ?? (autoEnabled && phase == .settling && stable ? "Placement stable · preparing crop" : "Hold steady")) }
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
        if let exposure = measuredExposureAdvice(measurements,name:name) { return exposure }
        let subject = name?.lowercased() ?? "subject"
        if measurements.shadowFraction > 0.4 { return "Try softer light to reveal the \(subject)" }
        if let edges = measurements.backgroundEdges, edges > 0.23 { return "Change your angle to separate the \(subject)" }
        return nil
    }
    private func measuredExposureAdvice(_ measurements: PhotoMeasurements, name: String?) -> String? {
        let subject = name?.lowercased() ?? "subject"
        if measurements.highlightFraction > 0.12 { return "Protect the \(subject) highlights · lower exposure" }
        if measurements.brightness < 0.18 || measurements.shadowFraction > 0.65 { return "Add soft light to the \(subject); hold steady" }
        return nil
    }
}

// Snapshot entry point for image evaluation. This seeds only the legacy display
// delay, not detector observations or real tracking/stability evidence.
extension BaselineGuidance21 {
    static func settled(reading:CompositionReading,subject:String?,measurements:PhotoMeasurements?,plan:SceneCompositionPlan?,aspect:Double,scene:SubjectScene?) -> GuidanceMessage {
        var engine = Self()
        engine.detectedSince = -1
        return engine.update(reading:reading,phase:.off,stable:true,rollReliable:false,autoEnabled:false,zoomAvailable:false,
                             timestamp:0,previewAspect:aspect,scene:scene,subjectLabel:subject,subjectMeasurements:measurements,compositionPlan:plan)
    }
}
#endif
