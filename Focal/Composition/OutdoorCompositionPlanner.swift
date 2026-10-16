import Foundation

/// Whole-scene alternatives from measured pixels/edges. These are photographic
/// opportunities, never detections of a mushroom, fog, water or a forest trail.
struct OutdoorCompositionPlanner {
    private(set) var plan:SceneCompositionPlan?
    private var challenger:CompositionTechnique?
    private var challengerSince:TimeInterval = 0
    private var lockedUntil:TimeInterval = 0
    private var alternativeRequested = false
    private var evidenceTime:TimeInterval = -.infinity
    private var lastUpdateTime:TimeInterval?
    private var cachedOptions:[CompositionOption] = []
    mutating func requestAlternative() { alternativeRequested = true }
    mutating func reset() { self = Self() }
    mutating func update(evidence:SceneCompositionEvidence?,at time:TimeInterval) -> SceneCompositionPlan? {
        guard time.isFinite else { challenger = nil; lastUpdateTime = nil; return nil }
        // A recommendation needs renewed support after an observation gap;
        // polling old pixels must not count an unseen interval toward its dwell.
        if let lastUpdateTime, time < lastUpdateTime || time-lastUpdateTime > 1.25 { challenger = nil }
        lastUpdateTime = time
        guard let evidence,evidence.isFresh(at:time) else { challenger = nil; return nil }
        if evidenceTime != evidence.timestamp {
            if evidence.timestamp < evidenceTime || evidence.timestamp-evidenceTime > 1.25 { challenger = nil }
            cachedOptions = Self.candidates(evidence); evidenceTime = evidence.timestamp
        }
        let options = cachedOptions
        guard let best = options.first else { plan = nil; challenger = nil; return nil }
        var chosen = best
        if let previous = plan, let retained = options.first(where:{$0.technique == previous.selected.technique}) {
            if alternativeRequested {
                let index = options.firstIndex(where:{$0.technique == previous.selected.technique}) ?? 0
                chosen = options[(index+1)%options.count]; lockedUntil = time+4; challenger = nil
            } else if time < lockedUntil || best.score < retained.score+0.06 {
                chosen = retained; challenger = nil
            } else if best.technique != retained.technique {
                if challenger != best.technique { challenger = best.technique; challengerSince = time }
                chosen = time-challengerSince >= 1.4 ? best : retained
            }
        }
        if let previous = plan, chosen.technique == previous.selected.technique,
           [.contrast,.thirds].contains(chosen.technique),
           let anchor = chosen.sceneAnchor, let oldAnchor = previous.selected.sceneAnchor,
           anchor.distance(to:oldAnchor) < 0.25 {
            chosen.target = previous.target // Do not flip thirds after a tiny pan.
        }
        alternativeRequested = false
        var result = SceneCompositionPlan(selected:chosen,alternatives:Array(options.filter{$0.technique != chosen.technique}.prefix(4)),subjectLabel:"Scene",timestamp:time)
        if plan?.selected.technique == chosen.technique { result.id = plan!.id }
        plan = result; return result
    }
    static func aligned(_ plan:SceneCompositionPlan) -> Bool {
        guard let anchor = plan.selected.sceneAnchor else { return false }
        return anchor.distance(to:plan.target) <= 0.10
    }
    static func permitsReady(plan:SceneCompositionPlan?,evidence:SceneCompositionEvidence?,at time:TimeInterval,motionPermitted:Bool) -> Bool {
        guard let plan,let evidence,evidence.isFresh(at:time),time >= plan.timestamp,time-plan.timestamp <= 1.25,
              motionPermitted,aligned(plan) else { return false }
        let region = evidence.region(SceneCompositionEvidence.full)
        return region.variance > 0.008 && region.clipping < 0.20
    }
    static func instruction(_ plan:SceneCompositionPlan,mirrored:Bool = false) -> (String,GuidanceAction?) {
        guard let anchor = plan.selected.sceneAnchor else { return (plan.selected.explanation,nil) }
        let dx = (anchor.x-plan.target.x)*(mirrored ? -1 : 1),dy = anchor.y-plan.target.y
        if !aligned(plan) {
            if abs(dx) > abs(dy) { return (dx > 0 ? "Aim slightly right" : "Aim slightly left",dx > 0 ? .panRight : .panLeft) }
            return (dy > 0 ? "Tilt slightly down" : "Tilt slightly up",dy > 0 ? .panDown : .panUp)
        }
        return (plan.selected.explanation,nil)
    }
    static func candidates(_ evidence:SceneCompositionEvidence) -> [CompositionOption] {
        let full = SceneCompositionEvidence.full, facts = evidence.region(full)
        guard facts.variance > 0.008,facts.clipping < 0.35 else { return [] }
        var choices = [CompositionOption]()
        func add(_ type:CompositionTechnique,_ score:Double,_ anchor:UnitPoint2D,_ target:UnitPoint2D,_ text:String) {
            guard [anchor.x,anchor.y,target.x,target.y].allSatisfy(\.isFinite) else { return }
            var option = CompositionOption(technique:type,target:target,crop:full,score:score-facts.clipping*0.1,
                explanation:text,zoomScale:1,isCurrentFrame:true)
            option.sceneAnchor = anchor
            choices.append(option)
        }
        let center = UnitPoint2D(x:0.5,y:0.5)
        add(.centered,0.42,center,center,"Keep the wide scene; look for a clear visual center")
        if evidence.symmetry > 0.7 { add(.symmetry,0.55+evidence.symmetry*0.15,center,center,"Keep the mirrored structure balanced") }
        if evidence.repetition > 0.55 { add(.repetition,0.54+evidence.repetition*0.13,center,center,"Keep the repeated shapes together") }
        let strong = evidence.lines.filter{$0.length > 0.45 && $0.support >= 0.75}
        if let line = strong.filter(\.diagonal).max(by:{$0.length < $1.length}) {
            add(.diagonals,0.56+line.support*0.08,center,center,"Keep the long diagonal structure inside the frame")
        }
        var crossing:UnitPoint2D?
        let converging = strong.filter(\.diagonal)
        for i in converging.indices {
            for j in converging.indices where j > i {
                let a = converging[i],b = converging[j]
                let ax = a.end.x-a.start.x,ay = a.end.y-a.start.y,bx = b.end.x-b.start.x,by = b.end.y-b.start.y
                let denominator = ax*by-ay*bx
                guard abs(denominator) > 0.12 else { continue }
                let t = ((b.start.x-a.start.x)*by-(b.start.y-a.start.y)*bx)/denominator
                let point = UnitPoint2D(x:a.start.x+t*ax,y:a.start.y+t*ay)
                // A crossing in a grid is not evidence of convergence. Both
                // diagonal segments must actually approach this point.
                guard min(a.start.distance(to:point),a.end.distance(to:point)) < 0.18,
                      min(b.start.distance(to:point),b.end.distance(to:point)) < 0.18 else { continue }
                if (0.12...0.88).contains(point.x),(0.12...0.88).contains(point.y) { crossing = point; break }
            }
            if crossing != nil { break }
        }
        if let crossing { add(.leadingLines,0.75,crossing,center,"Keep the visible converging lines together") }
        // Warm/cool separation is color evidence, not semantic foliage recognition.
        var warm = 0.0, wx = 0.0, wy = 0.0
        for y in 0..<evidence.image.height {
            for x in 0..<evidence.image.width {
                let pixel = evidence.image.pixels[y*evidence.image.width+x]
                let weight = max(0,pixel.red-pixel.blue-0.12)*max(0,pixel.red-pixel.green*0.65)
                warm += weight; wx += weight*(Double(x)+0.5)/Double(evidence.image.width); wy += weight*(Double(y)+0.5)/Double(evidence.image.height)
            }
        }
        let density = warm/Double(evidence.image.pixels.count)
        if density > 0.012,density < 0.30 {
            let point = UnitPoint2D(x:wx/warm,y:wy/warm)
            let third = UnitPoint2D(x:point.x < 0.5 ? 1.0/3 : 2.0/3,y:point.y < 0.5 ? 1.0/3 : 2.0/3)
            add(.contrast,0.66,point,third,"Place the warm color area near the marked third")
            add(.thirds,0.57,point,third,"Balance the color area against its surroundings")
        }
        let lower = evidence.region(CGRect(x:0,y:0.67,width:1,height:0.33))
        let upper = evidence.region(CGRect(x:0,y:0,width:1,height:0.33))
        if lower.edgeDensity > 0.08,upper.variance > 0.008,abs(lower.edgeDensity-upper.edgeDensity) > 0.05 {
            add(.layers,0.60,center,center,"Balance the lower texture with the upper scene")
        }
        if let boundary = evidence.horizontalBoundary() {
            let anchor = UnitPoint2D(x:0.5,y:(boundary.start.y+boundary.end.y)/2)
            add(.horizon,0.58,anchor,.init(x:0.5,y:anchor.y < 0.5 ? 1.0/3 : 2.0/3),"Place the long scene boundary near a third, if it is your horizon")
        }
        return Array(choices.sorted{$0.score > $1.score}.prefix(8))
    }
}
