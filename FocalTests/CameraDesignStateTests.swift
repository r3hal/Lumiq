import XCTest
@testable import Focal

final class CameraDesignStateTests: XCTestCase {
    func testProMaxStandardPreviewMatchesCapturedAspect() {
        XCTAssertEqual(CameraViewportLayout.aspect(source: .iPhone, capture: .standard, sonyFullFrame: false, sonyAspect: 1.5, width: 440, height: 716), 0.75, accuracy: 0.000001)
    }
    func testSelectedCropsAndRealSonyFrameKeepTheirOwnAspect() {
        XCTAssertEqual(CameraViewportLayout.aspect(source: .iPhone, capture: .square, sonyFullFrame: false, sonyAspect: 1.5, width: 440, height: 716), 1)
        XCTAssertEqual(CameraViewportLayout.aspect(source: .sony, capture: .standard, sonyFullFrame: true, sonyAspect: 1.5, width: 440, height: 716), 1.5)
        XCTAssertEqual(CameraViewportLayout.aspect(source: .sony, capture: .portrait, sonyFullFrame: false, sonyAspect: 1.5, width: 440, height: 716), 0.8)
    }
    func testShortWindowsDoNotStretchTheStandardPreview() {
        XCTAssertEqual(CameraViewportLayout.aspect(source: .iPhone, capture: .standard, sonyFullFrame: false, sonyAspect: 1.5, width: 375, height: 400), 0.75)
    }
    private func card(_ state: CameraGuideState, _ text: String) -> GuidancePresentationStabilizer.Presentation {
        GuidancePresentationStabilizer.Presentation(state: state, instruction: text)
    }
    func testGuidanceCardHoldsWordingLongEnoughToRead() throws {
        var stabilizer = GuidancePresentationStabilizer()
        XCTAssertEqual(stabilizer.update(card(.guiding, "Aim your phone left"), at: 0).presentation.instruction, "Aim your phone left")
        // One analysis frame of competing wording never reaches the screen.
        let flash = stabilizer.update(card(.searching, "Finding your shot"), at: 0.25)
        XCTAssertEqual(flash.presentation.instruction, "Aim your phone left")
        XCTAssertEqual(try XCTUnwrap(flash.recheckAt), 0.7, accuracy: 0.0001)
        XCTAssertEqual(stabilizer.update(card(.guiding, "Aim your phone left"), at: 0.5).presentation.instruction, "Aim your phone left")
        // A sustained change appears once minimum display and dwell have both elapsed.
        XCTAssertEqual(stabilizer.update(card(.guiding, "Aim slightly left"), at: 0.6).presentation.instruction, "Aim your phone left")
        XCTAssertEqual(stabilizer.update(card(.guiding, "Aim slightly left"), at: 0.9).presentation.instruction, "Aim slightly left")
    }
    func testGuidanceCardNeverDelaysReadyOffOrZoom() {
        var stabilizer = GuidancePresentationStabilizer()
        _ = stabilizer.update(card(.guiding, "Aim your phone left"), at: 0)
        XCTAssertEqual(stabilizer.update(card(.ready, "Ready to shoot"), at: 0.05).presentation.state, .ready)
        // Leaving READY is immediate so the card never claims a frame that is no longer measured.
        XCTAssertEqual(stabilizer.update(card(.holding, "Hold steady"), at: 0.1).presentation.state, .holding)
        XCTAssertEqual(stabilizer.update(card(.zooming, "Framing your shot"), at: 0.15).presentation.state, .zooming)
        XCTAssertEqual(stabilizer.update(card(.off, ""), at: 0.2).presentation.state, .off)
        let resumed = stabilizer.update(card(.searching, "Scanning the scene"), at: 0.25)
        XCTAssertEqual(resumed.presentation.state, .searching); XCTAssertNil(resumed.recheckAt)
    }
    func testGuidanceCardAppearsAtOnceButDoesNotBlinkOut() {
        var stabilizer = GuidancePresentationStabilizer()
        _ = stabilizer.update(card(.searching, ""), at: 0)
        XCTAssertEqual(stabilizer.update(card(.guiding, "Aim your phone up"), at: 0.1).presentation.instruction, "Aim your phone up")
        XCTAssertEqual(stabilizer.update(card(.searching, ""), at: 0.3).presentation.instruction, "Aim your phone up")
        XCTAssertTrue(stabilizer.update(card(.searching, ""), at: 1.0).presentation.instruction.isEmpty)
        XCTAssertEqual(stabilizer.update(card(.guiding, "Aim"), at: .nan).presentation.instruction, "Aim")
    }
    private var subject: CompositionReading {
        CompositionReading(state: .adjusting, subjectBounds: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), subjectConfidence: 0.9)
    }
    private func state(_ reading: CompositionReading, phase: FramingPhase, kind: GuidanceMessage.Kind, enabled: Bool = true) -> CameraGuideState {
        CameraGuideState.resolve(enabled: enabled, reading: reading, phase: phase, message: GuidanceMessage(kind: kind, text: "Measured guidance"))
    }
    func testGuidanceOffOverridesStaleDetectionAndZoomPresentation() {
        XCTAssertEqual(state(subject, phase: .zooming, kind: .framing, enabled: false), .off)
        XCTAssertEqual(state(subject, phase: .framed, kind: .ready, enabled: false), .off)
    }
    func testSixCameraPresentationsComeFromMeasuredState() {
        XCTAssertEqual(state(.init(), phase: .searching, kind: .searching), .searching)
        XCTAssertEqual(state(subject, phase: .aligning, kind: .detected), .detected)
        XCTAssertEqual(state(subject, phase: .aligning, kind: .adjustment), .guiding)
        XCTAssertEqual(state(subject, phase: .settling, kind: .steady), .holding)
        XCTAssertEqual(state(subject, phase: .zooming, kind: .framing), .zooming)
        var ready = subject; ready.state = .ready
        XCTAssertEqual(state(ready, phase: .framed, kind: .ready), .ready)
    }
    func testReadyRequiresBoundsConfidenceAndFinishedFraming() {
        var reading = subject; reading.state = .ready; reading.subjectConfidence = 0.1
        XCTAssertEqual(state(reading, phase: .framed, kind: .ready), .searching)
        reading.subjectConfidence = 1; reading.subjectBounds = .null
        XCTAssertEqual(state(reading, phase: .framed, kind: .ready), .searching)
        reading = subject; reading.state = .ready
        XCTAssertNotEqual(state(reading, phase: .settling, kind: .ready), .ready)
    }
    func testWholeSceneReadyRequiresExplicitVerificationAndFinishedFraming() {
        let reading = CompositionReading(state:.ready,sceneFrameVerified:true)
        XCTAssertNil(reading.subjectBounds)
        XCTAssertEqual(state(reading,phase:.framed,kind:.ready),.ready)
        XCTAssertEqual(state(reading,phase:.framed,kind:.ready,enabled:false),.off)
        for phase in [FramingPhase.off,.searching,.aligning,.settling,.zooming,.verifying,.reacquiring,.recoveringZoom,.rediscovering] {
            XCTAssertNotEqual(state(reading,phase:phase,kind:.ready),.ready)
        }
        XCTAssertNotEqual(state(reading,phase:.framed,kind:.framing),.ready)
        var notReady = reading; notReady.state = .adjusting
        XCTAssertNotEqual(state(notReady,phase:.framed,kind:.ready),.ready)
    }
    func testReadyMessageCannotInventSceneVerification() {
        let message = GuidanceMessage(kind:.ready,text:"Wide scene ready",action:GuidanceAction.none)
        var reading = CompositionReading(state:.ready)
        reading.shotStatus = .ready // Presentation metadata alone is not proof either.
        XCTAssertFalse(reading.sceneFrameVerified)
        XCTAssertEqual(CameraGuideState.resolve(enabled:true,reading:reading,phase:.framed,message:message),.searching)
        reading.subjectConfidence = 0.1
        reading.subjectBounds = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
        XCTAssertEqual(CameraGuideState.resolve(enabled:true,reading:reading,phase:.framed,message:message),.searching)
    }
    func testBriefLossShowsRecoveryWithoutDetectionOrReadyClaim() {
        XCTAssertEqual(state(.init(), phase: .framed, kind: .steady), .recovering)
        XCTAssertEqual(state(.init(), phase: .framed, kind: .ready), .searching)
    }
    func testThreeSecondHoldUsesMeasuredElapsedTimeAndResetsOnMotion() {
        var planner = FramingPlanner()
        let bounds = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        func step(_ time: Double, steady: Bool = true) -> Double? {
            planner.update(bounds: bounds, confidence: 0.9, roll: 0, timestamp: time, currentZoom: 1, maximumZoom: 3, deviceStable: steady, holdDuration: 3)
        }
        XCTAssertNil(step(0)); XCTAssertNil(step(1.5)); XCTAssertEqual(planner.holdProgress, 0.5, accuracy: 0.001)
        XCTAssertNil(step(2.9)); XCTAssertLessThan(planner.holdProgress, 1)
        XCTAssertNil(step(3, steady: false)); XCTAssertEqual(planner.holdProgress, 0)
        XCTAssertNil(step(4)); XCTAssertNil(step(6.9)); XCTAssertNotNil(step(7)); XCTAssertEqual(planner.holdProgress, 1)
        planner.reset(enabled: false); XCTAssertEqual(planner.holdProgress, 0)
    }
    func testSmartSelectionOffStillAllowsManualSelection() {
        var features = SubjectAnalysisFeatures(); features.smartSelection = false
        XCTAssertFalse(features.allowsAcquisition(manual: false)); XCTAssertTrue(features.allowsAcquisition(manual: true))
    }
    func testTrackingOffPreventsAutomaticZoomAtServiceGate() {
        var features = SubjectAnalysisFeatures(); features.subjectTracking = false
        XCTAssertFalse(features.allowsAutomaticZoom(requested: true))
        features.subjectTracking = true; XCTAssertTrue(features.allowsAutomaticZoom(requested: true))
        XCTAssertFalse(features.allowsAutomaticZoom(requested: false))
    }
    func testTrackerConfiguresActualFeatureOptionsAndClearsPreviousSelection() {
        let tracker = SubjectTracker()
        tracker.configure(pets: false, tracking: false, smartSelection: false)
        XCTAssertEqual(tracker.features, SubjectAnalysisFeatures(petDetection: false, subjectTracking: false, smartSelection: false))
        XCTAssertFalse(tracker.manual); XCTAssertEqual(tracker.label, "Auto subject")
        tracker.configure(pets: true, tracking: true, smartSelection: true)
        XCTAssertEqual(tracker.features, SubjectAnalysisFeatures())
    }
}

@MainActor
final class AISettingsPersistenceTests: XCTestCase {
    func testNewPreferencesDefaultOnWithoutEnablingGuidance() throws {
        let suite = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CameraSettings(defaults: defaults)
        XCTAssertTrue(settings.petDetection); XCTAssertTrue(settings.subjectTracking); XCTAssertTrue(settings.smartSelection)
        XCTAssertTrue(settings.compositionPlanning)
        XCTAssertFalse(settings.guide)
    }
    func testAllAISettingsAndThreeSecondHoldSurviveRelaunch() throws {
        let suite = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CameraSettings(defaults: defaults)
        settings.petDetection = false; settings.subjectTracking = false; settings.smartSelection = false
        settings.compositionPlanning = false
        settings.guide = true; settings.autoFrame = false; settings.holdDuration = 3
        let reopened = CameraSettings(defaults: defaults)
        XCTAssertFalse(reopened.petDetection); XCTAssertFalse(reopened.subjectTracking); XCTAssertFalse(reopened.smartSelection)
        XCTAssertFalse(reopened.compositionPlanning)
        XCTAssertTrue(reopened.guide); XCTAssertFalse(reopened.autoFrame); XCTAssertEqual(reopened.holdDuration, 3)
    }
}
