import XCTest
@testable import Focal

/// Deterministic observations, not measurements from an iPhone or a scene model.
final class FocalIntegrationTests:XCTestCase {
    private func evidence(_ time:Double,bright:Bool = false) throws -> SceneCompositionEvidence {
        let pixels = (0..<32*32).map { i -> SubjectImageEvidence.Pixel in
            let value = bright ? (i%2 == 0 ? 0.65 : 0.95) : (i%2 == 0 ? 0.08 : 0.38)
            return .init(red:value,green:value,blue:value)
        }
        var result = try XCTUnwrap(SceneCompositionEvidence(image:.init(pixels:pixels,width:32,height:32),
            projection:.init(imageAspect:1,previewAspect:1),timestamp:time))
        result.lines = []; result.symmetry = 1; result.repetition = 0
        return result
    }
    private let box = CGRect(x:0.30,y:0.27,width:0.38,height:0.42)
    private func update(_ planner:inout SceneCompositionPlanner,_ time:Double,reference:String = "chair-A",freeze:Bool = false) throws -> SceneCompositionPlan {
        try XCTUnwrap(planner.update(subject:box,confidence:0.95,label:"Chair",evidence:evidence(time),timestamp:time,
            maximumScale:1,freeze:freeze,trackingReference:reference))
    }
    func testOrdinaryObjectUpdatesRetainPlanIdentifier() throws {
        var planner = SceneCompositionPlanner(); let first = try update(&planner,0)
        for i in 1...20 { XCTAssertEqual(try update(&planner,Double(i)*0.1).id,first.id) }
    }
    func testSameNamedDifferentObjectGetsIndependentPlan() throws {
        var planner = SceneCompositionPlanner(); let first = try update(&planner,0)
        XCTAssertNotEqual(try update(&planner,0.1,reference:"chair-B").id,first.id)
    }
    func testObservationGapCannotCarryOldCompositionIdentity() throws {
        var planner = SceneCompositionPlanner(); let first = try update(&planner,0)
        XCTAssertNotEqual(try update(&planner,2).id,first.id)
    }
    func testReadyCurrentCompositionKeepsItsPlanDuringFreshReevaluation() throws {
        var planner = SceneCompositionPlanner(); let first = try update(&planner,0)
        XCTAssertTrue(first.selected.isCurrentFrame)
        for i in 1...10 { let next = try update(&planner,Double(i)*0.1,freeze:true)
            XCTAssertTrue(next.selected.isCurrentFrame); XCTAssertEqual(next.id,first.id) }
    }
    func testExplicitAlternativeCreatesNewPlanEvenWhenFrozen() throws {
        var planner = SceneCompositionPlanner(); let first = try update(&planner,0)
        planner.requestAlternative()
        let next = try update(&planner,0.1,freeze:true)
        XCTAssertNotEqual(next.id,first.id)
    }
    func testVerifiedCurrentFrameDoesNotChaseNewTighterCandidate() throws {
        var planner = SceneCompositionPlanner(); let first = try update(&planner,0)
        let smaller = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
        let next = try XCTUnwrap(planner.update(subject:smaller,confidence:0.95,label:"Chair",evidence:evidence(0.2),timestamp:0.2,
            maximumScale:3,freeze:true,availableScales:[1,1.5,2,3],trackingReference:"chair-A"))
        XCTAssertTrue(next.selected.isCurrentFrame); XCTAssertEqual(next.id,first.id)
        // Retaining a candidate is not retaining READY; measurement gates remain.
        let weak = CompositionAssessment(confidence:0.3)
        XCTAssertFalse(ShotReadiness.measuredCurrentFrame(plan:next,assessment:weak,label:"Chair",timestamp:0.2,stable:true))
    }
    func testOutdoorSceneCutGetsNewIdentifierEvenWithSameTechnique() throws {
        var planner = OutdoorCompositionPlanner()
        let first = try XCTUnwrap(planner.update(evidence:evidence(0),at:0))
        let next = try XCTUnwrap(planner.update(evidence:evidence(0.2,bright:true),at:0.2))
        XCTAssertEqual(first.selected.technique,next.selected.technique); XCTAssertNotEqual(first.id,next.id)
    }
    func testRepeatedSceneChangesDoNotResurrectOldIdentifier() throws {
        var planner = OutdoorCompositionPlanner(); var seen = Set<String>()
        for i in 0..<12 {
            let time = Double(i)*0.3
            let next = try XCTUnwrap(planner.update(evidence:evidence(time,bright:i%2 == 1),at:time))
            XCTAssertTrue(seen.insert(next.id).inserted)
        }
    }
    func testOutdoorDiagonalErrorCannotProduceAimlessInstruction() {
        var option = CompositionOption(technique:.thirds,target:.init(x:0.5,y:0.5),crop:.init(x:0,y:0,width:1,height:1),
            score:0.5,explanation:"Measured scene",zoomScale:1,isCurrentFrame:true)
        option.sceneAnchor = .init(x:0.58,y:0.58)
        let plan = SceneCompositionPlan(selected:option,alternatives:[],subjectLabel:"Scene",timestamp:0)
        XCTAssertFalse(OutdoorCompositionPlanner.aligned(plan))
        XCTAssertNotNil(OutdoorCompositionPlanner.instruction(plan).1)
    }
    func testOptionalVisionAdmissionExpiresAtSourceDeadline() {
        let admission = SubjectInferenceAdmission(revision:2,deadline:10.9)
        XCTAssertTrue(admission.permits(revision:2,at:10.89)); XCTAssertFalse(admission.permits(revision:2,at:10.9))
        XCTAssertFalse(admission.permits(revision:3,at:10.1)); XCTAssertFalse(admission.permits(revision:2,at:.nan))
    }
    func testCancellationRejectsLaterStagesFromSameInferencePass() {
        let first = SubjectInferenceAdmission(revision:1,deadline:12)
        XCTAssertTrue(first.permits(revision:1,at:10)); XCTAssertFalse(first.permits(revision:2,at:10.1))
        XCTAssertTrue(SubjectInferenceAdmission(revision:2,deadline:12).permits(revision:2,at:10.1))
    }
    func testDiagnosticsReportPlanChangesWithoutWaitingForHeartbeat() {
        var trace = FramingTransitionTrace()
        XCTAssertNotNil(trace.record(sessionID:1,shotID:"A",state:.aiming,at:1,values:[:]))
        XCTAssertNil(trace.record(sessionID:1,shotID:"A",state:.aiming,at:1.1,values:[:]))
        let event = trace.record(sessionID:1,shotID:"B",state:.aiming,at:1.2,values:[:])
        XCTAssertTrue(event?.contains("transitionReason=plan_replaced") == true)
        XCTAssertTrue(event?.contains("previousShot=A") == true)
    }
    func testUnchangedCurrentShotDoesNotRestartDirector() throws {
        var scenePlanner = SceneCompositionPlanner(); let scene = try update(&scenePlanner,0)
        let shot = try XCTUnwrap(AutomaticShotPlan.propose(bounds:box,label:"Chair",confidence:0.95,
            trackingReference:"chair-A",composition:scene,currentZoom:1,maximumZoom:5,detailLimit:3,nativeStops:[],regions:[],
            anatomy:nil,projection:.init(imageAspect:1,previewAspect:1)))
        var director = FramingPlanner(continuousRecovery:true)
        XCTAssertTrue(director.selectShot(shot)); XCTAssertFalse(director.selectShot(shot))
        XCTAssertEqual(director.shotPlan?.id,scene.id)
    }
    func testReadyRetentionStillExpiresAndDoesNotSurviveIdentityChange() {
        var continuity = ReadyContinuity()
        XCTAssertFalse(continuity.update(eligible:true,retaining:false,identity:"A",timestamp:0,hold:0.5))
        XCTAssertTrue(continuity.update(eligible:true,retaining:false,identity:"A",timestamp:0.6,hold:0.5))
        XCTAssertFalse(continuity.fresh(at:1.51))
        XCTAssertFalse(continuity.update(eligible:true,retaining:true,identity:"B",timestamp:0.7,hold:0.5))
    }
    func testManualZoomDoesNotRequireDisablingLocalAutofocus() {
        var grace = ManualZoomGrace(); grace.begin(at:1)
        XCTAssertFalse(grace.permitsAutomaticZoom(at:3))
        var focus = SubjectAutofocus()
        let enabled = SubjectAutofocus.permitted(guidance:true,tracking:true,iPhone:true,manualFocus:false)
        let decision = focus.update(enabled:enabled,selectedIdentity:"A",observedIdentity:"A",bounds:box,confidence:0.95,observedAt:1,now:1.01)
        XCTAssertNotNil(decision)
    }
}
