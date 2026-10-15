import XCTest
@testable import Focal

final class FramingProgressionTests: XCTestCase {
    private let subject = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
    private func shot() throws -> AutomaticShotPlan {
        let scene = SceneCompositionPlan(selected:.init(technique:.fillFrame,target:.init(x:0.5,y:0.5),crop:CGRect(x:0.25,y:0.25,width:0.5,height:0.5),
            score:0.9,explanation:"Controlled cat fixture",zoomScale:2,measuredImprovement:0.15),alternatives:[],subjectLabel:"Cat",timestamp:0)
        return try XCTUnwrap(AutomaticShotPlan.make(bounds:subject,label:"Cat",composition:scene,currentZoom:1.8,
            maximumZoom:5,detailLimit:4,nativeStops:[1,5],regions:[],anatomy:nil,previewAspect:0.75))
    }
    private func ramp() throws -> (FramingPlanner,AutomaticShotPlan) {
        var p = FramingPlanner(); let shot = try shot()
        _ = step(&p,0); _ = step(&p,1); p.commitShot(shot); return (p,shot)
    }
    private func step(_ p:inout FramingPlanner,_ time:Double,stable:Bool = true,bounds:CGRect? = nil) -> Double? {
        p.update(bounds:bounds ?? subject,confidence:0.95,roll:0,timestamp:time,currentZoom:1.8,maximumZoom:5,
            detailZoomLimit:4,deviceStable:stable,holdDuration:0.75,plannedScale:2,zoomDestination:.init(x:0.5,y:0.5),requiresShotPlan:true)
    }
    private func verify(_ p:inout FramingPlanner,_ shot:AutomaticShotPlan,_ time:Double,zoom:Double = 2.7,
                        stable:Bool = true,confidence:Float = 0.95,ramping:Bool = true) -> FramingPlanner.ShotProgress {
        p.verifyShot(bounds:FramingPlanner.zoomedRect(subject,scale:zoom/1.8),label:shot.subjectLabel,confidence:confidence,zoom:zoom,
            stable:stable,fresh:true,timestamp:time,previewAspect:0.75,cameraRamping:ramping)
    }
    func testHandheldFramingGateAcceptsSmallShakeAndRejectsPanning() {
        XCTAssertTrue(FramingMotionMeasurement(rotation:0.16,acceleration:0.055,age:0.1).stable)
        XCTAssertFalse(FramingMotionMeasurement(rotation:0.6,acceleration:0.01,age:0.1).stable)
        XCTAssertFalse(FramingMotionMeasurement(rotation:0.01,acceleration:0.2,age:0.1).stable)
        XCTAssertFalse(FramingMotionMeasurement(rotation:0,acceleration:0,age:0.8).stable)
        XCTAssertFalse(FramingMotionMeasurement(rotation:.nan,acceleration:0,age:0).stable)
    }
    func testSubjectMovementIsIndependentOfPhoneMotion() {
        XCTAssertTrue(GuidanceObservationPolicy.permitsZoom(stable:true,relativeSpeed:0.16,fresh:true))
        XCTAssertFalse(GuidanceObservationPolicy.permitsZoom(stable:false,relativeSpeed:0,fresh:true))
        XCTAssertFalse(GuidanceObservationPolicy.permitsZoom(stable:true,relativeSpeed:0.5,fresh:true))
        XCTAssertFalse(GuidanceObservationPolicy.permitsZoom(stable:true,relativeSpeed:nil,fresh:true))
    }
    func testBriefPhoneShakePausesHoldCreditWithoutEndlessReset() {
        var p = FramingPlanner()
        for time in [0.0,0.25,0.5] { XCTAssertNil(step(&p,time)) }
        XCTAssertNil(step(&p,0.75,stable:false)); XCTAssertNil(step(&p,1))
        XCTAssertEqual(step(&p,1.25),3.6)
    }
    func testLongCameraMovementNeverForcesUnsafeZoomAndExplainsWait() {
        var p = FramingPlanner()
        for i in 0...24 { XCTAssertNil(step(&p,Double(i)*0.25,stable:false)) }
        XCTAssertEqual(p.blockReason,.cameraMotion)
        XCTAssertEqual(p.progressInstruction,FramingBlockReason.cameraMotion.instruction)
        XCTAssertFalse(p.shotVerified)
    }
    func testAlignedShotStartsOnlyAfterAiming() {
        var p = FramingPlanner()
        XCTAssertNil(step(&p,0,bounds:subject.offsetBy(dx:0.15,dy:0))); XCTAssertEqual(p.phase,.aligning)
        XCTAssertNil(step(&p,1)); XCTAssertEqual(step(&p,2),3.6)
    }
    func testTemporaryTrackingLossPausesAndRecoversSamePlan() throws {
        var (p,s) = try ramp()
        XCTAssertEqual(p.verifyShot(bounds:nil,label:"Cat",confidence:0,zoom:2.7,stable:true,fresh:true,timestamp:1.25,previewAspect:0.75),.recovering)
        XCTAssertEqual(p.shotPlan?.id,s.id)
        XCTAssertEqual(verify(&p,s,1.5),.recovering)
        XCTAssertEqual(verify(&p,s,1.75),.resuming)
        XCTAssertEqual(p.shotPlan?.id,s.id); XCTAssertFalse(p.recovering); XCTAssertFalse(p.shotVerified)
    }
    func testRecoveryExpiresInsteadOfPausingForever() throws {
        var (p,_) = try ramp()
        for time in [1.25,1.5,2.0] {
            XCTAssertEqual(p.verifyShot(bounds:nil,label:"Cat",confidence:0,zoom:2,stable:true,fresh:true,timestamp:time,previewAspect:0.75),.recovering)
        }
        XCTAssertEqual(p.verifyShot(bounds:nil,label:"Cat",confidence:0,zoom:2,stable:true,fresh:true,timestamp:2.75,previewAspect:0.75),.cancel)
        XCTAssertEqual(p.blockReason,.recoveryExpired); XCTAssertFalse(p.shotVerified)
    }
    func testRepeatedBriefLossHasBoundedResumeBudget() throws {
        var (p,s) = try ramp()
        for start in [1.25,2.0] {
            XCTAssertEqual(verify(&p,s,start,stable:false),.recovering)
            XCTAssertEqual(verify(&p,s,start+0.2),.recovering)
            XCTAssertEqual(verify(&p,s,start+0.45),.resuming)
        }
        XCTAssertEqual(verify(&p,s,2.75,stable:false),.cancel)
        XCTAssertEqual(p.blockReason,.recoveryExpired)
    }
    func testWrongIdentityOrUnsafeCropNeverResumes() throws {
        var (p,_) = try ramp()
        XCTAssertEqual(p.verifyShot(bounds:subject,label:"Chair",confidence:1,zoom:2.7,stable:true,fresh:true,timestamp:2,previewAspect:0.75),.cancel)
        XCTAssertEqual(p.blockReason,.tracking)
        XCTAssertEqual(p.verifyShot(bounds:CGRect(x:0.85,y:0.4,width:0.2,height:0.2),label:"Cat",confidence:1,zoom:2.7,stable:true,fresh:true,timestamp:2.25,previewAspect:0.75),.cancel)
        XCTAssertEqual(p.blockReason,.unsafeCrop)
    }
    func testTargetZoomAndStoppedMotorStillNeedFreshCompositionVerification() throws {
        var (p,s) = try ramp()
        XCTAssertEqual(verify(&p,s,2,zoom:3.6),.holding); XCTAssertFalse(p.shotVerified)
        XCTAssertEqual(verify(&p,s,2.25,zoom:3.6,ramping:false),.holding)
        XCTAssertEqual(verify(&p,s,2.5,zoom:3.6,ramping:false),.achieved)
        XCTAssertTrue(p.shotVerified); XCTAssertEqual(p.directorState(hasPlan:true),.ready)
        XCTAssertNil(step(&p,3)); XCTAssertNil(step(&p,4))
    }
    func testInterruptedVerificationRequiresNewContinuousDwell() throws {
        var (p,s) = try ramp()
        XCTAssertEqual(verify(&p,s,2,zoom:3.6,ramping:false),.holding)
        XCTAssertEqual(p.verifyShot(bounds:subject,label:"Cat",confidence:0.95,zoom:3.6,stable:true,fresh:true,timestamp:2.25,previewAspect:0.75),.continuing)
        XCTAssertEqual(verify(&p,s,2.5,zoom:3.6,ramping:false),.holding)
        XCTAssertFalse(p.shotVerified)
        XCTAssertEqual(verify(&p,s,2.75,zoom:3.6,ramping:false),.achieved)
    }
    func testLongAnalysisGapCannotEarnHoldCredit() {
        var p = FramingPlanner()
        XCTAssertNil(step(&p,0)); XCTAssertNil(step(&p,0.5))
        XCTAssertNil(step(&p,4)); XCTAssertNil(step(&p,4.5))
        XCTAssertEqual(step(&p,4.75),3.6)
    }
    func testMotorTargetWithWrongGeometryCannotBeReady() throws {
        var (p,_) = try ramp()
        for time in [2.0,2.25,2.5] {
            let progress = p.verifyShot(bounds:subject,label:"Cat",confidence:0.95,zoom:3.6,stable:true,fresh:true,timestamp:time,previewAspect:0.75,cameraRamping:false)
            XCTAssertNotEqual(progress,.achieved); XCTAssertFalse(p.shotVerified)
        }
    }
    func testFailedZoomCommandGetsSpecificReasonWithoutReady() {
        var watchdog = ZoomProgressWatchdog(); watchdog.start(zoom:3.6,target:7.2,at:0)
        XCTAssertNil(watchdog.failure(actual:3.6,at:0.5,paused:false))
        XCTAssertEqual(watchdog.failure(actual:3.6,at:0.9,paused:false),.zoomNotMoving)
        var p = FramingPlanner(); p.stop(reason:.zoomNotMoving)
        XCTAssertFalse(p.shotVerified); XCTAssertEqual(p.progressInstruction,FramingBlockReason.zoomNotMoving.instruction)
    }
    func testRealMotorMovementAcknowledgedInHardwareUnits() {
        var watchdog = ZoomProgressWatchdog(); watchdog.start(zoom:3.6,target:7.2,at:0)
        XCTAssertNil(watchdog.failure(actual:3.7,at:0.3,paused:false))
        XCTAssertTrue(watchdog.observedMovement)
        XCTAssertNil(watchdog.failure(actual:5,at:1,paused:false))
        let observation = CameraZoomObservation(hardwareFactor:5.4,multiplier:2,ramping:true,timestamp:1)
        XCTAssertEqual(observation.displayedFactor,2.7)
        XCTAssertEqual(CameraZoomObservation.hardwareTarget(displayed:3.6,multiplier:2,minimum:1,maximum:10),7.2)
    }
    func testPinchAndAIOffDiscardPlanAndDoNotAutomaticallyRearm() throws {
        for reason in [FramingBlockReason.manualControl,.disabled] {
            var (p,s) = try ramp(); p.stop(reason:reason)
            XCTAssertNil(p.shotPlan); XCTAssertFalse(p.shotVerified)
            XCTAssertNil(step(&p,3)); XCTAssertNotEqual(verify(&p,s,4),.achieved)
        }
    }
    func testAlreadyGoodMeasuredFrameDoesNotRequestAnotherZoom() {
        var p = FramingPlanner()
        p.noteBlock(.quality,at:0) // A prior planning gate must not mask a later measured good frame.
        p.confirmCurrentFrame(eligible:true,timestamp:0,holdDuration:0.75)
        p.confirmCurrentFrame(eligible:true,timestamp:1,holdDuration:0.75)
        XCTAssertTrue(p.currentFrameVerified); XCTAssertEqual(p.directorState(hasPlan:true),.ready)
        XCTAssertNil(step(&p,2)); XCTAssertNil(p.progressInstruction)
    }
    func testUserShutterPairsOnlyVerifiedFinalZoom() throws {
        var (p,s) = try ramp(); var capture = ShotCaptureSession()
        capture.select(s,preview:.init(data:Data([1,2,3]),pixelWidth:900,pixelHeight:1200,observedAt:Date(timeIntervalSince1970:1)))
        XCTAssertNil(capture.userCapture(at:1.2,guidanceEnabled:true))
        _ = verify(&p,s,2,zoom:3.6,ramping:false); _ = verify(&p,s,2.25,zoom:3.6,ramping:false)
        capture.observe(plan:p.shotPlan,verified:p.shotVerified,bounds:s.desiredBounds,label:"Cat",confidence:0.95,zoom:3.6,stable:true,timestamp:2.25,aspect:0.75)
        let payload = try XCTUnwrap(capture.userCapture(at:2.3,guidanceEnabled:true))
        XCTAssertTrue(payload.matchesCamera(zoom:3.6,enabled:true,ramping:false))
        XCTAssertFalse(payload.matchesCamera(zoom:1.8,enabled:true,ramping:false))
        XCTAssertFalse(payload.matchesCamera(zoom:3.6,enabled:true,ramping:true))
        XCTAssertNotNil(payload.widePreview)
    }
    func testMirroredFrontPreviewKeepsPhysicalPanDirectionCorrect() throws {
        let imageRect = CGRect(x:0.65,y:0.4,width:0.1,height:0.2)
        for mirrored in [false,true] {
            let projection = PreviewProjection(imageAspect:0.75,previewAspect:0.75,mirrored:mirrored)
            let reading = CompositionReading(subjectBounds:projection.visibleRect(imageRect),subjectConfidence:1,target:.init(x:0.5,y:0.5),mirrored:mirrored)
            let cue = try XCTUnwrap(CompositionCue(reading:reading,previewAspect:0.75))
            XCTAssertEqual(cue.direction,"right")
            // Panning right reduces sensor x; mirror changes display x only.
            let after = projection.visibleRect(imageRect.offsetBy(dx:-0.1,dy:0))
            XCTAssertLessThan(abs(after.midX-0.5),abs((reading.subjectBounds?.midX ?? 0)-0.5))
        }
    }
    func testGeometryBasedAimingDirectionsUseTopLeftPreviewCoordinates() throws {
        for (offset,direction) in [(CGPoint(x:0.1,y:0),"right"),(CGPoint(x:-0.1,y:0),"left"),(CGPoint(x:0,y:0.1),"down"),(CGPoint(x:0,y:-0.1),"up")] {
            let reading = CompositionReading(subjectBounds:subject.offsetBy(dx:offset.x,dy:offset.y),subjectConfidence:1,target:.init(x:0.5,y:0.5))
            XCTAssertEqual(try XCTUnwrap(CompositionCue(reading:reading,previewAspect:0.75)).direction,direction)
        }
        let projection = PreviewProjection(imageAspect:1,previewAspect:0.75)
        let visible = projection.visibleRect(CGRect(x:0.6,y:0.4,width:0.2,height:0.2))
        let reading = CompositionReading(subjectBounds:visible,subjectConfidence:1,target:.init(x:0.5,y:0.5))
        XCTAssertEqual(try XCTUnwrap(CompositionCue(reading:reading,previewAspect:0.75)).direction,"right")
    }
}
