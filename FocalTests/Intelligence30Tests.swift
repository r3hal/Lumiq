import XCTest
@testable import Focal

final class Intelligence30Tests: XCTestCase {
    private let box = CGRect(x:0.2,y:0.2,width:0.6,height:0.6)
    private func recommend(_ bounds: CGRect, stable: Bool = true, label: String = "Cat", intent: PhotographyIntent = .pet) -> FeasibleGuidance {
        let assessment = CompositionAssessment.evaluate(bounds:bounds,confidence:0.95,label:label,intent:intent,stable:stable,exposure:nil,evidence:nil)
        return ActionFeasibility.recommend(assessment:assessment,reading:.init(state:.ready,subjectBounds:bounds,subjectConfidence:0.95),intent:intent,plan:nil,rollReliable:false,previewAspect:1)
    }
    func testCropAndRoomAreOpposingAdjustments() {
        XCTAssertTrue(GuidanceAction.tighterCrop.opposes(.makeRoom))
        XCTAssertTrue(GuidanceAction.makeRoom.opposes(.tighterCrop))
    }
    func testMovingEdgeSubjectDoesNotReceiveMovementCommand() {
        XCTAssertEqual(recommend(CGRect(x:0,y:0.2,width:0.6,height:0.6),stable:false).action,.hold)
    }
    func testUncertainObservationProvidesNoInstruction() {
        var engine = AutomaticGuidance()
        let reading = CompositionReading(state:.ready,subjectBounds:box,subjectConfidence:0.5)
        let message = engine.update(reading:reading,phase:.off,stable:true,rollReliable:false,autoEnabled:true,zoomAvailable:false,timestamp:0,subjectLabel:"Cat")
        XCTAssertTrue(message.text.isEmpty)
        XCTAssertFalse(message.showsDirection)
    }
    func testIntentionalPeripheralPortraitHasNoCenteringPenalty() {
        let facts = CompositionAssessment.evaluate(bounds:CGRect(x:0.02,y:0.15,width:0.24,height:0.7),confidence:0.95,label:"Person",intent:.portrait,stable:true,exposure:nil,evidence:nil)
        XCTAssertEqual(facts.positionPenalty,0)
        XCTAssertEqual(recommend(CGRect(x:0.02,y:0.15,width:0.24,height:0.7),label:"Person",intent:.portrait).action,.none)
    }
    func testHeadMeasurementsDoNotApplyToProduct() {
        let anatomy = SubjectAnatomy(face:CGRect(x:0.3,y:0,width:0.2,height:0.2),headYaw:0.8,timestamp:0)
        let facts = CompositionAssessment.evaluate(bounds:box,confidence:0.95,label:"Box",intent:.product,stable:true,exposure:nil,evidence:nil,anatomy:anatomy)
        XCTAssertNil(facts.headroom)
        XCTAssertNil(facts.headYaw)
    }
    func testFaceCategoryIsRecognized() { XCTAssertEqual(SubjectCategory.classified("Face"),.face) }
    func testNewRoomWarningWithdrawsPreviousTighterCrop() {
        var memory = RecommendationMemory()
        _ = memory.update(.init(action:.tighterCrop,text:"Crop",confidence:0.9,issue:0.5),bounds:box,label:"Cat",intent:.pet,timestamp:0)
        let result = memory.update(.init(action:.makeRoom,text:"Room",confidence:0.9,issue:0.3),bounds:box,label:"Cat",intent:.pet,timestamp:0.3)
        XCTAssertFalse(result.action == .tighterCrop)
        XCTAssertFalse(result.action == .makeRoom)
    }
}

final class Intelligence30ObservationTests: XCTestCase {
    func testConfidenceSmoothingNeverPromotesWeakObservation() {
        var filter = GuidanceConfidenceFilter()
        XCTAssertEqual(filter.update(0.9,label:"Cat",at:0),0.9,accuracy:0.0001)
        XCTAssertEqual(filter.update(0.4,label:"Cat",at:0.3),0.4,accuracy:0.0001)
        XCTAssertLessThan(filter.update(0.9,label:"Cat",at:0.6),0.9)
        XCTAssertEqual(filter.update(0.9,label:"Dog",at:0.9),0.9,accuracy:0.0001)
    }
    func testStaleFutureAndNonFiniteResultsAreRejected() {
        XCTAssertTrue(GuidanceObservationPolicy.fresh(capturedAt:0,evaluatedAt:0.5))
        XCTAssertFalse(GuidanceObservationPolicy.fresh(capturedAt:0,evaluatedAt:1))
        XCTAssertFalse(GuidanceObservationPolicy.fresh(capturedAt:1,evaluatedAt:0))
        XCTAssertFalse(GuidanceObservationPolicy.fresh(capturedAt:.nan,evaluatedAt:0))
    }
    func testZoomRequiresObservedSlowSubjectAndFreshStableCamera() {
        XCTAssertFalse(GuidanceObservationPolicy.permitsZoom(stable:true,relativeSpeed:nil,fresh:true))
        XCTAssertFalse(GuidanceObservationPolicy.permitsZoom(stable:true,relativeSpeed:0.4,fresh:true))
        XCTAssertFalse(GuidanceObservationPolicy.permitsZoom(stable:false,relativeSpeed:0,fresh:true))
        XCTAssertFalse(GuidanceObservationPolicy.permitsZoom(stable:true,relativeSpeed:0,fresh:false))
        XCTAssertTrue(GuidanceObservationPolicy.permitsZoom(stable:true,relativeSpeed:0.03,fresh:true))
    }
    func testPetIntentDoesNotPenalizeHorizontalNegativeSpace() throws {
        var center = SubjectCandidate(bounds:CGRect(x:0.4,y:0.3,width:0.2,height:0.3),confidence:0.95,category:.pet,label:"Cat",classificationConfidence:0.95,prominence:0.8,isolation:0.3,detail:0.05)
        let centered = try XCTUnwrap(center.score(configuration:.init(intent:.pet)))
        center.bounds.origin.x = 0.03
        XCTAssertEqual(try XCTUnwrap(center.score(configuration:.init(intent:.pet))),centered,accuracy:0.0001)
    }
    func testLeastUsefulCropPreservesFullSubjectAndContext() throws {
        let pixels = Array(repeating:SubjectImageEvidence.Pixel(red:0.5,green:0.5,blue:0.5),count:48*48)
        let evidence = try XCTUnwrap(SceneCompositionEvidence(image:.init(pixels:pixels,width:48,height:48),projection:.init(imageAspect:1,previewAspect:1),timestamp:0))
        let subject = CGRect(x:0.45,y:0.45,width:0.1,height:0.1)
        let plan = try XCTUnwrap(IntentCompositionSearch.zoomPlan(subject:subject,label:"Cat",intent:.pet,evidence:evidence,others:[],frames:[],scales:[1,1.6,2,2.5,3],forceCenter:false))
        XCTAssertEqual(plan.selected.zoomScale,2,accuracy:0.0001)
        XCTAssertTrue(plan.selected.crop.contains(subject))
        XCTAssertGreaterThanOrEqual(plan.selected.measuredImprovement,0.08)
    }
    func testCumulativeWorseningWithdrawsAdjustment() {
        var memory = RecommendationMemory()
        for (time,x,issue) in [(0.0,0.1,0.1),(0.4,0.14,0.15),(0.8,0.18,0.2),(1.2,0.22,0.25)] {
            let result = memory.update(.init(action:.panRight,text:"Right",confidence:0.9,issue:issue),bounds:CGRect(x:x,y:0.2,width:0.2,height:0.3),label:"Cat",intent:.pet,timestamp:time)
            if time == 1.2 { XCTAssertEqual(result.action,.hold) }
        }
    }
    func testSameClassDistantReplacementClearsMemory() {
        var memory = RecommendationMemory()
        _ = memory.update(.init(action:.panLeft,text:"Left",confidence:0.9,issue:0.4),bounds:CGRect(x:0.02,y:0.2,width:0.1,height:0.3),label:"Person",intent:.portrait,timestamp:0)
        let result = memory.update(.init(action:.panRight,text:"Right",confidence:0.9,issue:0.3),bounds:CGRect(x:0.85,y:0.2,width:0.1,height:0.3),label:"Person",intent:.portrait,timestamp:0.2)
        XCTAssertEqual(result.action,.panRight)
    }
}

final class Intelligence30SceneTests: XCTestCase {
    func testStaleStructuredSceneCannotGenerateAdvice() {
        let scene = GuidanceSceneSnapshot(observedAt:0,evaluatedAt:2,label:"Cat",intent:.pet,selectedBounds:CGRect(x:0,y:0,width:0.5,height:0.5),confidence:0.95,surroundingSubjects:[],anatomy:nil,measurements:nil,imageEvidence:nil,relativeSpeed:0,deviceStable:true)
        var guide = AutomaticGuidance()
        let result = guide.update(reading:.init(state:.ready,subjectBounds:scene.selectedBounds,subjectConfidence:0.95),phase:.off,stable:true,rollReliable:false,autoEnabled:true,zoomAvailable:true,timestamp:2,observedScene:scene)
        XCTAssertTrue(result.text.isEmpty)
        XCTAssertFalse(result.showsDirection)
    }
    func testSceneReadinessClearsEarlierLevelAdvice() {
        var guide = AutomaticGuidance()
        var tilted = CompositionReading(); tilted.rollDegrees = 8
        _ = guide.update(reading:tilted,phase:.off,stable:true,rollReliable:true,autoEnabled:false,zoomAvailable:false,timestamp:0,intent:.landscape)
        let result = guide.update(reading:.init(),phase:.off,stable:true,rollReliable:true,autoEnabled:false,zoomAvailable:false,timestamp:0.3,intent:.landscape)
        XCTAssertEqual(result.action,GuidanceAction.none)
        XCTAssertEqual(result.text,"Ready to shoot")
    }
}
