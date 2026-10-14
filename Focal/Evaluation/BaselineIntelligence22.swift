#if DEBUG || FOCAL_EVALUATION
import Foundation

// Frozen decision code from published Focal 2.2/build 19.
struct BaselineProfile22 {
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

struct BaselineAssessment22 {
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
        let context = BaselinePlanner22.distinctSubjects(others,selected:visible)
        let profile = BaselineProfile22.forIntent(intent,category:SubjectCategory.classified(label),hasContext:!context.isEmpty)
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

struct BaselineMeasurements22: Codable, Sendable {
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
    init(_ measured: BaselineAssessment22) {
        subjectArea = measured.subjectArea; visibleFraction = measured.visibleFraction; minimumMargin = measured.minimumMargin
        headroom = measured.headroom; edgeJointCount = measured.edgeJointCount; backgroundEdges = measured.backgroundEdges
        subjectBackgroundContrast = measured.contrast; adjacentNamedRegions = measured.backgroundDistractors
        visualMassOffset = measured.balanceOffset; candidateBoundaryDegrees = measured.horizonDegrees
        verticalLeanDegrees = measured.verticalLeanDegrees; headYawRadians = measured.headYaw
        sizePenalty = measured.sizePenalty; positionPenalty = measured.positionPenalty
    }
}

struct BaselineFeasibleGuidance22: Equatable {
    var action: GuidanceAction
    var text: String
    var confidence: Double
    var issue: Double
    var showsDirection: Bool { [.panLeft,.panRight,.panUp,.panDown].contains(action) }
}

enum BaselineFeasibility22 {
    static func sceneRecommendation(landscape: Bool, stable: Bool, roll: Double, rollReliable: Bool, measurements: PhotoMeasurements?,
                                    evidence: SceneCompositionEvidence?, timestamp: TimeInterval, previewAspect: Double) -> BaselineFeasibleGuidance22? {
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
    static func recommend(assessment: BaselineAssessment22, reading: CompositionReading, intent: PhotographyIntent,
                          plan: SceneCompositionPlan?, rollReliable: Bool, previewAspect: Double,
                          manualComposition: Bool = false, autoPreparing: Bool = false) -> BaselineFeasibleGuidance22 {
        func decision(_ action:GuidanceAction,_ text:String,_ issue:Double) -> BaselineFeasibleGuidance22 {
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
        if manualComposition || (plan?.selected.measuredImprovement ?? 0) >= BaselineCropSearch22.minimumImprovement {
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



struct BaselineMemory22 {
    private static func opposes22(_ a:GuidanceAction,_ b:GuidanceAction) -> Bool {
        (a == .panLeft && b == .panRight) || (a == .panRight && b == .panLeft)
            || (a == .panUp && b == .panDown) || (a == .panDown && b == .panUp)
    }
    private var shown: BaselineFeasibleGuidance22?
    private var shownAt: TimeInterval = 0
    private var pending: BaselineFeasibleGuidance22?
    private var pendingAt: TimeInterval = 0
    private var pendingSamples = 0
    private var previousBounds: CGRect?
    private var previousIssue: Double?
    private var subject: String?
    private var intent: PhotographyIntent?
    private var previousTime: TimeInterval?
    private var reconsiderUntil: TimeInterval = 0
    private var worseningSamples = 0
    mutating func reset() { self = Self() }
    mutating func update(_ decision: BaselineFeasibleGuidance22, bounds: CGRect?, label: String, intent: PhotographyIntent, timestamp: TimeInterval) -> BaselineFeasibleGuidance22 {
        guard timestamp.isFinite else { reset(); return .init(action:.none,text:"No reliable adjustment identified",confidence:0,issue:0) }
        if subject != label || self.intent != intent || previousTime.map({ timestamp < $0 || timestamp-$0 > 2.5 }) == true { reset() }
        defer { previousBounds = bounds; previousIssue = decision.issue; previousTime = timestamp; subject = label; self.intent = intent }
        let changed = previousBounds.flatMap { old in bounds.map { box in
            hypot(Double(old.midX-box.midX),Double(old.midY-box.midY)) > 0.025 || abs(Double(old.width-box.width)) > 0.06
        } } ?? false
        if changed, shown?.action == decision.action, decision.showsDirection, let previousIssue, decision.issue > previousIssue+0.08 {
            worseningSamples += 1
        } else { worseningSamples = 0 }
        if worseningSamples >= 2 { reconsiderUntil = timestamp+1.5; shown = nil; pending = nil; worseningSamples = 0 }
        if timestamp < reconsiderUntil { return .init(action:.hold,text:"Keep this frame while guidance reassesses",confidence:decision.confidence,issue:0) }
        if decision.action == .none || decision.action == .hold || decision.action == .makeRoom || shown == nil {
            shown = decision; shownAt = timestamp; pending = nil; return decision
        }
        if shown?.action == decision.action { shown = decision; return decision }
        if pending?.action != decision.action { pending = decision; pendingAt = timestamp; pendingSamples = 1 }
        else { pending = decision; pendingSamples += 1 }
        let opposite = shown.map { Self.opposes22(decision.action,$0.action) } ?? false
        let delay = opposite ? 1.4 : 0.7
        if timestamp-shownAt >= 1.8, timestamp-pendingAt >= delay, pendingSamples >= 2 {
            shown = decision; shownAt = timestamp; pending = nil
        }
        return shown ?? decision
    }
}



struct BaselineCropCandidate22 {
    let crop: CGRect
    let fitness: Double
    let improvement: Double
    let scale: Double
    let mapsToCameraZoom: Bool
}

enum BaselineCropSearch22 {
    static let minimumImprovement = 0.08
    static func zoomPlan(subject: CGRect, label: String, intent: PhotographyIntent, evidence: SceneCompositionEvidence,
                         others: [CompositionContextSubject], frames: [CGRect], scales: [Double], forceCenter: Bool) -> SceneCompositionPlan? {
        let enclosing = frames.filter { $0.contains(subject) && $0.width*$0.height > subject.width*subject.height*1.7 }
        guard let best = candidates(subject:subject,label:label,intent:intent,evidence:evidence,others:others,frames:enclosing,scales:scales)
            .first(where: { $0.mapsToCameraZoom && $0.improvement >= minimumImprovement && $0.scale > 1.12 }) else { return nil }
        let relative = FramingPlanner.zoomedRect(subject,scale:best.scale)
        let target = forceCenter ? UnitPoint2D(x:0.5,y:0.5) : .init(x:relative.midX,y:relative.midY)
        let option = CompositionOption(technique:.fillFrame,target:target,crop:best.crop,score:best.fitness,
            explanation:"tighten only the observed frame",zoomScale:best.scale,measuredImprovement:best.improvement)
        return .init(selected:option,alternatives:[],subjectLabel:label,timestamp:evidence.timestamp)
    }
    static func candidates(subject: CGRect, label: String, intent: PhotographyIntent, evidence: SceneCompositionEvidence,
                           others: [CompositionContextSubject], frames: [CGRect], scales: [Double]) -> [BaselineCropCandidate22] {
        let original = BaselineAssessment22.evaluate(bounds:subject,confidence:1,label:label,intent:intent,stable:true,
            exposure:nil,evidence:evidence,others:others,timestamp:evidence.timestamp)
        guard let originalFitness = original.fitness else { return [] }
        let context = BaselinePlanner22.distinctSubjects(others,selected:subject)
        var result = [BaselineCropCandidate22(crop:SceneCompositionEvidence.full,fitness:originalFitness,improvement:0,scale:1,mapsToCameraZoom:true)]
        for scale in scales where scale.isFinite && scale > 1 && scale <= intent.maximumCropScale {
            let size = 1/scale
            let centers = [CGPoint(x:0.5,y:0.5),CGPoint(x:subject.midX,y:subject.midY)]
            for center in centers {
                let x = max(0,min(1-size,Double(center.x)-size/2)), y = max(0,min(1-size,Double(center.y)-size/2))
                let crop = CGRect(x:x,y:y,width:size,height:size)
                guard crop.insetBy(dx:0.018/scale,dy:0.018/scale).contains(subject),
                      context.allSatisfy({ crop.contains($0.bounds) }),frames.allSatisfy({ crop.contains($0) }) else { continue }
                let relative = CGRect(x:(subject.minX-crop.minX)/crop.width,y:(subject.minY-crop.minY)/crop.height,width:subject.width/crop.width,height:subject.height/crop.height)
                let relativeOthers = context.map { item in CompositionContextSubject(bounds:CGRect(x:(item.bounds.minX-crop.minX)/crop.width,y:(item.bounds.minY-crop.minY)/crop.height,width:item.bounds.width/crop.width,height:item.bounds.height/crop.height),label:item.label,confidence:item.confidence) }
                let measured = BaselineAssessment22.evaluate(bounds:relative,confidence:1,label:label,intent:intent,stable:true,exposure:nil,evidence:nil,others:relativeOthers)
                // Only measured scale/visibility/margins/position improvements
                // count; cleaner unknown surroundings are never assumed.
                guard let measuredFitness = measured.fitness else { continue }
                let fitness = measuredFitness-(scale-1)*0.012
                let centered = abs(crop.midX-0.5) < 0.001 && abs(crop.midY-0.5) < 0.001
                if !result.contains(where: { $0.crop == crop }) {
                    result.append(.init(crop:crop,fitness:fitness,improvement:fitness-originalFitness,scale:scale,mapsToCameraZoom:centered))
                }
            }
        }
        return result.sorted { $0.improvement > $1.improvement }
    }
}

struct BaselinePlanner22 {
    private(set) var plan: SceneCompositionPlan?
    private var pending: CompositionTechnique?
    private var pendingSince: TimeInterval = 0
    private var previousBounds: CGRect?
    private var lastSeen: TimeInterval?
    private var evaluatedEvidenceTime: TimeInterval = -.infinity
    private var evaluatedBounds: CGRect?
    private var evaluatedIntent: PhotographyIntent?
    private var evaluatedScales: [Double]?
    private var evaluatedMaximumScale: Double = 0
    private var evaluatedContext: [CGRect] = []
    private var cachedOptions: [CompositionOption] = []
    mutating func reset() { self = Self() }

    mutating func update(subject: CGRect?, confidence: Float, label: String, evidence: SceneCompositionEvidence?,
                         others: [CompositionContextSubject] = [], enclosingFrames: [CGRect] = [],
                         timestamp: TimeInterval, maximumScale: Double = 1, freeze: Bool = false, intent: PhotographyIntent = .auto, availableScales: [Double]? = nil) -> SceneCompositionPlan? {
        guard timestamp.isFinite else { reset(); return nil }
        guard let subject, Self.valid(subject), confidence >= 0.55 else {
            // Return no plan/box during loss; preserve the choice only for a
            // short tracker recovery, never across a different subject.
            if lastSeen.map({ timestamp < $0 || timestamp-$0 > 0.6 }) ?? true { reset() }
            return nil
        }
        if plan?.subjectLabel != label || previousBounds.map({ hypot(Double($0.midX-subject.midX),Double($0.midY-subject.midY)) > 0.3 }) == true { reset() }
        previousBounds = subject; lastSeen = timestamp
        if freeze, var retained = plan, !retained.selected.isCurrentFrame {
            retained.selected.target = Self.safeTarget(retained.target,subject:subject)
            plan = retained; return retained
        }
        guard let evidence, evidence.isFresh(at:timestamp) else {
            if var retained = plan, timestamp >= retained.timestamp, timestamp-retained.timestamp < 2.5 {
                retained.selected.target = Self.safeTarget(retained.target,subject:subject)
                return retained
            }
            return nil
        }
        let context = others.map(\.bounds)+enclosingFrames
        let sameGeometry = evaluatedBounds.map { abs($0.midX-subject.midX) < 0.015 && abs($0.midY-subject.midY) < 0.015 && abs($0.width-subject.width) < 0.015 && abs($0.height-subject.height) < 0.015 } ?? false
        let options: [CompositionOption]
        if evaluatedEvidenceTime == evidence.timestamp, evaluatedIntent == intent, evaluatedScales == availableScales, evaluatedMaximumScale == maximumScale,
           sameGeometry, evaluatedContext == context, cachedOptions.first?.isCurrentFrame == true {
            options = cachedOptions.map { option in
                var updated = option
                if updated.isCurrentFrame { updated.target = .init(x:subject.midX,y:subject.midY) }
                return updated
            }
        } else {
            options = Self.compare(subject:subject,evidence:evidence,others:others,enclosingFrames:enclosingFrames,maximumScale:min(maximumScale,intent.maximumCropScale),intent:intent,availableScales:availableScales,label:label)
            evaluatedEvidenceTime = evidence.timestamp; evaluatedIntent = intent; evaluatedScales = availableScales
            evaluatedMaximumScale = maximumScale
            evaluatedBounds = subject; evaluatedContext = context; cachedOptions = options
        }
        guard let best = options.first else { reset(); return nil }
        let chosen: CompositionOption
        if best.isCurrentFrame { chosen = best; pending = nil }
        else if let old = plan,
           let stillSupported = options.first(where: { $0.technique == old.selected.technique }) {
            if best.technique != old.selected.technique && best.score > stillSupported.score+0.035 {
                if pending != best.technique { pending = best.technique; pendingSince = timestamp }
                if timestamp-pendingSince >= 1.6 { chosen = best; pending = nil }
                else { chosen = retainingTarget(stillSupported,from:old,subject:subject) }
            } else {
                pending = nil; chosen = retainingTarget(stillSupported,from:old,subject:subject)
            }
        } else { chosen = best; pending = nil }
        let result = SceneCompositionPlan(selected:chosen,alternatives:Array(options.filter { $0.technique != chosen.technique }.prefix(3)),subjectLabel:label,timestamp:timestamp)
        plan = result
        return result
    }
    private func retainingTarget(_ option: CompositionOption, from old: SceneCompositionPlan, subject: CGRect) -> CompositionOption {
        var retained = option
        if option.isCurrentFrame { return option }
        // Retain the chosen side/corner through ordinary panning. Adjust only
        // if a larger subject would cross an edge at that target.
        retained.target = Self.safeTarget(old.target,subject:subject)
        return retained
    }
    static func compare(subject: CGRect, evidence: SceneCompositionEvidence, others: [CompositionContextSubject] = [],
                        enclosingFrames: [CGRect] = [], maximumScale: Double = 1, intent: PhotographyIntent = .auto, availableScales: [Double]? = nil, label: String = "Subject") -> [CompositionOption] {
        guard intent != .landscape else { return [] }
        guard valid(subject), maximumScale.isFinite, maximumScale >= 1 else { return [] }
        let center = UnitPoint2D(x:subject.midX,y:subject.midY)
        let background = evidence.region(SceneCompositionEvidence.full,excluding:subject)
        let separation = evidence.separation(subject:subject)
        let context = distinctSubjects(others,selected:subject)
        let group = context + [CompositionContextSubject(bounds:subject,label:"Selected",confidence:1)]
        let hasGroup = context.count > 0
        let enclosing = enclosingFrames.filter { valid($0) && $0.contains(subject) && $0.width*$0.height > subject.width*subject.height*1.7 }
        // Exclude short subject contours from environment line evidence.
        let environmentLines = evidence.lines.filter { line in
            !subject.insetBy(dx:-0.03,dy:-0.03).contains(CGPoint(x:line.start.x,y:line.start.y))
                && !subject.insetBy(dx:-0.03,dy:-0.03).contains(CGPoint(x:line.end.x,y:line.end.y))
        }
        let leading = environmentLines.filter { $0.distance(to:center) < 0.1 && $0.length > 0.45 }
        let diagonal = environmentLines.filter(\.diagonal)
        let left = evidence.region(CGRect(x:0,y:0,width:0.32,height:1),excluding:subject)
        let right = evidence.region(CGRect(x:0.68,y:0,width:0.32,height:1),excluding:subject)
        var specifications = [(CompositionTechnique,UnitPoint2D,Double,String)]()
        func add(_ technique: CompositionTechnique, _ target: UnitPoint2D, _ support: Double, _ reason: String) {
            specifications.append((technique,safeTarget(target,subject:subject),support,reason))
        }
        let third = UnitPoint2D(x:center.x < 0.5 ? 1.0/3 : 2.0/3,y:center.y < 0.5 ? 1.0/3 : 2.0/3)
        let golden = UnitPoint2D(x:center.x < 0.5 ? 0.382 : 0.618,y:center.y < 0.5 ? 0.382 : 0.618)
        add(.centered,.init(x:0.5,y:0.5),0.49+separation*0.15,"keep the subject clear")
        add(.thirds,third,0.58,"give the subject breathing room")
        add(.goldenRatio,golden,0.55,"gentle off-center placement")
        if evidence.symmetry > 0.72 { add(.symmetry,.init(x:0.5,y:0.5),0.62+evidence.symmetry*0.2,"align the mirrored scene") }
        if max(left.calm,right.calm) > 0.76 && subject.width*subject.height < 0.28 && !hasGroup {
            // Subject to left preserves the observed calm RIGHT side.
            let x = right.calm >= left.calm ? 1.0/3 : 2.0/3
            add(.negativeSpace,.init(x:x,y:0.5),0.65+max(left.calm,right.calm)*0.12,"keep the calm space \(x < 0.5 ? "on the right" : "on the left")")
        }
        if !hasGroup && separation > 0.35 && subject.width*subject.height < 0.5 {
            add(.fillFrame,.init(x:0.5,y:0.5),0.48+separation*0.2,"tighten without cutting the subject")
        }
        if !leading.isEmpty { add(.leadingLines,center,0.76+min(0.12,Double(leading.count)*0.04),"keep the visible lines pointing toward the subject") }
        if !diagonal.isEmpty { add(.diagonals,center,0.73,"preserve the strong diagonal") }
        if !enclosing.isEmpty { add(.framing,center,0.87,"keep the enclosing shape intact") }
        if hasGroup {
            let leftWeight = group.filter { $0.bounds.midX < 0.5 }.reduce(0.0) { $0+Double($1.bounds.width*$1.bounds.height)*$1.confidence }
            let rightWeight = group.filter { $0.bounds.midX >= 0.5 }.reduce(0.0) { $0+Double($1.bounds.width*$1.bounds.height)*$1.confidence }
            if min(leftWeight,rightWeight)/max(0.001,max(leftWeight,rightWeight)) > 0.25 {
                add(.balance,center,0.83,"keep the counterweight in view")
            }
            if group.count == 3 || group.count == 5 { add(.odds,center,0.82,"keep all \(group.count) subjects together") }
            if group.count == 3 {
                let a = group[0].bounds, b = group[1].bounds, c = group[2].bounds
                let area = abs((b.midX-a.midX)*(c.midY-a.midY)-(c.midX-a.midX)*(b.midY-a.midY))/2
                if area > 0.025 { add(.triangles,center,0.89,"preserve the three-point arrangement") }
            }
            if context.contains(where: { abs($0.bounds.midY-subject.midY) > 0.25 && abs($0.bounds.height-subject.height) > 0.12 }) {
                add(.layers,center,0.8,"keep the separated elements for context")
            }
        }
        if evidence.repetition > 0.78 { add(.repetition,center,0.81,"preserve the repeated shapes") }
        if background.edgeDensity > 0.2 && !hasGroup && enclosing.isEmpty {
            add(.simplicity,.init(x:0.5,y:0.5),0.65+background.edgeDensity*0.3,"reduce the busy edges")
        }
        if separation > 0.65 { add(.contrast,third,0.61+separation*0.15,"preserve the subject's color separation") }
        var ranked = [CompositionOption]()
        for (technique,target,support,reason) in specifications {
            let canTighten = [CompositionTechnique.centered,.fillFrame,.simplicity,.contrast,.thirds,.goldenRatio].contains(technique) && !hasGroup && enclosing.isEmpty && intent.permitsZoom
            let choices = availableScales ?? [1.0,1.15,1.35,1.6,2.0,2.5,3.0]
            let scales = canTighten ? Array(Set([1.0] + choices.filter { $0.isFinite && $0 >= 1 && $0 <= min(maximumScale,intent.maximumCropScale) })).sorted() : [1.0]
            var best: CompositionOption?
            for scale in scales {
                // Physical phone zoom is centered. Score ONLY that observed
                // crop; never score unknown scenery revealed by future panning.
                let crop = CGRect(x:(1-1/scale)/2,y:(1-1/scale)/2,width:1/scale,height:1/scale)
                guard crop.insetBy(dx:0.025/scale,dy:0.025/scale).contains(subject),
                      context.allSatisfy({ crop.contains($0.bounds) }), enclosing.allSatisfy({ crop.contains($0) }) else { continue }
                let relative = CGRect(x:(subject.minX-crop.minX)/crop.width,y:(subject.minY-crop.minY)/crop.height,width:subject.width/crop.width,height:subject.height/crop.height)
                // The whole subject must also fit at its intended final mark.
                let safe = safeTarget(target,subject:relative)
                guard safe.distance(to:target) < 0.001 else { continue }
                let area = Double(relative.width*relative.height)
                let idealArea = technique == .fillFrame ? 0.42 : technique == .negativeSpace ? 0.10 : 0.25
                let size = max(0,1-abs(area-idealArea)/max(0.15,idealArea))
                let ease = max(0,1-hypot(Double(relative.midX)-target.x,Double(relative.midY)-target.y))
                let croppedBackground = evidence.region(crop,excluding:subject)
                let clean = max(0,1-croppedBackground.edgeDensity*2)
                let penalty = croppedBackground.clipping*0.06+(scale-1)*0.025
                let score = support*0.68+size*0.1+ease*0.1+clean*0.12-penalty+intent.bonus(for:technique)
                let zoom = canTighten ? scale : 1
                let option = CompositionOption(technique:technique,target:target,crop:crop,score:score,explanation:reason,zoomScale:zoom)
                if best == nil || option.score > (best?.score ?? 0) { best = option }
            }
            if let best { ranked.append(best) }
        }
        let scales = availableScales ?? [1.0,1.15,1.35,1.6,2.0,2.5,3.0].filter { $0 <= maximumScale }
        let measured = BaselineCropSearch22.candidates(subject:subject,label:label,intent:intent,evidence:evidence,
            others:others,frames:enclosing,scales:scales)
        let baseline = BaselineAssessment22.evaluate(bounds:subject,confidence:1,label:label,intent:intent,stable:true,exposure:nil,evidence:evidence,others:others,timestamp:evidence.timestamp)
        guard let currentFitness = baseline.fitness else { return [] }
        for index in ranked.indices {
            let option = ranked[index]
            let cropGain = measured.first(where: { $0.crop == option.crop && $0.mapsToCameraZoom })?.improvement ?? 0
            // A target shift is justified only by an observed position issue.
            // Existing comfortable off-center placement incurs no penalty.
            let targetGain = baseline.positionPenalty > 0 ? min(0.2,baseline.positionPenalty*0.2) : 0
            ranked[index].measuredImprovement = max(cropGain,targetGain)
            if cropGain >= BaselineCropSearch22.minimumImprovement && baseline.positionPenalty == 0 {
                let relative = FramingPlanner.zoomedRect(subject,scale:option.zoomScale)
                ranked[index].target = UnitPoint2D(x:relative.midX,y:relative.midY)
                ranked[index].technique = .fillFrame
                ranked[index].explanation = "improve subject scale while retaining the observed placement"
            }
            if ranked[index].measuredImprovement < BaselineCropSearch22.minimumImprovement { ranked[index].zoomScale = 1 }
        }
        let keep = CompositionOption(technique:.centered,target:center,crop:SceneCompositionEvidence.full,score:currentFitness,
                                     explanation:"keep the current composition",zoomScale:1,measuredImprovement:0,isCurrentFrame:true)
        let improvements = ranked.filter { $0.measuredImprovement >= BaselineCropSearch22.minimumImprovement }
            .sorted { $0.measuredImprovement == $1.measuredImprovement ? $0.score > $1.score : $0.measuredImprovement > $1.measuredImprovement }
        return improvements.isEmpty ? [keep]+ranked.sorted { $0.score > $1.score } : improvements+[keep]+ranked.filter { $0.measuredImprovement < BaselineCropSearch22.minimumImprovement }.sorted { $0.score > $1.score }
    }
    static func distinctSubjects(_ subjects: [CompositionContextSubject], selected: CGRect) -> [CompositionContextSubject] {
        var distinct = [CompositionContextSubject]()
        for candidate in subjects.sorted(by: { $0.bounds.width*$0.bounds.height > $1.bounds.width*$1.bounds.height }) {
            guard valid(candidate.bounds), candidate.confidence.isFinite, candidate.confidence >= 0.65 else { continue }
            let duplicate = ([CompositionContextSubject(bounds:selected,label:"Selected",confidence:1)]+distinct).contains { existing in
                let overlap = candidate.bounds.intersection(existing.bounds)
                let area = min(candidate.bounds.width*candidate.bounds.height,existing.bounds.width*existing.bounds.height)
                return !overlap.isNull && area > 0 && overlap.width*overlap.height/area > 0.55
            }
            if !duplicate { distinct.append(candidate) }
        }
        return Array(distinct.prefix(6))
    }
    static func safeTarget(_ point: UnitPoint2D, subject: CGRect) -> UnitPoint2D {
        let marginX = min(0.49,Double(subject.width)/2+0.035), marginY = min(0.49,Double(subject.height)/2+0.035)
        return UnitPoint2D(x:max(marginX,min(1-marginX,point.x)),y:max(marginY,min(1-marginY,point.y)))
    }
    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && [rect.minX,rect.minY,rect.width,rect.height].allSatisfy(\.isFinite)
            && rect.width > 0.025 && rect.height > 0.025 && SceneCompositionEvidence.full.contains(rect)
    }
}

struct BaselineGuidance22 {
    private var memory = BaselineMemory22()
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
            if let decision = BaselineFeasibility22.sceneRecommendation(landscape:landscape,stable:stable,roll:reading.rollDegrees,rollReliable:rollReliable,
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
        let assessment = BaselineAssessment22.evaluate(bounds:bounds,confidence:Double(reading.subjectConfidence),label:label,
            intent:intent,stable:stable && relativeSpeed <= 0.25,exposure:subjectMeasurements,evidence:sceneEvidence,others:others,anatomy:anatomy,timestamp:timestamp)
        if phase == .zooming { return .init(kind:.framing,text:"Refining the evaluated crop…") }
        if assessment.confidence < 0.55 { return .init(kind:.steady,text:"Keep the selected subject visible",action:.hold) }
        let proposed = BaselineFeasibility22.recommend(assessment:assessment,reading:reading,intent:intent,plan:compositionPlan,
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


extension SubjectCandidate {
    func baselineScore22(configuration: SubjectSelectionConfiguration) -> Double? {
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
        // Fur, clothing and bedding texture cannot outweigh a strong native
        // person/pet recognition. Anonymous salient regions retain the penalty.
        let texturePenalty = category.semantic ? 0.03 : category == .nature ? 0.02 : textConfidence >= 0.65 ? 0.06 : 0.22
        let score = 0.35 * confidence + 0.12 * category.priority + 0.15 * classificationConfidence
            + 0.12 * prominence + 0.08 * isolation + 0.07 * sizeQuality + 0.11 * centerPreference - texturePenalty * textureDensity
        // Small peripheral people should not eclipse an isolated foreground
        // product. A central portrait keeps its normal semantic priority.
        let peripheralPenalty = category.semantic && area < 0.035 ? (1 - centerPreference) * 0.12 : 0
        return max(0, min(1, score - peripheralPenalty + max(0,min(1,compositionPotential))*0.10))
    }
}

extension BaselineGuidance22 {
    static func settled(reading:CompositionReading,subject:String?,measurements:PhotoMeasurements?,plan:SceneCompositionPlan?,aspect:Double,scene:SubjectScene?,intent:PhotographyIntent,anatomy:SubjectAnatomy?,context:[CompositionContextSubject],evidence:SceneCompositionEvidence?) -> GuidanceMessage {
        var engine = Self()
        engine.subject = subject ?? "Subject"; engine.detectedSince = -1
        return engine.update(reading:reading,phase:.off,stable:true,rollReliable:false,autoEnabled:false,zoomAvailable:false,
            timestamp:0,previewAspect:aspect,scene:scene,subjectLabel:subject,subjectMeasurements:measurements,compositionPlan:plan,
            sceneEvidence:evidence,intent:intent,anatomy:anatomy,others:context)
    }
}
extension AssessmentMeasurements {
    static func fromBaseline(_ old:BaselineAssessment22) -> Self {
        var result = Self(CompositionAssessment(confidence:old.confidence))
        result.subjectArea = old.subjectArea; result.visibleFraction = old.visibleFraction; result.minimumMargin = old.minimumMargin
        result.headroom = old.headroom; result.edgeJointCount = old.edgeJointCount; result.backgroundEdges = old.backgroundEdges
        result.subjectBackgroundContrast = old.contrast; result.adjacentNamedRegions = old.backgroundDistractors
        result.visualMassOffset = old.balanceOffset; result.candidateBoundaryDegrees = old.horizonDegrees
        result.verticalLeanDegrees = old.verticalLeanDegrees; result.headYawRadians = old.headYaw
        result.sizePenalty = old.sizePenalty; result.positionPenalty = old.positionPenalty
        return result
    }
}
#endif

#if DEBUG || FOCAL_EVALUATION
extension SceneCompositionEvidence {
    /// Each sequence entry is a different analyzed photograph. Preserve its
    /// measured pixels/lines while expressing its annotation's observation time.
    init(evaluationSnapshot original:SceneCompositionEvidence,at time:TimeInterval) {
        image = original.image; timestamp = time; lines = original.lines
        symmetry = original.symmetry; repetition = original.repetition
    }
}
#endif
