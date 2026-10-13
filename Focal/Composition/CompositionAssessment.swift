import Foundation

enum GuidanceAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, hold, makeRoom, tighterCrop, panLeft, panRight, panUp, panDown, level, reduceExposure, addLight, reviewOverlap
    var id: Self { self }
    var isAdjustment: Bool { ![Self.none,.hold].contains(self) }
    func opposes(_ other: Self) -> Bool {
        (self == .panLeft && other == .panRight) || (self == .panRight && other == .panLeft)
            || (self == .panUp && other == .panDown) || (self == .panDown && other == .panUp)
    }
}

struct SubjectAnatomy: Sendable {
    var face: CGRect?
    var headYaw: Double?
    var joints: [CGPoint] = []
    var timestamp: TimeInterval
}

struct IntentFramingProfile {
    let minimumArea: Double
    let maximumArea: Double
    let positionRegion: CGRect
    static func forIntent(_ intent: PhotographyIntent, category: SubjectCategory, hasContext: Bool) -> Self {
        let resolved = intent == .auto ? (category == .pet ? PhotographyIntent.pet : category == .person || category == .face ? .portrait : category == .architecture ? .architecture : .auto) : intent
        let minimum: Double
        let maximum: Double
        switch resolved {
        case .portrait: minimum = 0.08; maximum = 0.82
        case .pet: minimum = 0.055; maximum = 0.82
        case .product: minimum = 0.08; maximum = 0.70
        case .architecture: minimum = 0.035; maximum = 0.94
        case .landscape: minimum = 0; maximum = 1
        case .auto: minimum = 0.035; maximum = 0.90
        }
        return .init(minimumArea:hasContext ? min(minimum,0.025) : minimum,maximumArea:maximum,
                     positionRegion:CGRect(x:0.16,y:0.12,width:0.68,height:0.76))
    }
}

struct CompositionAssessment {
    var confidence: Double
    var subjectArea: Double?
    var visibleFraction: Double?
    var minimumMargin: Double?
    var headroom: Double?
    var edgeJointCount = 0
    var positionPenalty: Double = 0
    var sizePenalty: Double = 0
    var backgroundEdges: Double?
    var contrast: Double?
    var backgroundDistractors: Int = 0
    var balanceOffset: Double?
    var horizonDegrees: Double?
    var verticalLeanDegrees: Double?
    var exposure: PhotoMeasurements?
    var cameraMoving = false
    var headYaw: Double?
    var touchesEdge: Bool { (visibleFraction ?? 1) < 0.98 || (minimumMargin ?? 1) < 0.012 || (headroom ?? 1) < 0.012 || edgeJointCount > 0 }
    var fitness: Double? {
        guard subjectArea != nil, confidence.isFinite, confidence >= 0.55 else { return nil }
        let clipping = 1-(visibleFraction ?? 1)
        let marginPenalty = touchesEdge ? 0.3 : 0
        return max(0,1-clipping*0.8-marginPenalty-sizePenalty*0.3-positionPenalty*0.2)
    }
    static func evaluate(bounds: CGRect?, confidence: Double, label: String, intent: PhotographyIntent,
                         stable: Bool, exposure: PhotoMeasurements?, evidence: SceneCompositionEvidence?,
                         others: [CompositionContextSubject] = [], anatomy: SubjectAnatomy? = nil, timestamp: TimeInterval = 0) -> Self {
        var result = Self(confidence:confidence,exposure:exposure,cameraMoving:!stable)
        if let evidence, evidence.isFresh(at:timestamp) {
            result.balanceOffset = evidence.balanceOffset(in:SceneCompositionEvidence.full)
            if intent == .landscape, let line = evidence.tiltedSceneBoundary() {
                let aspect = Double(evidence.image.width)/Double(evidence.image.height)
                result.horizonDegrees = atan((line.end.y-line.start.y)/((line.end.x-line.start.x)*aspect))*180/Double.pi
            }
        }
        guard let bounds, !bounds.isNull, [bounds.minX,bounds.minY,bounds.width,bounds.height].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0, confidence.isFinite, confidence >= 0.4 else { return result }
        let visible = bounds.intersection(SceneCompositionEvidence.full)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return result }
        let context = SceneCompositionPlanner.distinctSubjects(others,selected:visible)
        let profile = IntentFramingProfile.forIntent(intent,category:SubjectCategory.classified(label),hasContext:!context.isEmpty)
        let area = Double(visible.width*visible.height)
        result.subjectArea = area
        result.visibleFraction = Double(visible.width*visible.height/(bounds.width*bounds.height))
        result.minimumMargin = Double(min(bounds.minX,min(bounds.minY,min(1-bounds.maxX,1-bounds.maxY))))
        result.sizePenalty = area < profile.minimumArea ? (profile.minimumArea-area)/max(0.01,profile.minimumArea)
            : area > profile.maximumArea ? (area-profile.maximumArea)/max(0.01,1-profile.maximumArea) : 0
        let region = profile.positionRegion
        let dx = max(0,max(Double(region.minX-bounds.midX),Double(bounds.midX-region.maxX)))
        let dy = max(0,max(Double(region.minY-bounds.midY),Double(bounds.midY-region.maxY)))
        result.positionPenalty = min(1,hypot(dx,dy)*3)
        if let anatomy, timestamp >= anatomy.timestamp, timestamp-anatomy.timestamp <= 1.5 {
            if let face = anatomy.face, face.intersects(visible) { result.headroom = Double(face.minY) }
            result.edgeJointCount = anatomy.joints.filter { point in
                visible.insetBy(dx:-0.03,dy:-0.03).contains(point) && (point.x < 0.012 || point.y < 0.012 || point.x > 0.988 || point.y > 0.988)
            }.count
            result.headYaw = anatomy.headYaw
        }
        if let evidence, evidence.isFresh(at:timestamp) {
            result.backgroundEdges = evidence.region(SceneCompositionEvidence.full,excluding:visible).edgeDensity
            result.contrast = evidence.separation(subject:visible)
            result.backgroundDistractors = context.filter { candidate in
                candidate.confidence >= 0.75 && visible.insetBy(dx:-0.08,dy:-0.08).intersects(candidate.bounds)
            }.count
            if intent == .architecture || SubjectCategory.classified(label) == .architecture {
                let verticals = evidence.lines.filter { abs($0.end.y-$0.start.y) > 0.5 && abs($0.end.x-$0.start.x) < 0.15 }
                if verticals.count >= 2 {
                    result.verticalLeanDegrees = verticals.map { atan(($0.end.x-$0.start.x)/($0.end.y-$0.start.y))*180/Double.pi }.reduce(0,+)/Double(verticals.count)
                }
            }
        }
        return result
    }
}

struct AssessmentMeasurements: Codable, Sendable {
    var subjectArea: Double?
    var visibleFraction: Double?
    var minimumMargin: Double?
    var headroom: Double?
    var edgeJointCount: Int
    var backgroundEdges: Double?
    var subjectBackgroundContrast: Double?
    var adjacentNamedRegions: Int
    var visualMassOffset: Double?
    var candidateBoundaryDegrees: Double?
    var verticalLeanDegrees: Double?
    var headYawRadians: Double?
    var sizePenalty: Double
    var positionPenalty: Double
    init(_ measured: CompositionAssessment) {
        subjectArea = measured.subjectArea; visibleFraction = measured.visibleFraction; minimumMargin = measured.minimumMargin
        headroom = measured.headroom; edgeJointCount = measured.edgeJointCount; backgroundEdges = measured.backgroundEdges
        subjectBackgroundContrast = measured.contrast; adjacentNamedRegions = measured.backgroundDistractors
        visualMassOffset = measured.balanceOffset; candidateBoundaryDegrees = measured.horizonDegrees
        verticalLeanDegrees = measured.verticalLeanDegrees; headYawRadians = measured.headYaw
        sizePenalty = measured.sizePenalty; positionPenalty = measured.positionPenalty
    }
}

struct FeasibleGuidance: Equatable {
    var action: GuidanceAction
    var text: String
    var confidence: Double
    var issue: Double
    var showsDirection: Bool { [.panLeft,.panRight,.panUp,.panDown].contains(action) }
}

enum ActionFeasibility {
    static func sceneRecommendation(landscape: Bool, stable: Bool, roll: Double, rollReliable: Bool, measurements: PhotoMeasurements?,
                                    evidence: SceneCompositionEvidence?, timestamp: TimeInterval, previewAspect: Double) -> FeasibleGuidance? {
        guard landscape else { return nil }
        if !stable { return .init(action:.hold,text:"Hold steady",confidence:0,issue:0) }
        if rollReliable && abs(roll) > 5 { return .init(action:.level,text:"Keep the camera level",confidence:0,issue:min(1,abs(roll)/20)) }
        if let measurements, measurements.highlightFraction > 0.18 {
            return .init(action:.reduceExposure,text:"Lower exposure to protect bright scene detail",confidence:0,issue:measurements.highlightFraction)
        }
        if let evidence, evidence.isFresh(at:timestamp), let line = evidence.tiltedSceneBoundary() {
            let angle = atan((line.end.y-line.start.y)/((line.end.x-line.start.x)*max(0.1,previewAspect)))*180/Double.pi
            if abs(angle) > 6 { return .init(action:.level,text:"Check the tilted scene boundary if it is your horizon",confidence:0,issue:min(1,abs(angle)/20)) }
        }
        return .init(action:.none,text:"Ready to shoot",confidence:0,issue:0)
    }
    static func recommend(assessment: CompositionAssessment, reading: CompositionReading, intent: PhotographyIntent,
                          plan: SceneCompositionPlan?, rollReliable: Bool, previewAspect: Double,
                          manualComposition: Bool = false, autoPreparing: Bool = false) -> FeasibleGuidance {
        func decision(_ action:GuidanceAction,_ text:String,_ issue:Double) -> FeasibleGuidance {
            .init(action:action,text:text,confidence:assessment.confidence,issue:issue)
        }
        guard assessment.confidence.isFinite, assessment.confidence >= 0.55, assessment.subjectArea != nil else {
            return decision(.none,"No reliable adjustment identified",0)
        }
        if assessment.touchesEdge { return decision(.makeRoom,"Leave a little room around the visible subject edges",max(0.3,1-(assessment.visibleFraction ?? 1))) }
        if assessment.cameraMoving { return decision(.hold,"Hold steady while the frame settles",0) }
        if rollReliable, abs(reading.rollDegrees) > 5 { return decision(.level,"Level the camera",min(1,abs(reading.rollDegrees)/20)) }
        if let exposure = assessment.exposure {
            if exposure.highlightFraction > 0.18 { return decision(.reduceExposure,"Lower exposure to protect bright subject detail",exposure.highlightFraction) }
            if exposure.brightness < 0.12 && exposure.shadowFraction > 0.75 { return decision(.addLight,"More light can reveal subject detail",exposure.shadowFraction) }
        }
        if manualComposition || (plan?.selected.measuredImprovement ?? 0) >= IntentCompositionSearch.minimumImprovement {
            if let cue = CompositionCue(reading:reading,previewAspect:previewAspect), !cue.aligned,
               manualComposition || assessment.positionPenalty > 0.05 || autoPreparing {
                let action: GuidanceAction = cue.direction == "left" ? .panLeft : cue.direction == "right" ? .panRight : cue.direction == "up" ? .panUp : .panDown
                let error = hypot(cue.subject.x-cue.target.x,(cue.subject.y-cue.target.y)/max(0.1,previewAspect))
                return decision(action,cue.phoneInstruction,max(0.05,error))
            }
            if assessment.sizePenalty > 0.15, let plan, plan.permitsZoom {
                return decision(.tighterCrop,"The evaluated tighter frame keeps the subject visible",assessment.sizePenalty)
            }
        }
        // Texture, fur, bedding and low edge energy alone do not justify
        // isolation, an angle change, a focus claim or anatomical clipping.
        return decision(.none,"Ready to shoot",0)
    }
}
