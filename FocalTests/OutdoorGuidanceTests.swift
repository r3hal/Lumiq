import XCTest
@testable import Focal

final class OutdoorGuidanceTests: XCTestCase {
    private func evidence(at time:Double = 0, warm:Bool = false) throws -> SceneCompositionEvidence {
        // Varied greens/browns are pixel fixtures, not labelled forest photos.
        let pixels = (0..<48).flatMap { y in (0..<48).map { x -> SubjectImageEvidence.Pixel in
            if warm && x < 19 && y < 21 { return .init(red:0.85,green:0.40,blue:0.08) }
            let v = (x/4+y/7)%2 == 0 ? 0.15 : 0.65
            return .init(red:v*0.8,green:v,blue:v*0.65)
        } }
        return try XCTUnwrap(SceneCompositionEvidence(image:.init(pixels:pixels,width:48,height:48),
            projection:.init(imageAspect:1,previewAspect:1),timestamp:time))
    }
    private func scenePlan(_ evidence:SceneCompositionEvidence, at time:Double = 0) throws -> SceneCompositionPlan {
        var planner = SceneCompositionPlanner()
        return try XCTUnwrap(planner.update(subject:nil,confidence:0,label:"",evidence:evidence,timestamp:time))
    }
    private func alignedEvidence(at time:Double = 0) throws -> SceneCompositionEvidence {
        var pixels = try evidence(at:time)
        pixels.lines = []; pixels.symmetry = 1; pixels.repetition = 0
        return pixels
    }
    func testMotorRemainsSuspendedForEntirePinchAndGraceStartsAtEnd() {
        var policy = ManualZoomGrace()
        policy.begin(at:1)
        XCTAssertFalse(policy.permitsAutomaticZoom(at:100))
        policy.end(at:100)
        XCTAssertFalse(policy.permitsAutomaticZoom(at:102.99))
        XCTAssertTrue(policy.permitsAutomaticZoom(at:103))
    }
    func testRepeatedZoomExtendsGraceWithoutPermanentLatch() {
        var policy = ManualZoomGrace()
        for time in stride(from:0.0,through:10,by:0.25) {
            policy.changed(at:time)
            XCTAssertFalse(policy.permitsAutomaticZoom(at:time+0.24))
        }
        XCTAssertTrue(policy.permitsAutomaticZoom(at:13))
    }
    func testNewInteractionInvalidatesScheduledResumeRevision() {
        var policy = ManualZoomGrace()
        policy.changed(at:0); let first = policy.revision
        policy.begin(at:2); XCTAssertNotEqual(first,policy.revision)
        policy.end(at:4); XCTAssertFalse(policy.permitsAutomaticZoom(at:5))
        XCTAssertTrue(policy.permitsAutomaticZoom(at:7))
    }
    func testResetInvalidatesOldDeadlineAndRejectsNonfiniteTime() {
        var policy = ManualZoomGrace()
        policy.begin(at:0); let revision = policy.revision
        policy.reset(); XCTAssertNotEqual(policy.revision,revision)
        XCTAssertFalse(policy.active); XCTAssertTrue(policy.permitsAutomaticZoom(at:0))
        policy.changed(at:.nan); XCTAssertEqual(policy.resumeAt,0)
        XCTAssertFalse(policy.permitsAutomaticZoom(at:.infinity))
    }
    func testZoomRebasesRetainedSubjectWithoutApplyingOldScaleTwice() throws {
        let original = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
        let intermediate = try XCTUnwrap(ManualZoomGrace.trackedBounds(original,from:1,to:1.5))
        let final = try XCTUnwrap(ManualZoomGrace.trackedBounds(intermediate,from:1.5,to:2))
        let expected = try XCTUnwrap(ManualZoomGrace.trackedBounds(original,from:1,to:2))
        XCTAssertEqual(final.minX,expected.minX,accuracy:0.00001)
        XCTAssertEqual(final.width,expected.width,accuracy:0.00001)
        let wide = try XCTUnwrap(ManualZoomGrace.trackedBounds(final,from:2,to:1))
        XCTAssertEqual(wide.width,original.width,accuracy:0.00001)
    }
    func testSubjectOutsideNewFieldOfViewIsNotInvented() {
        XCTAssertNil(ManualZoomGrace.trackedBounds(CGRect(x:0.01,y:0.2,width:0.1,height:0.1),from:1,to:4))
        XCTAssertNil(ManualZoomGrace.trackedBounds(.zero,from:0,to:2))
        XCTAssertNil(ManualZoomGrace.trackedBounds(.zero,from:1,to:.nan))
    }
    func testLandscapeWithoutObjectProducesMeasuredWidePlan() throws {
        let plan = try scenePlan(evidence())
        XCTAssertNotNil(plan.selected.sceneAnchor)
        XCTAssertEqual(plan.subjectLabel,"Scene")
        XCTAssertEqual(plan.selected.zoomScale,1)
        XCTAssertEqual(plan.selected.crop,SceneCompositionEvidence.full)
        XCTAssertFalse(plan.permitsZoom)
        XCTAssertFalse(plan.alternatives.isEmpty)
    }
    func testLandscapeIntentDoesNotNeedClassifierOrSubjectConfidence() throws {
        var planner = SceneCompositionPlanner()
        let plan = try XCTUnwrap(planner.update(subject:nil,confidence:0,label:"",evidence:try evidence(),timestamp:0,intent:.landscape))
        XCTAssertNotNil(plan.selected.sceneAnchor)
    }
    func testUniformAndClippedScenesDoNotProduceFakeOpportunities() throws {
        for v in [0.0,0.5,1.0] {
            let image = SubjectImageEvidence(pixels:Array(repeating:.init(red:v,green:v,blue:v),count:48*48),width:48,height:48)
            let flat = try XCTUnwrap(SceneCompositionEvidence(image:image,projection:.init(imageAspect:1,previewAspect:1),timestamp:0))
            XCTAssertTrue(OutdoorCompositionPlanner.candidates(flat).isEmpty)
        }
    }
    func testStaleEvidenceCannotAcquireOrVerifyScene() throws {
        let pixels = try evidence()
        var planner = OutdoorCompositionPlanner()
        XCTAssertNil(planner.update(evidence:pixels,at:2))
        let plan = try scenePlan(pixels)
        XCTAssertFalse(OutdoorCompositionPlanner.permitsReady(plan:plan,evidence:pixels,at:2,motionPermitted:true))
    }
    func testWarmPixelAreaGeneratesColorAndThirdsWithoutSpeciesClaim() throws {
        let choices = OutdoorCompositionPlanner.candidates(try evidence(warm:true))
        let color = try XCTUnwrap(choices.first{$0.technique == .contrast})
        XCTAssertLessThan(try XCTUnwrap(color.sceneAnchor).x,0.5)
        XCTAssertEqual(color.target.x,1.0/3,accuracy:0.0001)
        XCTAssertTrue(choices.contains{$0.technique == .thirds})
        for option in choices {
            for unsupported in ["mushroom","forest trail","fog","waterfall","sun rays"] {
                XCTAssertFalse(option.explanation.lowercased().contains(unsupported))
            }
        }
    }
    func testConvergingLinesUseActualIntersectionForAiming() throws {
        var pixels = try evidence()
        pixels.lines = [.init(start:.init(x:0,y:1),end:.init(x:0.3,y:0.3),support:0.9),
                        .init(start:.init(x:1,y:1),end:.init(x:0.3,y:0.3),support:0.9)]
        let option = try XCTUnwrap(OutdoorCompositionPlanner.candidates(pixels).first{$0.technique == .leadingLines})
        XCTAssertEqual(try XCTUnwrap(option.sceneAnchor).x,0.3,accuracy:0.001)
        let plan = SceneCompositionPlan(selected:option,alternatives:[],subjectLabel:"Scene",timestamp:0)
        XCTAssertFalse(OutdoorCompositionPlanner.aligned(plan))
        XCTAssertNotNil(OutdoorCompositionPlanner.instruction(plan).1)
    }
    func testWeakOrParallelLinesDoNotInventVanishingPoint() throws {
        var pixels = try evidence()
        pixels.lines = [.init(start:.init(x:0,y:0.2),end:.init(x:1,y:0.2),support:0.9),
                        .init(start:.init(x:0,y:0.4),end:.init(x:1,y:0.4),support:0.9)]
        XCTAssertFalse(OutdoorCompositionPlanner.candidates(pixels).contains{$0.technique == .leadingLines})
        pixels.lines = [.init(start:.init(x:0,y:0),end:.init(x:1,y:1),support:0.4)]
        XCTAssertFalse(OutdoorCompositionPlanner.candidates(pixels).contains{$0.technique == .diagonals})
    }
    func testAlternativesAreDistinctTechniquesAndBounded() throws {
        let choices = OutdoorCompositionPlanner.candidates(try evidence(warm:true))
        XCTAssertGreaterThan(choices.count,2)
        XCTAssertEqual(Set(choices.map(\.technique)).count,choices.count)
        XCTAssertLessThanOrEqual(choices.count,8)
        XCTAssertTrue(choices.allSatisfy{$0.zoomScale == 1 && $0.crop == SceneCompositionEvidence.full})
    }
    func testRepeatedEquivalentSceneRetainsPlanIdentityAndChoice() throws {
        var planner = OutdoorCompositionPlanner()
        let first = try XCTUnwrap(planner.update(evidence:try evidence(),at:0))
        for time in [0.4,0.8,1.2,2.0] {
            let next = try XCTUnwrap(planner.update(evidence:try evidence(at:time),at:time))
            XCTAssertEqual(next.id,first.id)
            XCTAssertEqual(next.selected.technique,first.selected.technique)
        }
    }
    func testTryAnotherChoosesDifferentCompositionAndRetainsItDuringPolling() throws {
        var planner = SceneCompositionPlanner()
        let pixels = try evidence(warm:true)
        let first = try XCTUnwrap(planner.update(subject:nil,confidence:0,label:"",evidence:pixels,timestamp:0))
        planner.requestAlternative()
        let second = try XCTUnwrap(planner.update(subject:nil,confidence:0,label:"",evidence:pixels,timestamp:0.2))
        XCTAssertNotEqual(first.selected.technique,second.selected.technique)
        let third = try XCTUnwrap(planner.update(subject:nil,confidence:0,label:"",evidence:try evidence(at:1,warm:true),timestamp:1))
        XCTAssertEqual(third.selected.technique,second.selected.technique)
    }
    func testHandheldSceneCanReachReadyWithoutCaptureLevelStability() throws {
        let motion = FramingMotionMeasurement(rotation:0.5,acceleration:0.15,age:0.1)
        XCTAssertTrue(motion.permitsFraming); XCTAssertFalse(motion.stable)
        var framing = FramingPlanner(continuousRecovery:true)
        for time in [0.0,0.25,0.5,0.75] {
            let pixels = try alignedEvidence(at:time)
            let plan = try scenePlan(pixels,at:time)
            if framing.shotPlan == nil {
                XCTAssertTrue(framing.selectShot(.scene(label:"Scene",evidence:pixels,zoom:1.8,projection:.init(imageAspect:1,previewAspect:1))))
            }
            framing.confirmCurrentFrame(eligible:OutdoorCompositionPlanner.permitsReady(plan:plan,evidence:pixels,at:time,motionPermitted:motion.permitsFraming),timestamp:time,holdDuration:0.7)
        }
        XCTAssertEqual(framing.phase,.framed); XCTAssertTrue(framing.currentFrameVerified)
        XCTAssertFalse(framing.shotPlan?.requiresZoom ?? true)
    }
    func testFastMovementAndMisalignmentCannotVerifyScene() throws {
        let pixels = try evidence()
        var plan = try scenePlan(pixels)
        XCTAssertFalse(OutdoorCompositionPlanner.permitsReady(plan:plan,evidence:pixels,at:0,motionPermitted:false))
        plan.selected.sceneAnchor = .init(x:0.1,y:0.1); plan.selected.target = .init(x:0.5,y:0.5)
        XCTAssertFalse(OutdoorCompositionPlanner.permitsReady(plan:plan,evidence:pixels,at:0,motionPermitted:true))
    }
    func testSceneGuidanceContinuesDuringManualGraceWithoutObject() throws {
        var grace = ManualZoomGrace(); grace.begin(at:0)
        let pixels = try evidence()
        let plan = try scenePlan(pixels)
        var guidance = AutomaticGuidance()
        let message = guidance.update(reading:.init(),phase:.searching,stable:false,rollReliable:false,
            autoEnabled:true,zoomAvailable:false,timestamp:0,compositionPlan:plan,sceneEvidence:pixels,
            requireShotCompletion:true,continuousFraming:true)
        XCTAssertEqual(message.kind,.scene); XCTAssertFalse(message.text.isEmpty)
        XCTAssertFalse(grace.permitsAutomaticZoom(at:0))
    }
    func testReadyMessageRequiresVerifiedCurrentScene() throws {
        let pixels = try alignedEvidence(), plan = try scenePlan(pixels)
        var guidance = AutomaticGuidance()
        let unverified = guidance.update(reading:.init(),phase:.searching,stable:true,rollReliable:true,
            autoEnabled:true,zoomAvailable:false,timestamp:0,compositionPlan:plan,sceneEvidence:pixels,
            requireShotCompletion:true,continuousFraming:true)
        XCTAssertNotEqual(unverified.kind,.ready)
        let ready = guidance.update(reading:.init(),phase:.framed,stable:false,rollReliable:true,
            autoEnabled:true,zoomAvailable:false,timestamp:0,compositionPlan:plan,sceneEvidence:pixels,
            requireShotCompletion:true,currentFrameVerified:true,continuousFraming:true)
        XCTAssertEqual(ready.kind,.ready)
    }
    func testNoCandidateKeepsSearchingRatherThanTurningOff() throws {
        var planner = SceneCompositionPlanner()
        _ = try XCTUnwrap(planner.update(subject:nil,confidence:0,label:"",evidence:try evidence(),timestamp:0))
        XCTAssertNil(planner.update(subject:nil,confidence:0,label:"",evidence:nil,timestamp:1))
        XCTAssertNotNil(planner.update(subject:nil,confidence:0,label:"",evidence:try evidence(at:2),timestamp:2))
    }
    func testMirroredSceneReversesPhysicalPanWithoutReversingTilt() throws {
        var plan = try scenePlan(evidence())
        plan.selected.sceneAnchor = .init(x:0.8,y:0.5); plan.selected.target = .init(x:0.5,y:0.5)
        XCTAssertEqual(OutdoorCompositionPlanner.instruction(plan).1,.panRight)
        XCTAssertEqual(OutdoorCompositionPlanner.instruction(plan,mirrored:true).1,.panLeft)
        plan.selected.sceneAnchor = .init(x:0.5,y:0.8)
        XCTAssertEqual(OutdoorCompositionPlanner.instruction(plan,mirrored:true).1,.panDown)
    }
    func testSceneReadyPresentationDoesNotRequireFakeSubjectBox() {
        let reading = CompositionReading(state:.ready,sceneFrameVerified:true)
        let message = GuidanceMessage(kind:.ready,text:"Wide scene ready",action:GuidanceAction.none)
        XCTAssertEqual(CameraGuideState.resolve(enabled:true,reading:reading,phase:.framed,message:message),.ready)
        XCTAssertEqual(CameraGuideState.resolve(enabled:false,reading:reading,phase:.framed,message:message),.off)
        XCTAssertNotEqual(CameraGuideState.resolve(enabled:true,reading:reading,phase:.aligning,message:message),.ready)
    }
    func testSceneAdviceDoesNotPresentUnverifiedReady() {
        XCTAssertEqual(CameraGuideState.resolve(enabled:true,reading:.init(),phase:.searching,
            message:.init(kind:.scene,text:"Balance the scene")),.scene)
    }
    func testCurrentHighlightEvidenceTakesPriorityOverSceneAimingAndReady() throws {
        let bright = SubjectImageEvidence(pixels:(0..<48*48).map{ index in
            let v = index%3 == 0 ? 0.99 : 0.3
            return .init(red:v,green:v,blue:v)
        },width:48,height:48)
        let pixels = try XCTUnwrap(SceneCompositionEvidence(image:bright,projection:.init(imageAspect:1,previewAspect:1),timestamp:0))
        let plan = try scenePlan(pixels)
        var guidance = AutomaticGuidance()
        let message = guidance.update(reading:.init(state:.ready),phase:.framed,stable:true,rollReliable:true,
            autoEnabled:true,zoomAvailable:false,timestamp:0,compositionPlan:plan,sceneEvidence:pixels,
            requireShotCompletion:true,currentFrameVerified:true,continuousFraming:true)
        XCTAssertEqual(message.action,.reduceExposure); XCTAssertNotEqual(message.kind,.ready)
    }
    func testUnsupportedAlternativeIsReleasedWhenImageChanges() throws {
        var planner = OutdoorCompositionPlanner()
        var pixels = try evidence(warm:true)
        pixels.lines = []; pixels.symmetry = 0; pixels.repetition = 0
        let first = try XCTUnwrap(planner.update(evidence:pixels,at:0))
        XCTAssertEqual(first.selected.technique,.contrast)
        var changed = try evidence(at:0.8)
        changed.lines = []; changed.symmetry = 0; changed.repetition = 0
        let next = try XCTUnwrap(planner.update(evidence:changed,at:0.8))
        XCTAssertNotEqual(next.selected.technique,.contrast)
    }
    func testAnotherObjectCompositionPrefersDistinctLayoutAndKeepsSubject() throws {
        var planner = SceneCompositionPlanner()
        let box = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
        let pixels = try evidence()
        let first = try XCTUnwrap(planner.update(subject:box,confidence:0.95,label:"Chair",evidence:pixels,timestamp:0))
        XCTAssertFalse(first.alternatives.isEmpty)
        planner.requestAlternative()
        let next = try XCTUnwrap(planner.update(subject:box,confidence:0.95,label:"Chair",evidence:pixels,timestamp:0.25))
        XCTAssertEqual(next.subjectLabel,first.subjectLabel)
        XCTAssertNotEqual(next.selected.technique,first.selected.technique)
        XCTAssertTrue(SceneCompositionEvidence.full.contains(next.selected.crop))
    }
}
