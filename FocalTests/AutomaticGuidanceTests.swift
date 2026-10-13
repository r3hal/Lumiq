import XCTest
@testable import Focal

final class AutomaticGuidanceTests: XCTestCase {
    private func reading(x: Double = 0.5, y: Double = 0.5, state: CompositionReading.State = .ready) -> CompositionReading {
        CompositionReading(state:state,subject:UnitPoint2D(x:x,y:y),subjectBounds:CGRect(x:x-0.1,y:y-0.1,width:0.2,height:0.2),subjectConfidence:0.9,target:UnitPoint2D(x:0.5,y:0.5))
    }
    private func update(_ guide: inout AutomaticGuidance, _ reading: CompositionReading, at time: Double,
                        phase: FramingPhase = .off, stable: Bool = true) -> GuidanceMessage {
        guide.update(reading:reading,phase:phase,stable:stable,rollReliable:true,autoEnabled:phase != .off,
                     zoomAvailable:true,timestamp:time)
    }
    func testSearchRequiresConfirmedBounds() {
        var guide = AutomaticGuidance()
        XCTAssertEqual(update(&guide,CompositionReading(),at:0).text,"Point at a subject")
        var uncertain = reading(); uncertain.subjectConfidence = 0.2
        XCTAssertEqual(update(&guide,uncertain,at:1).kind,.searching)
        uncertain.subjectConfidence = 1; uncertain.subjectBounds = nil
        XCTAssertEqual(update(&guide,uncertain,at:2).kind,.searching)
    }
    func testDetectionThenReadyDwellAndImmediateLoss() {
        var guide = AutomaticGuidance()
        XCTAssertEqual(update(&guide,reading(),at:0).kind,.detected)
        XCTAssertEqual(update(&guide,reading(),at:0.5).kind,.detected)
        XCTAssertEqual(update(&guide,reading(),at:1.2).text,"Great framing")
        XCTAssertEqual(update(&guide,CompositionReading(),at:1.3).kind,.searching)
    }
    func testPhysicalMotionPreventsReady() {
        var guide = AutomaticGuidance()
        _ = update(&guide,reading(),at:0,stable:false)
        _ = update(&guide,reading(),at:0.5,stable:false)
        XCTAssertEqual(update(&guide,reading(),at:1.2,stable:false).text,"Hold steady")
    }
    func testDirectionsAreDebouncedAndUseActualPosition() {
        var guide = AutomaticGuidance()
        _ = update(&guide,reading(x:0.7),at:0)
        _ = update(&guide,reading(x:0.7),at:0.5)
        XCTAssertEqual(update(&guide,reading(x:0.7),at:1.2).text,"Move slightly right")
        // A single noisy opposite observation must not flip the instruction.
        XCTAssertEqual(update(&guide,reading(x:0.3),at:1.4).text,"Move slightly right")
        _ = update(&guide,reading(x:0.3),at:1.6)
        XCTAssertEqual(update(&guide,reading(x:0.3),at:2.3).text,"Move slightly left")
    }
    func testVerticalDirectionAccountsForAspectFill() {
        var guide = AutomaticGuidance()
        _ = update(&guide,reading(y:0.3),at:0)
        _ = update(&guide,reading(y:0.3),at:0.5)
        XCTAssertEqual(update(&guide,reading(y:0.3),at:1.2).text,"Raise the camera")
    }
    func testRealZoomTransitionIsImmediateAndCompletionCanBecomeReady() {
        var guide = AutomaticGuidance()
        XCTAssertEqual(update(&guide,reading(),at:0,phase:.settling).text,"Subject detected")
        XCTAssertEqual(update(&guide,reading(),at:0.6,phase:.settling).text,"Centered — framing up…")
        XCTAssertEqual(update(&guide,reading(),at:0.7,phase:.zooming).text,"Framing your shot…")
        _ = update(&guide,reading(x:0.55),at:1.7,phase:.framed)
        XCTAssertEqual(update(&guide,reading(x:0.55),at:2.4,phase:.framed).text,"Great framing")
    }
    func testSubjectBoxDropsLostSubjectAndResetsOnSceneCut() throws {
        var smoother = SubjectBoxSmoother()
        let first = CGRect(x:0.3,y:0.3,width:0.2,height:0.2)
        XCTAssertEqual(smoother.update(first),first)
        let second = try XCTUnwrap(smoother.update(CGRect(x:0.32,y:0.3,width:0.2,height:0.2)))
        XCTAssertGreaterThan(second.minX,first.minX); XCTAssertLessThan(second.minX,0.32)
        XCTAssertNil(smoother.update(nil))
        let distant = CGRect(x:0.75,y:0.7,width:0.15,height:0.15)
        XCTAssertEqual(smoother.update(distant),distant)
    }
    func testMotionRequiresBothLowRotationAndLowAcceleration() {
        XCTAssertTrue(CameraStability.isStable(rotation:(0.01,0.01,0.01),acceleration:(0.01,0.01,0.01)))
        XCTAssertFalse(CameraStability.isStable(rotation:(0.13,0,0),acceleration:(0,0,0)))
        XCTAssertFalse(CameraStability.isStable(rotation:(0,0,0),acceleration:(0,0.05,0)))
        XCTAssertFalse(CameraStability.isStable(rotation:(Double.nan,0,0),acceleration:(0,0,0)))
    }
    func testLandscapeGuidanceUsesRealSceneAndTiltWithoutSubjectOrReadyClaim() {
        var guide = AutomaticGuidance()
        let scene = SubjectScene(label: "Mountain", confidence: 0.9, timestamp: 0)
        var reading = CompositionReading(); reading.rollDegrees = 8
        let result = guide.update(reading: reading, phase: .searching, stable: true, rollReliable: true,
                                  autoEnabled: true, zoomAvailable: true, timestamp: 1, scene: scene)
        XCTAssertEqual(result.kind, .scene); XCTAssertEqual(result.text, "Keep the camera level")
        XCTAssertNil(reading.subjectBounds)
        XCTAssertEqual(guide.update(reading: reading, phase: .searching, stable: true, rollReliable: true,
                                   autoEnabled: true, zoomAvailable: true, timestamp: 8, scene: scene).kind, .searching)
    }

    func testPhoneScanSearchDoesNotInventSubjectOrReadyState() {
        var guide = AutomaticGuidance()
        let result = guide.update(reading: CompositionReading(), phase: .searching, stable: true, rollReliable: true,
                                  autoEnabled: true, zoomAvailable: true, timestamp: 0)
        XCTAssertEqual(result.kind, .searching); XCTAssertEqual(result.text, "Finding your shot…")
    }
    func testPhonePanCombinesBothPhysicalDirectionsFromActualBounds() throws {
        let cue = try XCTUnwrap(CompositionCue(reading: reading(x: 0.3, y: 0.3), previewAspect: 0.75))
        XCTAssertEqual(cue.phoneInstruction, "Move your phone left & up")
        var guide = AutomaticGuidance()
        let offset = reading(x: 0.3, y: 0.3)
        _ = update(&guide, offset, at: 0, phase: .aligning)
        _ = update(&guide, offset, at: 0.5, phase: .aligning)
        XCTAssertEqual(update(&guide, offset, at: 1.2, phase: .aligning).text, cue.phoneInstruction)
    }
    func testSettlingCannotDescribeMovingPhoneAsCentered() {
        var guide = AutomaticGuidance()
        _ = update(&guide, reading(), at: 0, phase: .settling, stable: false)
        XCTAssertEqual(update(&guide, reading(), at: 0.6, phase: .settling, stable: false).text, "Hold steady")
    }

}
