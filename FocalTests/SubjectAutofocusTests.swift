import XCTest
@testable import Focal

/// Exercises the actual focus policy and existing framing/geometry models.
/// No simulated lens is used; optical focus and Apple coordinate conversion
/// still require an iPhone and an iOS build.
final class SubjectAutofocusTests: XCTestCase {
    private let body = CGRect(x:0.3,y:0.2,width:0.4,height:0.6)
    private func step(_ af:inout SubjectAutofocus,_ time:Double,bounds:CGRect? = nil,selected:String? = "chosen",observed:String? = "chosen",
                      enabled:Bool = true,confidence:Float = 0.95,head:CGRect? = nil,headAt:Double? = nil,zoom:Double = 1) -> SubjectAutofocus.Update? {
        af.update(enabled:enabled,selectedIdentity:selected,observedIdentity:observed,bounds:bounds ?? body,confidence:confidence,
            head:head,headObservedAt:headAt,observedAt:time,now:time,zoom:zoom)
    }
    private func target(_ update:SubjectAutofocus.Update?,file:StaticString = #filePath,line:UInt = #line) throws -> SubjectFocusTarget {
        if case .target(let t) = update { return t }
        XCTFail("Expected an autofocus target",file:file,line:line)
        throw NSError(domain:"SubjectAutofocusTests",code:1)
    }
    func testAutomaticallySelectedPersonFocusesImmediatelyWithoutTapOrDwell() throws {
        var af = SubjectAutofocus()
        let t = try target(step(&af,0))
        XCTAssertEqual(t.identity,"chosen"); XCTAssertEqual(t.point,.init(x:0.5,y:0.5))
        XCTAssertFalse(t.usesObservedHead)
    }
    func testPersonWalkingLeftAndRightKeepsSameIdentityAndFollowsPosition() throws {
        var af = SubjectAutofocus(); let initial = try target(step(&af,0))
        let right = try target(step(&af,0.3,bounds:body.offsetBy(dx:0.12,dy:0)))
        let left = try target(step(&af,0.7,bounds:body.offsetBy(dx:-0.12,dy:0)))
        XCTAssertGreaterThan(right.point.x,initial.point.x); XCTAssertLessThan(left.point.x,initial.point.x)
        XCTAssertEqual(right.identity,left.identity)
    }
    func testApproachingSubjectKeepsContinuousFocusTargetWithoutInventingLensDistance() throws {
        var af = SubjectAutofocus(); _ = try target(step(&af,0))
        let closer = CGRect(x:0.2,y:0.1,width:0.6,height:0.8)
        let u = step(&af,0.3,bounds:closer)
        XCTAssertEqual(u,.maintain(identity:"chosen",observedAt:0.3))
        XCTAssertEqual(af.identity,"chosen") // Continuous AF does the depth adjustment, not this policy.
    }
    func testRecedingSubjectRetainsCAFAndPeriodicallyAuditsUnchangedPoint() throws {
        var af = SubjectAutofocus(); _ = step(&af,0)
        let farther = CGRect(x:0.4,y:0.35,width:0.2,height:0.3)
        XCTAssertEqual(step(&af,0.4,bounds:farther),.maintain(identity:"chosen",observedAt:0.4))
        let refreshed = try target(step(&af,1.1,bounds:farther))
        XCTAssertEqual(refreshed.point.x,0.5,accuracy:0.000001)
        XCTAssertEqual(refreshed.point.y,0.5,accuracy:0.000001); XCTAssertEqual(refreshed.identity,"chosen")
    }
    func testCatUsesObservedHeadWhenAvailableAndFresh() throws {
        var af = SubjectAutofocus()
        let head = CGRect(x:0.4,y:0.24,width:0.2,height:0.15)
        let t = try target(step(&af,1,selected:"cat",observed:"cat",head:head,headAt:1))
        XCTAssertTrue(t.usesObservedHead); XCTAssertEqual(t.identity,"cat")
        XCTAssertEqual(t.point.y,head.midY,accuracy:0.001)
    }
    func testChairVehicleAndOtherAnimalsUseTheirMainRegionWithoutRequiringAFace() throws {
        for identity in ["chair","vehicle","bird","everyday-object"] {
            var af = SubjectAutofocus()
            let t = try target(step(&af,0,selected:identity,observed:identity))
            XCTAssertEqual(t.identity,identity); XCTAssertEqual(t.point,.init(x:body.midX,y:body.midY))
            XCTAssertFalse(t.usesObservedHead)
        }
    }
    func testAutofocusContinuesDuringActualFramingDirectorZoomPhase() throws {
        var director = FramingPlanner(continuousRecovery:true)
        let subject = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
        let scene = SceneCompositionPlan(selected:.init(technique:.fillFrame,target:.init(x:0.5,y:0.5),
            crop:CGRect(x:0.25,y:0.25,width:0.5,height:0.5),score:0.9,explanation:"Controlled portrait",zoomScale:2,
            measuredImprovement:0.2),alternatives:[],subjectLabel:"Person",timestamp:0)
        let plan = try XCTUnwrap(AutomaticShotPlan.propose(bounds:subject,label:"Person",confidence:0.95,trackingReference:"chosen",
            composition:scene,currentZoom:1,maximumZoom:5,detailLimit:3,nativeStops:[],regions:[],anatomy:nil,
            projection:.init(imageAspect:0.75,previewAspect:0.75)))
        XCTAssertTrue(director.selectShot(plan))
        XCTAssertEqual(director.update(bounds:subject,confidence:0.95,roll:0,timestamp:0,currentZoom:1,maximumZoom:5,
            plannedScale:2,zoomDestination:plan.desiredPosition,requiresShotPlan:true,startConfirmationDuration:0.2),2)
        XCTAssertEqual(director.phase,.zooming)
        var af = SubjectAutofocus()
        for (time,zoom) in [(0.0,1.0),(0.4,1.4),(0.8,2.0)] {
            let u = step(&af,time,bounds:FramingPlanner.zoomedRect(subject,scale:zoom),selected:plan.trackingReference,
                observed:plan.trackingReference,zoom:zoom)
            XCTAssertNotEqual(u,.normal); XCTAssertEqual(af.identity,plan.trackingReference)
        }
    }
    func testBriefOcclusionRetainsIdentityAndReacquisitionResumesImmediately() throws {
        var af = SubjectAutofocus(); _ = step(&af,0)
        XCTAssertNil(step(&af,0.2,observed:nil,confidence:0))
        XCTAssertEqual(af.identity,"chosen")
        let t = try target(step(&af,0.7,bounds:body.offsetBy(dx:0.04,dy:0)))
        XCTAssertEqual(t.identity,"chosen"); XCTAssertEqual(t.point.x,body.midX+0.04,accuracy:0.001)
    }
    func testGenuineLossReturnsToNormalOnceThenAcceptsANewSelectedSubject() throws {
        var af = SubjectAutofocus(); _ = step(&af,0)
        XCTAssertNil(step(&af,0.2,observed:nil,confidence:0))
        XCTAssertEqual(step(&af,1.8,observed:nil,confidence:0),.normal)
        XCTAssertNil(af.identity); XCTAssertNil(step(&af,2,observed:nil,confidence:0))
        XCTAssertEqual(try target(step(&af,2.1,selected:"new",observed:"new")).identity,"new")
    }
    func testNewSubjectAtSamePositionUpdatesImmediatelyAndCannotInheritOldHead() throws {
        var af = SubjectAutofocus(); _ = step(&af,0,selected:"A",observed:"A")
        XCTAssertEqual(try target(step(&af,0.05,selected:"B",observed:"B")).identity,"B")
        XCTAssertNil(step(&af,0.1,selected:"B",observed:"C"))
        XCTAssertEqual(af.identity,"B")
    }
    func testManualFocusInvalidatesQueuedAFAndResumesOnlyAfterManualRelease() {
        let gate = AutofocusRequestGate(); let pending = gate.invalidate()
        gate.setManualFocus(true)
        XCTAssertTrue(gate.manuallyControlled); XCTAssertFalse(gate.accepts(pending))
        XCTAssertFalse(ManualCameraState(mode:.pro,focus:0.6).permitsFocus(automatic:true))
        gate.setManualFocus(false)
        XCTAssertFalse(gate.manuallyControlled)
        XCTAssertTrue(ManualCameraState(mode:.pro).permitsFocus(automatic:true))
    }
    func testAutoFrameOffReleasesTargetAndRejectsDelayedConversions() throws {
        var af = SubjectAutofocus(); _ = step(&af,0)
        let gate = AutofocusRequestGate(), old = 0
        gate.invalidate()
        XCTAssertEqual(step(&af,0.1,enabled:false),.normal); XCTAssertNil(af.identity)
        XCTAssertFalse(gate.accepts(old)); XCTAssertNil(step(&af,0.2,enabled:false))
    }
    func testFramingTimeoutDoesNotDisableSubjectAutofocus() throws {
        var af = SubjectAutofocus(); _ = step(&af,0)
        // The autofocus contract deliberately has no zoom-armed/stability gate.
        let t = try target(step(&af,8,selected:"chosen",observed:"chosen"))
        XCTAssertEqual(t.identity,"chosen"); XCTAssertNotNil(af.lastReliableAt)
    }
    func testManualZoomRetainsFocusIdentityAndReprojectsAgainstObservedZoom() throws {
        var af = SubjectAutofocus()
        let t = try target(step(&af,0,bounds:body.offsetBy(dx:0.1,dy:0),zoom:1))
        let atTwo = try XCTUnwrap(t.point(atZoom:2))
        XCTAssertEqual(atTwo.x,0.7,accuracy:0.001); XCTAssertEqual(atTwo.y,0.5,accuracy:0.001)
        XCTAssertEqual(af.identity,"chosen")
    }
    func testTrackedHeadFollowsBodyMotionAndZoomButExpiresWithoutFreshEvidence() throws {
        let head = CGRect(x:0.4,y:0.25,width:0.2,height:0.15)
        let region = TrackedFocusRegion(identity:"cat",subject:body,region:head,observedAt:1)
        let moved = body.offsetBy(dx:0.1,dy:0.05)
        let projected = try XCTUnwrap(region.projected(in:moved,identity:"cat",at:1.4))
        XCTAssertEqual(projected.midX,head.midX+0.1,accuracy:0.001)
        XCTAssertEqual(projected.midY,head.midY+0.05,accuracy:0.001)
        XCTAssertNil(region.projected(in:moved,identity:"another-cat",at:1.4))
        XCTAssertNil(region.projected(in:moved,identity:"cat",at:2.6))
    }
    func testStaleOrOutsideHeadFallsBackToTheRealSubjectRegion() throws {
        for head in [CGRect(x:0.85,y:0.1,width:0.1,height:0.1),CGRect(x:0.4,y:0.25,width:0.2,height:0.1)] {
            var af = SubjectAutofocus()
            let t = try target(step(&af,3,head:head,headAt:0))
            XCTAssertFalse(t.usesObservedHead); XCTAssertEqual(t.point,.init(x:0.5,y:0.5))
        }
    }
    func testPointUpdatesAreThrottledAndSmoothingRemainsInsideMovingSubject() throws {
        var af = SubjectAutofocus(); var commands = 0
        for i in 0...100 {
            let time = Double(i)*0.01, box = body.offsetBy(dx:0.06*sin(time*4),dy:0)
            if case .target(let t) = step(&af,time,bounds:box) {
                commands += 1; XCTAssertTrue(box.contains(CGPoint(x:t.point.x,y:t.point.y)))
            }
        }
        XCTAssertLessThanOrEqual(commands,6); XCTAssertGreaterThan(commands,1)
    }
    func testStationaryTargetDoesNotRequestConfigurationOnEveryFrame() {
        var af = SubjectAutofocus(); var commands = 0
        for i in 0...100 {
            if case .target = step(&af,Double(i)*0.1) { commands += 1 }
        }
        XCTAssertLessThanOrEqual(commands,11) // Native adapter additionally skips unchanged CAF/POI writes.
    }
    func testAspectFillAndMirroredVisionCoordinatesIdentifySamePhysicalSubject() throws {
        let vision = CGRect(x:0.5,y:0.3,width:0.15,height:0.25)
        for mirrored in [false,true] {
            let projection = PreviewProjection(imageAspect:1,previewAspect:0.75,mirrored:mirrored)
            var af = SubjectAutofocus()
            let t = try target(step(&af,0,bounds:projection.visibleVisionRect(vision)))
            let image = projection.imagePoint(t.point)
            XCTAssertEqual(image.x,vision.midX,accuracy:0.001); XCTAssertEqual(image.y,1-vision.midY,accuracy:0.001)
        }
        // The remaining sensor conversion uses the real preview layer, not this test.
    }
    func testInvalidAndStaleObservationsNeverProduceAFCommands() {
        var af = SubjectAutofocus()
        XCTAssertNil(step(&af,0,confidence:.nan))
        XCTAssertNil(step(&af,0.1,bounds:CGRect(x:2,y:2,width:0.2,height:0.2)))
        XCTAssertNil(af.update(enabled:true,selectedIdentity:"chosen",observedIdentity:"chosen",bounds:body,confidence:1,
            observedAt:0,now:1))
        XCTAssertNil(af.identity)
    }
    func testNewDeviceOrSessionInvalidationRejectsOldCoordinateWork() {
        let gate = AutofocusRequestGate(); let old = gate.invalidate(); let current = gate.invalidate()
        XCTAssertFalse(gate.accepts(old)); XCTAssertTrue(gate.accepts(current))
        gate.invalidate(); XCTAssertFalse(gate.accepts(current))
    }
}
