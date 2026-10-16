import XCTest
@testable import Focal

/// Controlled director inputs derived from the failure sequence visible in the
/// 15:06:58 recording. Motion values/zoom telemetry are fixtures, not measurements
/// extracted from the video and not proof of AVFoundation hardware execution.
final class ContinuousFramingRecoveryTests: XCTestCase {
    private let box = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
    private func shot() throws -> AutomaticShotPlan {
        let scene = SceneCompositionPlan(selected:.init(technique:.fillFrame,target:.init(x:0.5,y:0.5),
            crop:CGRect(x:0.25,y:0.25,width:0.5,height:0.5),score:0.9,explanation:"Controlled tighter portrait",
            zoomScale:2,measuredImprovement:0.2),alternatives:[],subjectLabel:"Person",timestamp:0)
        return try XCTUnwrap(AutomaticShotPlan.propose(bounds:box,label:"Person",confidence:0.95,trackingReference:"person-A",
            composition:scene,currentZoom:1.1,maximumZoom:5,detailLimit:3,nativeStops:[1,5],regions:[],anatomy:nil,
            projection:.init(imageAspect:0.75,previewAspect:0.75)))
    }
    private func selected() throws -> FramingPlanner {
        var p = FramingPlanner(continuousRecovery:true)
        XCTAssertTrue(p.selectShot(try shot())); return p
    }
    @discardableResult private func aim(_ p:inout FramingPlanner,_ time:Double,zoom:Double = 1.1,bounds:CGRect? = nil,motion:Bool = true) -> Double? {
        let b = bounds ?? box, s = p.shotPlan
        return p.update(bounds:b,confidence:0.95,roll:8,timestamp:time,currentZoom:zoom,maximumZoom:5,
            detailZoomLimit:3,deviceStable:motion,holdDuration:3,alignmentTarget:s?.aimingTarget(bounds:b) ?? .init(x:0.5,y:0.5),
            plannedScale:s?.scaleForCurrentBounds(b),zoomDestination:s?.desiredPosition,requiresShotPlan:true,startConfirmationDuration:0.2)
    }
    @discardableResult private func verify(_ p:inout FramingPlanner,_ time:Double,zoom:Double = 2.2,bounds:CGRect? = nil,
                                          reference:String = "person-A",captureStable:Bool = true,ramping:Bool = false) -> FramingPlanner.ShotProgress {
        p.verifyShot(bounds:bounds ?? FramingPlanner.zoomedRect(box,scale:zoom/1.1),label:"Person",confidence:0.95,zoom:zoom,
            stable:true,fresh:true,timestamp:time,previewAspect:0.75,cameraRamping:ramping,captureStable:captureStable,
            trackingReference:reference,captureHoldDuration:0.5,liveZoom:zoom)
    }
    private func advance(_ p:inout FramingPlanner,_ time:Double,bounds:CGRect?,zoom:Double = 1.1,reference:String = "person-A",motion:Bool = true) -> FramingPlanner.RecoveryStep {
        p.advanceRecovery(bounds:bounds,label:"Person",trackingReference:reference,confidence:bounds == nil ? 0 : 0.95,
            zoom:zoom,aspect:0.75,fresh:true,motionPermitted:motion,timestamp:time)
    }
    func testAlignedPersonStartsImmediatelyWithoutCaptureHoldOrLevelGate() throws {
        var p = try selected()
        XCTAssertEqual(aim(&p,0),2.2)
        XCTAssertEqual(p.phase,.zooming); XCTAssertFalse(p.shotVerified)
    }
    func testAimMustBeCorrectBeforeZoom() throws {
        var p = try selected()
        XCTAssertNil(aim(&p,0,bounds:box.offsetBy(dx:0.1,dy:0)))
        XCTAssertEqual(p.phase,.aligning); XCTAssertEqual(aim(&p,0.3),2.2)
    }
    func testHandheldMotionPermitsFramingButFastPanStillBlocksMotor() throws {
        let m = FramingMotionMeasurement(rotation:0.5,acceleration:0.15,age:0.1)
        XCTAssertTrue(m.permitsFraming); XCTAssertFalse(m.stable)
        XCTAssertFalse(CameraStability.isStable(rotation:(0.5,0,0),acceleration:(0.15,0,0)))
        XCTAssertFalse(FramingMotionMeasurement(rotation:1.2,acceleration:0.1,age:0.1).permitsFraming)
        XCTAssertFalse(FramingMotionMeasurement(rotation:0,acceleration:0,age:1).permitsFraming)
        var p = try selected(); XCTAssertNil(aim(&p,0,motion:false)); XCTAssertEqual(aim(&p,0.2,motion:m.permitsFraming),2.2)
    }
    func testSmallSubjectMovementDuringRampRetainsPlanAndTarget() throws {
        var p = try selected(); aim(&p,0); let id = p.shotPlan?.id
        let moving = FramingPlanner.zoomedRect(box,scale:1.5/1.1).offsetBy(dx:0.025,dy:0.01)
        XCTAssertEqual(verify(&p,0.4,zoom:1.5,bounds:moving,ramping:true),.continuing)
        XCTAssertEqual(p.shotPlan?.id,id); XCTAssertEqual(p.shotPlan?.targetZoom,2.2)
        XCTAssertEqual(p.retryCount,0)
    }
    func testInterruptedRampReaimsFromMeasuredZoomAndKeepsIdentity() throws {
        var p = try selected(); aim(&p,0); let id = p.shotPlan?.id
        p.requestRecovery(reason:.interrupted,at:1)
        let measured = FramingPlanner.zoomedRect(box,scale:1.5/1.1)
        XCTAssertEqual(advance(&p,1.2,bounds:measured,zoom:1.5),.waiting)
        XCTAssertEqual(advance(&p,1.5,bounds:measured,zoom:1.5),.aiming)
        XCTAssertEqual(try XCTUnwrap(aim(&p,1.6,zoom:1.5,bounds:measured)),2.2,accuracy:0.001)
        let plan = try XCTUnwrap(p.shotPlan?.prepared(bounds:measured,zoom:1.5,detailLimit:3,nativeStops:[],regions:[],anatomy:nil,aspect:0.75,allowSmallCorrection:true))
        XCTAssertEqual(plan.id,id); XCTAssertEqual(plan.startingZoom,1.5)
        XCTAssertEqual(plan.targetZoom,2.2,accuracy:0.001)
        print("CONTROLLED_RECOVERY interrupted -> backoff(0.4s) -> AIMING -> AUTO_ZOOMING; fixture actualZoom=1.5 computed target=\(plan.targetZoom) sameShot=\(plan.id == id) READY=\(p.shotVerified); no hardware adapter executed")
    }
    func testPreparationTimeoutRecoversRatherThanTurningOff() throws {
        var p = try selected(); XCTAssertNil(aim(&p,0,motion:false)); XCTAssertNil(aim(&p,8.1,motion:false))
        XCTAssertEqual(p.phase,.recoveringZoom); XCTAssertFalse(p.shotVerified)
        XCTAssertEqual(advance(&p,8.6,bounds:box),.aiming)
        XCTAssertEqual(aim(&p,8.7),2.2)
    }
    func testZoomWatchdogFailureSchedulesRetryWithoutManualReset() throws {
        var p = try selected(); aim(&p,0)
        for reason in [FramingBlockReason.deadline,.zoomNotMoving,.configuration] {
            p.requestRecovery(reason:reason,at:1+Double(p.retryCount)*3)
            let due = try XCTUnwrap(p.retryAt)
            XCTAssertEqual(advance(&p,due+0.01,bounds:box),.aiming)
            XCTAssertNotEqual(p.phase,.off); aim(&p,due+0.1)
        }
        XCTAssertEqual(p.retryCount,3)
    }
    func testLostSubjectGetsGraceThenAutomaticRediscovery() throws {
        var p = try selected(); aim(&p,0)
        XCTAssertEqual(p.verifyShot(bounds:nil,label:"Person",confidence:0,zoom:1.4,stable:true,fresh:true,timestamp:1,
            previewAspect:0.75,trackingReference:"person-A"),.recovering)
        let old = p.shotPlan?.id
        XCTAssertEqual(p.phase,.reacquiring); XCTAssertEqual(advance(&p,2,bounds:nil),.waiting)
        XCTAssertEqual(p.shotPlan?.id,old); XCTAssertFalse(p.selectShot(try shot()))
        XCTAssertEqual(advance(&p,2.6,bounds:nil),.waiting); XCTAssertEqual(p.phase,.rediscovering)
        XCTAssertNil(p.shotPlan); XCTAssertEqual(advance(&p,4.5,bounds:nil),.waiting)
        XCTAssertEqual(advance(&p,4.7,bounds:nil),.rediscovered); XCTAssertEqual(p.phase,.searching)
        XCTAssertTrue(p.selectShot(try shot()))
    }
    func testBriefLossReacquiresSameSubjectWithoutNewShot() throws {
        var p = try selected(); aim(&p,0); let id = p.shotPlan?.id
        p.requestRecovery(reason:.tracking,at:1)
        XCTAssertEqual(advance(&p,1.5,bounds:box),.aiming)
        XCTAssertEqual(p.shotPlan?.id,id); XCTAssertEqual(aim(&p,1.6),2.2)
    }
    func testSameNamedDifferentPersonCannotResumeOldRamp() throws {
        var p = try selected(); aim(&p,0)
        XCTAssertEqual(verify(&p,1,zoom:1.5,reference:"person-B"),.recovering)
        XCTAssertEqual(advance(&p,1.5,bounds:box,reference:"person-B"),.waiting)
        XCTAssertEqual(advance(&p,2.6,bounds:box,reference:"person-B"),.waiting)
        XCTAssertEqual(p.phase,.rediscovering); XCTAssertNil(p.shotPlan)
    }
    func testContinuousUseForSeveralMinutesKeepsDiscoveringAfterFailedAttempts() throws {
        var p = try selected()
        for i in 0..<40 {
            let t = Double(i)*6
            aim(&p,t); p.requestRecovery(reason:.tracking,at:t+0.2)
            _ = advance(&p,t+1.8,bounds:nil); XCTAssertEqual(p.phase,.rediscovering)
            XCTAssertEqual(advance(&p,t+4,bounds:nil),.rediscovered)
            XCTAssertTrue(p.selectShot(try shot())); XCTAssertEqual(p.retryCount,0)
            XCTAssertNotEqual(p.phase,.off)
        }
    }
    func testConsecutiveCompletedShotsDoNotLeaveStaleReadyOrPlan() throws {
        var p = try selected(); var ids = Set<String>()
        for i in 0..<5 {
            let t = Double(i)*7; ids.insert(try XCTUnwrap(p.shotPlan?.id))
            aim(&p,t); _ = verify(&p,t+0.5); XCTAssertEqual(verify(&p,t+1.1),.achieved)
            p.revalidateCompletedShot(bounds:nil,label:"Person",confidence:0,zoom:2.2,aspect:0.75,timestamp:t+1.2,trackingReference:"person-A")
            XCTAssertFalse(p.shotVerified); _ = advance(&p,t+2.8,bounds:nil)
            XCTAssertEqual(advance(&p,t+5,bounds:nil),.rediscovered)
            XCTAssertTrue(p.selectShot(try shot()))
        }
        XCTAssertEqual(ids.count,5)
    }
    func testManualPinchPreventsAnyAutomaticRecoveryOrRediscovery() throws {
        var p = try selected(); aim(&p,0); p.stop(reason:.manualControl)
        p.requestRecovery(reason:.deadline,at:1)
        XCTAssertEqual(advance(&p,100,bounds:box),.waiting)
        XCTAssertEqual(p.phase,.off); XCTAssertNil(aim(&p,101)); XCTAssertFalse(p.selectShot(try shot()))
    }
    func testAIOffCancelsPlanAndAllFutureAutomaticProgress() throws {
        var p = try selected(); aim(&p,0); p.requestRecovery(reason:.disabled,at:1)
        XCTAssertEqual(p.phase,.off); XCTAssertNil(p.shotPlan)
        XCTAssertEqual(advance(&p,100,bounds:box),.waiting); XCTAssertNil(aim(&p,101))
    }
    func testReadyNeedsActualZoomStoppedMotorCorrectGeometryAndCaptureDwell() throws {
        var p = try selected(); aim(&p,0)
        for t in [0.2,0.5] { XCTAssertNotEqual(verify(&p,t,zoom:1.1,bounds:box),.achieved) }
        XCTAssertEqual(verify(&p,0.7,ramping:true),.holding)
        XCTAssertEqual(verify(&p,1,captureStable:false),.holding); XCTAssertFalse(p.shotVerified)
        XCTAssertEqual(verify(&p,1.5),.holding); XCTAssertEqual(verify(&p,2.1),.achieved)
        XCTAssertTrue(p.shotVerified); XCTAssertNil(aim(&p,2.5))
    }
    func testAlreadyCorrectFrameCanBeReadyWithoutRequestingZoom() {
        var p = FramingPlanner(continuousRecovery:true)
        p.confirmCurrentFrame(eligible:true,timestamp:0,holdDuration:0.5)
        p.confirmCurrentFrame(eligible:true,timestamp:0.6,holdDuration:0.5)
        XCTAssertTrue(p.currentFrameVerified); XCTAssertEqual(p.directorState(hasPlan:true),.ready)
        XCTAssertNil(aim(&p,1)); XCTAssertNil(p.shotPlan)
    }
    func testReadyInvalidationReaimsAutomaticallyAndDoesNotHuntZoom() throws {
        var p = try selected(); aim(&p,0); _ = verify(&p,1); _ = verify(&p,1.6)
        let id = p.shotPlan?.id
        for t in [2.0,3,4] {
            p.revalidateCompletedShot(bounds:p.shotPlan?.desiredBounds,label:"Person",confidence:0.95,zoom:2.2,aspect:0.75,timestamp:t,trackingReference:"person-A")
            XCTAssertTrue(p.shotVerified); XCTAssertNil(aim(&p,t+0.1))
        }
        let moved = FramingPlanner.zoomedRect(box,scale:1.9/1.1).offsetBy(dx:0.06,dy:0)
        p.revalidateCompletedShot(bounds:moved,label:"Person",confidence:0.95,zoom:1.9,aspect:0.75,timestamp:5,trackingReference:"person-A")
        XCTAssertFalse(p.shotVerified); XCTAssertEqual(p.phase,.reacquiring)
        XCTAssertEqual(advance(&p,5.5,bounds:moved,zoom:1.9),.aiming); XCTAssertEqual(p.shotPlan?.id,id)
    }
    func testRetryLimitAndBackoffCannotSpinOrDisableAI() throws {
        var p = try selected(); aim(&p,0)
        for (i,delay) in [0.4,0.9,1.8].enumerated() {
            let t = Double(i)*4+1
            p.requestRecovery(reason:.interrupted,at:t)
            XCTAssertEqual(try XCTUnwrap(p.retryAt),t+delay,accuracy:0.001)
            p.requestRecovery(reason:.staleFrame,at:t+0.1)
            XCTAssertEqual(p.retryCount,i+1)
            XCTAssertEqual(advance(&p,t+delay-0.01,bounds:box),.waiting)
            XCTAssertEqual(advance(&p,t+delay+0.01,bounds:box),.aiming); aim(&p,t+delay+0.1)
        }
        p.requestRecovery(reason:.deadline,at:14)
        XCTAssertEqual(p.phase,.rediscovering); XCTAssertEqual(advance(&p,15.9,bounds:box),.waiting)
        XCTAssertEqual(advance(&p,16.1,bounds:box),.rediscovered); XCTAssertEqual(p.phase,.searching)
    }
    func testReadyPositionShiftReaimsAtSameZoomWithoutDiscardingComposition() throws {
        var p = try selected(); aim(&p,0); _ = verify(&p,1); _ = verify(&p,1.6)
        let id = p.shotPlan?.id, desired = try XCTUnwrap(p.shotPlan?.desiredBounds)
        let moved = desired.offsetBy(dx:0.08,dy:0)
        p.revalidateCompletedShot(bounds:moved,label:"Person",confidence:0.95,zoom:2.2,aspect:0.75,timestamp:2,trackingReference:"person-A")
        XCTAssertEqual(advance(&p,2.5,bounds:moved,zoom:2.2),.aiming)
        XCTAssertEqual(p.shotPlan?.id,id); XCTAssertNil(aim(&p,2.6,zoom:2.2,bounds:moved))
        XCTAssertFalse(p.verifyExistingTargetIfAligned(bounds:moved,label:"Person",confidence:0.95,zoom:2.2,aspect:0.75,
            trackingReference:"person-A",fresh:true,motionPermitted:true))
        XCTAssertTrue(p.verifyExistingTargetIfAligned(bounds:desired,label:"Person",confidence:0.95,zoom:2.2,aspect:0.75,
            trackingReference:"person-A",fresh:true,motionPermitted:true))
        XCTAssertEqual(p.phase,.verifying); XCTAssertFalse(p.shotVerified)
        XCTAssertEqual(verify(&p,3),.holding); XCTAssertEqual(verify(&p,3.6),.achieved)
        XCTAssertEqual(p.shotPlan?.id,id)
    }
    func testUnrecoveredRapidMotionHasTimedExitToDiscovery() throws {
        var p = try selected(); aim(&p,0); p.requestRecovery(reason:.cameraMotion,at:1)
        XCTAssertEqual(advance(&p,4,bounds:box,motion:false),.waiting)
        XCTAssertEqual(advance(&p,5.1,bounds:box,motion:false),.waiting)
        XCTAssertEqual(p.phase,.rediscovering); XCTAssertEqual(advance(&p,7.2,bounds:box),.rediscovered)
    }
    func testAtTargetRecoveryVerifiesWithoutAnotherZoomOrFakeCompletion() throws {
        var p = try selected(); aim(&p,0); p.requestRecovery(reason:.deadline,at:1)
        XCTAssertEqual(advance(&p,1.5,bounds:p.shotPlan?.desiredBounds,zoom:2.2),.verifying)
        XCTAssertFalse(p.shotVerified); XCTAssertNil(aim(&p,1.6))
        XCTAssertEqual(verify(&p,2),.holding); XCTAssertEqual(verify(&p,2.6),.achieved)
    }
    func testFineRemainingZoomCanResumeWithoutLosingRequiredFramingContract() throws {
        let original = try shot(), measured = FramingPlanner.zoomedRect(box,scale:2.08/1.1)
        let retry = try XCTUnwrap(original.prepared(bounds:measured,zoom:2.08,detailLimit:3,nativeStops:[],regions:[],anatomy:nil,aspect:0.75,allowSmallCorrection:true))
        XCTAssertTrue(retry.requiresZoom); XCTAssertEqual(retry.id,original.id)
        XCTAssertEqual(retry.targetZoom,2.2,accuracy:0.001); XCTAssertLessThan(retry.desiredScale,1.12)
    }
    func testRecoveryCannotZoomThroughClippedHeadOrBody() throws {
        var p = try selected(); aim(&p,0)
        XCTAssertEqual(verify(&p,1,zoom:1.5,bounds:CGRect(x:0.8,y:0.3,width:0.3,height:0.4)),.recovering)
        XCTAssertEqual(p.phase,.reacquiring); XCTAssertFalse(p.shotVerified)
        XCTAssertNil(aim(&p,1.1)); XCTAssertFalse(p.selectShot(try shot()))
    }
    func testRecoveryMessagesDoNotReintroduceHoldSteadyStage() {
        for phase in [FramingPhase.reacquiring,.recoveringZoom,.rediscovering,.zooming,.verifying] {
            var guidance = AutomaticGuidance()
            let message = guidance.update(reading:.init(),phase:phase,stable:false,rollReliable:true,autoEnabled:true,zoomAvailable:true,
                timestamp:1,requireShotCompletion:true,continuousFraming:true)
            XCTAssertEqual(message.kind,.framing)
            XCTAssertFalse(message.text.lowercased().contains("hold steady"))
            XCTAssertFalse(message.text.contains("paused"))
        }
    }
    func testPairedSavingKeepsOriginalWideAcrossRetryButRequiresFreshVerification() throws {
        let original = try shot(); var photos = ShotCaptureSession()
        let wide = WideScenePreview(data:Data([1]),pixelWidth:900,pixelHeight:1200,observedAt:Date(timeIntervalSince1970:1))
        photos.select(original,preview:wide); photos.invalidateVerification()
        let measured = FramingPlanner.zoomedRect(box,scale:1.5/1.1)
        let retry = try XCTUnwrap(original.prepared(bounds:measured,zoom:1.5,detailLimit:3,nativeStops:[],regions:[],anatomy:nil,aspect:0.75,allowSmallCorrection:true))
        photos.select(retry,preview:.init(data:Data([2]),pixelWidth:900,pixelHeight:1200,observedAt:Date(timeIntervalSince1970:2)))
        XCTAssertNil(photos.userCapture(at:2,guidanceEnabled:true))
        photos.observe(plan:retry,verified:true,bounds:retry.desiredBounds,label:"Person",confidence:0.95,zoom:retry.targetZoom,stable:true,timestamp:3,aspect:0.75)
        XCTAssertEqual(photos.userCapture(at:3.1,guidanceEnabled:true)?.widePreview?.data,wide.data)
        XCTAssertEqual(photos.userCapture(at:3.1,guidanceEnabled:true)?.metadata.startingZoom,original.startingZoom)
    }
}


/// Phase 1 regressions use production policies; no camera or shutter is simulated.
extension ContinuousFramingRecoveryTests {
    func testReadyDwellDoesNotCreditMissingObservations() {
        var p = FramingPlanner(continuousRecovery:true)
        p.confirmCurrentFrame(eligible:true,timestamp:0,holdDuration:0.5)
        p.confirmCurrentFrame(eligible:true,timestamp:10,holdDuration:0.5)
        XCTAssertFalse(p.currentFrameVerified)
        p.confirmCurrentFrame(eligible:true,timestamp:10.3,holdDuration:0.5)
        p.confirmCurrentFrame(eligible:true,timestamp:10.6,holdDuration:0.5)
        XCTAssertTrue(p.currentFrameVerified)
    }
    func testReadyContinuityRejectsSameLabelReplacement() {
        var p = ReadyContinuity()
        XCTAssertFalse(p.update(eligible:true,retaining:true,identity:"cat-A",timestamp:0,hold:0.5))
        XCTAssertTrue(p.update(eligible:true,retaining:true,identity:"cat-A",timestamp:0.6,hold:0.5))
        XCTAssertFalse(p.update(eligible:true,retaining:true,identity:"cat-B",timestamp:0.7,hold:0.5))
    }
    func testReadyRetentionNeedsGoodGeometryButNotNewEntryDwell() {
        var p = ReadyContinuity()
        _ = p.update(eligible:true,retaining:true,identity:"A",timestamp:0,hold:0.5)
        XCTAssertTrue(p.update(eligible:true,retaining:true,identity:"A",timestamp:0.6,hold:0.5))
        XCTAssertTrue(p.update(eligible:false,retaining:true,identity:"A",timestamp:0.8,hold:0.5))
        XCTAssertFalse(p.update(eligible:false,retaining:false,identity:"A",timestamp:1,hold:0.5))
        XCTAssertFalse(p.update(eligible:false,retaining:true,identity:"A",timestamp:1.2,hold:0.5))
    }
    func testReadyExpiresAndReacquiresWithoutDisablingDirector() {
        var p = FramingPlanner(continuousRecovery:true)
        p.confirmCurrentFrame(eligible:true,timestamp:0,holdDuration:0.5)
        p.confirmCurrentFrame(eligible:true,timestamp:0.6,holdDuration:0.5)
        p.expireReadiness(at:1)
        XCTAssertTrue(p.currentFrameVerified)
        p.expireReadiness(at:1.51)
        XCTAssertFalse(p.currentFrameVerified); XCTAssertEqual(p.phase,.searching)
        p.confirmCurrentFrame(eligible:true,timestamp:2,holdDuration:0.5)
        p.confirmCurrentFrame(eligible:true,timestamp:2.6,holdDuration:0.5)
        XCTAssertTrue(p.currentFrameVerified)
    }
    func testSubjectLossImmediatelyInvalidatesCurrentFrameReady() {
        var p = FramingPlanner(continuousRecovery:true)
        p.confirmCurrentFrame(eligible:true,timestamp:0,holdDuration:0.5)
        p.confirmCurrentFrame(eligible:true,timestamp:0.6,holdDuration:0.5)
        p.confirmCurrentFrame(eligible:false,timestamp:0.7,holdDuration:0.5)
        XCTAssertFalse(p.currentFrameVerified); XCTAssertNotEqual(p.phase,.off)
    }
    func testReadyDwellCannotAdvanceOnDuplicateOrBackwardsTime() {
        for t in [0.0,-1.0,Double.nan] {
            var p = ReadyContinuity()
            _ = p.update(eligible:true,retaining:true,identity:"A",timestamp:0,hold:0.5)
            XCTAssertFalse(p.update(eligible:true,retaining:true,identity:"A",timestamp:t,hold:0.5))
        }
    }
    func testCompletedZoomExpiryKeepsPlanAndEntersRecovery() throws {
        var p = try selected(); aim(&p,0)
        XCTAssertEqual(verify(&p,0.2),.holding)
        XCTAssertEqual(verify(&p,0.8),.achieved)
        let id = p.shotPlan?.id
        p.recordReadyEvidence(at:0.8); p.expireReadiness(at:1.71)
        XCTAssertFalse(p.shotVerified); XCTAssertTrue(p.phase.isRecovering)
        XCTAssertEqual(p.shotPlan?.id,id)
    }
    func testFinalZoomDwellCannotSpanStaleGap() throws {
        var p = try selected(); aim(&p,0)
        XCTAssertEqual(verify(&p,0.2),.holding)
        XCTAssertEqual(verify(&p,2),.holding)
        XCTAssertFalse(p.shotVerified)
        XCTAssertEqual(verify(&p,2.6),.achieved)
    }
    func testManualThirdsCompletesAtEverySelectedCornerWithoutZoomPlan() {
        for target in CompositionEngine.thirdsTargets {
            let b = CGRect(x:target.x-0.15,y:target.y-0.15,width:0.3,height:0.3)
            let a = CompositionAssessment.evaluate(bounds:b,confidence:0.95,label:"Person",intent:.portrait,stable:true,exposure:nil,evidence:nil)
            let eligible = ShotReadiness.measuredManualFrame(mode:.thirds,bounds:b,target:target,roll:0,aspect:0.75,assessment:a,stable:true)
            XCTAssertTrue(eligible)
            var p = FramingPlanner(continuousRecovery:true)
            p.confirmCurrentFrame(eligible:eligible,timestamp:0,holdDuration:0.5)
            p.confirmCurrentFrame(eligible:eligible,timestamp:0.6,holdDuration:0.5)
            XCTAssertTrue(p.currentFrameVerified); XCTAssertEqual(p.phase,.framed); XCTAssertNil(p.shotPlan)
        }
    }
    func testManualCenterVerifiesWithoutAutomaticZoomPermission() {
        let b = CGRect(x:0.35,y:0.35,width:0.3,height:0.3)
        let a = CompositionAssessment.evaluate(bounds:b,confidence:0.95,label:"Person",intent:.portrait,stable:true,exposure:nil,evidence:nil)
        XCTAssertTrue(ShotReadiness.measuredManualFrame(mode:.centered,bounds:b,target:.init(x:0.5,y:0.5),roll:0,aspect:0.75,assessment:a,stable:true))
        XCTAssertFalse(ShotReadiness.measuredManualFrame(mode:.automatic,bounds:b,target:.init(x:0.5,y:0.5),roll:0,aspect:0.75,assessment:a,stable:true))
    }
    func testManualCompletionRejectsLossWeakEvidenceMotionAndWrongTarget() {
        let b = CGRect(x:0.35,y:0.35,width:0.3,height:0.3)
        var a = CompositionAssessment.evaluate(bounds:b,confidence:0.95,label:"Person",intent:.portrait,stable:true,exposure:nil,evidence:nil)
        func eligible(_ bounds:CGRect?,_ target:UnitPoint2D,_ stable:Bool) -> Bool {
            ShotReadiness.measuredManualFrame(mode:.thirds,bounds:bounds,target:target,roll:0,aspect:0.75,assessment:a,stable:stable)
        }
        XCTAssertFalse(eligible(nil,.init(x:0.5,y:0.5),true))
        XCTAssertFalse(eligible(b,.init(x:1.0/3,y:1.0/3),true))
        XCTAssertFalse(eligible(b,.init(x:0.5,y:0.5),false))
        a.confidence = 0.64
        XCTAssertFalse(eligible(b,.init(x:0.5,y:0.5),true))
        a.confidence = 0.95; a.edgeJointCount = 1
        XCTAssertFalse(eligible(b,.init(x:0.5,y:0.5),true))
    }
    func testManualReadyRetainsOnlyWithinExitTolerance() {
        let b = CGRect(x:0.422,y:0.35,width:0.3,height:0.3)
        let a = CompositionAssessment.evaluate(bounds:b,confidence:0.95,label:"Person",intent:.portrait,stable:true,exposure:nil,evidence:nil)
        XCTAssertFalse(ShotReadiness.measuredManualFrame(mode:.thirds,bounds:b,target:.init(x:0.5,y:0.5),roll:4.5,aspect:0.75,assessment:a,stable:true))
        XCTAssertTrue(ShotReadiness.measuredManualFrame(mode:.thirds,bounds:b,target:.init(x:0.5,y:0.5),roll:4.5,aspect:0.75,assessment:a,stable:true,retaining:true))
        XCTAssertFalse(ShotReadiness.measuredManualFrame(mode:.thirds,bounds:b.offsetBy(dx:0.03,dy:0),target:.init(x:0.5,y:0.5),roll:4.5,aspect:0.75,assessment:a,stable:true,retaining:true))
    }
    func testAlignmentEngineRetainsReadyThroughSmallVariation() {
        var e = CompositionEngine()
        for t in [0.0,0.3,0.7] { _ = e.update(subject:.init(x:0.5,y:0.5),rollDegrees:0,mode:.centered,timestamp:t) }
        let r = e.update(subject:.init(x:0.57,y:0.5),rollDegrees:4.5,mode:.centered,timestamp:0.9)
        XCTAssertEqual(r.state,.ready)
        XCTAssertEqual(e.update(subject:.init(x:0.7,y:0.5),rollDegrees:0,mode:.centered,timestamp:1.1).state,.adjusting)
    }
    func testAlignmentEngineCannotRemainReadyAcrossStreamGapOrLoss() {
        var e = CompositionEngine()
        for t in [0.0,0.3,0.7] { _ = e.update(subject:.init(x:0.5,y:0.5),rollDegrees:0,mode:.centered,timestamp:t) }
        XCTAssertEqual(e.update(subject:.init(x:0.5,y:0.5),rollDegrees:0,mode:.centered,timestamp:2).state,.settling)
        XCTAssertEqual(e.update(subject:nil,rollDegrees:0,mode:.centered,timestamp:2.1).state,.searching)
    }
    func testOldAnalysisCannotApplyAfterAnyContextSupersession() {
        for _ in ["subject","mode","zoom","guidance-session","lens","aspect"] {
            let g = GuidanceResultGate(), old = g.begin(observedAt:1)
            g.invalidate(at:1.1)
            XCTAssertFalse(g.apply(old,at:1.2))
            let next = g.begin(observedAt:1.2)
            XCTAssertTrue(g.apply(next,at:1.3))
            XCTAssertFalse(g.expire(old,at:2))
        }
    }
    func testFrameCapturedBeforeContextChangeIsRejectedEvenIfAdmittedLater() {
        let g = GuidanceResultGate(); g.invalidate(at:2)
        let old = g.begin(observedAt:1.9)
        XCTAssertFalse(g.accepts(old,at:2.1)); XCTAssertFalse(g.apply(old,at:2.1))
    }
    func testSlowMainQueueRejectsExpiredAnalysis() {
        let g = GuidanceResultGate(), t = g.begin(observedAt:0)
        XCTAssertFalse(g.apply(t,at:0.91))
    }
    func testOlderResultAndExpiryCannotResetNewerPublishedGuidance() {
        let g = GuidanceResultGate(), a = g.begin(observedAt:0)
        XCTAssertTrue(g.apply(a,at:0.1))
        let b = g.begin(observedAt:0.4)
        XCTAssertFalse(g.apply(a,at:0.5)); XCTAssertTrue(g.apply(b,at:0.5))
        XCTAssertFalse(g.expire(a,at:0.92)); XCTAssertTrue(g.accepts(b,at:0.92))
    }
    func testDisplayedReadyExpiresEvenWhenNewerFrameIsStillInFlight() {
        let g = GuidanceResultGate(), a = g.begin(observedAt:0)
        XCTAssertTrue(g.apply(a,at:0.1))
        let b = g.begin(observedAt:0.8)
        XCTAssertTrue(g.expire(a,at:0.91))
        XCTAssertTrue(g.apply(b,at:1))
        XCTAssertFalse(g.expire(a,at:1.1)); XCTAssertTrue(g.expire(b,at:1.71))
    }
    func testManualZoomSupersessionPreservesEnabledGuideAndGrace() {
        var activation = GuidanceActivation(); _ = activation.set(true)
        let old = activation.snapshot
        let zoom = activation.set(activation.snapshot.enabled)
        XCTAssertTrue(zoom.enabled); XCTAssertFalse(activation.accepts(old))
        var grace = ManualZoomGrace(); grace.begin(at:0)
        XCTAssertFalse(grace.permitsAutomaticZoom(at:10))
        grace.end(at:10); XCTAssertFalse(grace.permitsAutomaticZoom(at:12.9))
        XCTAssertTrue(grace.permitsAutomaticZoom(at:13.1))
    }
    func testSubjectFocusCapabilityIsIndependentOfZoomAndHonorsManualFocus() {
        XCTAssertTrue(SubjectAutofocus.permitted(guidance:true,tracking:true,iPhone:true,manualFocus:false))
        XCTAssertFalse(SubjectAutofocus.permitted(guidance:false,tracking:true,iPhone:true,manualFocus:false))
        XCTAssertFalse(SubjectAutofocus.permitted(guidance:true,tracking:false,iPhone:true,manualFocus:false))
        XCTAssertFalse(SubjectAutofocus.permitted(guidance:true,tracking:true,iPhone:false,manualFocus:false))
        XCTAssertFalse(SubjectAutofocus.permitted(guidance:true,tracking:true,iPhone:true,manualFocus:true))
    }
    func testSubjectAutofocusStationaryEvidenceMaintainsWithoutRetargeting() {
        var af = SubjectAutofocus()
        let b = CGRect(x:0.3,y:0.3,width:0.3,height:0.3)
        guard case .target? = af.update(enabled:true,selectedIdentity:"A",observedIdentity:"A",bounds:b,confidence:0.95,observedAt:0,now:0) else { return XCTFail("Initial target") }
        for t in [0.1,0.25,0.5,0.75] {
            guard case .maintain? = af.update(enabled:true,selectedIdentity:"A",observedIdentity:"A",bounds:b,confidence:0.95,observedAt:t,now:t) else { return XCTFail("Stationary target must not hunt") }
        }
    }

    func testDelayedExpiryCannotInvalidateNewerReadyEvidence() {
        var p = FramingPlanner(continuousRecovery:true)
        p.confirmCurrentFrame(eligible:true,timestamp:0,holdDuration:0.5)
        p.confirmCurrentFrame(eligible:true,timestamp:0.6,holdDuration:0.5)
        p.confirmCurrentFrame(eligible:true,timestamp:1.2,holdDuration:0.5)
        XCTAssertFalse(p.expireReadiness(at:1.51))
        XCTAssertTrue(p.currentFrameVerified)
        XCTAssertTrue(p.expireReadiness(at:2.11))
        XCTAssertFalse(p.currentFrameVerified)
    }
    func testManualThirdsPipelinePublishesReadyWithEitherZoomPreference() {
        let target = UnitPoint2D(x:1.0/3,y:1.0/3)
        let bounds = CGRect(x:target.x-0.15,y:target.y-0.15,width:0.3,height:0.3)
        let assessment = CompositionAssessment.evaluate(bounds:bounds,confidence:0.95,label:"Person",intent:.portrait,stable:true,exposure:nil,evidence:nil)
        for autoZoom in [false,true] {
            var director = FramingPlanner(continuousRecovery:true), engine = CompositionEngine(), guide = AutomaticGuidance()
            var message = GuidanceMessage()
            for time in [0.0,0.3,0.6,0.9] {
                director.confirmCurrentFrame(eligible:ShotReadiness.measuredManualFrame(mode:.thirds,bounds:bounds,target:target,roll:0,aspect:0.75,assessment:assessment,stable:true),timestamp:time,holdDuration:0.5)
                var reading = engine.update(subject:target,rollDegrees:0,mode:.thirds,timestamp:time,preferredTarget:target)
                reading.subjectBounds = bounds; reading.guidanceBounds = bounds; reading.subjectConfidence = 0.95
                message = guide.update(reading:reading,phase:director.phase,stable:true,rollReliable:true,autoEnabled:autoZoom,zoomAvailable:false,timestamp:time,subjectLabel:"Person",intent:.portrait,manualComposition:true,requireShotCompletion:true,currentFrameVerified:director.currentFrameVerified,framingInstruction:director.progressInstruction,continuousFraming:true)
                XCTAssertEqual(reading.target,target)
                XCTAssertNil(director.shotPlan)
            }
            XCTAssertTrue(director.currentFrameVerified)
            XCTAssertEqual(message.kind,.ready,"Auto Zoom preference: \(autoZoom)")
        }
    }
}
