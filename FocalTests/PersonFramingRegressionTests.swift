import XCTest
@testable import Focal

/// The supplied 32.7s recording shows a selected frame, alternating hold/missing
/// plan messages and unchanged 1.1x. These controlled inputs reproduce code
/// gates; they are not Core Motion/Vision/device telemetry extracted from video.
final class PersonFramingRegressionTests: XCTestCase {
    private let bounds = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
    private func scene() -> SceneCompositionPlan {
        .init(selected:.init(technique:.fillFrame,target:.init(x:0.5,y:0.5),crop:CGRect(x:0.25,y:0.25,width:0.5,height:0.5),
            score:0.9,explanation:"Controlled tighter person portrait",zoomScale:2,measuredImprovement:0.2),
            alternatives:[],subjectLabel:"Person",timestamp:0)
    }
    private func selected() throws -> AutomaticShotPlan {
        try XCTUnwrap(AutomaticShotPlan.propose(bounds:bounds,label:"Person",confidence:0.95,trackingReference:"seated-person",
            composition:scene(),currentZoom:1.1,maximumZoom:5,detailLimit:3,nativeStops:[1,5],regions:[],anatomy:nil,
            projection:.init(imageAspect:0.75,previewAspect:0.75)))
    }
    func testRetainedShotCanExecuteWhenSceneCandidateTemporarilyDisappears() throws {
        let shot = try selected()
        let context = FramingExecutionContext(selected:shot,candidate:nil)
        XCTAssertTrue(context.permitsZoom(settingsAllow:true,cropPermitted:true))
        XCTAssertTrue(context.requiresZoom); XCTAssertGreaterThan(shot.targetZoom,shot.startingZoom*1.12)
    }
    func testKeepCurrentSceneCandidateCannotVetoPreviouslySelectedTighterShot() throws {
        var current = scene(); current.selected.isCurrentFrame = true; current.selected.zoomScale = 1
        let context = FramingExecutionContext(selected:try selected(),candidate:current)
        XCTAssertTrue(context.permitsZoom(settingsAllow:true,cropPermitted:true))
        XCTAssertFalse(context.candidateMatchesSelected)
    }
    func testSceneCandidateAloneCannotAuthorizeCameraZoom() {
        XCTAssertFalse(FramingExecutionContext(selected:nil,candidate:scene()).permitsZoom(settingsAllow:true,cropPermitted:true))
    }
    func testAlignedPersonStartsAfterBriefConfirmationRatherThanCaptureHold() throws {
        var director = FramingPlanner(); let shot = try selected(); director.selectShot(shot)
        func update(_ time:Double) -> Double? {
            director.update(bounds:bounds,confidence:0.95,roll:0,timestamp:time,currentZoom:1.1,maximumZoom:5,
                detailZoomLimit:3,deviceStable:true,holdDuration:3,plannedScale:2,zoomDestination:.init(x:0.5,y:0.5),
                requiresShotPlan:true,startConfirmationDuration:0.2)
        }
        XCTAssertNil(update(0)); XCTAssertEqual(update(0.25),2.2)
        XCTAssertEqual(director.shotPlan?.id,shot.id); XCTAssertFalse(director.shotVerified)
    }
    func testMissingVelocityIsNotEvidenceThatReliablyTrackedSubjectIsMoving() {
        XCTAssertTrue(GuidanceObservationPolicy.permitsZoom(stable:true,relativeSpeed:nil,fresh:true,trackedSubject:true))
        XCTAssertFalse(GuidanceObservationPolicy.permitsZoom(stable:false,relativeSpeed:nil,fresh:true,trackedSubject:true))
        XCTAssertFalse(GuidanceObservationPolicy.permitsZoom(stable:true,relativeSpeed:0.8,fresh:true,trackedSubject:true))
    }
    func testPairedCameraReadingDoesNotBecomeStaleOnlyBecauseVisionTookHalfASecond() {
        let camera = CameraZoomObservation(hardwareFactor:2.2,multiplier:2,ramping:true,timestamp:10.02)
        XCTAssertTrue(camera.matchesFrame(capturedAt:10,evaluatedAt:10.55))
        XCTAssertFalse(camera.matchesFrame(capturedAt:10,evaluatedAt:11.2))
    }
    func testSettingsAndCropSafetyStillVetoRetainedPlan() throws {
        let context = FramingExecutionContext(selected:try selected(),candidate:nil)
        XCTAssertFalse(context.permitsZoom(settingsAllow:false,cropPermitted:true))
        XCTAssertFalse(context.permitsZoom(settingsAllow:true,cropPermitted:false))
    }
    func testManualOverrideCannotBeRearmedBySceneCandidate() throws {
        var director = FramingPlanner(); director.selectShot(try selected())
        director.stop(reason:.manualControl)
        XCTAssertFalse(director.selectShot(try selected()))
        XCTAssertFalse(FramingExecutionContext(selected:director.shotPlan,candidate:scene()).permitsZoom(settingsAllow:true,cropPermitted:true))
    }
    func testNewCandidateCannotReplaceSelectedPersonOrTarget() throws {
        var director = FramingPlanner(); let first = try selected()
        XCTAssertTrue(director.selectShot(first)); XCTAssertFalse(director.selectShot(try selected()))
        XCTAssertEqual(director.shotPlan?.id,first.id); XCTAssertEqual(director.shotPlan?.targetZoom,2.2)
    }
    func testHandheldFramingDoesNotRequireCaptureLevelStability() {
        let measurement = FramingMotionMeasurement(rotation:0.17,acceleration:0.05,age:0.1)
        XCTAssertTrue(measurement.stable)
        XCTAssertFalse(CameraStability.isStable(rotation:(0.17,0,0),acceleration:(0.05,0,0)))
        XCTAssertTrue(GuidanceObservationPolicy.permitsZoom(stable:measurement.stable,relativeSpeed:nil,fresh:true,trackedSubject:true))
    }
    func testAlignedButBlockedPreparationEndsRatherThanWaitingForever() throws {
        var director = FramingPlanner(); director.selectShot(try selected())
        for time in [0.0,2,4,6,8.25] {
            XCTAssertNil(director.update(bounds:bounds,confidence:0.95,roll:0,timestamp:time,currentZoom:1.1,maximumZoom:5,
                detailZoomLimit:3,deviceStable:false,plannedScale:2,zoomDestination:.init(x:0.5,y:0.5),requiresShotPlan:true,
                blockedBy:.cameraMotion,startConfirmationDuration:0.2))
        }
        XCTAssertEqual(director.phase,.off); XCTAssertEqual(director.blockReason,.deadline)
        XCTAssertFalse(director.shotVerified)
    }
    func testFramePairRejectsUnrelatedFutureAndInvalidCameraReadings() {
        let valid = CameraZoomObservation(hardwareFactor:2.2,multiplier:2,ramping:true,timestamp:10)
        XCTAssertFalse(valid.matchesFrame(capturedAt:9.6,evaluatedAt:10.1))
        XCTAssertFalse(valid.matchesFrame(capturedAt:10,evaluatedAt:9.9))
        var invalid = valid; invalid.multiplier = 0
        XCTAssertFalse(invalid.matchesFrame(capturedAt:10,evaluatedAt:10.2))
    }
    func testTraceTimesStateIndependentlyOfChangingBlockReasons() throws {
        var trace = FramingTransitionTrace()
        _ = trace.record(sessionID:1,shotID:"selected",state:.aligned,at:10,values:["blockingReason":"motion"])
        let changedReason = try XCTUnwrap(trace.record(sessionID:1,shotID:"selected",state:.aligned,at:12,values:["blockingReason":"crop"]))
        XCTAssertTrue(changedReason.contains("stateSeconds=2.0000"))
        let transition = try XCTUnwrap(trace.record(sessionID:1,shotID:"selected",state:.autoZooming,at:12.25,values:[:]))
        XCTAssertTrue(transition.contains("sessionSeconds=2.2500")); XCTAssertTrue(transition.contains("stateSeconds=0.0000"))
        XCTAssertTrue(transition.contains("previousState=ALIGNED previousStateSeconds=2.2500"))
    }
    func testTraceDoesNotFabricateMissingMeasurements() {
        XCTAssertEqual(FramingTransitionTrace.number(nil),"unknown")
        XCTAssertEqual(FramingTransitionTrace.number(.nan),"unknown")
        XCTAssertEqual(FramingTransitionTrace.number(1.1),"1.1000")
    }
    func testDeveloperTraceRemainsBounded() {
        let trace = FramingTraceBuffer(limit:2)
        trace.append("first"); trace.append("second"); trace.append("third")
        XCTAssertEqual(trace.text(),"second\nthird")
    }
    func testKnownProtectedContextFollowsAimingWithoutAddingNewBackground() throws {
        let context = CGRect(x:0.42,y:0.42,width:0.03,height:0.03)
        let shot = try XCTUnwrap(AutomaticShotPlan.make(bounds:bounds,label:"Person",composition:scene(),currentZoom:1.1,
            maximumZoom:5,detailLimit:3,nativeStops:[],regions:[context],anatomy:nil,previewAspect:0.75))
        let moved = shot.trackedProtectedRegions(bounds:bounds.offsetBy(dx:0.02,dy:-0.04))
        XCTAssertEqual(moved.count,1)
        XCTAssertEqual(moved[0].minX,context.minX+0.02,accuracy:0.00001)
        XCTAssertEqual(moved[0].minY,context.minY-0.04,accuracy:0.00001)
    }
    func testLatestActualZoomMustAgreeBeforeReadiness() throws {
        var director = FramingPlanner(); let shot = try selected(); director.selectShot(shot)
        for time in [0.0,0.25] {
            _ = director.update(bounds:bounds,confidence:0.95,roll:0,timestamp:time,currentZoom:1.1,maximumZoom:5,
                detailZoomLimit:3,plannedScale:2,zoomDestination:.init(x:0.5,y:0.5),requiresShotPlan:true,startConfirmationDuration:0.2)
        }
        director.commitShot(shot)
        for time in [1.0,1.5,2.0] {
            XCTAssertEqual(director.verifyShot(bounds:shot.desiredBounds,label:"Person",confidence:0.95,zoom:2.2,stable:true,
                fresh:true,timestamp:time,previewAspect:0.75,cameraRamping:false,trackingReference:"seated-person",liveZoom:1.1),.holding)
        }
        XCTAssertFalse(director.shotVerified)
    }
    func testControlledPersonReplayCompletesAfterActualZoomObservationsAndManualShutter() throws {
        var director = FramingPlanner(); let selected = try selected(); director.selectShot(selected)
        print("CONTROLLED_REPLAY SHOT_SELECTED zoom=1.1 target=\(selected.targetZoom) scale=\(selected.desiredScale); sensor inputs below are fixtures")
        XCTAssertNil(director.update(bounds:bounds.offsetBy(dx:0,dy:0.1),confidence:0.95,roll:0,timestamp:0,currentZoom:1.1,maximumZoom:5,
            plannedScale:2,zoomDestination:.init(x:0.5,y:0.5),requiresShotPlan:true,startConfirmationDuration:0.2))
        XCTAssertEqual(director.directorState(hasPlan:true),.aiming)
        print("CONTROLLED_REPLAY AIMING wrong aim; no zoom command")
        let permission = FramingExecutionContext(selected:director.shotPlan,candidate:nil).permitsZoom(settingsAllow:true,cropPermitted:true)
        var command:Double?
        for time in [0.25,0.5] {
            command = director.update(bounds:bounds,confidence:0.95,roll:0,timestamp:time,currentZoom:1.1,maximumZoom:5,
                detailZoomLimit:3,deviceStable:true,holdDuration:3,allowZoom:permission,plannedScale:2,
                zoomDestination:.init(x:0.5,y:0.5),requiresShotPlan:true,startConfirmationDuration:0.2) ?? command
        }
        XCTAssertEqual(command,2.2)
        let executable = try XCTUnwrap(selected.prepared(bounds:bounds,zoom:1.1,detailLimit:3,nativeStops:[],regions:[],anatomy:nil,aspect:0.75))
        XCTAssertEqual(executable.id,selected.id); director.commitShot(executable)
        print("CONTROLLED_REPLAY ALIGNED -> AUTO_ZOOMING command=\(try XCTUnwrap(command)); native target=\(try XCTUnwrap(CameraZoomObservation.hardwareTarget(displayed:executable.targetZoom,multiplier:2,minimum:1,maximum:10)))")
        var photos = ShotCaptureSession(); photos.select(executable,preview:nil)
        for (time,zoom) in [(0.75,1.45),(1.0,1.9)] {
            let measured = FramingPlanner.zoomedRect(bounds,scale:zoom/1.1)
            XCTAssertEqual(director.verifyShot(bounds:measured,label:"Person",confidence:0.95,zoom:zoom,stable:true,fresh:true,
                timestamp:time,previewAspect:0.75,cameraRamping:true,trackingReference:"seated-person",liveZoom:zoom),.continuing)
            print("CONTROLLED_REPLAY observed fixture zoom=\(zoom); READY=NO")
        }
        XCTAssertEqual(director.verifyShot(bounds:executable.desiredBounds,label:"Person",confidence:0.95,zoom:2.2,stable:true,fresh:true,
            timestamp:1.25,previewAspect:0.75,cameraRamping:false,captureStable:false,trackingReference:"seated-person",liveZoom:2.2),.holding)
        XCTAssertNil(photos.userCapture(at:1.25,guidanceEnabled:true))
        for time in [1.5,1.75,2.0,2.25] {
            _ = director.verifyShot(bounds:executable.desiredBounds,label:"Person",confidence:0.95,zoom:2.2,stable:true,fresh:true,
                timestamp:time,previewAspect:0.75,cameraRamping:false,trackingReference:"seated-person",captureHoldDuration:0.75,liveZoom:2.2)
        }
        XCTAssertTrue(director.shotVerified); XCTAssertEqual(director.directorState(hasPlan:true),.ready)
        print("CONTROLLED_REPLAY VERIFYING -> READY measured geometry and stopped motor=2.2; capture hold=0.75s; automatic shutter=NO")
        photos.observe(plan:director.shotPlan,verified:true,bounds:executable.desiredBounds,label:"Person",confidence:0.95,zoom:2.2,
            stable:true,timestamp:2.25,aspect:0.75)
        XCTAssertNotNil(photos.userCapture(at:2.3,guidanceEnabled:true))
    }
}
