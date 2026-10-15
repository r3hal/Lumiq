import XCTest
@testable import Focal

/// Controlled pixel/geometry fixtures inspired by the references. These do not
/// replace Vision inference on the videos or exercise a physical camera motor.
final class TargetRectangleDirectorTests: XCTestCase {
    private func evidence(subject:CGRect,timestamp:Double = 0) throws -> SceneCompositionEvidence {
        let width = 48, height = 64
        let pixels = (0..<width*height).map { i -> SubjectImageEvidence.Pixel in
            let point = CGPoint(x:(Double(i%width)+0.5)/Double(width),y:(Double(i/width)+0.5)/Double(height))
            let value = subject.contains(point) ? 0.7 : ((i/width)%12 < 6 ? 0.3 : 0.5)
            return .init(red:value,green:value*0.9,blue:value*0.8)
        }
        return try XCTUnwrap(SceneCompositionEvidence(image:.init(pixels:pixels,width:width,height:height),
            projection:.init(imageAspect:0.75,previewAspect:0.75),timestamp:timestamp))
    }
    private func selected(subject:CGRect,label:String = "Cat",intent:PhotographyIntent = .pet) throws -> (SceneCompositionPlan,AutomaticShotPlan) {
        let evidence = try evidence(subject:subject)
        let desired = TargetRectangleGeometry.preferredScale(subject:subject,label:label,intent:intent)
        let scales = FramingPlanner.availableScales(currentZoom:1.8,maximumZoom:6,detailZoomLimit:6,nativeStops:[1,5],maximumScale:3,desiredScale:desired)
        let scene = try XCTUnwrap(TargetRectangleSearch.plan(subject:subject,label:label,intent:intent,evidence:evidence,
            others:[],scales:scales,forceCenter:true,anatomy:nil))
        let shot = try XCTUnwrap(AutomaticShotPlan.propose(bounds:subject,label:label,confidence:0.95,trackingReference:"chosen-subject",composition:scene,
            currentZoom:1.8,maximumZoom:6,detailLimit:6,nativeStops:[1,5],regions:[],anatomy:nil,
            projection:.init(imageAspect:0.75,previewAspect:0.75)))
        return (scene,shot)
    }
    func testCatAboveOldVisibilityMinimumStillGetsSpecificTighterPhotograph() throws {
        let subject = CGRect(x:0.25,y:0.25,width:0.3,height:0.5) // 15%, already above old minimum.
        let (scene,shot) = try selected(subject:subject)
        XCTAssertTrue(scene.permitsZoom); XCTAssertGreaterThan(shot.targetZoom,1.8)
        XCTAssertGreaterThan(shot.desiredBounds.width*shot.desiredBounds.height,subject.width*subject.height)
        XCTAssertGreaterThan(shot.desiredBounds.width*shot.desiredBounds.height,0.3)
        XCTAssertNotEqual(shot.initialBounds,shot.framingRectangle)
        XCTAssertEqual(shot.id,scene.id); XCTAssertEqual(shot.trackingReference,"chosen-subject")
        XCTAssertFalse(shot.selectionReason.isEmpty); XCTAssertGreaterThan(shot.qualityScore,0)
    }
    func testExistingScenePlannerSelectsAndFreezesTargetRectangleBeforeAiming() throws {
        let subject = CGRect(x:0.25,y:0.25,width:0.3,height:0.5)
        let e = try evidence(subject:subject)
        var planner = SceneCompositionPlanner()
        let first = try XCTUnwrap(planner.update(subject:subject,confidence:0.95,label:"Cat",evidence:e,timestamp:0,
            maximumScale:3,intent:.pet,availableScales:[1,1.15,1.35,1.6]))
        XCTAssertTrue(first.permitsZoom)
        let moved = try XCTUnwrap(planner.update(subject:subject.offsetBy(dx:0.01,dy:0),confidence:0.95,label:"Cat",evidence:e,timestamp:0.5,
            maximumScale:3,freeze:true,intent:.pet,availableScales:[1,1.15,1.35,1.6]))
        XCTAssertEqual(moved.id,first.id); XCTAssertEqual(moved.target,first.target)
        XCTAssertEqual(moved.selected.zoomScale,first.selected.zoomScale)
    }
    func testUsefulTighterShotWinsOverExistingVisibilityOnlyFitness() throws {
        let subject = CGRect(x:0.25,y:0.25,width:0.3,height:0.5)
        let options = SceneCompositionPlanner.compare(subject:subject,evidence:try evidence(subject:subject),maximumScale:3,
            intent:.pet,availableScales:[1,1.15,1.35,1.6],label:"Cat")
        let best = try XCTUnwrap(options.first)
        XCTAssertFalse(best.isCurrentFrame); XCTAssertNotNil(best.kind)
        XCTAssertTrue(options.contains { $0.isCurrentFrame })
    }
    func testChairHasAimingPlanBeforeItIsCentered() throws {
        let subject = CGRect(x:0.17,y:0.19,width:0.14,height:0.22)
        let (_,shot) = try selected(subject:subject,label:"Chair",intent:.product)
        let reading = CompositionReading(subjectBounds:subject,subjectConfidence:0.95,target:shot.aimingTarget(bounds:subject))
        let cue = try XCTUnwrap(CompositionCue(reading:reading,previewAspect:0.75))
        XCTAssertEqual(shot.kind,.objectPortrait)
        XCTAssertTrue(cue.phoneInstruction.contains("left")); XCTAssertTrue(cue.phoneInstruction.contains("up"))
        XCTAssertFalse(cue.aligned)
        XCTAssertNil(shot.prepared(bounds:subject,zoom:1.8,detailLimit:6,nativeStops:[1,5],regions:[],anatomy:nil,aspect:0.75))
    }
    func testChairAlignmentProducesRealCameraCommandGeometry() throws {
        let subject = CGRect(x:0.17,y:0.19,width:0.14,height:0.22)
        let (_,shot) = try selected(subject:subject,label:"Chair",intent:.product)
        let aim = shot.aimingTarget(bounds:subject)
        let aligned = subject.offsetBy(dx:aim.x-subject.midX,dy:aim.y-subject.midY)
        var director = FramingPlanner(); director.selectShot(shot)
        var requested:Double?
        for i in 0...5 {
            requested = director.update(bounds:aligned,confidence:0.95,roll:0,timestamp:Double(i)*0.25,currentZoom:1.8,maximumZoom:6,
                detailZoomLimit:6,alignmentTarget:aim,plannedScale:shot.desiredScale,zoomDestination:shot.desiredPosition,requiresShotPlan:true) ?? requested
        }
        let command = try XCTUnwrap(requested)
        let hardware = try XCTUnwrap(CameraZoomObservation.hardwareTarget(displayed:command,multiplier:2,minimum:1,maximum:12))
        XCTAssertGreaterThan(hardware,3.6)
        let prepared = try XCTUnwrap(shot.prepared(bounds:aligned,zoom:1.8,detailLimit:6,nativeStops:[1,5],regions:[],anatomy:nil,aspect:0.75))
        XCTAssertEqual(prepared.id,shot.id); XCTAssertEqual(prepared.targetZoom,command,accuracy:0.00001)
        XCTAssertTrue(AutomaticShotPlan.safe(prepared.desiredBounds))
    }
    func testCatPipelineAimsRampsVerifiesThenAllowsUserPair() throws {
        let original = CGRect(x:0.25,y:0.25,width:0.3,height:0.5)
        let (_,selected) = try selected(subject:original)
        var director = FramingPlanner(); director.selectShot(selected)
        XCTAssertEqual(director.shotPlan?.id,selected.id)
        XCTAssertFalse(director.shotVerified)
        let target = selected.aimingTarget(bounds:original)
        let aimed = original.offsetBy(dx:target.x-original.midX,dy:target.y-original.midY)
        var command:Double?
        for i in 0...6 {
            command = director.update(bounds:aimed,confidence:0.95,roll:0,timestamp:Double(i)*0.25,currentZoom:1.8,maximumZoom:6,
                detailZoomLimit:6,holdDuration:0.75,previewAspect:0.75,alignmentTarget:target,plannedScale:selected.desiredScale,
                zoomDestination:selected.desiredPosition,requiresShotPlan:true) ?? command
        }
        let request = try XCTUnwrap(command)
        let prepared = try XCTUnwrap(selected.prepared(bounds:aimed,zoom:1.8,detailLimit:6,nativeStops:[1,5],regions:[],anatomy:nil,aspect:0.75))
        XCTAssertEqual(prepared.id,selected.id); XCTAssertEqual(request,prepared.targetZoom,accuracy:0.00001)
        XCTAssertEqual(try XCTUnwrap(CameraZoomObservation.hardwareTarget(displayed:request,multiplier:2,minimum:1,maximum:12)),request*2)
        director.commitShot(prepared)
        let middleZoom = (1.8+request)/2
        let middle = FramingPlanner.zoomedRect(aimed,scale:middleZoom/1.8)
        XCTAssertEqual(director.verifyShot(bounds:middle,label:"Cat",confidence:0.95,zoom:middleZoom,stable:true,fresh:true,timestamp:2,
            previewAspect:0.75,cameraRamping:true,trackingReference:"chosen-subject"),.continuing)
        XCTAssertFalse(director.shotVerified)
        let final = FramingPlanner.zoomedRect(aimed,scale:request/1.8)
        XCTAssertEqual(director.verifyShot(bounds:final,label:"Cat",confidence:0.95,zoom:request,stable:true,fresh:true,timestamp:2.25,
            previewAspect:0.75,cameraRamping:false,trackingReference:"chosen-subject"),.holding)
        XCTAssertEqual(director.verifyShot(bounds:final,label:"Cat",confidence:0.95,zoom:request,stable:true,fresh:true,timestamp:2.5,
            previewAspect:0.75,cameraRamping:false,trackingReference:"chosen-subject"),.achieved)
        var captures = ShotCaptureSession()
        captures.select(prepared,preview:nil)
        XCTAssertNil(captures.userCapture(at:2.5,guidanceEnabled:true))
        captures.observe(plan:prepared,verified:director.shotVerified,bounds:final,label:"Cat",confidence:0.95,zoom:request,stable:true,timestamp:2.5,aspect:0.75)
        XCTAssertTrue(try XCTUnwrap(captures.userCapture(at:2.6,guidanceEnabled:true)).matchesCamera(zoom:request,enabled:true,ramping:false))
    }
    func testCenteredSmallSubjectCannotUseCurrentFrameShortcut() throws {
        let (_,shot) = try selected(subject:CGRect(x:0.4,y:0.4,width:0.2,height:0.2))
        var director = FramingPlanner(); director.selectShot(shot)
        director.confirmCurrentFrame(eligible:true,timestamp:0,holdDuration:0.5)
        director.confirmCurrentFrame(eligible:true,timestamp:1,holdDuration:0.5)
        XCTAssertFalse(director.currentFrameVerified); XCTAssertFalse(director.shotVerified)
    }
    func testAimingAndCaptureStabilityAreDifferentGates() throws {
        let subject = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
        let (_,selected) = try selected(subject:subject)
        let shot = try XCTUnwrap(selected.prepared(bounds:subject,zoom:1.8,detailLimit:6,nativeStops:[1,5],regions:[],anatomy:nil,aspect:0.75))
        var director = FramingPlanner()
        for time in [0.0,1.0] {
            _ = director.update(bounds:subject,confidence:1,roll:0,timestamp:time,currentZoom:1.8,maximumZoom:6,detailZoomLimit:6,
                plannedScale:shot.desiredScale,zoomDestination:shot.desiredPosition,requiresShotPlan:true)
        }
        director.commitShot(shot)
        for time in [2.0,2.25] {
            XCTAssertEqual(director.verifyShot(bounds:shot.desiredBounds,label:"Cat",confidence:0.95,zoom:shot.targetZoom,stable:true,fresh:true,timestamp:time,
                previewAspect:0.75,cameraRamping:false,captureStable:false,trackingReference:"chosen-subject"),.holding)
            XCTAssertFalse(director.shotVerified)
        }
        XCTAssertEqual(director.verifyShot(bounds:shot.desiredBounds,label:"Cat",confidence:0.95,zoom:shot.targetZoom,stable:true,fresh:true,timestamp:2.5,
            previewAspect:0.75,cameraRamping:false,trackingReference:"chosen-subject"),.holding)
        XCTAssertEqual(director.verifyShot(bounds:shot.desiredBounds,label:"Cat",confidence:0.95,zoom:shot.targetZoom,stable:true,fresh:true,timestamp:2.75,
            previewAspect:0.75,cameraRamping:false,trackingReference:"chosen-subject"),.achieved)
    }
    func testSelectionPersistsThroughAimingWithoutTargetChanges() throws {
        let (_,shot) = try selected(subject:CGRect(x:0.3,y:0.3,width:0.3,height:0.3))
        let (_,challenger) = try selected(subject:CGRect(x:0.4,y:0.3,width:0.2,height:0.3))
        var director = FramingPlanner(); director.selectShot(shot); director.selectShot(challenger)
        XCTAssertEqual(director.shotPlan?.id,shot.id); XCTAssertEqual(director.shotPlan?.desiredBounds,shot.desiredBounds)
    }
    func testSameNamedDifferentSubjectCannotContinueZoom() throws {
        let subject = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
        let (_,shot) = try selected(subject:subject)
        var director = FramingPlanner()
        _ = director.update(bounds:subject,confidence:1,roll:0,timestamp:0,currentZoom:1.8,maximumZoom:6,detailZoomLimit:6,plannedScale:shot.desiredScale,zoomDestination:shot.desiredPosition)
        _ = director.update(bounds:subject,confidence:1,roll:0,timestamp:1,currentZoom:1.8,maximumZoom:6,detailZoomLimit:6,plannedScale:shot.desiredScale,zoomDestination:shot.desiredPosition)
        director.commitShot(shot)
        XCTAssertEqual(director.verifyShot(bounds:shot.desiredBounds,label:"Cat",confidence:1,zoom:shot.targetZoom,stable:true,fresh:true,timestamp:2,
            previewAspect:0.75,trackingReference:"different-cat"),.cancel)
        XCTAssertFalse(director.shotVerified)
    }
    func testFractionalZoomContainmentUsesActualBoundsWithoutUnionRounding() {
        let crop = CGRect(x:0.33333333333333337,y:0.33333333333333337,width:1.0/3,height:1.0/3).insetBy(dx:0.006,dy:0.006)
        XCTAssertTrue(TargetRectangleGeometry.contains(crop,CGRect(x:0.45,y:0.45,width:0.1,height:0.1)))
    }
    func testContainmentDoesNotRelaxMeaningfulCropMargins() {
        let safe = CGRect(x:0.035,y:0.035,width:0.93,height:0.93)
        XCTAssertFalse(TargetRectangleGeometry.contains(safe,CGRect(x:0.034,y:0.1,width:0.3,height:0.3)))
        XCTAssertFalse(TargetRectangleGeometry.contains(safe,.null))
    }
    func testObservedHeadProtectionSurvivesAimingWithoutFreshPoseInference() throws {
        let body = CGRect(x:0.3,y:0.3,width:0.3,height:0.3)
        let head = CGRect(x:0.37,y:0.3,width:0.14,height:0.1)
        let e = try evidence(subject:body)
        let scene = try XCTUnwrap(TargetRectangleSearch.plan(subject:body,label:"Person",intent:.portrait,evidence:e,others:[],
            scales:[1,1.35,1.6],forceCenter:true,anatomy:.init(face:head,timestamp:0)))
        let selected = try XCTUnwrap(AutomaticShotPlan.propose(bounds:body,label:"Person",confidence:0.95,trackingReference:"person",composition:scene,
            currentZoom:1,maximumZoom:3,detailLimit:3,nativeStops:[1],regions:[],anatomy:.init(face:head,timestamp:0),projection:.init(imageAspect:0.75,previewAspect:0.75)))
        let aim = selected.aimingTarget(bounds:body)
        let aimed = body.offsetBy(dx:aim.x-body.midX,dy:aim.y-body.midY)
        let tracked = try XCTUnwrap(selected.trackedAnatomy(bounds:aimed,timestamp:2))
        let ready = try XCTUnwrap(selected.prepared(bounds:aimed,zoom:1,detailLimit:3,nativeStops:[1],regions:[],anatomy:tracked,aspect:0.75))
        XCTAssertNotNil(ready.observedHead); XCTAssertFalse(ready.subjectRegions.isEmpty)
        XCTAssertEqual(ready.id,selected.id)
    }
    func testCanonicalImageGeometryRoundTripsThroughAspectFillAndMirror() throws {
        for mirror in [false,true] {
            let projection = PreviewProjection(imageAspect:0.75,previewAspect:1,mirrored:mirror)
            let vision = CGRect(x:0.3,y:0.3,width:0.2,height:0.2)
            let visible = projection.visibleVisionRect(vision)
            let original = projection.imageRect(visible)
            XCTAssertEqual(original.minX,vision.minX,accuracy:0.00001)
            XCTAssertEqual(original.minY,1-vision.maxY,accuracy:0.00001)
            XCTAssertEqual(original.width,vision.width,accuracy:0.00001)
            XCTAssertEqual(original.height,vision.height,accuracy:0.00001)
        }
    }
    func testNoZoomWhenSubjectAlreadyHasPortraitProminence() throws {
        let subject = CGRect(x:0.18,y:0.18,width:0.64,height:0.64)
        let options = TargetRectangleSearch.options(subject:subject,label:"Cat",intent:.pet,evidence:try evidence(subject:subject),others:[],scales:[1,1.15,1.35,1.6],anatomy:nil)
        XCTAssertTrue(options.isEmpty)
    }
    func testSourceTargetCropMustExistInsideObservedImage() throws {
        let subject = CGRect(x:0,y:0,width:0.25,height:0.25)
        let options = TargetRectangleSearch.options(subject:subject,label:"Chair",intent:.product,evidence:try evidence(subject:subject),others:[],scales:[1,2,3],anatomy:nil)
        XCTAssertTrue(options.isEmpty,"No invented pixels beyond the observed view")
    }
    func testMeaningfulCompanionKeepsEnvironmentalComposition() throws {
        let cat = CGRect(x:0.25,y:0.4,width:0.2,height:0.2)
        let dog = CompositionContextSubject(bounds:CGRect(x:0.55,y:0.4,width:0.2,height:0.2),label:"Dog",confidence:0.95)
        XCTAssertTrue(TargetRectangleSearch.options(subject:cat,label:"Cat",intent:.pet,evidence:try evidence(subject:cat),others:[dog],scales:[1,2,3]).isEmpty)
    }
    func testBackgroundChairDoesNotForceCatPortraitToPreserveEntireRoom() throws {
        let cat = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
        let furniture = CompositionContextSubject(bounds:CGRect(x:0.03,y:0.2,width:0.2,height:0.5),label:"Chair",confidence:0.9)
        let options = TargetRectangleSearch.options(subject:cat,label:"Cat",intent:.pet,evidence:try evidence(subject:cat),others:[furniture],scales:[1,2,3])
        XCTAssertFalse(options.isEmpty); XCTAssertEqual(options.first?.protectedContext,[])
    }
    func testNearTopPetCanPlanModestSupportedZoomWithoutInventingOutsidePixels() throws {
        let cat = CGRect(x:0.3,y:0.16,width:0.45,height:0.4)
        let options = TargetRectangleSearch.options(subject:cat,label:"Cat",intent:.pet,evidence:try evidence(subject:cat),others:[],scales:[1,1.15,1.25])
        let selected = try XCTUnwrap(options.first)
        XCTAssertGreaterThan(selected.zoomScale,1)
        XCTAssertTrue(TargetRectangleGeometry.contains(SceneCompositionEvidence.full,selected.crop))
        XCTAssertTrue(TargetRectangleGeometry.contains(selected.crop,cat))
        XCTAssertLessThan(selected.target.y,0.5)
        let scene = SceneCompositionPlan(selected:selected,alternatives:[],subjectLabel:"Cat",timestamp:0)
        let shot = try XCTUnwrap(AutomaticShotPlan.propose(bounds:cat,label:"Cat",confidence:0.95,trackingReference:"cat",composition:scene,
            currentZoom:1.8,maximumZoom:5,detailLimit:2.25,nativeStops:[1,5],regions:[],anatomy:nil,projection:.init(imageAspect:0.75,previewAspect:0.75)))
        XCTAssertGreaterThan(shot.targetZoom,1.8); XCTAssertLessThanOrEqual(shot.targetZoom,2.25)
        let cue = try XCTUnwrap(CompositionCue(reading:.init(subjectBounds:cat,subjectConfidence:0.95,target:shot.aimingTarget(bounds:cat)),previewAspect:0.75))
        XCTAssertTrue(cue.phoneInstruction.contains("up"))
    }
    func testQualityBudgetAllowsSafeIntermediateCropBelowPhysicalStop() {
        let limit = AutomaticZoomQualityBudget.detailLimit(existing:1.8,previewShortSide:2160,photoPixels:48_000_000)
        XCTAssertEqual(limit,2.25,accuracy:0.00001)
        let scales = FramingPlanner.availableScales(currentZoom:1.8,maximumZoom:5,detailZoomLimit:limit,nativeStops:[1,5],maximumScale:3,desiredScale:1.7)
        XCTAssertTrue(scales.contains { abs($0-1.25) < 0.00001 })
        XCTAssertFalse(scales.contains { abs($0-1.7) < 0.00001 })
    }
    func testUnknownAnatomyCannotCreateFaceCandidate() throws {
        let subject = CGRect(x:0.35,y:0.35,width:0.3,height:0.3)
        let options = TargetRectangleSearch.options(subject:subject,label:"Cat",intent:.pet,evidence:try evidence(subject:subject),others:[],scales:[1,2],anatomy:nil)
        XCTAssertFalse(options.contains { $0.kind == .observedFacePortrait })
    }
    func testCompletedTargetRectangleExpandsToVisibleFrameDuringActualZoom() throws {
        let subject = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
        let (_,shot) = try selected(subject:subject)
        let before = try XCTUnwrap(shot.currentTargetRectangle(bounds:subject,zoom:1.8))
        let after = try XCTUnwrap(shot.currentTargetRectangle(bounds:shot.desiredBounds,zoom:shot.targetZoom))
        XCTAssertLessThan(before.width,1); XCTAssertEqual(after.width,1,accuracy:0.00001)
        XCTAssertEqual(after.minX,0,accuracy:0.00001); XCTAssertEqual(after.minY,0,accuracy:0.00001)
    }
    func testExplicitFailureAndManualCancellationStates() {
        var director = FramingPlanner(); director.stop(reason:.configuration)
        XCTAssertEqual(director.directorState(hasPlan:true),.failed)
        director.stop(reason:.manualControl); XCTAssertEqual(director.directorState(hasPlan:true),.canceled)
    }
    func testScenePlanIsWideAndNeedsRealSceneEvidenceForReadiness() throws {
        let e = try evidence(subject:CGRect(x:0.2,y:0.2,width:0.3,height:0.3))
        let shot = AutomaticShotPlan.scene(label:"Mountain",evidence:e,zoom:1,projection:.init(imageAspect:0.75,previewAspect:0.75))
        XCTAssertTrue(shot.sceneAnchor); XCTAssertFalse(shot.requiresZoom)
        let light = PhotoMeasurements(brightness:0.5,shadowFraction:0.1,highlightFraction:0.02,detail:0.04,backgroundEdges:nil)
        XCTAssertTrue(ShotReadiness.measuredSceneFrame(scene:.init(label:"Mountain",confidence:0.95,timestamp:0),evidence:e,measurements:light,stable:true,timestamp:0.5))
        XCTAssertFalse(ShotReadiness.measuredSceneFrame(scene:.init(label:"Mountain",confidence:0.95,timestamp:0),evidence:e,measurements:light,stable:false,timestamp:0.5))
        XCTAssertFalse(ShotReadiness.measuredSceneFrame(scene:nil,evidence:e,measurements:light,stable:true,timestamp:0.5))
    }
    func testGuidanceReceivesReasonWithoutChangingReadinessContract() {
        for enabled in [false,true] {
            var guidance = AutomaticGuidance()
            let reason:FramingBlockReason = enabled ? .manualControl : .disabled
            let message = guidance.update(reading:CompositionReading(),phase:.off,stable:true,rollReliable:false,autoEnabled:enabled,zoomAvailable:false,
                timestamp:1,framingInstruction:reason.instruction)
            XCTAssertEqual(message.text,reason.instruction)
        }
        XCTAssertFalse(ShotReadiness.permitsReady(required:true,shotVerified:false,currentFrameVerified:false))
    }
}
