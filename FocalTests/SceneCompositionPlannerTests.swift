import XCTest
@testable import Focal

final class SceneCompositionPlannerTests: XCTestCase {
    private let subject = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
    private func evidence(at time: Double = 0, pixel: (Int,Int) -> Double = { _,_ in 0.45 }) throws -> SceneCompositionEvidence {
        var pixels = [SubjectImageEvidence.Pixel]()
        for y in 0..<48 {
            for x in 0..<48 {
                let v = pixel(x,y)
                pixels.append(.init(red:v,green:v,blue:v))
            }
        }
        return try XCTUnwrap(SceneCompositionEvidence(image:.init(pixels:pixels,width:48,height:48),projection:.init(imageAspect:1,previewAspect:1),timestamp:time))
    }
    func testBlankFrameNeverInventsSubjectOrPlan() throws {
        var planner = SceneCompositionPlanner()
        let pixels = try evidence()
        XCTAssertNil(planner.update(subject:nil,confidence:1,label:"Wall",evidence:pixels,timestamp:0))
        XCTAssertNil(planner.plan)
        XCTAssertEqual(pixels.symmetry,0)
        XCTAssertEqual(pixels.repetition,0)
        XCTAssertTrue(pixels.lines.isEmpty)
    }
    func testInvalidOrLowConfidenceSubjectsCannotProducePlan() throws {
        let pixels = try evidence()
        for box in [CGRect(x:-0.1,y:0.4,width:0.2,height:0.2), CGRect.zero,
                    CGRect(x:0.4,y:0.4,width:CGFloat.nan,height:0.2)] {
            var planner = SceneCompositionPlanner()
            XCTAssertNil(planner.update(subject:box,confidence:1,label:"Desk",evidence:pixels,timestamp:0))
        }
        var planner = SceneCompositionPlanner()
        XCTAssertNil(planner.update(subject:subject,confidence:0.3,label:"Desk",evidence:pixels,timestamp:0))
    }
    func testNamedObjectsReceiveSamePlannerAsPeople() throws {
        let pixels = try evidence()
        var people = SceneCompositionPlanner(), objects = SceneCompositionPlanner()
        let a = try XCTUnwrap(people.update(subject:subject,confidence:1,label:"Person",evidence:pixels,timestamp:0))
        let b = try XCTUnwrap(objects.update(subject:subject,confidence:1,label:"Desk",evidence:pixels,timestamp:0))
        XCTAssertEqual(a.selected.technique,b.selected.technique)
        XCTAssertEqual(a.target,b.target)
        XCTAssertGreaterThan(b.alternatives.count,1)
    }
    func testCalmBackgroundPreservesNegativeSpaceWithoutZoom() throws {
        let options = SceneCompositionPlanner.compare(subject:subject,evidence:try evidence(),maximumScale:3)
        let negative = try XCTUnwrap(options.first { $0.technique == .negativeSpace })
        XCTAssertLessThan(negative.target.x,0.5)
        XCTAssertEqual(negative.zoomScale,1)
        XCTAssertEqual(negative.crop,SceneCompositionEvidence.full)
    }
    func testSymmetryRequiresVisiblePixelVariation() throws {
        let symmetrical = try evidence { x,_ in min(x,47-x)%10 < 5 ? 0.2 : 0.8 }
        XCTAssertGreaterThan(symmetrical.symmetry,0.9)
        XCTAssertTrue(SceneCompositionPlanner.compare(subject:subject,evidence:symmetrical).contains { $0.technique == .symmetry })
        XCTAssertFalse(SceneCompositionPlanner.compare(subject:subject,evidence:try evidence()).contains { $0.technique == .symmetry })
    }
    func testPatternsRequireActualPeriodicStructure() throws {
        let stripes = try evidence { x,_ in x%8 < 4 ? 0.2 : 0.8 }
        XCTAssertGreaterThan(stripes.repetition,0.78)
        let gradient = try evidence { x,_ in Double(x)/48 }
        XCTAssertLessThan(gradient.repetition,0.78)
    }
    func testLeadingLinesMustLeadTowardObservedSubject() throws {
        var pixels = try evidence()
        pixels.lines = [.init(start:.init(x:0.05,y:0.05),end:.init(x:0.95,y:0.95),support:0.9)]
        XCTAssertTrue(SceneCompositionPlanner.compare(subject:subject,evidence:pixels).contains { $0.technique == .leadingLines })
        pixels.lines = [.init(start:.init(x:0.05,y:0.1),end:.init(x:0.95,y:0.1),support:0.9)]
        XCTAssertFalse(SceneCompositionPlanner.compare(subject:subject,evidence:pixels).contains { $0.technique == .leadingLines })
    }
    func testEnclosingFrameIsRetainedAndCannotBeZoomedAway() throws {
        let frame = CGRect(x:0.05,y:0.05,width:0.9,height:0.9)
        let options = SceneCompositionPlanner.compare(subject:subject,evidence:try evidence(),enclosingFrames:[frame],maximumScale:4)
        let choice = try XCTUnwrap(options.first { $0.technique == .framing })
        XCTAssertTrue(choice.crop.contains(frame))
        XCTAssertEqual(choice.zoomScale,1)
        XCTAssertFalse(options.contains { $0.zoomScale > 1 })
    }
    func testPeopleFacesAndOverlappingDetectionsAreNotCountedTwice() {
        let face = CGRect(x:0.45,y:0.42,width:0.1,height:0.1)
        let duplicate = CompositionContextSubject(bounds:face,label:"Person",confidence:0.9)
        XCTAssertTrue(SceneCompositionPlanner.distinctSubjects([duplicate],selected:subject).isEmpty)
    }
    func testGroupTriangleRetainsEverySubjectAndDisablesZoom() throws {
        let others = [CompositionContextSubject(bounds:CGRect(x:0.05,y:0.15,width:0.15,height:0.2),label:"Dog",confidence:0.9),
                      CompositionContextSubject(bounds:CGRect(x:0.75,y:0.1,width:0.15,height:0.2),label:"Chair",confidence:0.9)]
        let options = SceneCompositionPlanner.compare(subject:subject,evidence:try evidence(),others:others,maximumScale:4)
        XCTAssertTrue(options.contains { $0.technique == .triangles })
        XCTAssertTrue(options.contains { $0.technique == .odds })
        XCTAssertTrue(options.allSatisfy { option in option.zoomScale == 1 && others.allSatisfy { other in option.crop.contains(other.bounds) } })
    }
    func testCropsStayInsideObservedViewAndRetainSubject() throws {
        let pixels = try evidence { x,y in (x/2+y/2)%2 == 0 ? 0.1 : 0.9 }
        let options = SceneCompositionPlanner.compare(subject:subject,evidence:pixels,maximumScale:1.35)
        XCTAssertFalse(options.isEmpty)
        for option in options {
            XCTAssertTrue(SceneCompositionEvidence.full.contains(option.crop))
            XCTAssertTrue(option.crop.contains(subject))
            XCTAssertLessThanOrEqual(option.zoomScale,1.35)
            if option.target != UnitPoint2D(x:0.5,y:0.5), option.zoomScale > 1 {
                XCTAssertTrue([CompositionTechnique.thirds,.goldenRatio,.contrast].contains(option.technique))
            }
        }
    }
    func testStaleEvidenceCannotAcquirePlan() throws {
        var planner = SceneCompositionPlanner()
        XCTAssertNil(planner.update(subject:subject,confidence:1,label:"Tree",evidence:try evidence(at:0),timestamp:2))
        XCTAssertNil(planner.update(subject:subject,confidence:1,label:"Tree",evidence:try evidence(at:3),timestamp:2))
    }
    func testAcceptableCurrentFrameDoesNotLockAnArbitraryCorner() throws {
        var planner = SceneCompositionPlanner()
        let first = try XCTUnwrap(planner.update(subject:subject,confidence:1,label:"Tree",evidence:try evidence(at:0),timestamp:0))
        let moved = CGRect(x:0.47,y:0.4,width:0.2,height:0.2)
        let second = try XCTUnwrap(planner.update(subject:moved,confidence:1,label:"Tree",evidence:try evidence(at:0.8),timestamp:0.8))
        XCTAssertTrue(first.selected.isCurrentFrame); XCTAssertTrue(second.selected.isCurrentFrame)
        XCTAssertEqual(second.target,UnitPoint2D(x:moved.midX,y:moved.midY))
    }
    func testLossClearsPlanBeforeNextSubject() throws {
        var planner = SceneCompositionPlanner()
        _ = planner.update(subject:subject,confidence:1,label:"Desk",evidence:try evidence(),timestamp:0)
        XCTAssertNil(planner.update(subject:nil,confidence:0,label:"Desk",evidence:nil,timestamp:0.2))
        XCTAssertNil(planner.update(subject:nil,confidence:0,label:"Desk",evidence:nil,timestamp:1))
        XCTAssertNil(planner.plan)
    }
    func testLensRampCannotChangeChosenStyle() throws {
        var planner = SceneCompositionPlanner()
        let old = try XCTUnwrap(planner.update(subject:subject,confidence:1,label:"Desk",evidence:try evidence(),timestamp:0))
        var different = try evidence(at:1)
        different.symmetry = 1
        let frozen = try XCTUnwrap(planner.update(subject:subject,confidence:1,label:"Desk",evidence:different,timestamp:1,freeze:true))
        XCTAssertEqual(old.selected.technique,frozen.selected.technique)
    }
    func testLargeSubjectsHaveSafeTargets() {
        let large = CGRect(x:0.1,y:0.2,width:0.8,height:0.6)
        let target = SceneCompositionPlanner.safeTarget(.init(x:0.333,y:0.333),subject:large)
        XCTAssertGreaterThanOrEqual(target.x-Double(large.width)/2,0.034)
        XCTAssertGreaterThanOrEqual(target.y-Double(large.height)/2,0.034)
    }
    func testOffCenterHoldSettlesWithoutHardwareZoom() {
        var planner = FramingPlanner()
        let target = UnitPoint2D(x:1.0/3,y:1.0/3)
        let box = CGRect(x:target.x-0.1,y:target.y-0.1,width:0.2,height:0.2)
        for time in [0.0,1.0] {
            XCTAssertNil(planner.update(bounds:box,confidence:1,roll:0,timestamp:time,currentZoom:1,maximumZoom:5,alignmentTarget:target,allowZoom:true))
        }
        XCTAssertEqual(planner.phase,.framed)
    }
    func testAutomaticZoomHonorsEvaluatedCropScale() {
        var planner = FramingPlanner()
        _ = planner.update(bounds:subject,confidence:1,roll:0,timestamp:0,currentZoom:1,maximumZoom:5,plannedScale:1.35)
        XCTAssertEqual(planner.update(bounds:subject,confidence:1,roll:0,timestamp:1,currentZoom:1,maximumZoom:5,plannedScale:1.35),1.35)
    }
    func testSubjectCompositionMeritDoesNotBypassIdentityRequirements() {
        var chair = SubjectCandidate(bounds:subject,confidence:0.9,category:.object,label:"Chair",classificationConfidence:0.8,prominence:0.8,isolation:0.8,detail:0.08)
        let baseline = chair.score(configuration:.init()) ?? 0
        chair.compositionPotential = 1
        XCTAssertGreaterThan(chair.score(configuration:.init()) ?? 0,baseline)
        chair.label = "Object"
        XCTAssertNil(chair.score(configuration:.init()))
    }
    func testGuideContainsJudgmentTechniquesWithoutAutomaticClaims() {
        XCTAssertEqual(CompositionTechnique.allCases.count,22)
        XCTAssertFalse(CompositionTechnique.curves.automatic)
        XCTAssertFalse(CompositionTechnique.leadRoom.automatic)
        XCTAssertFalse(CompositionTechnique.perspective.automatic)
    }
    func testPixelEvidenceMatchesMirroredAspectFillViewport() throws {
        let pixels = (0..<48).flatMap { _ in (0..<96).map { x in
            SubjectImageEvidence.Pixel(red:Double(x)/96,green:0.5,blue:0.5)
        } }
        let image = SubjectImageEvidence(pixels:pixels,width:96,height:48)
        let normal = try XCTUnwrap(SceneCompositionEvidence(image:image,projection:.init(imageAspect:2,previewAspect:1),timestamp:0))
        let mirrored = try XCTUnwrap(SceneCompositionEvidence(image:image,projection:.init(imageAspect:2,previewAspect:1,mirrored:true),timestamp:0))
        XCTAssertEqual(normal.image.pixels[0].red,mirrored.image.pixels[47].red,accuracy:0.02)
        XCTAssertGreaterThan(normal.image.pixels[0].red,0.23)
        XCTAssertLessThan(normal.image.pixels[47].red,0.76)
    }
    func testEnclosingContextDoesNotForceAChangeToAlreadyGoodFraming() throws {
        var planner = SceneCompositionPlanner()
        let first = try XCTUnwrap(planner.update(subject:subject,confidence:1,label:"Desk",evidence:try evidence(),timestamp:0))
        let frames = [CGRect(x:0.05,y:0.05,width:0.9,height:0.9)]
        let transient = try XCTUnwrap(planner.update(subject:subject,confidence:1,label:"Desk",evidence:try evidence(at:1),enclosingFrames:frames,timestamp:1))
        XCTAssertEqual(first.selected.technique,transient.selected.technique)
        let persistent = try XCTUnwrap(planner.update(subject:subject,confidence:1,label:"Desk",evidence:try evidence(at:2.7),enclosingFrames:frames,timestamp:2.7))
        XCTAssertTrue(persistent.selected.isCurrentFrame)
        XCTAssertTrue(persistent.selected.crop.contains(frames[0]))
    }
    func testKeepCurrentPlanDoesNotInventCameraMovement() throws {
        var planner = SceneCompositionPlanner(), guidance = AutomaticGuidance()
        let plan = try XCTUnwrap(planner.update(subject:subject,confidence:1,label:"Desk",evidence:try evidence(),timestamp:0))
        let reading = CompositionReading(state:.ready,subject:.init(x:0.5,y:0.5),subjectBounds:subject,subjectConfidence:1,target:plan.target)
        var message = GuidanceMessage()
        for time in [0.0,1.0,2.0] {
            message = guidance.update(reading:reading,phase:.off,stable:true,rollReliable:true,autoEnabled:false,zoomAvailable:false,timestamp:time,subjectLabel:"Desk",compositionPlan:plan)
        }
        XCTAssertEqual(message.action,GuidanceAction.none)
        XCTAssertFalse(message.showsDirection)
    }
    func testAutomaticEngineHonorsPlanWhileManualCenterOverridesIt() {
        let target = UnitPoint2D(x:1.0/3,y:0.5)
        var engine = CompositionEngine()
        _ = engine.update(subject:target,rollDegrees:0,mode:.automatic,timestamp:0,preferredTarget:target)
        let automatic = engine.update(subject:target,rollDegrees:0,mode:.automatic,timestamp:1,preferredTarget:target)
        XCTAssertEqual(automatic.target,target)
        XCTAssertEqual(automatic.state,.ready)
        let manual = engine.update(subject:target,rollDegrees:0,mode:.centered,timestamp:2,preferredTarget:target)
        XCTAssertEqual(manual.target,UnitPoint2D(x:0.5,y:0.5))
        XCTAssertEqual(manual.state,.adjusting)
    }
    func testVerifiedCurrentFrameChoiceRefreshesWithoutCropReassessment() throws {
        var planner = SceneCompositionPlanner()
        let initial = try XCTUnwrap(planner.update(subject:subject,confidence:1,label:"Desk",evidence:try evidence(),timestamp:0))
        XCTAssertTrue(initial.selected.isCurrentFrame)
        for time in [0.8,1.6,2.4,3.2] {
            let retained = try XCTUnwrap(planner.update(subject:subject,confidence:1,label:"Desk",evidence:try evidence(at:time),timestamp:time,maximumScale:3,freeze:true))
            XCTAssertTrue(retained.selected.isCurrentFrame)
            XCTAssertFalse(retained.permitsZoom)
            XCTAssertEqual(retained.timestamp,time)
        }
    }
    func testExplicitAlternativeCanLeaveVerifiedCurrentFrameChoice() throws {
        var planner = SceneCompositionPlanner()
        let first = try XCTUnwrap(planner.update(subject:subject,confidence:1,label:"Desk",evidence:try evidence(),timestamp:0))
        XCTAssertTrue(first.selected.isCurrentFrame)
        planner.requestAlternative()
        let different = try XCTUnwrap(planner.update(subject:subject,confidence:1,label:"Desk",evidence:try evidence(at:0.5),timestamp:0.5,freeze:true))
        XCTAssertNotEqual(different.selected.technique,first.selected.technique)
    }
    func testExplicitAlternativeIsNotBlockedByFrozenNoncurrentChoice() throws {
        var planner = SceneCompositionPlanner()
        _ = try XCTUnwrap(planner.update(subject:subject,confidence:1,label:"Desk",evidence:try evidence(),timestamp:0))
        planner.requestAlternative()
        let selected = try XCTUnwrap(planner.update(subject:subject,confidence:1,label:"Desk",evidence:try evidence(at:0.2),timestamp:0.2))
        XCTAssertFalse(selected.selected.isCurrentFrame)
        planner.requestAlternative()
        let alternative = try XCTUnwrap(planner.update(subject:subject,confidence:1,label:"Desk",evidence:try evidence(at:0.4),timestamp:0.4,freeze:true))
        XCTAssertNotEqual(alternative.selected.technique,selected.selected.technique)
    }
    func testVerifiedChoiceDoesNotHideCurrentSubjectLossOrStaleEvidence() throws {
        var planner = SceneCompositionPlanner()
        _ = try XCTUnwrap(planner.update(subject:subject,confidence:1,label:"Desk",evidence:try evidence(),timestamp:0))
        XCTAssertNil(planner.update(subject:subject,confidence:0.2,label:"Desk",evidence:try evidence(at:0.5),timestamp:0.5,freeze:true))
        XCTAssertNil(planner.update(subject:subject,confidence:1,label:"Desk",evidence:try evidence(),timestamp:3,freeze:true))
    }
    func testHorizonAdviceRequiresLandscapeAndObservedHorizontalBoundary() throws {
        let pixels = try evidence { _,y in y < 24 ? 0.2 : 0.8 }
        XCTAssertNotNil(pixels.horizontalBoundary())
        var guidance = AutomaticGuidance()
        let landscape = SubjectScene(label:"Mountain",confidence:0.9,timestamp:0)
        let message = guidance.update(reading:.init(),phase:.off,stable:true,rollReliable:false,autoEnabled:true,zoomAvailable:false,timestamp:0,scene:landscape,sceneEvidence:pixels)
        XCTAssertEqual(message.kind,.scene)
        XCTAssertEqual(message.action,GuidanceAction.none)
        let nonLandscape = SubjectScene(label:"Desk",confidence:0.9,timestamp:0)
        let noHorizon = guidance.update(reading:.init(),phase:.off,stable:true,rollReliable:false,autoEnabled:true,zoomAvailable:false,timestamp:0,scene:nonLandscape,sceneEvidence:pixels)
        XCTAssertEqual(noHorizon.kind,.searching)
    }
}
