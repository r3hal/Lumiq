import XCTest
@testable import Focal

final class FramingPlannerTests: XCTestCase {
    private let subject = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    private func update(_ planner: inout FramingPlanner, at time: Double, bounds: CGRect? = nil,
                        confidence: Float = 1, roll: Double = 0, zoom: Double = 1, limit: Double = 3) -> Double? {
        planner.update(bounds: bounds ?? subject, confidence: confidence, roll: roll,
                       timestamp: time, currentZoom: zoom, maximumZoom: limit)
    }

    func testZoomWaitsForCenterAndStableDwell() {
        var planner = FramingPlanner()
        XCTAssertNil(update(&planner, at: 0, bounds: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.2)))
        XCTAssertEqual(planner.phase, .aligning)
        XCTAssertNil(update(&planner, at: 1))
        XCTAssertEqual(planner.phase, .settling)
        XCTAssertNil(update(&planner, at: 1.5))
        XCTAssertEqual(update(&planner, at: 1.8), 3)
        XCTAssertEqual(planner.phase, .zooming)
    }

    func testScanCannotKeepZoomingAfterItFinishes() {
        var planner = FramingPlanner()
        _ = update(&planner, at: 0)
        XCTAssertNotNil(update(&planner, at: 1))
        XCTAssertNil(update(&planner, at: 2))
        planner.finish()
        XCTAssertNil(update(&planner, at: 3))
        planner.reset(enabled: true)
        XCTAssertNil(update(&planner, at: 4))
        XCTAssertNotNil(update(&planner, at: 5))
    }

    func testMissingOrUncertainSubjectCannotTriggerZoom() {
        var planner = FramingPlanner()
        _ = update(&planner, at: 0)
        XCTAssertNil(planner.update(bounds: nil, confidence: 1, roll: 0, timestamp: 2, currentZoom: 1, maximumZoom: 6))
        XCTAssertEqual(planner.phase, .searching)
        XCTAssertNil(update(&planner, at: 3, confidence: 0.4))
        XCTAssertNil(update(&planner, at: 4))
    }

    func testTiltAndMotionResetDwell() {
        var planner = FramingPlanner()
        _ = update(&planner, at: 0)
        XCTAssertNil(update(&planner, at: 1, roll: 8))
        XCTAssertNil(update(&planner, at: 2))
        XCTAssertNil(update(&planner, at: 2.5, bounds: CGRect(x: 0.445, y: 0.4, width: 0.2, height: 0.2)))
        XCTAssertNil(update(&planner, at: 3, bounds: CGRect(x: 0.445, y: 0.4, width: 0.2, height: 0.2)))
    }

    func testZoomRespectsDeviceLimitAndKeepsWholeSubject() throws {
        var planner = FramingPlanner()
        let bounds = CGRect(x: 0.38, y: 0.36, width: 0.3, height: 0.3)
        _ = update(&planner, at: 0, bounds: bounds, limit: 2)
        let zoom = try XCTUnwrap(update(&planner, at: 1, bounds: bounds, limit: 2))
        XCTAssertLessThanOrEqual(zoom, 2)
        let framed = FramingPlanner.zoomedRect(bounds, scale: zoom)
        XCTAssertGreaterThanOrEqual(framed.minX, 0)
        XCTAssertGreaterThanOrEqual(framed.minY, 0)
        XCTAssertLessThanOrEqual(framed.maxX, 1)
        XCTAssertLessThanOrEqual(framed.maxY, 1)
    }

    func testLargeSubjectAndNoZoomBudgetDoNotZoom() {
        var planner = FramingPlanner()
        let large = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        _ = update(&planner, at: 0, bounds: large)
        XCTAssertNil(update(&planner, at: 1, bounds: large))
        XCTAssertEqual(planner.phase, .framed)
        planner.reset(enabled: true)
        _ = update(&planner, at: 2, limit: 1)
        XCTAssertNil(update(&planner, at: 3, limit: 1))
        XCTAssertEqual(planner.phase, .framed)
    }

    func testManualOverrideDisablesZoomUntilNextScan() {
        var planner = FramingPlanner()
        planner.reset(enabled: false)
        XCTAssertNil(update(&planner, at: 0))
        XCTAssertNil(update(&planner, at: 5))
        XCTAssertEqual(planner.phase, .off)
    }

    func testInvalidBoxesCannotTriggerZoom() {
        for rect in [CGRect(x: -0.1, y: 0.4, width: 0.2, height: 0.2),
                     CGRect(x: 0.45, y: 0.4, width: 0, height: 0.2),
                     CGRect(x: 0.4, y: 0.4, width: 1.2, height: 0.2)] {
            var planner = FramingPlanner()
            _ = update(&planner, at: 0, bounds: rect)
            XCTAssertNil(update(&planner, at: 1, bounds: rect))
            XCTAssertEqual(planner.phase, .searching)
        }
    }

    func testSubjectRectIsReprojectedAcrossZoom() {
        let rect = FramingPlanner.zoomedRect(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), scale: 2)
        XCTAssertEqual(rect.minX, 0.3, accuracy: 0.00001)
        XCTAssertEqual(rect.minY, 0.3, accuracy: 0.00001)
        XCTAssertEqual(rect.width, 0.4, accuracy: 0.00001)
        XCTAssertEqual(rect.height, 0.4, accuracy: 0.00001)
    }

    func testIntermediateZoomDoesNotPretendToBeTelephoto() {
        var planner = FramingPlanner()
        _ = planner.update(bounds: subject, confidence: 1, roll: 0, timestamp: 0,
                           currentZoom: 1, maximumZoom: 5, detailZoomLimit: 1, nativeStops: [1, 5])
        XCTAssertNil(planner.update(bounds: subject, confidence: 1, roll: 0, timestamp: 1,
                                    currentZoom: 1, maximumZoom: 5, detailZoomLimit: 1, nativeStops: [1, 5]))
        XCTAssertEqual(planner.phase, .framed)
        planner.reset(enabled: true)
        _ = planner.update(bounds: subject, confidence: 1, roll: 0, timestamp: 2,
                           currentZoom: 1, maximumZoom: 3, detailZoomLimit: 1, nativeStops: [1, 3])
        XCTAssertEqual(planner.update(bounds: subject, confidence: 1, roll: 0, timestamp: 3,
                                      currentZoom: 1, maximumZoom: 3, detailZoomLimit: 1, nativeStops: [1, 3]), 3)
    }

    func testAdviceUsesRecognizedSubjectWithoutInventingDetails() {
        XCTAssertEqual(SubjectAdvice.text(for: "Cat"), "Isolate the cat, tighten the frame.")
        XCTAssertEqual(SubjectAdvice.text(for: "Subject"), "Isolate your subject, tighten the frame.")
        XCTAssertEqual(SubjectAdvice.text(for: "Cathedral"), "Isolate the cathedral, tighten the frame.")
    }
    func testPhysicalMotionRestartsConfiguredHoldDuration() {
        var planner = FramingPlanner()
        func step(_ time:Double,_ stable:Bool) -> Double? {
            planner.update(bounds:subject,confidence:1,roll:0,timestamp:time,currentZoom:1,maximumZoom:3,deviceStable:stable,holdDuration:1.2)
        }
        XCTAssertNil(step(0,true)); XCTAssertNil(step(1,false))
        XCTAssertNil(step(1.1,true)); XCTAssertNil(step(2.2,true))
        XCTAssertNotNil(step(2.4,true))
    }
    func testSlowSubjectDriftRestartsDwell() {
        var planner = FramingPlanner()
        func step(_ time:Double,_ x:Double) -> Double? {
            planner.update(bounds:CGRect(x:x,y:0.4,width:0.2,height:0.2),confidence:1,roll:0,timestamp:time,currentZoom:1,maximumZoom:3,holdDuration:1.5)
        }
        XCTAssertNil(step(0,0.37)); XCTAssertNil(step(0.5,0.39)); XCTAssertNil(step(1,0.415))
        XCTAssertNil(step(1.5,0.43)) // Aggregate drift invalidates the original anchor.
        XCTAssertNil(step(2,0.43)); XCTAssertNotNil(step(2.6,0.43))
    }
    func testOffCenterZoomRetainsCompositionAndInvalidZoomCannotStart() throws {
        let bounds = CGRect(x:0.42,y:0.4,width:0.2,height:0.2)
        var planner = FramingPlanner()
        _ = update(&planner,at:0,bounds:bounds)
        let zoom = try XCTUnwrap(update(&planner,at:1,bounds:bounds))
        let rect = FramingPlanner.zoomedRect(bounds,scale:zoom)
        XCTAssertLessThanOrEqual(abs(rect.midX-0.5),0.065)
        planner.reset(enabled:true)
        XCTAssertNil(planner.update(bounds:subject,confidence:1,roll:0,timestamp:0,currentZoom:.nan,maximumZoom:3))
    }

}
