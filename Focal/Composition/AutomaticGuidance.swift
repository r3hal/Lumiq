import Foundation

struct GuidanceMessage: Equatable {
    enum Kind: Equatable { case searching, detected, adjustment, steady, framing, ready, scene }
    var kind: Kind = .searching
    var text = "Select a photographic subject"
    var action: GuidanceAction? = nil
    var showsDirection: Bool { action.map { [.panLeft,.panRight,.panUp,.panDown].contains($0) } ?? false }
}

/// Measurements select a feasible action; temporal memory decides when to show it.
struct AutomaticGuidance {
    private var memory = RecommendationMemory()
    private var detectedSince: TimeInterval?
    private var subject: String?
    private var previousBounds: CGRect?
    private var previousTime: TimeInterval?
    mutating func reset() { self = Self() }
    mutating func update(reading: CompositionReading, phase: FramingPhase, stable: Bool,
                         rollReliable: Bool, autoEnabled: Bool, zoomAvailable: Bool,
                         timestamp: TimeInterval, previewAspect: Double = 0.75, scene: SubjectScene? = nil,
                         sceneMeasurements: PhotoMeasurements? = nil, subjectLabel: String? = nil,
                         subjectMeasurements: PhotoMeasurements? = nil, recovering: Bool = false,
                         compositionPlan: SceneCompositionPlan? = nil, sceneEvidence: SceneCompositionEvidence? = nil,
                         intent: PhotographyIntent = .auto, manualSubject: Bool = false,
                         manualComposition: Bool = false, anatomy: SubjectAnatomy? = nil,
                         others: [CompositionContextSubject] = []) -> GuidanceMessage {
        guard timestamp.isFinite else { reset(); return GuidanceMessage() }
        guard let bounds = reading.guidanceBounds ?? reading.subjectBounds, reading.subjectConfidence >= 0.4,
              !bounds.isNull, bounds.width > 0, bounds.height > 0,
              [bounds.minX,bounds.minY,bounds.width,bounds.height].allSatisfy(\.isFinite) else {
            if recovering, detectedSince != nil { return .init(kind:.steady,text:"Keep the subject in view",action:.hold) }
            reset()
            let landscape = intent == .landscape || scene.map { $0.isLandscape && timestamp >= $0.timestamp && timestamp-$0.timestamp <= 6 } == true
            if let decision = ActionFeasibility.sceneRecommendation(landscape:landscape,stable:stable,roll:reading.rollDegrees,rollReliable:rollReliable,
                measurements:sceneMeasurements,evidence:sceneEvidence,timestamp:timestamp,previewAspect:previewAspect) {
                return .init(kind:.scene,text:decision.text,action:decision.action)
            }
            return .init(kind:.searching,text:autoEnabled ? "Scanning the scene…" : "Select a photographic subject")
        }
        let label = subjectLabel ?? "Subject"
        if subject != label { reset(); subject = label; detectedSince = timestamp }
        let relativeSpeed: Double
        if let previousBounds, let previousTime, timestamp > previousTime, timestamp-previousTime <= 2.5 {
            relativeSpeed = hypot(Double(bounds.midX-previousBounds.midX),Double(bounds.midY-previousBounds.midY)/max(0.1,previewAspect))/(timestamp-previousTime)
        } else { relativeSpeed = 0 }
        self.previousBounds = bounds; previousTime = timestamp
        let assessment = CompositionAssessment.evaluate(bounds:bounds,confidence:Double(reading.subjectConfidence),label:label,
            intent:intent,stable:stable && relativeSpeed <= 0.25,exposure:subjectMeasurements,evidence:sceneEvidence,others:others,anatomy:anatomy,timestamp:timestamp)
        if phase == .zooming { return .init(kind:.framing,text:"Refining the evaluated crop…") }
        if assessment.confidence < 0.55 { return .init(kind:.steady,text:"Keep the selected subject visible",action:.hold) }
        let proposed = ActionFeasibility.recommend(assessment:assessment,reading:reading,intent:intent,plan:compositionPlan,
            rollReliable:rollReliable,previewAspect:previewAspect,manualComposition:manualComposition,
            autoPreparing:autoEnabled && phase.isPreparing && compositionPlan?.permitsZoom == true)
        let retained = memory.update(proposed,bounds:bounds,label:label,intent:intent,timestamp:timestamp)
        if timestamp-(detectedSince ?? timestamp) < 0.45 && retained.action != .makeRoom {
            return .init(kind:.detected,text:SubjectIdentity.name(label).map { "\($0) detected" } ?? (manualSubject ? "Selected subject" : "Subject detected"))
        }
        if retained.action == .hold { return .init(kind:.steady,text:retained.text,action:.hold) }
        if retained.action == .none {
            if phase.isPreparing && autoEnabled { return .init(kind:.steady,text:"Hold steady",action:.hold) }
            if reading.state != .ready { return .init(kind:.steady,text:"Hold steady",action:.hold) }
            return .init(kind:.ready,text:"Ready to shoot",action:GuidanceAction.none)
        }
        if phase == .settling && retained.action == .tighterCrop { return .init(kind:.steady,text:"Hold steady for the evaluated crop",action:.hold) }
        return .init(kind:.adjustment,text:retained.text,action:retained.action)
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
    /// Acquisition tolerates ordinary handheld movement. The stricter hold
    /// below is reserved for focus/readiness and a real automatic lens ramp.
    static func permitsDetection(rotation: (Double,Double,Double), acceleration: (Double,Double,Double)) -> Bool {
        let values = [rotation.0,rotation.1,rotation.2,acceleration.0,acceleration.1,acceleration.2]
        guard values.allSatisfy(\.isFinite) else { return false }
        return sqrt(rotation.0*rotation.0+rotation.1*rotation.1+rotation.2*rotation.2) < 1.8
            && sqrt(acceleration.0*acceleration.0+acceleration.1*acceleration.1+acceleration.2*acceleration.2) < 0.7
    }
    static func isStable(rotation: (Double,Double,Double), acceleration: (Double,Double,Double)) -> Bool {
        let values = [rotation.0,rotation.1,rotation.2,acceleration.0,acceleration.1,acceleration.2]
        guard values.allSatisfy(\.isFinite) else { return false }
        return sqrt(rotation.0*rotation.0+rotation.1*rotation.1+rotation.2*rotation.2) < 0.12
            && sqrt(acceleration.0*acceleration.0+acceleration.1*acceleration.1+acceleration.2*acceleration.2) < 0.04
    }
}
