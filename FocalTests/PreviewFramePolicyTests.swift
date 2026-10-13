import XCTest
@testable import Focal

final class PreviewFramePolicyTests: XCTestCase {
    func testInferenceCannotQueueFramesWhileBusyOrDisabled() {
        var scheduler = PreviewAnalysisScheduler()
        XCTAssertFalse(scheduler.admit(at: 0, enabled: false))
        XCTAssertTrue(scheduler.admit(at: 0, enabled: true))
        for frame in 1...120 { XCTAssertFalse(scheduler.admit(at: Double(frame) / 60, enabled: true)) }
        scheduler.finish()
        XCTAssertTrue(scheduler.admit(at: 2.1, enabled: true))
    }
    func testFinishedInferenceStillRespectsAdmissionRate() {
        var scheduler = PreviewAnalysisScheduler()
        XCTAssertTrue(scheduler.admit(at: 0, enabled: true)); scheduler.finish()
        XCTAssertFalse(scheduler.admit(at: 0.1, enabled: true))
        XCTAssertTrue(scheduler.admit(at: 0.25, enabled: true)); scheduler.finish()
        XCTAssertFalse(scheduler.admit(at: .nan, enabled: true))
    }
    func testPinchRequestsCoalesceToLatestAndStopClearsOldTarget() {
        var requests = ZoomRequestCoalescer()
        XCTAssertTrue(requests.enqueue(1))
        for value in 2...100 { XCTAssertFalse(requests.enqueue(Double(value))) }
        XCTAssertEqual(requests.take(), 100); XCTAssertNil(requests.take())
        XCTAssertTrue(requests.enqueue(2)); requests.clear(); XCTAssertNil(requests.take())
        XCTAssertFalse(requests.enqueue(.nan)); XCTAssertFalse(requests.enqueue(0))
        XCTAssertTrue(requests.enqueue(3)); XCTAssertEqual(requests.take(), 3)
    }
    func testObservedCadenceUsesDeliveredFrameTimestamps() throws {
        var cadence = PreviewFrameCadence()
        XCTAssertNil(cadence.observe(0))
        for frame in 1..<60 { XCTAssertNil(cadence.observe(Double(frame) / 60)) }
        XCTAssertEqual(try XCTUnwrap(cadence.observe(1)), 60, accuracy: 0.001)
        XCTAssertNil(cadence.observe(.nan)); XCTAssertNil(cadence.observe(1))
        XCTAssertEqual(try XCTUnwrap(cadence.observe(2)), 1, accuracy: 0.001)
    }
}
