import Foundation

struct CompositionContextSubject {
    var bounds: CGRect // Visible preview, origin at top left.
    var label: String
    var confidence: Double
}

struct CompositionOption {
    var technique: CompositionTechnique
    var target: UnitPoint2D
    var crop: CGRect // An evaluated region INSIDE the observed preview.
    var score: Double // Relative heuristic ranking, not an aesthetic probability.
    var explanation: String
    var zoomScale: Double
    var measuredImprovement: Double = 0
    var isCurrentFrame = false
    var kind: ShotCompositionKind? = nil
    var protectedContext: [CGRect]? = nil
    var sceneAnchor:UnitPoint2D? = nil
}

struct SceneCompositionPlan {
    var selected: CompositionOption
    var alternatives: [CompositionOption]
    var subjectLabel: String
    var timestamp: TimeInterval
    var id: String = UUID().uuidString
    var target: UnitPoint2D { selected.target }
    var permitsZoom: Bool { !selected.isCurrentFrame && selected.measuredImprovement >= IntentCompositionSearch.minimumImprovement && selected.zoomScale > 1.12 && [CompositionTechnique.centered,.fillFrame,.simplicity,.contrast,.thirds,.goldenRatio].contains(selected.technique) }
    var zoomAlignmentTarget: UnitPoint2D {
        guard permitsZoom, selected.zoomScale.isFinite else { return target }
        // Sensor zoom expands from the center. Pan to this pre-zoom point so
        // the real subject lands on the selected mark after the lens ramp.
        return UnitPoint2D(x: 0.5+(target.x-0.5)/selected.zoomScale, y: 0.5+(target.y-0.5)/selected.zoomScale)
    }
    var summary: String { "\(selected.technique.rawValue) · \(selected.explanation)" }
    func movementInstruction(reading: CompositionReading, previewAspect: Double) -> String? {
        guard let cue = CompositionCue(reading:reading,previewAspect:previewAspect) else { return nil }
        return "\(cue.phoneInstruction) · \(selected.technique.rawValue.lowercased())"
    }
}

/// Compare candidate crops/layouts, retain subject/context, then debounce the
/// recommendation. This is a transparent local planner, not a trained aesthetic
/// model and not a claim to see the greatest photograph outside the live view.
struct SceneCompositionPlanner {
    private(set) var plan: SceneCompositionPlan?
    private var outdoor = OutdoorCompositionPlanner()
    private var alternativeRequested = false
    private var forcedTechnique:CompositionTechnique?
    private var forcedUntil:TimeInterval = 0
    mutating func requestAlternative() { alternativeRequested = true; outdoor.requestAlternative() }
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
                         timestamp: TimeInterval, maximumScale: Double = 1, freeze: Bool = false, intent: PhotographyIntent = .auto, availableScales: [Double]? = nil, anatomy:SubjectAnatomy? = nil) -> SceneCompositionPlan? {
        guard timestamp.isFinite else { reset(); return nil }
        if subject == nil || intent == .landscape {
            let result = outdoor.update(evidence:evidence,at:timestamp)
            alternativeRequested = false
            plan = result; return result
        }
        guard let subject, Self.valid(subject), confidence >= 0.55 else {
            // Return no plan/box during loss; preserve the choice only for a
            // short tracker recovery, never across a different subject.
            if lastSeen.map({ timestamp < $0 || timestamp-$0 > 0.6 }) ?? true { reset() }
            return nil
        }
        if plan?.subjectLabel != label || previousBounds.map({ hypot(Double($0.midX-subject.midX),Double($0.midY-subject.midY)) > 0.3 }) == true { reset() }
        previousBounds = subject; lastSeen = timestamp
        if freeze, let retained = plan, !retained.selected.isCurrentFrame { return retained }
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
            options = Self.compare(subject:subject,evidence:evidence,others:others,enclosingFrames:enclosingFrames,maximumScale:min(maximumScale,intent.maximumCropScale),intent:intent,availableScales:availableScales,label:label,anatomy:anatomy)
            evaluatedEvidenceTime = evidence.timestamp; evaluatedIntent = intent; evaluatedScales = availableScales
            evaluatedMaximumScale = maximumScale
            evaluatedBounds = subject; evaluatedContext = context; cachedOptions = options
        }
        guard let best = options.first else { reset(); return nil }
        let chosen: CompositionOption
        if alternativeRequested, let old = plan, let index = options.firstIndex(where:{$0.technique == old.selected.technique}), options.count > 1 {
            // Ranked object crops can contain several versions of one rule.
            // Prefer a genuinely different supported layout on explicit request.
            chosen = options.dropFirst(index+1).first{$0.technique != old.selected.technique}
                ?? options.first{$0.technique != old.selected.technique} ?? best
            forcedTechnique = chosen.technique; forcedUntil = timestamp+4
            alternativeRequested = false; pending = nil
        } else if timestamp < forcedUntil, let forcedTechnique, let forced = options.first(where:{$0.technique == forcedTechnique}) { chosen = forced }
        else if best.isCurrentFrame { chosen = best; pending = nil }
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
                        enclosingFrames: [CGRect] = [], maximumScale: Double = 1, intent: PhotographyIntent = .auto, availableScales: [Double]? = nil, label: String = "Subject", anatomy:SubjectAnatomy? = nil) -> [CompositionOption] {
        guard intent != .landscape else { return [] }
        guard valid(subject), maximumScale.isFinite, maximumScale >= 1 else { return [] }
        let center = UnitPoint2D(x:subject.midX,y:subject.midY)
        let background = evidence.region(SceneCompositionEvidence.full,excluding:subject)
        let separation = evidence.separation(subject:subject)
        let context = distinctSubjects(others,selected:subject)
        let group = context + [CompositionContextSubject(bounds:subject,label:"Selected",confidence:1)]
        let hasGroup = context.count > 0
        let enclosing = protectedFrames(enclosingFrames,subject:subject)
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
            if hasTriangularArrangement(group.map(\.bounds)) {
                add(.triangles,center,0.89,"preserve the three-point arrangement")
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
                guard TargetRectangleGeometry.contains(crop.insetBy(dx:0.025/scale,dy:0.025/scale),subject),
                      context.allSatisfy({ TargetRectangleGeometry.contains(crop,$0.bounds) }), enclosing.allSatisfy({ TargetRectangleGeometry.contains(crop,$0) }) else { continue }
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
        let measured = IntentCompositionSearch.candidates(subject:subject,label:label,intent:intent,evidence:evidence,
            others:others,frames:enclosing,scales:scales)
        let baseline = CompositionAssessment.evaluate(bounds:subject,confidence:1,label:label,intent:intent,stable:true,exposure:nil,evidence:evidence,others:others,timestamp:evidence.timestamp)
        guard let currentFitness = baseline.fitness else { return [] }
        for index in ranked.indices {
            let option = ranked[index]
            let cropGain = measured.first(where: { $0.crop == option.crop && $0.mapsToCameraZoom })?.improvement ?? 0
            // A target shift is justified only by an observed position issue.
            // Existing comfortable off-center placement incurs no penalty.
            let shifted = subject.offsetBy(dx:option.target.x-Double(subject.midX),dy:option.target.y-Double(subject.midY))
            let shiftedFacts = CompositionAssessment.evaluate(bounds:shifted,confidence:1,label:label,intent:intent,stable:true,exposure:nil,evidence:nil,others:others)
            let targetGain = baseline.positionPenalty > 0 && SceneCompositionEvidence.full.contains(shifted)
                ? max(0,(shiftedFacts.fitness ?? currentFitness)-currentFitness) : 0
            ranked[index].measuredImprovement = max(cropGain,targetGain)
            if cropGain >= IntentCompositionSearch.minimumImprovement && baseline.positionPenalty == 0 {
                let relative = FramingPlanner.zoomedRect(subject,scale:option.zoomScale)
                ranked[index].target = UnitPoint2D(x:relative.midX,y:relative.midY)
                ranked[index].technique = .fillFrame
                ranked[index].explanation = "improve subject scale while retaining the observed placement"
            }
            if ranked[index].measuredImprovement < IntentCompositionSearch.minimumImprovement { ranked[index].zoomScale = 1 }
        }
        if let smallest = measured.first(where: { $0.mapsToCameraZoom && $0.improvement >= IntentCompositionSearch.minimumImprovement && $0.scale > 1.12 }) {
            let relative = FramingPlanner.zoomedRect(subject,scale:smallest.scale)
            ranked.append(.init(technique:.fillFrame,target:.init(x:relative.midX,y:relative.midY),crop:smallest.crop,score:smallest.fitness,
                explanation:"smallest measured useful crop",zoomScale:smallest.scale,measuredImprovement:smallest.improvement))
        }
        let keep = CompositionOption(technique:.centered,target:center,crop:SceneCompositionEvidence.full,score:currentFitness,
                                     explanation:"keep the current composition",zoomScale:1,measuredImprovement:0,isCurrentFrame:true)
        let improvements = ranked.filter { $0.measuredImprovement >= IntentCompositionSearch.minimumImprovement }
            .sorted {
                if abs($0.zoomScale-$1.zoomScale) > 0.001 { return $0.zoomScale < $1.zoomScale }
                return $0.measuredImprovement == $1.measuredImprovement ? $0.score > $1.score : $0.measuredImprovement > $1.measuredImprovement
            }
        let directed = TargetRectangleSearch.options(subject:subject,label:label,intent:intent,evidence:evidence,others:others,
            scales:scales.filter { $0 <= maximumScale },anatomy:anatomy,enclosingFrames:enclosing)
        // Compare whole planned photographs, rather than declaring every subject
        // above a tiny visibility threshold to have optimal scale.
        let useful = (directed+improvements).sorted {
            if abs($0.measuredImprovement-$1.measuredImprovement) > 0.001 { return $0.measuredImprovement > $1.measuredImprovement }
            return $0.score > $1.score
        }
        return useful.isEmpty ? [keep]+ranked.sorted { $0.score > $1.score }
            : useful+[keep]+ranked.filter { $0.measuredImprovement < IntentCompositionSearch.minimumImprovement }.sorted { $0.score > $1.score }
    }
    // Shared by environmental and target-rectangle planning so a tighter
    // portrait cannot silently override observed compositional structure.
    static func protectedFrames(_ frames: [CGRect], subject: CGRect) -> [CGRect] {
        frames.filter { valid($0) && TargetRectangleGeometry.contains($0,subject)
            && $0.width*$0.height > subject.width*subject.height*1.7 }
    }
    static func hasTriangularArrangement(_ bounds: [CGRect]) -> Bool {
        guard bounds.count == 3 else { return false }
        let a = bounds[0], b = bounds[1], c = bounds[2]
        let area = abs((b.midX-a.midX)*(c.midY-a.midY)-(c.midX-a.midX)*(b.midY-a.midY))/2
        return area > 0.025
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
            && rect.width > 0.025 && rect.height > 0.025 && TargetRectangleGeometry.contains(SceneCompositionEvidence.full,rect)
    }
}
