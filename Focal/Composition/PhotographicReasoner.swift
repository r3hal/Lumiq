import Foundation

/// Support is a conservative engineering score, not a calibrated probability.
struct RecommendationSupport: Codable, Sendable {
    var detection: Double
    var measurement: Double
    var feasibility: Double
    var risk: Double
    var value: Double {
        guard [detection,measurement,feasibility,risk].allSatisfy(\.isFinite) else { return 0 }
        return max(0,min(1,min(detection,min(measurement,feasibility))))*(1-max(0,min(1,risk)))
    }
}
struct PhotographicCandidate {
    var guidance: FeasibleGuidance
    var priority: Int // Visibility > severe light/alignment > small composition refinements.
    var expectedGain: Double
    var support: RecommendationSupport
    var evidence: String
    var rejection: String?
    var usable: Bool { rejection == nil && support.value >= 0.55 && expectedGain >= 0.08 }
}
struct PhotographicDecision {
    var selected: FeasibleGuidance
    var candidates: [PhotographicCandidate]
    var reason: String
}

enum PhotographicReasoner {
    static func evaluate(assessment a:CompositionAssessment,reading:CompositionReading,intent:PhotographyIntent,
                         plan:SceneCompositionPlan?,rollReliable:Bool,previewAspect:Double,
                         manualComposition:Bool = false,autoPreparing:Bool = false) -> PhotographicDecision {
        func single(_ action:GuidanceAction,_ text:String,_ reason:String) -> PhotographicDecision {
            .init(selected:.init(action:action,text:text,confidence:a.confidence,issue:0),candidates:[],reason:reason)
        }
        guard a.confidence.isFinite, a.confidence >= 0.55, a.subjectArea != nil, a.assessmentReliable else {
            return single(.none,"","insufficient observed subject or required head evidence")
        }
        if a.cameraMoving { return single(.hold,"Hold steady while the frame settles","motion invalidates directional predictions") }
        var candidates = [PhotographicCandidate]()
        func add(_ action:GuidanceAction,_ text:String,_ priority:Int,_ gain:Double,_ evidence:String,
                 measurement:Double = 0.9,feasibility:Double = 0.9,risk:Double = 0,rejection:String? = nil) {
            let support = RecommendationSupport(detection:a.confidence,measurement:measurement,feasibility:feasibility,risk:risk)
            candidates.append(.init(guidance:.init(action:action,text:text,confidence:support.value,issue:gain),priority:priority,
                expectedGain:gain,support:support,evidence:evidence,rejection:rejection))
        }
        if a.touchesEdge {
            add(.makeRoom,"Leave a little room around the visible subject edges",100,max(0.3,1-(a.visibleFraction ?? 1)),"observed clipping, boundary or head margin")
        }
        if let exposure = a.exposure, exposure.highlightFraction.isFinite, exposure.highlightFraction > 0.18 {
            add(.reduceExposure,"Lower exposure to protect bright subject detail",80,exposure.highlightFraction,"measured subject highlight fraction",feasibility:0.95)
        }
        if rollReliable, reading.rollDegrees.isFinite, abs(reading.rollDegrees) > 5 {
            add(.level,"Level the camera",70,min(1,abs(reading.rollDegrees)/20),"fresh gravity-derived camera roll")
        }
        if let exposure = a.exposure, exposure.brightness < 0.12, exposure.shadowFraction > 0.75 {
            add(.addLight,"More light may help if you can adjust it",60,exposure.shadowFraction,"measured dark subject; lighting control unknown",feasibility:0.65)
        }
        let gain = plan?.selected.measuredImprovement ?? 0
        if manualComposition || gain >= IntentCompositionSearch.minimumImprovement {
            if let cue = CompositionCue(reading:reading,previewAspect:previewAspect), !cue.aligned,
               manualComposition || a.positionPenalty > 0.05 || autoPreparing {
                let action: GuidanceAction = cue.direction == "left" ? .panLeft : cue.direction == "right" ? .panRight : cue.direction == "up" ? .panUp : .panDown
                let distance = hypot(cue.subject.x-cue.target.x,(cue.subject.y-cue.target.y)/max(0.1,previewAspect))
                add(action,cue.phoneInstruction,40,max(0.08,distance),manualComposition ? "explicit user placement target" : "measured candidate placement",
                    rejection:a.touchesEdge ? "subject visibility takes priority" : nil)
            }
            if a.sizePenalty > 0.15, let plan, plan.permitsZoom {
                add(.tighterCrop,"Try the evaluated tighter frame",30,gain,"measured scale gain with visible subject/context retained",
                    rejection:a.touchesEdge || (a.exposure?.highlightFraction ?? 0) > 0.18 ? "resolve clipping or severe exposure first" : nil)
            }
        }
        let best = candidates.filter(\.usable).sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.expectedGain*$0.support.value > $1.expectedGain*$1.support.value
        }.first
        if var best {
            if best.guidance.action == .tighterCrop { best.guidance.issue = a.sizePenalty }
            return .init(selected:best.guidance,candidates:candidates,reason:best.evidence)
        }
        return .init(selected:.init(action:.none,text:"Ready to shoot",confidence:a.confidence,issue:0),candidates:candidates,
                     reason:"no supported significant improvement; preserve current framing")
    }
}
