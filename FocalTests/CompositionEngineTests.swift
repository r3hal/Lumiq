import XCTest
@testable import Focal

final class CompositionEngineTests: XCTestCase {
    func testNearestThirdsIntersection() {
        XCTAssertEqual(CompositionEngine.target(for: .init(x: 0.8, y: 0.1), mode: .thirds),
                       .init(x: 2.0 / 3, y: 1.0 / 3))
        XCTAssertEqual(CompositionEngine.target(for: .init(x: 0.1, y: 0.8), mode: .thirds),
                       .init(x: 1.0 / 3, y: 2.0 / 3))
    }

    func testCenterMode() {
        XCTAssertEqual(CompositionEngine.target(for: .init(x: 0.9, y: 0.9), mode: .centered), .init(x: 0.5, y: 0.5))
    }

    func testReadyRequiresDwellTime() {
        var engine = CompositionEngine()
        let point = UnitPoint2D(x: 0.5, y: 0.5)
        XCTAssertEqual(engine.update(subject: point, rollDegrees: 0, mode: .centered, timestamp: 0).state, .settling)
        XCTAssertEqual(engine.update(subject: point, rollDegrees: 0, mode: .centered, timestamp: 0.5).state, .settling)
        XCTAssertEqual(engine.update(subject: point, rollDegrees: 0, mode: .centered, timestamp: 0.7).state, .ready)
    }

    func testTiltResetsDwell() {
        var engine = CompositionEngine()
        let point = UnitPoint2D(x: 0.5, y: 0.5)
        _ = engine.update(subject: point, rollDegrees: 0, mode: .centered, timestamp: 0)
        XCTAssertEqual(engine.update(subject: point, rollDegrees: 8, mode: .centered, timestamp: 1).state, .adjusting)
        XCTAssertEqual(engine.update(subject: point, rollDegrees: 0, mode: .centered, timestamp: 1.2).state, .settling)
    }

    func testMissingSubjectClearsReadyState() {
        var engine = CompositionEngine()
        _ = engine.update(subject: .init(x: 0.5, y: 0.5), rollDegrees: 0, mode: .centered, timestamp: 0)
        _ = engine.update(subject: .init(x: 0.5, y: 0.5), rollDegrees: 0, mode: .centered, timestamp: 1)
        let missing = engine.update(subject: nil, rollDegrees: 0, mode: .centered, timestamp: 2)
        XCTAssertEqual(missing.state, .searching)
        XCTAssertNil(missing.subject)
        XCTAssertEqual(engine.update(subject: .init(x: 0.5, y: 0.5), rollDegrees: 0, mode: .centered, timestamp: 3).state, .settling)
    }

    func testDirectionsAccountForCameraMovement() {
        var engine = CompositionEngine()
        XCTAssertEqual(engine.update(subject: .init(x: 0.8, y: 0.5), rollDegrees: 0, mode: .centered, timestamp: 0).title, "Aim a little right")
        engine.reset()
        XCTAssertEqual(engine.update(subject: .init(x: 0.5, y: 0.2), rollDegrees: 0, mode: .centered, timestamp: 1).title, "Aim a little up")
    }

    func testModeChangeResetsDwell() {
        var engine = CompositionEngine()
        _ = engine.update(subject: .init(x: 0.5, y: 0.5), rollDegrees: 0, mode: .centered, timestamp: 0)
        _ = engine.update(subject: .init(x: 0.5, y: 0.5), rollDegrees: 0, mode: .centered, timestamp: 1)
        let reading = engine.update(subject: .init(x: 2.0 / 3, y: 2.0 / 3), rollDegrees: 0, mode: .thirds, timestamp: 2)
        XCTAssertEqual(reading.state, .settling)
    }

    func testInvalidCoordinatesAreNotPresentedAsGuidance() {
        var engine = CompositionEngine()
        XCTAssertEqual(engine.update(subject: .init(x: .nan, y: 0.5), rollDegrees: 0, mode: .centered, timestamp: 0).state, .searching)
        XCTAssertEqual(engine.update(subject: .init(x: 2, y: 0.5), rollDegrees: 0, mode: .centered, timestamp: 1).state, .searching)
    }

    func testThirdsTargetDoesNotSwitchAcrossCenterLine() {
        var engine = CompositionEngine()
        let first = engine.update(subject: .init(x: 0.49, y: 0.3), rollDegrees: 0, mode: .thirds, timestamp: 0)
        let next = engine.update(subject: .init(x: 0.51, y: 0.3), rollDegrees: 0, mode: .thirds, timestamp: 0.1)
        XCTAssertEqual(next.target, first.target)
    }

    func testOneMissedFramePreservesTargetButClearsReadiness() {
        var engine = CompositionEngine()
        let target = UnitPoint2D(x: 1.0 / 3, y: 1.0 / 3)
        _ = engine.update(subject: target, rollDegrees: 0, mode: .thirds, timestamp: 0)
        _ = engine.update(subject: target, rollDegrees: 0, mode: .thirds, timestamp: 1)
        let lost = engine.update(subject: nil, rollDegrees: 0, mode: .thirds, timestamp: 1.1)
        XCTAssertEqual(lost.state, .searching)
        XCTAssertEqual(lost.target, target)
        XCTAssertEqual(engine.update(subject: target, rollDegrees: 0, mode: .thirds, timestamp: 1.2).state, .settling)
    }

    func testPreferredCornerIsHonoredAndCenterModeIgnoresIt() {
        var engine = CompositionEngine()
        let chosen = CompositionEngine.thirdsTargets[0]
        let reading = engine.update(subject: .init(x: 0.7, y: 0.7), rollDegrees: 0, mode: .thirds,
                                    timestamp: 0, preferredTarget: chosen)
        XCTAssertEqual(reading.target, chosen)
        XCTAssertEqual(engine.update(subject: .init(x: 0.5, y: 0.5), rollDegrees: 0, mode: .centered,
                                     timestamp: 1, preferredTarget: chosen).target, .init(x: 0.5, y: 0.5))
    }

    func testOutOfAlignmentRawObservationCannotStayReadyBehindSmoothing() {
        var engine = CompositionEngine()
        _ = engine.update(subject: .init(x: 0.5, y: 0.5), rollDegrees: 0, mode: .centered, timestamp: 0)
        _ = engine.update(subject: .init(x: 0.5, y: 0.5), rollDegrees: 0, mode: .centered, timestamp: 1)
        XCTAssertEqual(engine.update(subject: .init(x: 0.6, y: 0.5), rollDegrees: 0, mode: .centered, timestamp: 1.1).state, .adjusting)
    }

    func testWideBufferCropMapsThirdsToVisiblePreview() {
        let projection = PreviewProjection(imageAspect: 1, previewAspect: 0.75)
        let visible = projection.visiblePoint(.init(x: 0.375, y: 1.0 / 3))
        XCTAssertEqual(visible.x, 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(visible.y, 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(projection.imagePoint(visible).x, 0.375, accuracy: 0.0001)
    }

    func testTallBufferCropMapsVerticalPosition() {
        let projection = PreviewProjection(imageAspect: 9.0 / 16, previewAspect: 3.0 / 4)
        XCTAssertEqual(projection.visiblePoint(.init(x: 0.5, y: 0.375)).y, 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(projection.visiblePoint(.init(x: 0.5, y: 0.5)), .init(x: 0.5, y: 0.5))
    }

    func testReadinessUsesPortraitScreenDistance() {
        var engine = CompositionEngine()
        let reading = engine.update(subject: .init(x: 0.5, y: 0.56), rollDegrees: 0,
                                    mode: .centered, timestamp: 0)
        XCTAssertEqual(reading.state, .adjusting)
    }
}
