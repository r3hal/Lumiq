import Foundation

struct MeasuredCropCandidate {
    let crop: CGRect
    let fitness: Double
    let improvement: Double
    let scale: Double
    let mapsToCameraZoom: Bool
}

enum IntentCompositionSearch {
    static let minimumImprovement = 0.08
    static func zoomPlan(subject: CGRect, label: String, intent: PhotographyIntent, evidence: SceneCompositionEvidence,
                         others: [CompositionContextSubject], frames: [CGRect], scales: [Double], forceCenter: Bool) -> SceneCompositionPlan? {
        let enclosing = frames.filter { $0.contains(subject) && $0.width*$0.height > subject.width*subject.height*1.7 }
        guard let best = candidates(subject:subject,label:label,intent:intent,evidence:evidence,others:others,frames:enclosing,scales:scales)
            .filter({ $0.mapsToCameraZoom && $0.improvement >= minimumImprovement && $0.scale > 1.12 })
            .min(by:{ $0.scale < $1.scale }) else { return nil }
        let relative = FramingPlanner.zoomedRect(subject,scale:best.scale)
        let target = forceCenter ? UnitPoint2D(x:0.5,y:0.5) : .init(x:relative.midX,y:relative.midY)
        let option = CompositionOption(technique:.fillFrame,target:target,crop:best.crop,score:best.fitness,
            explanation:"tighten only the observed frame",zoomScale:best.scale,measuredImprovement:best.improvement)
        return .init(selected:option,alternatives:[],subjectLabel:label,timestamp:evidence.timestamp)
    }
    static func candidates(subject: CGRect, label: String, intent: PhotographyIntent, evidence: SceneCompositionEvidence,
                           others: [CompositionContextSubject], frames: [CGRect], scales: [Double]) -> [MeasuredCropCandidate] {
        let original = CompositionAssessment.evaluate(bounds:subject,confidence:1,label:label,intent:intent,stable:true,
            exposure:nil,evidence:evidence,others:others,timestamp:evidence.timestamp)
        guard let originalFitness = original.fitness else { return [] }
        let context = SceneCompositionPlanner.distinctSubjects(others,selected:subject)
        let originalLight = evidence.region(SceneCompositionEvidence.full).clipping
        var result = [MeasuredCropCandidate(crop:SceneCompositionEvidence.full,fitness:originalFitness,improvement:0,scale:1,mapsToCameraZoom:true)]
        for scale in scales where scale.isFinite && scale > 1 && scale <= intent.maximumCropScale {
            let size = 1/scale
            let centers = [CGPoint(x:0.5,y:0.5),CGPoint(x:subject.midX,y:subject.midY)]
            for center in centers {
                let x = max(0,min(1-size,Double(center.x)-size/2)), y = max(0,min(1-size,Double(center.y)-size/2))
                let crop = CGRect(x:x,y:y,width:size,height:size)
                guard TargetRectangleGeometry.contains(crop.insetBy(dx:0.018/scale,dy:0.018/scale),subject),
                      context.allSatisfy({ TargetRectangleGeometry.contains(crop,$0.bounds) }),frames.allSatisfy({ TargetRectangleGeometry.contains(crop,$0) }) else { continue }
                let relative = CGRect(x:(subject.minX-crop.minX)/crop.width,y:(subject.minY-crop.minY)/crop.height,width:subject.width/crop.width,height:subject.height/crop.height)
                let relativeOthers = context.map { item in CompositionContextSubject(bounds:CGRect(x:(item.bounds.minX-crop.minX)/crop.width,y:(item.bounds.minY-crop.minY)/crop.height,width:item.bounds.width/crop.width,height:item.bounds.height/crop.height),label:item.label,confidence:item.confidence) }
                let cropLight = evidence.region(crop).clipping
                guard cropLight <= 0.2 || cropLight-originalLight <= 0.08 else { continue }
                let measured = CompositionAssessment.evaluate(bounds:relative,confidence:1,label:label,intent:intent,stable:true,exposure:nil,evidence:nil,others:relativeOthers)
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
        return result.sorted {
            let aUseful = $0.improvement >= minimumImprovement, bUseful = $1.improvement >= minimumImprovement
            if aUseful != bUseful { return aUseful }
            if aUseful, abs($0.scale-$1.scale) > 0.001 { return $0.scale < $1.scale }
            return $0.improvement > $1.improvement
        }
    }
}
