import XCTest
@testable import Focal

final class GuidanceRefinementTests: XCTestCase {
    private func advice(_ kind: AutoTuneRecommendation.Kind, at time: Double, ev: Double? = nil) -> AutoTuneRecommendation {
        .init(kind:kind,title:kind.rawValue,reason:"Measured preview",exposureBias:ev,timestamp:time)
    }
    private func reading(x: Double = 0.5) -> CompositionReading {
        CompositionReading(state:.ready,subject:.init(x:x,y:0.5),subjectBounds:CGRect(x:x-0.1,y:0.4,width:0.2,height:0.2),subjectConfidence:0.9,target:.init(x:0.5,y:0.5))
    }
    func testSonyAddressDefaultsAndPreservesOnlyValidSavedHost() {
        XCTAssertEqual(SonyEndpoint.initialHost(previous:nil),"192.168.122.1")
        XCTAssertEqual(SonyEndpoint.initialHost(previous:""),"192.168.122.1")
        XCTAssertEqual(SonyEndpoint.initialHost(previous:"https://example.com"),"192.168.122.1")
        XCTAssertEqual(SonyEndpoint.initialHost(previous:" 192.168.1.9 "),"192.168.1.9")
    }
    func testLensTransitionRetainsProAndLensChoicesWithoutOldCapabilities() {
        let lenses = [CameraLensOption(id:"wide",label:"Wide"),CameraLensOption(id:"tele",label:"Telephoto")]
        let snapshot = CameraControlSnapshot.transitioning(mode:.pro,lenses:lenses)
        XCTAssertEqual(snapshot.mode,.pro); XCTAssertEqual(snapshot.lenses,lenses)
        XCTAssertNil(snapshot.isoRange); XCTAssertNil(snapshot.lensID)
        XCTAssertFalse(snapshot.canFocus)
    }
    func testBriefAdviceRemainsReadableThenClears() {
        var presenter = AutoTunePresentation()
        XCTAssertEqual(presenter.update([advice(.light,at:0)],at:0).first?.kind,.light)
        XCTAssertEqual(presenter.update([],at:0.35).first?.kind,.light)
        XCTAssertEqual(presenter.update([],at:3.4).first?.kind,.light)
        XCTAssertTrue(presenter.update([],at:3.6).isEmpty)
    }
    func testDifferentAdviceWaitsForReadableDwellAndRepeatedEvidence() {
        var presenter = AutoTunePresentation()
        _ = presenter.update([advice(.light,at:0)],at:0)
        XCTAssertEqual(presenter.update([advice(.motion,at:1)],at:1).first?.kind,.light)
        XCTAssertEqual(presenter.update([advice(.motion,at:3)],at:3).first?.kind,.light)
        XCTAssertEqual(presenter.update([advice(.motion,at:3.6)],at:3.6).first?.kind,.motion)
    }
    func testRetainedAdviceCannotApplyExpiredExposureSuggestion() throws {
        var presenter = AutoTunePresentation()
        _ = presenter.update([advice(.highlights,at:0,ev:-0.3)],at:0)
        let retained = try XCTUnwrap(presenter.update([],at:2.3).first)
        XCTAssertEqual(retained.timestamp,0)
        XCTAssertFalse(AutoTune.permitsApplication(retained,source:.iPhone,mode:.auto,manualExposure:false,paused:false,busy:false,now:2.3))
    }
    func testSameAdviceRefreshesMeasurementWithoutRestartingDwell() {
        var presenter = AutoTunePresentation()
        _ = presenter.update([advice(.light,at:0)],at:0)
        XCTAssertEqual(presenter.update([advice(.light,at:2)],at:2).first?.timestamp,2)
        XCTAssertTrue(presenter.update([],at:3.6).isEmpty)
    }
    func testAdviceResetsAcrossClockRegressionAndPause() {
        var presenter = AutoTunePresentation()
        _ = presenter.update([advice(.light,at:10)],at:10)
        XCTAssertTrue(presenter.update([],at:9).isEmpty)
        _ = presenter.update([advice(.motion,at:10)],at:10)
        XCTAssertTrue(presenter.update([],at:15).isEmpty)
    }
    func testSpecificClassifierLabelsOutsideLegacyListAreEligible() {
        for label in ["Telescope","Violin","Umbrella","Saxophone","Teapot","Dragonfly","Seashell"] {
            XCTAssertFalse(SubjectIdentity.isCommonPhotographicSubject(label))
            XCTAssertEqual(SubjectIdentity.recognized([(label,0.4),("Desk",0.1)],localized:true)?.name,label)
        }
    }
    func testBroaderRecognitionStillRejectsWeakAmbiguousAndGenericPredictions() {
        XCTAssertNil(SubjectIdentity.recognized([("Telescope",0.3)],localized:true))
        XCTAssertNil(SubjectIdentity.recognized([("Violin",0.4),("Guitar",0.38)],localized:true))
        XCTAssertNil(SubjectIdentity.recognized([("Object",0.99)],localized:true))
        XCTAssertNil(SubjectIdentity.recognized([("Imaginary thing",0.99)],localized:true))
    }
    func testNewObjectLabelStillNeedsSpatialEvidenceAndSelectionDwell() throws {
        var object = SubjectCandidate(bounds:CGRect(x:0.35,y:0.35,width:0.3,height:0.3),confidence:0.95,
            category:.object,label:"Violin",classificationConfidence:0.4,prominence:0.9,isolation:0.01,detail:0.02,localizedProposal:true)
        XCTAssertGreaterThan(try XCTUnwrap(object.score(configuration:.init())),0.68)
        var selector = SubjectSelector()
        XCTAssertNil(selector.select([object],timestamp:0))
        XCTAssertNil(selector.select([object],timestamp:0.65))
        XCTAssertEqual(selector.select([object],timestamp:1.3),0)
        object.localizedProposal = false
        XCTAssertNil(object.score(configuration:.init()))
    }
    func testCropSchedulingRevisitsEveryProposalWithinTwoCropBudget() {
        var schedule = SubjectCropSchedule()
        XCTAssertEqual(schedule.indices(count:4),[0,1])
        XCTAssertEqual(schedule.indices(count:4),[0,2])
        XCTAssertEqual(schedule.indices(count:4),[0,3])
        XCTAssertEqual(schedule.indices(count:4),[0,1])
        XCTAssertEqual(schedule.indices(count:1),[0]); XCTAssertEqual(schedule.indices(count:0),[])
    }
    func testCachedCropIdentityNeedsFreshMatchingBoundary() {
        var cache = SubjectCropIdentityCache()
        let box = CGRect(x:0.3,y:0.3,width:0.2,height:0.2)
        cache.store(bounds:box,name:"Violin",confidence:0.8,at:1)
        XCTAssertEqual(cache.identity(for:box.offsetBy(dx:0.01,dy:0),at:2)?.name,"Violin")
        XCTAssertNil(cache.identity(for:box.offsetBy(dx:0.4,dy:0),at:2))
        XCTAssertNil(cache.identity(for:box,at:4)); XCTAssertNil(cache.identity(for:box,at:0))
        cache.invalidate(box); XCTAssertNil(cache.identity(for:box,at:2))
    }
    func testOffCenterAutomaticZoomLandsOnChosenThirdsPoint() throws {
        let final = UnitPoint2D(x:1.0/3,y:1.0/3), scale = 1.6
        let start = UnitPoint2D(x:0.5+(final.x-0.5)/scale,y:0.5+(final.y-0.5)/scale)
        let box = CGRect(x:start.x-0.08,y:start.y-0.08,width:0.16,height:0.16)
        var planner = FramingPlanner()
        func step(_ time: Double) -> Double? {
            planner.update(bounds:box,confidence:0.9,roll:0,timestamp:time,currentZoom:1,maximumZoom:3,
                detailZoomLimit:2,alignmentTarget:start,plannedScale:scale,zoomDestination:final)
        }
        XCTAssertNil(step(0)); XCTAssertEqual(planner.phase,.settling)
        let zoom = try XCTUnwrap(step(1))
        let projected = FramingPlanner.zoomedRect(box,scale:zoom)
        XCTAssertEqual(projected.midX,final.x,accuracy:0.0001)
        XCTAssertEqual(projected.midY,final.y,accuracy:0.0001)
        XCTAssertTrue(CGRect(x:0,y:0,width:1,height:1).contains(projected))
        XCTAssertEqual(planner.phase,.zooming)
    }
    func testUnverifiedOffCenterCropCannotStartAutomaticZoom() {
        let final = UnitPoint2D(x:1.0/3,y:1.0/3)
        let box = CGRect(x:final.x-0.08,y:final.y-0.08,width:0.16,height:0.16)
        var planner = FramingPlanner()
        for time in [0.0,1.0] {
            XCTAssertNil(planner.update(bounds:box,confidence:1,roll:0,timestamp:time,currentZoom:1,maximumZoom:3,
                alignmentTarget:final,plannedScale:1.6,zoomDestination:final))
        }
        XCTAssertEqual(planner.phase,.framed)
    }
    func testCropBudgetAllowsRealNativeStopsWithoutIntermediateDigitalEnlargement() {
        let scales = FramingPlanner.availableScales(currentZoom:1,maximumZoom:5,detailZoomLimit:1.35,nativeStops:[1,3,5],maximumScale:3)
        XCTAssertTrue(scales.contains(1.35)); XCTAssertTrue(scales.contains(3))
        XCTAssertFalse(scales.contains(1.6)); XCTAssertFalse(scales.contains(2.5))
        XCTAssertFalse(scales.contains(5))
    }
    func testManualCancellationDisarmsPlannedOffCenterZoom() {
        var planner = FramingPlanner(); planner.reset(enabled:false)
        XCTAssertNil(planner.update(bounds:CGRect(x:0.3,y:0.3,width:0.2,height:0.2),confidence:1,roll:0,timestamp:10,
            currentZoom:1,maximumZoom:3,alignmentTarget:.init(x:0.4,y:0.4),plannedScale:1.6,zoomDestination:.init(x:1.0/3,y:1.0/3)))
        XCTAssertEqual(planner.phase,.off)
    }
    func testZoomPlanComputesRealPreZoomAlignmentPoint() {
        let target = UnitPoint2D(x:1.0/3,y:2.0/3)
        let option = CompositionOption(technique:.thirds,target:target,crop:CGRect(x:0.1875,y:0.1875,width:0.625,height:0.625),score:0.8,explanation:"Keep the subject",zoomScale:1.6,measuredImprovement:0.2)
        let plan = SceneCompositionPlan(selected:option,alternatives:[],subjectLabel:"Violin",timestamp:0)
        XCTAssertTrue(plan.permitsZoom)
        XCTAssertEqual((plan.zoomAlignmentTarget.x-0.5)*1.6+0.5,target.x,accuracy:0.0001)
        XCTAssertEqual((plan.zoomAlignmentTarget.y-0.5)*1.6+0.5,target.y,accuracy:0.0001)
    }
    func testPlannerEvaluatesOffCenterCropsAndHonorsAvailableQualityScales() throws {
        let pixels = (0..<48*48).map { index -> SubjectImageEvidence.Pixel in
            let x = index%48, y = index/48
            let inside = (19...28).contains(x) && (19...28).contains(y)
            return .init(red:inside ? 0.8 : 0.2,green:0.2,blue:0.2)
        }
        let evidence = try XCTUnwrap(SceneCompositionEvidence(image:.init(pixels:pixels,width:48,height:48),projection:.init(imageAspect:1,previewAspect:1),timestamp:0))
        let subject = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
        let options = SceneCompositionPlanner.compare(subject:subject,evidence:evidence,maximumScale:3,intent:.product,availableScales:[1,1.6],label:"Violin")
        let thirds = try XCTUnwrap(options.first { $0.measuredImprovement >= IntentCompositionSearch.minimumImprovement })
        XCTAssertEqual(thirds.zoomScale,1.6)
        XCTAssertTrue(options.allSatisfy { $0.zoomScale == 1 || $0.zoomScale == 1.6 })
        let projected = CGRect(x:thirds.target.x-Double(subject.width)*thirds.zoomScale/2,y:thirds.target.y-Double(subject.height)*thirds.zoomScale/2,
                               width:Double(subject.width)*thirds.zoomScale,height:Double(subject.height)*thirds.zoomScale)
        XCTAssertTrue(CGRect(x:0.025,y:0.025,width:0.95,height:0.95).contains(projected))
    }
    func testUnsafeSubjectCropCannotTriggerZoomEvenWithCorrectDestination() {
        let final = UnitPoint2D(x:1.0/3,y:1.0/3), scale = 1.6
        let start = UnitPoint2D(x:0.5+(final.x-0.5)/scale,y:0.5+(final.y-0.5)/scale)
        let box = CGRect(x:start.x-0.25,y:start.y-0.25,width:0.5,height:0.5)
        var planner = FramingPlanner()
        for time in [0.0,1.0] {
            XCTAssertNil(planner.update(bounds:box,confidence:1,roll:0,timestamp:time,currentZoom:1,maximumZoom:3,
                alignmentTarget:start,plannedScale:scale,zoomDestination:final))
        }
        XCTAssertEqual(planner.phase,.framed)
    }
    func testReadyFrameIsNotBlockedByOptionalBackgroundAdvice() {
        var guide = AutomaticGuidance()
        let busy = PhotoMeasurements(brightness:0.5,shadowFraction:0.1,highlightFraction:0,detail:0.04,backgroundEdges:0.5)
        func step(_ time: Double) -> GuidanceMessage {
            guide.update(reading:reading(),phase:.framed,stable:true,rollReliable:true,autoEnabled:true,
                zoomAvailable:true,timestamp:time,subjectLabel:"Violin",subjectMeasurements:busy)
        }
        _ = step(0); _ = step(0.5)
        XCTAssertEqual(step(1.2).kind,.ready)
    }
    func testSeverelyDarkSubjectKeepsSpecificLightWarning() {
        var guide = AutomaticGuidance()
        let dark = PhotoMeasurements(brightness:0.1,shadowFraction:0.8,highlightFraction:0,detail:0.04,backgroundEdges:0.5)
        func step(_ time: Double) -> GuidanceMessage {
            guide.update(reading:reading(),phase:.settling,stable:true,rollReliable:true,autoEnabled:true,
                zoomAvailable:true,timestamp:time,subjectLabel:"Violin",subjectMeasurements:dark)
        }
        _ = step(0)
        XCTAssertEqual(step(0.6).action,.addLight)
    }
    func testDirectionUsesRawBoundaryAndSharedCropTolerance() throws {
        var value = reading(x:0.5)
        value.guidanceBounds = CGRect(x:0.445,y:0.4,width:0.2,height:0.2)
        value.alignmentTolerance = FramingPlanner.alignmentTolerance(plannedScale:3,destination:.init(x:1.0/3,y:1.0/3))
        XCTAssertEqual(value.alignmentTolerance,0.02,accuracy:0.00001)
        XCTAssertFalse(try XCTUnwrap(CompositionCue(reading:value,previewAspect:0.75)).aligned)
        value.guidanceBounds = CGRect(x:0.405,y:0.4,width:0.2,height:0.2)
        XCTAssertTrue(try XCTUnwrap(CompositionCue(reading:value,previewAspect:0.75)).aligned)
    }
}
