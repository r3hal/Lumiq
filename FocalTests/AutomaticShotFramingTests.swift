import XCTest
@testable import Focal

final class AutomaticShotFramingTests: XCTestCase {
    private let subject = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
    private func composition(scale:Double = 2,target:UnitPoint2D = .init(x:0.5,y:0.5)) -> SceneCompositionPlan {
        .init(selected:.init(technique:.fillFrame,target:target,crop:CGRect(x:0.25,y:0.25,width:0.5,height:0.5),score:0.9,
                            explanation:"measured test crop",zoomScale:scale,measuredImprovement:0.15),alternatives:[],subjectLabel:"Cat",timestamp:0)
    }
    private func shot(scale:Double = 2,start:Double = 1,bounds:CGRect? = nil,regions:[CGRect] = [],anatomy:SubjectAnatomy? = nil) throws -> AutomaticShotPlan {
        try XCTUnwrap(AutomaticShotPlan.make(bounds:bounds ?? subject,label:"Cat",composition:composition(scale:scale),currentZoom:start,
            maximumZoom:4,detailLimit:4,nativeStops:[1],regions:regions,anatomy:anatomy,previewAspect:1))
    }
    private func ramp(_ shot:AutomaticShotPlan) -> FramingPlanner {
        var planner = FramingPlanner()
        for time in [0.0,1.0] {
            _ = planner.update(bounds:shot.initialBounds,confidence:0.95,roll:0,timestamp:time,currentZoom:shot.startingZoom,
                maximumZoom:4,detailZoomLimit:4,alignmentTarget:.init(x:0.5,y:0.5),plannedScale:shot.desiredScale,zoomDestination:.init(x:0.5,y:0.5))
        }
        planner.commitShot(shot); return planner
    }
    func testAimingPrecedesAutomaticZoom() throws {
        var planner = FramingPlanner()
        let plan = composition(target:.init(x:1.0/3,y:0.5))
        let wrong = subject
        XCTAssertNil(planner.update(bounds:wrong,confidence:1,roll:0,timestamp:0,currentZoom:1,maximumZoom:3,alignmentTarget:plan.zoomAlignmentTarget,plannedScale:2,zoomDestination:plan.target))
        XCTAssertEqual(planner.phase,.aligning)
        let aimed = CGRect(x:plan.zoomAlignmentTarget.x-0.1,y:0.4,width:0.2,height:0.2)
        XCTAssertNil(planner.update(bounds:aimed,confidence:1,roll:0,timestamp:1,currentZoom:1,maximumZoom:3,alignmentTarget:plan.zoomAlignmentTarget,plannedScale:2,zoomDestination:plan.target))
        XCTAssertEqual(planner.update(bounds:aimed,confidence:1,roll:0,timestamp:2,currentZoom:1,maximumZoom:3,alignmentTarget:plan.zoomAlignmentTarget,plannedScale:2,zoomDestination:plan.target),2)
        XCTAssertNotNil(AutomaticShotPlan.make(bounds:aimed,label:"Cat",composition:plan,currentZoom:1,maximumZoom:3,detailLimit:3,nativeStops:[1],regions:[],anatomy:nil,previewAspect:1))
    }
    func testUnstableCameraCannotStartRamp() {
        var planner = FramingPlanner()
        for time in [0.0,1.0,2.0] {
            XCTAssertNil(planner.update(bounds:subject,confidence:1,roll:0,timestamp:time,currentZoom:1,maximumZoom:3,deviceStable:false,plannedScale:2,zoomDestination:.init(x:0.5,y:0.5)))
        }
        XCTAssertEqual(planner.holdProgress,0)
    }
    func testGeometrySupportsContinuousZoomAndMatchesDesiredBounds() throws {
        let plan = try shot(scale:1.65,start:1.3)
        XCTAssertEqual(plan.targetZoom,2.145,accuracy:0.00001)
        XCTAssertEqual(Double(plan.desiredBounds.width/plan.initialBounds.width)*plan.startingZoom,plan.targetZoom,accuracy:0.00001)
        XCTAssertEqual(Double(plan.framingRectangle.width),1/1.65,accuracy:0.00001)
    }
    func testQualityLimitRejectsUnsupportedDigitalCrop() {
        XCTAssertNil(AutomaticShotPlan.make(bounds:subject,label:"Chair",composition:composition(scale:2.3),currentZoom:1,maximumZoom:5,
            detailLimit:1.7,nativeStops:[1,5],regions:[],anatomy:nil,previewAspect:1))
    }
    func testImportantContextCannotBeCroppedOut() {
        XCTAssertNil(AutomaticShotPlan.make(bounds:subject,label:"Cat",composition:composition(),currentZoom:1,maximumZoom:3,
            detailLimit:3,nativeStops:[1],regions:[CGRect(x:0.05,y:0.3,width:0.15,height:0.2)],anatomy:nil,previewAspect:1))
    }
    func testObservedHeadFollowsTrackedSubjectDuringZoom() throws {
        let head = CGRect(x:0.43,y:0.4,width:0.12,height:0.08)
        let plan = try shot(anatomy:.init(face:head,timestamp:0))
        let body = FramingPlanner.zoomedRect(subject,scale:1.5)
        let tracked = try XCTUnwrap(plan.trackedAnatomy(bounds:body,timestamp:1))
        XCTAssertEqual(try XCTUnwrap(tracked.face).width,head.width*1.5,accuracy:0.00001)
        XCTAssertTrue(plan.safeRemainingCrop(bounds:body,zoom:1.5,observedRegions:[]))
    }
    func testSubjectRetentionCompensatesForChangingFieldOfView() throws {
        let plan = try shot(); var planner = ramp(plan)
        for (time,zoom) in [(1.1,1.1),(1.3,1.4),(1.5,1.7)] {
            XCTAssertEqual(planner.verifyShot(bounds:FramingPlanner.zoomedRect(subject,scale:zoom),label:"Cat",confidence:0.9,zoom:zoom,
                stable:true,fresh:true,timestamp:time,previewAspect:1),.continuing)
        }
        XCTAssertFalse(planner.shotVerified)
    }
    func testMotorTargetAloneDoesNotClaimShotReady() throws {
        let plan = try shot(); var planner = ramp(plan)
        XCTAssertEqual(planner.verifyShot(bounds:subject,label:"Cat",confidence:0.9,zoom:2,stable:true,fresh:true,timestamp:2,previewAspect:1),.continuing)
        XCTAssertFalse(planner.shotVerified)
    }
    func testCorrectFramingNeedsTwoFreshObservationsThenLocks() throws {
        let plan = try shot(); var planner = ramp(plan)
        XCTAssertEqual(planner.verifyShot(bounds:plan.desiredBounds,label:"Cat",confidence:0.9,zoom:2,stable:true,fresh:true,timestamp:2,previewAspect:1),.holding)
        XCTAssertEqual(planner.verifyShot(bounds:plan.desiredBounds,label:"Cat",confidence:0.9,zoom:2,stable:true,fresh:true,timestamp:2,previewAspect:1),.holding)
        XCTAssertEqual(planner.verifyShot(bounds:plan.desiredBounds,label:"Cat",confidence:0.9,zoom:2,stable:true,fresh:true,timestamp:2.3,previewAspect:1),.achieved)
        XCTAssertTrue(planner.shotVerified); XCTAssertEqual(planner.phase,.framed)
        XCTAssertNil(planner.update(bounds:subject,confidence:1,roll:0,timestamp:3,currentZoom:2,maximumZoom:4))
    }
    func testAchievedGeometryCannotCompleteBeforeActualTargetZoom() throws {
        let plan = try shot(); var planner = ramp(plan)
        // Geometry alone must not acknowledge a target the device never applied.
        XCTAssertEqual(planner.verifyShot(bounds:plan.desiredBounds,label:"Cat",confidence:0.9,zoom:1.7,stable:true,fresh:true,timestamp:2,previewAspect:1),.continuing)
        XCTAssertFalse(planner.shotVerified)
        XCTAssertEqual(planner.verifyShot(bounds:plan.desiredBounds,label:"Cat",confidence:0.9,zoom:2,stable:true,fresh:true,timestamp:2.3,previewAspect:1),.holding)
        XCTAssertEqual(planner.verifyShot(bounds:plan.desiredBounds,label:"Cat",confidence:0.9,zoom:2,stable:true,fresh:true,timestamp:2.6,previewAspect:1),.achieved)
        XCTAssertTrue(planner.shotVerified)
    }
    func testTrackingLossPausesButIdentityChangeCancelsRamp() throws {
        let plan = try shot(); var planner = ramp(plan)
        XCTAssertEqual(planner.verifyShot(bounds:nil,label:"Cat",confidence:0,zoom:1.5,stable:true,fresh:true,timestamp:2,previewAspect:1),.recovering)
        XCTAssertEqual(planner.verifyShot(bounds:subject,label:"Chair",confidence:0.9,zoom:1.5,stable:true,fresh:true,timestamp:2,previewAspect:1),.cancel)
    }
    func testClippingCancelsButBriefCameraMotionPausesRamp() throws {
        let plan = try shot(); var planner = ramp(plan)
        XCTAssertEqual(planner.verifyShot(bounds:CGRect(x:0.7,y:0.3,width:0.3,height:0.3),label:"Cat",confidence:0.9,zoom:1.5,stable:true,fresh:true,timestamp:2,previewAspect:1),.cancel)
        XCTAssertEqual(planner.verifyShot(bounds:subject,label:"Cat",confidence:0.9,zoom:1.5,stable:false,fresh:true,timestamp:2,previewAspect:1),.recovering)
    }
    func testStaleResultCannotCompleteZoom() throws {
        let plan = try shot(); var planner = ramp(plan)
        XCTAssertEqual(planner.verifyShot(bounds:plan.desiredBounds,label:"Cat",confidence:0.9,zoom:2,stable:true,fresh:false,timestamp:2,previewAspect:1),.recovering)
    }
    func testManualCancellationDiscardsPendingShotVerification() throws {
        let plan = try shot(); var planner = ramp(plan)
        planner.reset(enabled:false)
        XCTAssertNil(planner.shotPlan)
        XCTAssertEqual(planner.verifyShot(bounds:plan.desiredBounds,label:"Cat",confidence:1,zoom:2,stable:true,fresh:true,timestamp:2,previewAspect:1),.cancel)
        XCTAssertNil(planner.update(bounds:subject,confidence:1,roll:0,timestamp:3,currentZoom:1,maximumZoom:3))
    }
    func testAIActivationEpochRejectsOldShotAfterToggle() {
        var activation = GuidanceActivation()
        let first = activation.set(true)
        _ = activation.set(false)
        let next = activation.set(true)
        XCTAssertNotEqual(first,next)
    }
    func testAlreadyGoodCompositionCannotCreateRampPlan() {
        var current = composition(); current.selected.isCurrentFrame = true
        XCTAssertNil(AutomaticShotPlan.make(bounds:subject,label:"Cat",composition:current,currentZoom:1,maximumZoom:3,
            detailLimit:3,nativeStops:[1],regions:[],anatomy:nil,previewAspect:1))
    }
    func testHardwareRateStagesEaseInAndOutWithoutChangingTarget() {
        let stages = [0.0,0.1,0.2,0.5,0.75,0.9,1.0].map { AutomaticZoomRampProfile.stage(progress:$0) }
        XCTAssertEqual(stages,[0,0,1,1,2,2,2])
        let rates = (0...2).map { AutomaticZoomRampProfile.rate(stage:$0,hardwareDistance:2) }
        XCTAssertGreaterThan(rates[1],rates[0]); XCTAssertGreaterThan(rates[1],rates[2])
        XCTAssertTrue(rates.allSatisfy { $0.isFinite && $0 > 0 })
    }
    func testVerifiedShotStopsFurtherTighterCropAdvice() {
        var guidance = AutomaticGuidance()
        let reading = CompositionReading(state:.ready,subjectBounds:CGRect(x:0.3,y:0.3,width:0.4,height:0.4),subjectConfidence:0.9)
        let result = guidance.update(reading:reading,phase:.framed,stable:true,rollReliable:false,autoEnabled:true,zoomAvailable:true,timestamp:2,
            subjectLabel:"Cat",compositionPlan:composition(),shotVerified:true)
        XCTAssertEqual(result.text,"Shot ready"); XCTAssertFalse(result.showsDirection)
    }
    func testCenteredUndersizedShotStartsZoomInsteadOfCompleting() throws {
        var planner = FramingPlanner()
        let plan = try shot()
        for time in [0.0,1.0] {
            let requested = planner.update(bounds:subject,confidence:0.95,roll:0,timestamp:time,currentZoom:1,maximumZoom:4,
                plannedScale:2,zoomDestination:.init(x:0.5,y:0.5),requiresShotPlan:true)
            if time == 1 { XCTAssertEqual(requested,2) }
        }
        planner.commitShot(plan)
        XCTAssertEqual(planner.directorState(hasPlan:true),.autoZooming)
        XCTAssertFalse(ShotReadiness.permitsReady(required:true,shotVerified:planner.shotVerified,currentFrameVerified:planner.currentFrameVerified))
    }
    func testTemporaryZoomGateDoesNotConsumeAlignedShot() {
        var planner = FramingPlanner()
        for time in [0.0,1.0,2.0] {
            XCTAssertNil(planner.update(bounds:subject,confidence:1,roll:0,timestamp:time,currentZoom:1,maximumZoom:4,
                allowZoom:false,plannedScale:2,zoomDestination:.init(x:0.5,y:0.5),requiresShotPlan:true))
            XCTAssertNotEqual(planner.phase,.framed)
        }
        XCTAssertNil(planner.update(bounds:subject,confidence:1,roll:0,timestamp:3,currentZoom:1,maximumZoom:4,
            plannedScale:2,zoomDestination:.init(x:0.5,y:0.5),requiresShotPlan:true))
        XCTAssertEqual(planner.update(bounds:subject,confidence:1,roll:0,timestamp:4,currentZoom:1,maximumZoom:4,
            plannedScale:2,zoomDestination:.init(x:0.5,y:0.5),requiresShotPlan:true),2)
    }
    func testMissingShotCannotCompleteFromStabilityAlone() {
        var planner = FramingPlanner()
        for time in [0.0,1.0,2.0] {
            XCTAssertNil(planner.update(bounds:subject,confidence:1,roll:0,timestamp:time,currentZoom:1,maximumZoom:4,requiresShotPlan:true))
        }
        XCTAssertFalse(planner.currentFrameVerified); XCTAssertNotEqual(planner.directorState(hasPlan:false),.ready)
    }
    func testActualMotorMustStopBeforeFinalVerification() throws {
        let plan = try shot(); var planner = ramp(plan)
        for time in [2.0,2.3] {
            XCTAssertEqual(planner.verifyShot(bounds:plan.desiredBounds,label:"Cat",confidence:1,zoom:2,stable:true,fresh:true,timestamp:time,
                previewAspect:1,cameraRamping:true),.holding)
            XCTAssertFalse(planner.shotVerified); XCTAssertEqual(planner.directorState(hasPlan:true),.verifyingFraming)
        }
        XCTAssertEqual(planner.verifyShot(bounds:plan.desiredBounds,label:"Cat",confidence:1,zoom:2,stable:true,fresh:true,timestamp:2.6,
            previewAspect:1,cameraRamping:false),.holding)
        XCTAssertEqual(planner.verifyShot(bounds:plan.desiredBounds,label:"Cat",confidence:1,zoom:2,stable:true,fresh:true,timestamp:2.9,
            previewAspect:1,cameraRamping:false),.achieved)
    }
    func testStaleCameraTelemetryCannotAcknowledgeAppliedTarget() throws {
        let plan = try shot(); var planner = ramp(plan)
        XCTAssertEqual(planner.verifyShot(bounds:plan.desiredBounds,label:"Cat",confidence:1,zoom:2,stable:true,fresh:true,timestamp:2,
            previewAspect:1,cameraFresh:false),.recovering)
        XCTAssertFalse(planner.shotVerified)
    }
    func testPendingZoomPlanCannotProduceReadyGuidance() {
        var guide = AutomaticGuidance()
        let reading = CompositionReading(state:.ready,subjectBounds:subject,subjectConfidence:0.95)
        for time in [0.0,1.0,2.0] {
            let message = guide.update(reading:reading,phase:.framed,stable:true,rollReliable:false,autoEnabled:true,zoomAvailable:true,
                timestamp:time,subjectLabel:"Cat",compositionPlan:composition(),requireShotCompletion:true)
            XCTAssertNotEqual(message.kind,.ready)
        }
    }
    func testRequestedZoomStillShowsFramingUntilApplied() {
        var guide = AutomaticGuidance()
        let reading = CompositionReading(state:.ready,subjectBounds:subject,subjectConfidence:0.95)
        for phase in [FramingPhase.zooming,.verifying] {
            let message = guide.update(reading:reading,phase:phase,stable:true,rollReliable:false,autoEnabled:true,zoomAvailable:true,
                timestamp:1,subjectLabel:"Cat",compositionPlan:composition(),requireShotCompletion:true)
            XCTAssertEqual(message.kind,.framing); XCTAssertNotEqual(message.reasoningState,.readyToShoot)
        }
    }
    func testAlreadyGoodMeasuredFrameNeedsStableDwell() {
        var planner = FramingPlanner()
        planner.confirmCurrentFrame(eligible:true,timestamp:0,holdDuration:1)
        XCTAssertFalse(planner.currentFrameVerified)
        planner.confirmCurrentFrame(eligible:true,timestamp:1,holdDuration:1)
        XCTAssertTrue(planner.currentFrameVerified); XCTAssertEqual(planner.directorState(hasPlan:true),.ready)
        planner.confirmCurrentFrame(eligible:false,timestamp:1.1,holdDuration:1)
        XCTAssertFalse(planner.currentFrameVerified); XCTAssertEqual(planner.phase,.searching)
    }
    func testSmallSubjectCannotBeDeclaredOptimalByCurrentFrameLabel() {
        var current = composition(scale:1); current.selected.isCurrentFrame = true
        let bounds = CGRect(x:0.45,y:0.45,width:0.1,height:0.1)
        let facts = CompositionAssessment.evaluate(bounds:bounds,confidence:1,label:"Cat",intent:.pet,stable:true,exposure:nil,evidence:nil)
        XCTAssertFalse(ShotReadiness.measuredCurrentFrame(plan:current,assessment:facts,label:"Cat",timestamp:1,stable:true))
        XCTAssertFalse(ShotReadiness.measuredCurrentFrame(plan:nil,assessment:facts,label:"Cat",timestamp:1,stable:true))
    }
    func testGoodMeasuredFrameRejectsStaleOrUnstableDecision() {
        var current = composition(scale:1); current.selected.isCurrentFrame = true
        let bounds = CGRect(x:0.3,y:0.3,width:0.4,height:0.4)
        let facts = CompositionAssessment.evaluate(bounds:bounds,confidence:1,label:"Cat",intent:.pet,stable:true,exposure:nil,evidence:nil)
        XCTAssertTrue(ShotReadiness.measuredCurrentFrame(plan:current,assessment:facts,label:"Cat",timestamp:1,stable:true))
        XCTAssertFalse(ShotReadiness.measuredCurrentFrame(plan:current,assessment:facts,label:"Cat",timestamp:3,stable:true))
        XCTAssertFalse(ShotReadiness.measuredCurrentFrame(plan:current,assessment:facts,label:"Cat",timestamp:1,stable:false))
    }
    func testVirtualCameraZoomUnitsDoNotTreatNativeTwoPointFiveAsDisplayed() throws {
        let sample = CameraZoomObservation(hardwareFactor:2.5,multiplier:2,ramping:false,timestamp:1)
        XCTAssertEqual(sample.displayedFactor,1.25)
        XCTAssertEqual(try XCTUnwrap(CameraZoomObservation.hardwareTarget(displayed:2.5,multiplier:2,minimum:1,maximum:10)),5)
        XCTAssertNil(CameraZoomObservation.hardwareTarget(displayed:6,multiplier:2,minimum:1,maximum:10))
    }
    func testStartingAtDisplayedTwoPointFiveStillSupportsGeometricTarget() throws {
        let plan = try shot(scale:1.35,start:2.5)
        XCTAssertEqual(plan.targetZoom,3.375,accuracy:0.00001)
        XCTAssertTrue(CameraZoomObservation(hardwareFactor:5,multiplier:2,ramping:false,timestamp:1).fresh(at:1.2))
        XCTAssertFalse(CameraZoomObservation(hardwareFactor:5,multiplier:2,ramping:false,timestamp:1).fresh(at:1.5))
    }

    func testUnmeasuredLandscapeCannotBypassReadyGate() {
        var guide = AutomaticGuidance()
        let message = guide.update(reading:.init(),phase:.searching,stable:true,rollReliable:false,autoEnabled:true,zoomAvailable:false,
            timestamp:1,intent:.landscape,requireShotCompletion:true)
        XCTAssertNotEqual(message.reasoningState,.readyToShoot)
    }

}
