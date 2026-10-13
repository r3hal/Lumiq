#if DEBUG || FOCAL_EVALUATION
import Foundation

actor EvaluationRunner {
    static let shared = EvaluationRunner()
    func run(samples:[EvaluationSample],directory:URL) async throws -> EvaluationReport {
        var baseline = [EvaluationOutcome](), updated = [EvaluationOutcome](), errors = [String]()
        var memories = [String:RecommendationMemory]()
        var baselineMemories = [String:BaselineGuidance21]()
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
                let configuration = SubjectSelectionConfiguration(intent:label.intent)
                let legacyCandidate = analyzed.nativeCandidates.filter { ($0.baselineScore21(configuration:configuration) ?? 0) >= configuration.threshold }
                    .max { ($0.baselineScore21(configuration:configuration) ?? 0) < ($1.baselineScore21(configuration:configuration) ?? 0) }
                let legacyPrimary: AnalyzedSubject?
                if label.manualSelection != nil { legacyPrimary = primary }
                else if let legacyCandidate {
                    legacyPrimary = analyzed.subjects.first { $0.label == legacyCandidate.label && $0.bounds == CGRect(x:legacyCandidate.bounds.minX,y:1-legacyCandidate.bounds.maxY,width:legacyCandidate.bounds.width,height:legacyCandidate.bounds.height) }
                } else { legacyPrimary = nil }
                let legacyContext = analyzed.nativeCandidates.filter { $0.baselineScore21(configuration:configuration) != nil }.map { candidate in
                    CompositionContextSubject(bounds:CGRect(x:candidate.bounds.minX,y:1-candidate.bounds.maxY,width:candidate.bounds.width,height:candidate.bounds.height),label:candidate.label,confidence:candidate.confidence)
                }
                let context = analyzed.contextSubjects.map { CompositionContextSubject(bounds:$0.bounds,label:$0.label,confidence:$0.confidence) }
                let layouts = primary.flatMap { selected in analyzed.evidence.map { evidence in
                    SceneCompositionPlanner.compare(subject:selected.bounds,evidence:evidence,others:context,enclosingFrames:analyzed.enclosingFrames,maximumScale:label.intent.maximumCropScale,intent:label.intent,label:selected.label)
                } } ?? []
                let plan = layouts.first.map { SceneCompositionPlan(selected:$0,alternatives:Array(layouts.dropFirst().prefix(3)),subjectLabel:primary?.label ?? "Subject",timestamp:0) }
                let measured = CompositionAssessment.evaluate(bounds:primary?.bounds,confidence:primary?.confidence ?? 0,label:primary?.label ?? "Subject",
                    intent:label.intent,stable:true,exposure:analyzed.subjectMeasurements,evidence:analyzed.evidence,others:context,anatomy:analyzed.anatomy)
                let reading = CompositionReading(state:.ready,subjectBounds:primary?.bounds,subjectConfidence:Float(primary?.confidence ?? 0),target:plan?.target ?? .init(x:0.5,y:0.5))
                var decision = ActionFeasibility.recommend(assessment:measured,reading:reading,intent:label.intent,plan:plan,rollReliable:false,previewAspect:analyzed.aspect)
                if primary == nil, let scene = ActionFeasibility.sceneRecommendation(landscape:analyzed.landscape,stable:true,roll:0,rollReliable:false,
                    measurements:analyzed.measurements,evidence:analyzed.evidence,timestamp:0,previewAspect:analyzed.aspect) { decision = scene }
                if let sequence = label.sequenceID, !sequence.isEmpty, let time = label.sequenceTime {
                    var memory = memories[sequence] ?? RecommendationMemory()
                    decision = memory.update(decision,bounds:primary?.bounds,label:primary?.label ?? "Scene",intent:label.intent,timestamp:time)
                    memories[sequence] = memory
                }
                let oldLayouts = legacyPrimary.flatMap { selected in analyzed.evidence.map { evidence in
                    BaselinePlanner21.compare(subject:selected.bounds,evidence:evidence,others:legacyContext,enclosingFrames:analyzed.enclosingFrames,maximumScale:label.intent.maximumCropScale,intent:label.intent)
                } } ?? []
                let oldPlan = oldLayouts.first.map { SceneCompositionPlan(selected:$0,alternatives:[],subjectLabel:legacyPrimary?.label ?? "Subject",timestamp:0) }
                let oldReading = CompositionReading(state:.ready,subjectBounds:legacyPrimary?.bounds,subjectConfidence:Float(legacyPrimary?.confidence ?? 0),target:oldPlan?.target ?? .init(x:0.5,y:0.5))
                let legacyAssessment = CompositionAssessment.evaluate(bounds:legacyPrimary?.bounds,confidence:legacyPrimary?.confidence ?? 0,
                    label:legacyPrimary?.label ?? "Subject",intent:label.intent,stable:true,exposure:legacyPrimary?.measurements,
                    evidence:analyzed.evidence,others:legacyContext,anatomy:legacyPrimary?.bounds == primary?.bounds ? analyzed.anatomy : nil)
                let observedScene = analyzed.sceneLabel.flatMap { name in analyzed.sceneConfidence.map { SubjectScene(label:name,confidence:Float($0),timestamp:0) } }
                let old: GuidanceMessage
                if let sequence = label.sequenceID, !sequence.isEmpty, let time = label.sequenceTime {
                    var engine = baselineMemories[sequence] ?? BaselineGuidance21()
                    var scene = observedScene; scene?.timestamp = time
                    old = engine.update(reading:oldReading,phase:.off,stable:true,rollReliable:false,autoEnabled:false,zoomAvailable:false,
                        timestamp:time,previewAspect:analyzed.aspect,scene:scene,subjectLabel:legacyPrimary?.label,subjectMeasurements:legacyPrimary?.measurements,compositionPlan:oldPlan)
                    baselineMemories[sequence] = engine
                } else {
                    old = BaselineGuidance21.settled(reading:oldReading,subject:legacyPrimary?.label,measurements:legacyPrimary?.measurements,plan:oldPlan,aspect:analyzed.aspect,scene:observedScene)
                }
                baseline.append(.init(sampleID:sample.id,algorithm:"Focal 2.1 settled guidance",selected:legacyPrimary,detections:analyzed.subjects,action:Self.baselineAction(old),text:old.text,
                    inferenceMilliseconds:nil,aestheticScore:analyzed.aestheticScore,fitness:legacyAssessment.fitness,assessment:AssessmentMeasurements(legacyAssessment)))
                updated.append(.init(sampleID:sample.id,algorithm:"Focal Intelligence 2.0",selected:primary,detections:analyzed.subjects,action:decision.action,text:decision.text,
                    inferenceMilliseconds:analyzed.inferenceMilliseconds,aestheticScore:analyzed.aestheticScore,fitness:measured.fitness,assessment:AssessmentMeasurements(measured)))
            } catch is CancellationError { throw CancellationError() }
            catch { errors.append("\(sample.id): \(error.localizedDescription)") }
        }
        return .init(baseline:baseline,updated:updated,baselineMetrics:.calculate(samples:samples,outcomes:baseline),updatedMetrics:.calculate(samples:samples,outcomes:updated),errors:errors)
    }
    private static func baselineAction(_ message:GuidanceMessage) -> GuidanceAction {
        let text = message.text.lowercased()
        if text.contains("step back") || text.contains("farther back") { return .makeRoom }
        if text.contains("move closer") { return .tighterCrop }
        if text.contains("left") { return .panLeft }; if text.contains("right") { return .panRight }
        if text.contains("lower the camera") || text.contains("phone down") { return .panDown }
        if text.contains("raise the camera") || text.contains("phone up") { return .panUp }
        if text.contains("level") && message.kind != .ready { return .level }
        if text.contains("leave space") || text.contains("breathing room") { return .makeRoom }
        if text.contains("lower exposure") { return .reduceExposure }
        if text.contains("light") && (text.contains("add") || text.contains("softer")) { return .addLight }
        if text.contains("separate") || text.contains("isolate") || text.contains("eye level") || text.contains("angle") || text.contains("foreground") { return .reviewOverlap }
        return message.kind == .steady ? .hold : .none
    }
}
#endif
