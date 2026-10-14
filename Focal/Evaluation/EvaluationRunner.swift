#if DEBUG || FOCAL_EVALUATION
import Foundation

actor EvaluationRunner {
    static let shared = EvaluationRunner()
    func run(samples:[EvaluationSample],directory:URL) async throws -> EvaluationReport {
        var baseline = [EvaluationOutcome](), updated = [EvaluationOutcome](), errors = [String]()
        var memories = [String:RecommendationMemory]()
        var previousSelections = [String: (bounds:CGRect,time:Double,label:String)]()
        var baselineMemories = [String:BaselineReasoning30.Memory]()
        let ordered = samples.filter { $0.annotation.reviewed }.sorted {
            let a = $0.annotation.sequenceID ?? $0.id.uuidString, b = $1.annotation.sequenceID ?? $1.id.uuidString
            return a == b ? ($0.annotation.sequenceTime ?? 0) < ($1.annotation.sequenceTime ?? 0) : a < b
        }
        for sample in ordered {
            try Task.checkCancellation()
            do {
                let label = sample.annotation
                let analyzed = try await SceneAnalyzer.shared.analyze(directory.appendingPathComponent(sample.imageFile),intent:label.intent,
                    manualRegion:label.manualSelection?.cgRect,includeAesthetics:true)
                try Task.checkCancellation()
                let primary = analyzed.selected
                let prior = label.sequenceID.flatMap { previousSelections[$0] }
                let priorBounds = prior.flatMap { old -> CGRect? in
                    guard let time = label.sequenceTime, time > old.time, time-old.time <= 2, old.label == primary?.label else { return nil }
                    return old.bounds
                }
                let overlap: Double? = primary.flatMap { chosen in priorBounds.map { EvaluationRect($0).overlap(chosen.bounds) } }
                if let sequence = label.sequenceID, let primary, let time = label.sequenceTime { previousSelections[sequence] = (primary.bounds,time,primary.label) }
                let proposedScale = primary.flatMap { selected in analyzed.evidence.flatMap { evidence in
                    IntentCompositionSearch.zoomPlan(subject:selected.bounds,label:selected.label,intent:label.intent,evidence:evidence,
                        others:analyzed.contextSubjects.map { .init(bounds:$0.bounds,label:$0.label,confidence:$0.confidence) },
                        frames:analyzed.enclosingFrames,scales:[1,1.15,1.35,1.6,2,2.5,3],forceCenter:false)?.selected.zoomScale
                } }
                let context = analyzed.contextSubjects.map { CompositionContextSubject(bounds:$0.bounds,label:$0.label,confidence:$0.confidence) }
                let layouts = primary.flatMap { selected in analyzed.evidence.map { evidence in
                    SceneCompositionPlanner.compare(subject:selected.bounds,evidence:evidence,others:context,enclosingFrames:analyzed.enclosingFrames,maximumScale:label.intent.maximumCropScale,intent:label.intent,label:selected.label)
                } } ?? []
                let plan = layouts.first.map { SceneCompositionPlan(selected:$0,alternatives:Array(layouts.dropFirst().prefix(3)),subjectLabel:primary?.label ?? "Subject",timestamp:0) }
                let measured = CompositionAssessment.evaluate(bounds:primary?.bounds,confidence:primary?.confidence ?? 0,label:primary?.label ?? "Subject",
                    intent:label.intent,stable:true,exposure:analyzed.subjectMeasurements,evidence:analyzed.evidence,others:context,anatomy:analyzed.anatomy,petStyle:label.petStyle ?? .balanced)
                let reading = CompositionReading(state:.ready,subjectBounds:primary?.bounds,subjectConfidence:Float(primary?.confidence ?? 0),target:plan?.target ?? .init(x:0.5,y:0.5))
                let decisionStart = ProcessInfo.processInfo.systemUptime
                var decision = ActionFeasibility.recommend(assessment:measured,reading:reading,intent:label.intent,plan:plan,rollReliable:false,previewAspect:analyzed.aspect)
                var old = BaselineReasoning30.recommend(assessment:measured,reading:reading,intent:label.intent,plan:plan,rollReliable:false,previewAspect:analyzed.aspect)
                if primary == nil, let scene = ActionFeasibility.sceneRecommendation(landscape:analyzed.landscape,stable:true,roll:0,rollReliable:false,
                    measurements:analyzed.measurements,evidence:analyzed.evidence,timestamp:0,previewAspect:analyzed.aspect) { decision = scene; old = scene }
                if let sequence = label.sequenceID, !sequence.isEmpty, let time = label.sequenceTime {
                    var memory = memories[sequence] ?? RecommendationMemory()
                    decision = memory.update(decision,bounds:primary?.bounds,label:primary?.label ?? "Scene",intent:label.intent,timestamp:time,assessment:measured)
                    memories[sequence] = memory
                    var oldMemory = baselineMemories[sequence] ?? BaselineReasoning30.Memory()
                    old = oldMemory.update(old,bounds:primary?.bounds,label:primary?.label ?? "Scene",intent:label.intent,timestamp:time)
                    baselineMemories[sequence] = oldMemory
                }
                let pairedDecisionMS = (ProcessInfo.processInfo.systemUptime-decisionStart)*1000
                let petAllowsZoom = label.intent != .pet || (label.petStyle ?? .balanced).permitsAutomaticZoom
                let permittedScale = petAllowsZoom && measured.permitsAutomaticCrop ? proposedScale : nil
                baseline.append(.init(sampleID:sample.id,algorithm:"Intelligence 3.0 recommendation baseline",selected:primary,detections:analyzed.subjects,action:old.action,text:old.text,
                    inferenceMilliseconds:nil,aestheticScore:analyzed.aestheticScore,fitness:measured.fitness,assessment:AssessmentMeasurements(measured)))
                updated.append(.init(sampleID:sample.id,algorithm:"Focal Intelligence 4.0",selected:primary,detections:analyzed.subjects,action:decision.action,text:decision.text,
                    inferenceMilliseconds:analyzed.inferenceMilliseconds,aestheticScore:analyzed.aestheticScore,fitness:measured.fitness,assessment:AssessmentMeasurements(measured),proposedZoomScale:permittedScale,previousSelectionOverlap:overlap,pairedDecisionMilliseconds:pairedDecisionMS))
            } catch is CancellationError { throw CancellationError() }
            catch { errors.append("\(sample.id): \(error.localizedDescription)") }
        }
        let heldOut = samples.filter { $0.annotation.datasetSplit == "held-out" }
        return .init(baseline:baseline,updated:updated,baselineMetrics:.calculate(samples:samples,outcomes:baseline),updatedMetrics:.calculate(samples:samples,outcomes:updated),errors:errors,
            heldOutBaselineMetrics:heldOut.isEmpty ? nil : .calculate(samples:heldOut,outcomes:baseline),
            heldOutUpdatedMetrics:heldOut.isEmpty ? nil : .calculate(samples:heldOut,outcomes:updated))
    }
}
#endif
