import Foundation

enum GuidanceReasoningState: String, Codable {
    case searching, subjectAcquired, evaluating, adjustmentRecommended, stabilizing, readyToShoot, insufficientConfidence
}

struct GuidanceMessage: Equatable {
    enum Kind: Equatable { case searching, detected, adjustment, steady, framing, ready, scene }
    var kind: Kind = .searching
    var text = "Select a photographic subject"
    var action: GuidanceAction? = nil
    var reasoningState: GuidanceReasoningState {
        switch kind {
        case .searching: return text.isEmpty ? .insufficientConfidence : .searching
        case .detected: return .subjectAcquired
        case .framing: return .evaluating
        case .adjustment: return .adjustmentRecommended
        case .steady: return .stabilizing
        case .ready: return .readyToShoot
        case .scene: return action?.isAdjustment == true ? .adjustmentRecommended : action == .hold ? .stabilizing : .readyToShoot
        }
    }
    var showsDirection: Bool { action.map { [.panLeft,.panRight,.panUp,.panDown].contains($0) } ?? false }
}

/// Measurements select a feasible action; temporal memory decides when to show it.
struct AutomaticGuidance {
    private var memory = RecommendationMemory()
    private var detectedSince: TimeInterval?
    private var subject: String?
    private var previousBounds: CGRect?
    private var previousTime: TimeInterval?
    private var confidenceFilter = GuidanceConfidenceFilter()
    var memoryOutcome: String { memory.outcome }
    var previousAction: GuidanceAction? { memory.currentAction }
    private(set) var reasoning: PhotographicDecision?
    mutating func reset() { self = Self() }
    mutating func update(reading: CompositionReading, phase: FramingPhase, stable: Bool,
                         rollReliable: Bool, autoEnabled: Bool, zoomAvailable: Bool,
                         timestamp: TimeInterval, previewAspect: Double = 0.75, scene: SubjectScene? = nil,
                         sceneMeasurements: PhotoMeasurements? = nil, subjectLabel: String? = nil,
                         subjectMeasurements: PhotoMeasurements? = nil, recovering: Bool = false,
                         compositionPlan: SceneCompositionPlan? = nil, sceneEvidence: SceneCompositionEvidence? = nil,
                         intent: PhotographyIntent = .auto, manualSubject: Bool = false,
                         manualComposition: Bool = false, anatomy: SubjectAnatomy? = nil,
                         others: [CompositionContextSubject] = [], observedScene: GuidanceSceneSnapshot? = nil, shotVerified:Bool = false, requireShotCompletion:Bool = false, currentFrameVerified:Bool = false, framingInstruction:String? = nil,continuousFraming:Bool = false) -> GuidanceMessage {
        guard timestamp.isFinite else { reset(); return GuidanceMessage() }
        if let observedScene, !observedScene.fresh { reset(); return .init(kind:.searching,text:"") }
        if continuousFraming, autoEnabled, phase.isRecovering {
            return .init(kind:.framing,text:framingInstruction ?? "Finding your shot…")
        }
        if continuousFraming, autoEnabled, phase.isAutoFraming {
            return .init(kind:.framing,text:phase == .verifying ? "Checking the final framing…" : "Framing your shot…")
        }
        if let framingInstruction {
            return .init(kind:continuousFraming ? .framing : .steady,text:framingInstruction)
        }
        if continuousFraming, autoEnabled, phase == .aligning,
           let cue = CompositionCue(reading:reading,previewAspect:previewAspect) {
            if !cue.aligned {
                let action:GuidanceAction = cue.direction == "left" ? .panLeft : cue.direction == "right" ? .panRight : cue.direction == "up" ? .panUp : .panDown
                return .init(kind:.adjustment,text:"Aim your phone \(cue.direction)",action:action)
            }
            return .init(kind:.framing,text:"Framing your shot…")
        }
        guard let bounds = reading.guidanceBounds ?? reading.subjectBounds, reading.subjectConfidence >= 0.4,
              !bounds.isNull, bounds.width > 0, bounds.height > 0,
              [bounds.minX,bounds.minY,bounds.width,bounds.height].allSatisfy(\.isFinite) else {
            if recovering, detectedSince != nil { return .init(kind:.steady,text:"Keep the subject in view",action:.hold) }
            let landscape = intent == .landscape || scene.map { $0.isLandscape && timestamp >= $0.timestamp && timestamp-$0.timestamp <= 6 } == true
            let architecture = intent == .architecture || scene.map { $0.isArchitecture && timestamp >= $0.timestamp && timestamp-$0.timestamp <= 6 } == true
            if let decision = ActionFeasibility.sceneRecommendation(landscape:landscape,stable:stable,roll:reading.rollDegrees,rollReliable:rollReliable,
                measurements:sceneMeasurements,evidence:sceneEvidence,timestamp:timestamp,previewAspect:previewAspect,architecture:architecture) {
                if subject != "Scene" { reset(); subject = "Scene" }
                let retained = memory.update(decision,bounds:nil,label:architecture ? "Architecture" : "Landscape",intent:intent,timestamp:timestamp)
                if requireShotCompletion, retained.action == .none,
                   !stable || sceneEvidence?.isFresh(at:timestamp) != true || sceneMeasurements == nil || !currentFrameVerified {
                    return .init(kind:.framing,text:"Evaluating the scene…")
                }
                if requireShotCompletion, currentFrameVerified, retained.action == .none {
                    return .init(kind:.ready,text:"Wide scene ready",action:GuidanceAction.none)
                }
                return .init(kind:.scene,text:retained.text,action:retained.action)
            }
            reset()
            return .init(kind:.searching,text:autoEnabled ? "Scanning the scene…" : "Select a photographic subject")
        }
        let label = subjectLabel ?? "Subject"
        if subject != label || previousBounds.map({ hypot(Double($0.midX-bounds.midX),Double($0.midY-bounds.midY)) > 0.55 }) == true { reset(); subject = label; detectedSince = timestamp }
        let relativeSpeed: Double
        if let previousBounds, let previousTime, timestamp > previousTime, timestamp-previousTime <= 2.5 {
            relativeSpeed = hypot(Double(bounds.midX-previousBounds.midX),Double(bounds.midY-previousBounds.midY)/max(0.1,previewAspect))/(timestamp-previousTime)
        } else { relativeSpeed = 0 }
        self.previousBounds = bounds; previousTime = timestamp
        var sharedScene = observedScene
        let trustedConfidence = confidenceFilter.update(Double(reading.subjectConfidence),label:label,at:timestamp)
        sharedScene?.confidence = trustedConfidence
        sharedScene?.deviceStable = stable && relativeSpeed <= 0.25
        let assessment = sharedScene?.assessment ?? CompositionAssessment.evaluate(bounds:bounds,confidence:trustedConfidence,label:label,
            intent:intent,stable:stable && relativeSpeed <= 0.25,exposure:subjectMeasurements,evidence:sceneEvidence,others:others,anatomy:anatomy,timestamp:timestamp)
        if phase.isAutoFraming { return .init(kind:.framing,text:phase == .verifying ? "Checking the final framing…" : "Refining the evaluated crop…") }
        if assessment.confidence < 0.55 || !assessment.assessmentReliable { memory.reset(); return .init(kind:.searching,text:"") }
        if shotVerified, stable, reading.state == .ready, !assessment.touchesEdge {
            memory.reset()
            return .init(kind:.ready,text:"Shot ready",action:GuidanceAction.none)
        }
        let evaluated = PhotographicReasoner.evaluate(assessment:assessment,reading:reading,intent:intent,plan:compositionPlan,
            rollReliable:rollReliable,previewAspect:previewAspect,manualComposition:manualComposition,
            autoPreparing:autoEnabled && phase.isPreparing && compositionPlan?.permitsZoom == true)
        reasoning = evaluated
        let retained = memory.update(evaluated.selected,bounds:bounds,label:label,intent:intent,timestamp:timestamp,assessment:assessment)
        if timestamp-(detectedSince ?? timestamp) < 0.45 && retained.action != .makeRoom {
            return .init(kind:.detected,text:SubjectIdentity.name(label).map { "\($0) detected" } ?? (manualSubject ? "Selected subject" : "Subject detected"))
        }
        if retained.action == .hold { return .init(kind:.steady,text:retained.text,action:.hold) }
        if retained.action == .none {
            if phase.isPreparing && autoEnabled {
                return continuousFraming ? .init(kind:.framing,text:"Finding your shot…") : .init(kind:.steady,text:"Hold steady",action:.hold)
            }
            if !ShotReadiness.permitsReady(required:requireShotCompletion,shotVerified:shotVerified,currentFrameVerified:currentFrameVerified) {
                if phase == .off { return .init(kind:continuousFraming ? .framing : .steady,text:continuousFraming ? "Frame with the camera controls" : "Automatic framing paused") }
                return .init(kind:.framing,text:compositionPlan == nil ? "Evaluating the shot…" : "Checking the selected framing…")
            }
            if reading.state != .ready { return .init(kind:.steady,text:"Hold steady",action:.hold) }
            return .init(kind:.ready,text:"Ready to shoot",action:GuidanceAction.none)
        }
        if phase == .settling && retained.action == .tighterCrop { return .init(kind:.steady,text:"Hold steady",action:.hold) }
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
