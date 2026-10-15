import XCTest
import UIKit
@testable import Focal

final class IntelligenceAcceptanceTests: XCTestCase {
    private let cat = CGRect(x:0.2,y:0.2,width:0.6,height:0.55)
    private func evidence() throws -> SceneCompositionEvidence {
        let pixels = (0..<48*48).map { index -> SubjectImageEvidence.Pixel in
            let value = (index%48/3+index/48/3)%2 == 0 ? 0.25 : 0.65
            return .init(red:value,green:value,blue:value)
        }
        return try XCTUnwrap(.init(image:.init(pixels:pixels,width:48,height:48),projection:.init(imageAspect:1,previewAspect:1),timestamp:0))
    }
    private func decision(box:CGRect,label:String = "Cat",intent:PhotographyIntent = .pet,stable:Bool = true,plan:SceneCompositionPlan? = nil,measurements:PhotoMeasurements? = nil) -> FeasibleGuidance {
        let facts = CompositionAssessment.evaluate(bounds:box,confidence:0.95,label:label,intent:intent,stable:stable,exposure:measurements,evidence:nil)
        let reading = CompositionReading(state:.ready,subjectBounds:box,subjectConfidence:0.95,target:plan?.target ?? .init(x:box.midX,y:box.midY))
        return ActionFeasibility.recommend(assessment:facts,reading:reading,intent:intent,plan:plan,rollReliable:false,previewAspect:1)
    }
    func testCatOnClutteredBedAlreadyFramedNeedsNoIsolation() {
        let texture = PhotoMeasurements(brightness:0.5,shadowFraction:0.1,highlightFraction:0,detail:0.08,backgroundEdges:0.8)
        XCTAssertEqual(decision(box:cat,measurements:texture).action,.none)
        XCTAssertEqual(decision(box:cat,measurements:texture).text,"Ready to shoot")
    }
    func testCatPartlyOutsideVisibleFrameNeedsRoom() {
        let result = decision(box:CGRect(x:-0.04,y:0.2,width:0.5,height:0.6))
        XCTAssertEqual(result.action,.makeRoom)
        XCTAssertFalse(result.text.contains("body parts"))
    }
    func testLargeContainedCatDoesNotTriggerStepBack() {
        XCTAssertEqual(decision(box:CGRect(x:0.06,y:0.2,width:0.88,height:0.6)).action,.none)
    }
    func testSmallCatGetsCloserCropOnlyAfterMeasuredImprovement() throws {
        let box = CGRect(x:0.45,y:0.45,width:0.1,height:0.1)
        let options = SceneCompositionPlanner.compare(subject:box,evidence:try evidence(),maximumScale:3,intent:.pet,label:"Cat")
        let selected = try XCTUnwrap(options.first)
        let plan = SceneCompositionPlan(selected:selected,alternatives:[],subjectLabel:"Cat",timestamp:0)
        XCTAssertGreaterThanOrEqual(selected.measuredImprovement,IntentCompositionSearch.minimumImprovement)
        XCTAssertTrue(plan.permitsZoom)
        XCTAssertEqual(decision(box:box,plan:plan).action,.tighterCrop)
        XCTAssertEqual(decision(box:box).action,.none) // No evidence of a feasible improvement.
    }
    func testWellComposedOffCenterPersonNeedsNoForcedThirds() throws {
        let box = CGRect(x:0.38,y:0.12,width:0.42,height:0.72)
        let options = SceneCompositionPlanner.compare(subject:box,evidence:try evidence(),maximumScale:1.6,intent:.portrait,label:"Person")
        XCTAssertTrue(try XCTUnwrap(options.first).isCurrentFrame)
        XCTAssertEqual(decision(box:box,label:"Person",intent:.portrait).action,.none)
    }
    func testLandscapeHasSceneGuidanceAndNoInventedBox() {
        var guide = AutomaticGuidance()
        let result = guide.update(reading:.init(),phase:.off,stable:true,rollReliable:false,autoEnabled:true,zoomAvailable:false,timestamp:0,intent:.landscape)
        XCTAssertEqual(result.kind,.scene); XCTAssertFalse(result.showsDirection)
        XCTAssertEqual(result.text,"Ready to shoot")
    }
    func testMultipleObjectsRetainContextInCandidateSearch() throws {
        let other = CompositionContextSubject(bounds:CGRect(x:0.75,y:0.2,width:0.2,height:0.3),label:"Chair",confidence:0.9)
        let candidates = IntentCompositionSearch.candidates(subject:CGRect(x:0.2,y:0.3,width:0.2,height:0.3),label:"Table",intent:.auto,evidence:try evidence(),others:[other],frames:[],scales:[1,1.6,2.5])
        XCTAssertTrue(candidates.allSatisfy { $0.crop.contains(other.bounds) })
    }
    func testMovementDoesNotImmediatelyFlipDirection() {
        var memory = RecommendationMemory()
        let right = FeasibleGuidance(action:.panRight,text:"Right",confidence:0.9,issue:0.2)
        let left = FeasibleGuidance(action:.panLeft,text:"Left",confidence:0.9,issue:0.2)
        _ = memory.update(right,bounds:cat,label:"Cat",intent:.pet,timestamp:0)
        XCTAssertEqual(memory.update(left,bounds:cat,label:"Cat",intent:.pet,timestamp:0.2).action,.panRight)
        XCTAssertEqual(memory.update(left,bounds:cat,label:"Cat",intent:.pet,timestamp:1).action,.panRight)
        XCTAssertEqual(memory.update(left,bounds:cat,label:"Cat",intent:.pet,timestamp:2).action,.panLeft)
    }
    func testManualRegionSelectionBypassesAutomaticRelevanceWithoutFakeConfidence() {
        var selector = SubjectSelector()
        let selected = SubjectCandidate(bounds:CGRect(x:0.2,y:0.2,width:0.3,height:0.3),confidence:0.9,category:.object,label:"Your subject",detail:0.03,localizedProposal:true)
        var selectable = selected; selectable.prominence = 0.8
        XCTAssertNil(selectable.score(configuration:.init()))
        XCTAssertEqual(selector.select([selectable],timestamp:0,manualPoint:CGPoint(x:0.3,y:0.3)),0)
    }
    func testManualPinchDisarmsEvenAnImprovedCrop() {
        var planner = FramingPlanner(); planner.reset(enabled:false)
        XCTAssertNil(planner.update(bounds:CGRect(x:0.45,y:0.45,width:0.1,height:0.1),confidence:0.95,roll:0,timestamp:2,currentZoom:1,maximumZoom:3,plannedScale:2.5))
        XCTAssertEqual(planner.phase,.off)
    }
    func testNoMeaningfulImprovementSelectsCurrentFrame() throws {
        let options = SceneCompositionPlanner.compare(subject:cat,evidence:try evidence(),maximumScale:3,intent:.pet,label:"Cat")
        XCTAssertTrue(try XCTUnwrap(options.first).isCurrentFrame)
        XCTAssertEqual(options.first?.zoomScale,1)
    }
    func testMemoryWithdrawsAdviceWhenSameIssueWorsensAfterPositionChanges() {
        var memory = RecommendationMemory()
        for (time,x,issue) in [(0.0,0.1,0.1),(0.5,0.15,0.25),(1.0,0.2,0.4)] {
            let next = FeasibleGuidance(action:.panRight,text:"Right",confidence:0.9,issue:issue)
            let result = memory.update(next,bounds:cat.offsetBy(dx:x,dy:0),label:"Cat",intent:.pet,timestamp:time)
            if time == 1 { XCTAssertEqual(result.action,.hold); XCTAssertTrue(result.text.contains("reassesses")) }
        }
    }
    func testSuccessfulAlignmentWithdrawsPreviousPanImmediately() {
        var memory = RecommendationMemory()
        _ = memory.update(.init(action:.panRight,text:"Right",confidence:0.9,issue:0.2),bounds:cat,label:"Cat",intent:.pet,timestamp:0)
        let result = memory.update(.init(action:.none,text:"Ready to shoot",confidence:0.9,issue:0),bounds:cat,label:"Cat",intent:.pet,timestamp:0.2)
        XCTAssertEqual(result.action,.none)
    }
    func testDifferentSubjectAndClockRegressionClearRecommendationHistory() {
        var memory = RecommendationMemory()
        _ = memory.update(.init(action:.panRight,text:"Right",confidence:0.9,issue:0.2),bounds:cat,label:"Cat",intent:.pet,timestamp:10)
        let next = FeasibleGuidance(action:.panLeft,text:"Left",confidence:0.9,issue:0.2)
        XCTAssertEqual(memory.update(next,bounds:cat,label:"Dog",intent:.pet,timestamp:11).action,.panLeft)
        XCTAssertEqual(memory.update(.init(action:.none,text:"Ready",confidence:0.9,issue:0),bounds:cat,label:"Cat",intent:.pet,timestamp:1).action,.none)
    }
    func testMissingPoseJointsAreNotProofOfClippedLimbs() {
        let facts = CompositionAssessment.evaluate(bounds:cat,confidence:0.95,label:"Cat",intent:.pet,stable:true,exposure:nil,evidence:nil,
            anatomy:SubjectAnatomy(face:nil,joints:[CGPoint(x:0.5,y:0.5)],timestamp:0))
        XCTAssertEqual(facts.edgeJointCount,0); XCTAssertFalse(facts.touchesEdge)
        XCTAssertNil(facts.headroom); XCTAssertNil(facts.headYaw)
    }
    func testConfidentVisibleJointOnEdgeSuppliesMarginEvidence() {
        let box = CGRect(x:0.01,y:0.1,width:0.8,height:0.8)
        let facts = CompositionAssessment.evaluate(bounds:box,confidence:0.95,label:"Cat",intent:.pet,stable:true,exposure:nil,evidence:nil,
            anatomy:SubjectAnatomy(face:nil,joints:[CGPoint(x:0.01,y:0.5)],timestamp:0))
        XCTAssertEqual(facts.edgeJointCount,1); XCTAssertTrue(facts.touchesEdge)
    }
    func testStaleAnatomyCannotCreateAClippingWarning() {
        let facts = CompositionAssessment.evaluate(bounds:cat,confidence:0.95,label:"Cat",intent:.pet,stable:true,exposure:nil,evidence:nil,
            anatomy:SubjectAnatomy(face:nil,joints:[CGPoint(x:0,y:0.5)],timestamp:0),timestamp:5)
        XCTAssertEqual(facts.edgeJointCount,0)
    }
    func testPortraitAndProductHaveIntentSpecificSizeProfiles() {
        let portrait = IntentFramingProfile.forIntent(.portrait,category:.person,hasContext:false)
        let architecture = IntentFramingProfile.forIntent(.architecture,category:.architecture,hasContext:false)
        XCTAssertGreaterThan(portrait.minimumArea,architecture.minimumArea)
        XCTAssertLessThan(portrait.maximumArea,architecture.maximumArea)
    }
    func testCropSearchNeverInventsPixelsOrDropsEnclosingContext() throws {
        let enclosure = CGRect(x:0.05,y:0.05,width:0.9,height:0.9)
        let candidates = IntentCompositionSearch.candidates(subject:cat,label:"Cat",intent:.pet,evidence:try evidence(),others:[],frames:[enclosure],scales:[1,1.6,3])
        XCTAssertTrue(candidates.allSatisfy { SceneCompositionEvidence.full.contains($0.crop) && $0.crop.contains(enclosure) })
        XCTAssertEqual(candidates.count,1)
    }
    func testCurrentFrameTargetCanFollowHarmlessJitterWithoutResettingReadiness() {
        var engine = CompositionEngine()
        for (time,x) in [(0.0,0.4),(0.4,0.402),(0.8,0.401)] {
            let point = UnitPoint2D(x:x,y:0.5)
            let reading = engine.update(subject:point,rollDegrees:0,mode:.automatic,timestamp:time,preferredTarget:point,acceptCurrentFrame:true)
            if time == 0.8 { XCTAssertEqual(reading.state,.ready) }
        }
    }
    func testRealLandscapePhotoRunsSharedAnalysisWithoutInventingAnObjectBox() async throws {
        let image = try XCTUnwrap(UIImage(named:"DemoScene"))
        let data = try XCTUnwrap(image.jpegData(compressionQuality:0.95))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".jpg")
        try data.write(to:url); defer { try? FileManager.default.removeItem(at:url) }
        let result = try await SceneAnalyzer.shared.analyze(url,intent:.landscape)
        XCTAssertTrue(result.landscape); XCTAssertNil(result.selected); XCTAssertTrue(result.subjects.isEmpty)
        XCTAssertTrue(result.measurements.brightness.isFinite)
        XCTAssertEqual(try Data(contentsOf:url),data)
        let recommendation = ActionFeasibility.sceneRecommendation(landscape:result.landscape,stable:true,roll:0,rollReliable:false,
            measurements:result.measurements,evidence:result.evidence,timestamp:0,previewAspect:result.aspect)
        XCTAssertFalse(try XCTUnwrap(recommendation).showsDirection)
    }
    func testBasicZoomAlsoRequiresMeasuredImprovementWhenLayoutPlanningIsOff() throws {
        XCTAssertNil(IntentCompositionSearch.zoomPlan(subject:cat,label:"Cat",intent:.pet,evidence:try evidence(),others:[],frames:[],scales:[1,1.6,3],forceCenter:true))
        let tiny = CGRect(x:0.45,y:0.45,width:0.1,height:0.1)
        let plan = try XCTUnwrap(IntentCompositionSearch.zoomPlan(subject:tiny,label:"Cat",intent:.pet,evidence:try evidence(),others:[],frames:[],scales:[1,1.6,3],forceCenter:true))
        XCTAssertTrue(plan.permitsZoom)
        XCTAssertEqual(plan.target,UnitPoint2D(x:0.5,y:0.5))
    }
    func testBasicAutomaticCropPreservesObservedOffCenterPositionWithoutForcedPan() throws {
        let tiny = CGRect(x:0.39,y:0.41,width:0.1,height:0.1)
        let plan = try XCTUnwrap(IntentCompositionSearch.zoomPlan(subject:tiny,label:"Cat",intent:.pet,evidence:try evidence(),others:[],frames:[],scales:[1,1.6,3],forceCenter:false))
        XCTAssertEqual(plan.zoomAlignmentTarget.x,tiny.midX,accuracy:0.0001)
        XCTAssertEqual(plan.zoomAlignmentTarget.y,tiny.midY,accuracy:0.0001)
        XCTAssertTrue(TargetRectangleGeometry.contains(plan.selected.crop,tiny))
    }
    func testMeasuredHeadNearFrameEdgeJustifiesRoomWithoutGuessingHiddenAnatomy() {
        let body = CGRect(x:0.1,y:0,width:0.8,height:0.8)
        let anatomy = SubjectAnatomy(face:CGRect(x:0.3,y:0.005,width:0.2,height:0.2),joints:[],timestamp:0)
        let facts = CompositionAssessment.evaluate(bounds:body,confidence:0.95,label:"Cat",intent:.pet,stable:true,exposure:nil,evidence:nil,anatomy:anatomy)
        XCTAssertEqual(facts.headroom,0.005)
        XCTAssertTrue(facts.touchesEdge); XCTAssertEqual(facts.edgeJointCount,0)
        XCTAssertNil(facts.headYaw)
    }
    func testUnknownSubjectHasUnavailableFitnessInsteadOfAPerfectScore() {
        let facts = CompositionAssessment.evaluate(bounds:nil,confidence:0,label:"Unknown",intent:.auto,stable:true,exposure:nil,evidence:nil)
        XCTAssertNil(facts.fitness)
        XCTAssertNil(facts.subjectArea); XCTAssertNil(facts.headroom)
    }
}
