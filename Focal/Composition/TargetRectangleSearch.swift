import Foundation

/// Independent, bounded photographic heuristics over observed pixels. Not a
/// learned aesthetic model and not a promise of a globally best photograph.
enum TargetRectangleSearch {
    static let minimumGain = 0.12 // Avoid unnecessary crops of an already strong portrait.
    static func options(subject:CGRect,label:String,intent:PhotographyIntent,evidence:SceneCompositionEvidence,
                        others:[CompositionContextSubject],scales:[Double],anatomy:SubjectAnatomy? = nil) -> [CompositionOption] {
        guard AutomaticShotPlan.valid(subject), TargetRectangleGeometry.contains(SceneCompositionEvidence.full,subject),
              intent.permitsZoom, SubjectCategory.classified(label) != .background else { return [] }
        let category = SubjectCategory.classified(label)
        let companions = SceneCompositionPlanner.distinctSubjects(others,selected:subject).filter {
            let otherCategory = SubjectCategory.classified($0.label)
            return (category == .pet || category == .person || category == .face)
                && (otherCategory == .pet || otherCategory == .person || otherCategory == .face)
                && $0.confidence >= 0.8 && $0.bounds.width*$0.bounds.height >= subject.width*subject.height*0.15
                && hypot($0.bounds.midX-subject.midX,$0.bounds.midY-subject.midY) < 0.45
        }
        // Preserve a meaningful group with the existing environmental planner.
        guard companions.isEmpty else { return [] }
        let goal = TargetRectangleGeometry.desiredArea(label:label,intent:intent)
        let baseline = score(subject:subject,crop:SceneCompositionEvidence.full,goal:goal,evidence:evidence,scale:1)
        let freshFace = anatomy.flatMap { evidence.timestamp >= $0.timestamp-0.5 && abs(evidence.timestamp-$0.timestamp) <= 1.5 ? $0.face : nil }
        let kind:ShotCompositionKind = category == .face && freshFace != nil ? .observedFacePortrait
            : category == .pet || category == .person || category == .face ? .subjectPortrait : .objectPortrait
        var result = [CompositionOption]()
        let positions = [UnitPoint2D(x:0.5,y:0.5),.init(x:subject.midX < 0.5 ? 1.0/3 : 2.0/3,y:0.5)]
        for scale in scales where scale.isFinite && scale > 1.12 && scale <= intent.maximumCropScale {
            for position in positions {
                guard let proposed = TargetRectangleGeometry.crop(subject:subject,position:position,scale:scale) else { continue }
                // Stay inside actually observed pixels. Near an edge, retain a
                // measured off-center portrait rather than inventing outside scenery.
                let crop = CGRect(x:max(0,min(1-proposed.width,proposed.minX)),y:max(0,min(1-proposed.height,proposed.minY)),
                    width:proposed.width,height:proposed.height)
                guard TargetRectangleGeometry.contains(SceneCompositionEvidence.full,crop),
                      TargetRectangleGeometry.contains(crop.insetBy(dx:TargetRectangleGeometry.margin/scale,dy:TargetRectangleGeometry.margin/scale),subject) else { continue }
                let finalBounds = TargetRectangleGeometry.relative(subject,in:crop)
                let measuredPosition = UnitPoint2D(x:finalBounds.midX,y:finalBounds.midY)
                guard AutomaticShotPlan.safe(finalBounds) else { continue }
                let anatomyRegions = (anatomy?.face.map { [$0] } ?? []) + (anatomy?.joints ?? []).map { CGRect(x:$0.x-0.004,y:$0.y-0.004,width:0.008,height:0.008) }
                guard anatomyRegions.allSatisfy({ TargetRectangleGeometry.contains(crop,$0) }) else { continue }
                let light = evidence.region(crop).clipping
                guard light <= 0.2 || light-evidence.region(SceneCompositionEvidence.full).clipping <= 0.08 else { continue }
                let measured = score(subject:subject,crop:crop,goal:goal,evidence:evidence,scale:scale)
                let gain = measured-baseline
                guard gain >= minimumGain else { continue }
                let reason = "Increase subject prominence from \(Int(subject.width*subject.height*100))% to \(Int(finalBounds.width*finalBounds.height*100))%; preserve visible boundaries"
                var option = CompositionOption(technique:position.x == 0.5 ? .fillFrame : .thirds,target:measuredPosition,crop:crop,
                    score:measured,explanation:reason,zoomScale:scale,measuredImprovement:gain)
                option.kind = kind; option.protectedContext = []
                result.append(option)
            }
        }
        return result.sorted {
            if abs($0.score-$1.score) > 0.001 { return $0.score > $1.score }
            return $0.zoomScale < $1.zoomScale
        }
    }
    static func plan(subject:CGRect,label:String,intent:PhotographyIntent,evidence:SceneCompositionEvidence,
                     others:[CompositionContextSubject],scales:[Double],forceCenter:Bool,anatomy:SubjectAnatomy?) -> SceneCompositionPlan? {
        let candidates = options(subject:subject,label:label,intent:intent,evidence:evidence,others:others,scales:scales,anatomy:anatomy)
            .filter { !forceCenter || (abs($0.target.x-0.5) < 0.001 && abs($0.target.y-0.5) < 0.001) }
        guard let selected = candidates.first else { return nil }
        return .init(selected:selected,alternatives:Array(candidates.dropFirst().prefix(3)),subjectLabel:label,timestamp:evidence.timestamp)
    }
    private static func score(subject:CGRect,crop:CGRect,goal:Double,evidence:SceneCompositionEvidence,scale:Double) -> Double {
        let relative = TargetRectangleGeometry.relative(subject,in:crop)
        let area = Double(relative.width*relative.height)
        let prominence = max(0,1-abs(log(max(0.0001,area)/goal))/log(4))
        let margin = Double(min(relative.minX,relative.minY,1-relative.maxX,1-relative.maxY))
        let complete = min(1,max(0,margin/0.06))
        let balance = max(0,1-hypot(Double(relative.midX)-0.5,Double(relative.midY)-0.5))
        let background = evidence.region(crop,excluding:subject)
        let isolation = max(0,1-background.edgeDensity*2)
        let light = max(0,1-evidence.region(crop).clipping)
        return prominence*0.48+complete*0.22+balance*0.10+isolation*0.10+light*0.10-(scale-1)*0.025
    }
}
