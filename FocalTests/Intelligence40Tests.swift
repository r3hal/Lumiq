import XCTest
@testable import Focal

final class Intelligence40Tests: XCTestCase {
    func testNewExposureIssueWithdrawsObsoleteDirection() {
        var memory = RecommendationMemory()
        _ = memory.update(.init(action:.panRight,text:"Right",confidence:0.9,issue:0.3),bounds:CGRect(x:0.2,y:0.2,width:0.3,height:0.4),label:"Cat",intent:.pet,timestamp:0)
        let next = memory.update(.init(action:.reduceExposure,text:"Protect highlights",confidence:0.9,issue:0.4),bounds:CGRect(x:0.2,y:0.2,width:0.3,height:0.4),label:"Cat",intent:.pet,timestamp:0.2)
        XCTAssertNotEqual(next.action,.panRight)
    }
    func testUncertainRecommendationIsSilent() {
        let facts = CompositionAssessment(confidence:0.4)
        let decision = ActionFeasibility.recommend(assessment:facts,reading:.init(),intent:.pet,plan:nil,rollReliable:false,previewAspect:1)
        XCTAssertTrue(decision.text.isEmpty)
    }
}

final class Intelligence40PetTests: XCTestCase {
    private func facts(_ bounds:CGRect,style:PetFramingStyle = .balanced,anatomy:SubjectAnatomy? = nil,stable:Bool = true) -> CompositionAssessment {
        CompositionAssessment.evaluate(bounds:bounds,confidence:0.95,label:"Cat",intent:.pet,stable:stable,exposure:nil,evidence:nil,anatomy:anatomy,petStyle:style)
    }
    private func advice(_ facts:CompositionAssessment) -> FeasibleGuidance {
        ActionFeasibility.recommend(assessment:facts,reading:.init(state:.ready),intent:.pet,plan:nil,rollReliable:false,previewAspect:1)
    }
    func testCloseUpAcceptsCroppedBodyWhenObservedHeadIsVisible() {
        let body = CGRect(x:-0.1,y:0.1,width:1.2,height:0.8)
        let head = CGRect(x:0.2,y:0.15,width:0.4,height:0.4)
        let measured = facts(body,style:.closeUp,anatomy:.init(face:head,timestamp:0))
        XCTAssertTrue(measured.assessmentReliable)
        XCTAssertEqual(measured.protectedHead,head)
        XCTAssertFalse(measured.touchesEdge)
        XCTAssertEqual(advice(measured).action,.none)
    }
    func testCloseUpWithoutObservedHeadStaysSilent() {
        let measured = facts(CGRect(x:0.1,y:0.1,width:0.8,height:0.8),style:.closeUp)
        XCTAssertFalse(measured.assessmentReliable)
        XCTAssertTrue(advice(measured).text.isEmpty)
        XCTAssertFalse(measured.permitsAutomaticCrop)
    }
    func testCloseUpDoesNotUseExpiredPose() {
        let measured = facts(CGRect(x:0.1,y:0.1,width:0.8,height:0.8),style:.closeUp,
            anatomy:.init(face:CGRect(x:0.2,y:0.2,width:0.4,height:0.4),timestamp:-2))
        XCTAssertFalse(measured.assessmentReliable)
    }
    func testWholeBodyProtectsObservedBoundary() {
        XCTAssertEqual(advice(facts(CGRect(x:-0.04,y:0.2,width:0.6,height:0.5),style:.wholeBody)).action,.makeRoom)
    }
    func testEnvironmentalPetAllowsSmallSubjectAndRetainsContext() {
        let measured = facts(CGRect(x:0.25,y:0.25,width:0.12,height:0.12),style:.environmental)
        XCTAssertEqual(measured.sizePenalty,0)
        XCTAssertEqual(advice(measured).action,.none)
        XCTAssertFalse(PetFramingStyle.environmental.permitsAutomaticZoom)
    }
    func testActionPetMotionSuppressesReframing() {
        XCTAssertEqual(advice(facts(CGRect(x:0.01,y:0.2,width:0.4,height:0.4),style:.action,stable:false)).action,.hold)
        XCTAssertFalse(PetFramingStyle.action.permitsAutomaticZoom)
    }
    @MainActor
    func testPetFramingPreferencePersists() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let settings = CameraSettings(defaults:defaults)
        XCTAssertEqual(settings.petFraming,.balanced)
        settings.petFraming = .environmental
        XCTAssertEqual(CameraSettings(defaults:defaults).petFraming,.environmental)
    }
}

final class Intelligence40ReasoningTests: XCTestCase {
    private let box = CGRect(x:0.2,y:0.2,width:0.4,height:0.4)
    private var facts:CompositionAssessment {
        CompositionAssessment.evaluate(bounds:box,confidence:0.95,label:"Cat",intent:.pet,stable:true,exposure:nil,evidence:nil)
    }
    func testSevereHighlightsTakePriorityOverMinorLevelAndPan() {
        var measured = facts
        measured.exposure = .init(brightness:0.8,shadowFraction:0,highlightFraction:0.3,detail:0.1,backgroundEdges:nil)
        let decision = PhotographicReasoner.evaluate(assessment:measured,reading:.init(subjectBounds:box,target:.init(x:0.7,y:0.7),rollDegrees:6),intent:.pet,plan:nil,rollReliable:true,previewAspect:1,manualComposition:true)
        XCTAssertEqual(decision.selected.action,.reduceExposure)
        XCTAssertTrue(decision.candidates.contains { $0.guidance.action == .level })
        XCTAssertTrue(decision.candidates.contains { $0.guidance.showsDirection })
    }
    func testVisibleHeadMarginTakesPriorityOverExposure() {
        var measured = facts; measured.headroom = 0.005
        measured.exposure = .init(brightness:0.8,shadowFraction:0,highlightFraction:0.3,detail:0.1,backgroundEdges:nil)
        let decision = PhotographicReasoner.evaluate(assessment:measured,reading:.init(),intent:.pet,plan:nil,rollReliable:false,previewAspect:1)
        XCTAssertEqual(decision.selected.action,.makeRoom)
    }
    func testAutomaticCropRequiresConfidentVisibleSubject() {
        var measured = facts
        XCTAssertTrue(measured.permitsAutomaticCrop)
        measured.confidence = 0.6
        XCTAssertFalse(measured.permitsAutomaticCrop)
        measured.confidence = 0.95; measured.headroom = 0.005
        XCTAssertFalse(measured.permitsAutomaticCrop)
    }
    func testAutomaticCropPausesForSevereLightOrMissingHeadEvidence() {
        var measured = facts
        measured.exposure = .init(brightness:0.1,shadowFraction:0.8,highlightFraction:0,detail:0.1,backgroundEdges:nil)
        XCTAssertFalse(measured.permitsAutomaticCrop)
        measured.exposure = .init(brightness:0.8,shadowFraction:0,highlightFraction:0.3,detail:0.1,backgroundEdges:nil)
        XCTAssertFalse(measured.permitsAutomaticCrop)
        measured.exposure = nil; measured.assessmentReliable = false
        XCTAssertFalse(measured.permitsAutomaticCrop)
    }
    func testSupportRejectsNonFiniteValuesAndBoundsRisk() {
        XCTAssertEqual(RecommendationSupport(detection:.nan,measurement:1,feasibility:1,risk:0).value,0)
        XCTAssertEqual(RecommendationSupport(detection:2,measurement:2,feasibility:2,risk:-1).value,1)
        XCTAssertEqual(RecommendationSupport(detection:1,measurement:1,feasibility:1,risk:2).value,0)
    }
    func testCollateralClippingWithdrawsRepeatedCrop() {
        var memory = RecommendationMemory(), current = facts
        let crop = FeasibleGuidance(action:.tighterCrop,text:"Crop",confidence:0.9,issue:0.4)
        _ = memory.update(crop,bounds:box,label:"Cat",intent:.pet,timestamp:0,assessment:current)
        current.minimumMargin = -0.01
        _ = memory.update(crop,bounds:box,label:"Cat",intent:.pet,timestamp:0.3,assessment:current)
        let result = memory.update(crop,bounds:box,label:"Cat",intent:.pet,timestamp:0.6,assessment:current)
        XCTAssertEqual(result.action,.hold)
        XCTAssertTrue(memory.outcome.contains("no causal claim"))
    }
    func testCollateralHighlightDamageWithdrawsPan() {
        var memory = RecommendationMemory(), current = facts
        current.exposure = .init(brightness:0.5,shadowFraction:0,highlightFraction:0.01,detail:0.1,backgroundEdges:nil)
        let pan = FeasibleGuidance(action:.panRight,text:"Right",confidence:0.9,issue:0.4)
        _ = memory.update(pan,bounds:box,label:"Cat",intent:.pet,timestamp:0,assessment:current)
        current.exposure = .init(brightness:0.8,shadowFraction:0,highlightFraction:0.3,detail:0.1,backgroundEdges:nil)
        _ = memory.update(pan,bounds:box,label:"Cat",intent:.pet,timestamp:0.3,assessment:current)
        XCTAssertEqual(memory.update(pan,bounds:box,label:"Cat",intent:.pet,timestamp:0.6,assessment:current).action,.hold)
    }
    func testRepeatedTimestampDoesNotAccumulateContradictoryEvidence() {
        var memory = RecommendationMemory()
        let first = FeasibleGuidance(action:.panRight,text:"Right",confidence:0.9,issue:0.3)
        let second = FeasibleGuidance(action:.panLeft,text:"Left",confidence:0.9,issue:0.3)
        _ = memory.update(first,bounds:box,label:"Cat",intent:.pet,timestamp:0)
        for _ in 0..<20 { XCTAssertEqual(memory.update(second,bounds:box,label:"Cat",intent:.pet,timestamp:0).action,.panRight) }
    }
    func testIntentChangeClearsAdviceEvenAtSameTimestamp() {
        var memory = RecommendationMemory()
        _ = memory.update(.init(action:.panRight,text:"Right",confidence:0.9,issue:0.3),bounds:box,label:"Cat",intent:.pet,timestamp:0)
        let result = memory.update(.init(action:.none,text:"Ready to shoot",confidence:0.9,issue:0),bounds:box,label:"Cat",intent:.auto,timestamp:0)
        XCTAssertEqual(result.action,.none)
    }
    func testReadyAndUncertainStatesAreExplicit() {
        XCTAssertEqual(GuidanceMessage(kind:.ready,text:"Ready to shoot",action:GuidanceAction.none).reasoningState,.readyToShoot)
        XCTAssertEqual(GuidanceMessage(kind:.searching,text:"").reasoningState,.insufficientConfidence)
        XCTAssertEqual(GuidanceMessage(kind:.detected,text:"Cat detected").reasoningState,.subjectAcquired)
        XCTAssertEqual(GuidanceMessage(kind:.framing,text:"Refining").reasoningState,.evaluating)
    }
    func testNativeTimingAggregationRejectsDuplicateAndInvalidSamples() {
        var timings = GuidanceTimingAccumulator()
        timings.record(inferenceMS:20,decisionMS:2,latencyMS:30,at:1)
        timings.record(inferenceMS:40,decisionMS:4,latencyMS:50,at:1.5)
        timings.record(inferenceMS:999,decisionMS:999,latencyMS:999,at:1.5)
        timings.record(inferenceMS:.nan,decisionMS:2,latencyMS:3,at:2)
        XCTAssertEqual(timings.count,2)
        XCTAssertEqual(timings.inferenceMean,30)
        XCTAssertEqual(timings.decisionMean,3)
        XCTAssertEqual(timings.latencyMean,40)
        XCTAssertEqual(timings.updateHz,2)
    }
    func testCropCannotIncreaseObservedClippingSeverely() throws {
        let pixels = (0..<48*48).map { index -> SubjectImageEvidence.Pixel in
            let x = index%48, y = index/48
            let value = (18..<30).contains(x) && (18..<30).contains(y) ? 1.0 : 0.5
            return .init(red:value,green:value,blue:value)
        }
        let evidence = try XCTUnwrap(SceneCompositionEvidence(image:.init(pixels:pixels,width:48,height:48),projection:.init(imageAspect:1,previewAspect:1),timestamp:0))
        let candidates = IntentCompositionSearch.candidates(subject:CGRect(x:0.45,y:0.45,width:0.1,height:0.1),label:"Cat",intent:.pet,evidence:evidence,others:[],frames:[],scales:[1,3])
        XCTAssertFalse(candidates.contains { $0.scale == 3 })
        XCTAssertTrue(candidates.contains { $0.scale == 1 })
    }
    func testHotDeviceReducesOptionalAnalysisCadence() {
        XCTAssertGreaterThan(PreviewAnalysisScheduler.thermalInterval(.serious),PreviewAnalysisScheduler.thermalInterval(.nominal))
        XCTAssertGreaterThan(PreviewAnalysisScheduler.thermalInterval(.critical),PreviewAnalysisScheduler.thermalInterval(.serious))
    }
}

#if DEBUG || FOCAL_EVALUATION
final class Intelligence40FeedbackTests: XCTestCase {
    func testFeedbackRoundTripLinksConsentedImageAndActualDecision() throws {
        let id = UUID(), hash = String(repeating:"a",count:64)
        let result = EvaluationOutcome(sampleID:id,algorithm:"Focal Intelligence 4.0",selected:nil,detections:[],action:.hold,text:"Hold",inferenceMilliseconds:42,aestheticScore:nil,fitness:nil)
        let feedback = EvaluationFeedback(label:.impossible,sampleID:id,imageSHA256:hash,intent:.pet,petStyle:.action,result:result)
        let data = try JSONEncoder().encode(feedback)
        let reopened = try JSONDecoder().decode(EvaluationFeedback.self,from:data)
        XCTAssertEqual(reopened.sampleID,id)
        XCTAssertEqual(reopened.imageSHA256,hash)
        XCTAssertEqual(reopened.label,.impossible)
        XCTAssertEqual(reopened.result.action,.hold)
        XCTAssertEqual(reopened.petStyle,.action)
    }
    func testSampleWithoutFeedbackAndPetStyleStillDecodes() throws {
        let sample = EvaluationSample(id:UUID(),imageFile:"test.jpg",imageSHA256:"test",provenance:"unit fixture")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(sample)) as? [String:Any])
        let restored = try JSONDecoder().decode(EvaluationSample.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNil(restored.feedback)
        XCTAssertNil(restored.annotation.petStyle)
    }
    func testFrozen30AndUpdatedMemoryExposeObsoleteAdviceRegression() {
        let box = CGRect(x:0.2,y:0.2,width:0.3,height:0.4)
        let pan = FeasibleGuidance(action:.panRight,text:"Right",confidence:0.9,issue:0.3)
        let exposure = FeasibleGuidance(action:.reduceExposure,text:"Highlights",confidence:0.9,issue:0.4)
        var old = BaselineReasoning30.Memory(), new = RecommendationMemory()
        _ = old.update(pan,bounds:box,label:"Cat",intent:.pet,timestamp:0)
        _ = new.update(pan,bounds:box,label:"Cat",intent:.pet,timestamp:0)
        XCTAssertEqual(old.update(exposure,bounds:box,label:"Cat",intent:.pet,timestamp:0.2).action,.panRight)
        XCTAssertEqual(new.update(exposure,bounds:box,label:"Cat",intent:.pet,timestamp:0.2).action,.hold)
    }
}
#endif
