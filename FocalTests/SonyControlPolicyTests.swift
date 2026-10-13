import XCTest
@testable import Focal

@MainActor private final class ScriptedSony {
    var methods = ["actTakePicture"]
    var calls = [String]()
    var replies = [String: [Result<[Any], Error>]]()
    func call(_ method: String, _ parameters: [Any], _ timeout: TimeInterval) async throws -> Data {
        calls.append(method)
        let result: [Any]
        if var queue = replies[method], !queue.isEmpty {
            let next = queue.removeFirst(); replies[method] = queue; result = try next.get()
        } else if method == "getAvailableApiList" { result = [methods] }
        else { throw SonyRemoteError(message: "Unexpected mock request: \(method)") }
        return try JSONSerialization.data(withJSONObject: ["result": result])
    }
}

final class SonyControlPolicyTests: XCTestCase {
    func testCameraCodesIncludeOperationAndUsefulRecovery() throws {
        let refused = try XCTUnwrap(SonyAPIError.parse(["error": [5, ""]], method: "actTakePicture"))
        XCTAssertEqual(refused.code, 5); XCTAssertTrue(refused.localizedDescription.contains("still-photo"))
        XCTAssertTrue(refused.localizedDescription.contains("actTakePicture"))
        let shooting = try XCTUnwrap(SonyAPIError.parse(["error": [40400, ""]], method: "actTakePicture"))
        XCTAssertTrue(shooting.localizedDescription.contains("memory card"))
        XCTAssertFalse(shooting.localizedDescription.hasSuffix("· "))
    }
    func testDynamicCameraStateAndSupportedMethodsAreParsed() {
        let state = SonyControlState.from([["type": "cameraStatus", "cameraStatus": "MovieRecording"],
            ["type": "focusStatus", "focusStatus": "Focused"], ["type": "availableApiList", "names": ["getEvent"]]])
        XCTAssertTrue(state.captureBusy); XCTAssertEqual(state.focusStatus, "Focused")
        XCTAssertEqual(state.availableMethods, Set(["getEvent"]))
        XCTAssertEqual(SonyMethodCapabilities.names([["cancelHalfPressShutter", [], [], "1.0"]]), Set(["cancelHalfPressShutter"]))
        XCTAssertEqual(SonyMethodCapabilities.names([[["cancelHalfPressShutter", [], [], "1.0"]]]), Set(["cancelHalfPressShutter"]))
    }
    func testReconnectHasFiniteBackoffAndHonorsManualDisconnect() {
        var policy = SonyReconnectPolicy()
        XCTAssertNil(policy.nextDelay(requested: false)); XCTAssertEqual(policy.attempts, 0)
        XCTAssertEqual(policy.nextDelay(requested: true), 1)
        XCTAssertEqual(policy.nextDelay(requested: true), 2)
        XCTAssertEqual(policy.nextDelay(requested: true), 4)
        XCTAssertNil(policy.nextDelay(requested: true)); policy.reset()
        XCTAssertEqual(policy.nextDelay(requested: true), 1)
    }
    @MainActor func testAutofocusPreparationAndReleaseSurroundSingleShutter() async throws {
        let mock = ScriptedSony()
        mock.methods = ["actTakePicture", "actHalfPressShutter", "getEvent"]
        mock.replies = ["getEvent": [.success([["type": "cameraStatus", "cameraStatus": "IDLE"]]), .success([["type": "focusStatus", "focusStatus": "Focused"]])],
            "actHalfPressShutter": [.success([])], "cancelHalfPressShutter": [.success([])], "actTakePicture": [.success([["http://192.168.122.1/photo.jpg"]])]]
        let urls = try await SonyCaptureWorkflow.take(call: mock.call, supported: ["cancelHalfPressShutter"], active: { true }, wait: { _ in })
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(mock.calls.filter { $0 == "actTakePicture" }.count, 1)
        XCTAssertLessThan(try XCTUnwrap(mock.calls.firstIndex(of: "actHalfPressShutter")), try XCTUnwrap(mock.calls.firstIndex(of: "actTakePicture")))
        XCTAssertEqual(mock.calls.last, "cancelHalfPressShutter")
    }
    @MainActor func testPendingPhotoAwaitsOriginalCaptureWithoutRefiring() async throws {
        let mock = ScriptedSony(); mock.methods = ["actTakePicture", "awaitTakePicture"]
        mock.replies = ["actTakePicture": [.failure(SonyAPIError(method: "actTakePicture", code: 40403, detail: ""))],
                       "awaitTakePicture": [.success([["http://192.168.122.1/photo.jpg"]])]]
        _ = try await SonyCaptureWorkflow.take(call: mock.call, active: { true }, wait: { _ in })
        XCTAssertEqual(mock.calls.filter { $0 == "actTakePicture" }.count, 1)
        XCTAssertEqual(mock.calls.filter { $0 == "awaitTakePicture" }.count, 1)
    }
    @MainActor func testBusyCameraNeverReceivesShutterOrModeChange() async {
        let mock = ScriptedSony(); mock.methods = ["actTakePicture", "getEvent", "setShootMode"]
        mock.replies = ["getEvent": [.success([["type": "cameraStatus", "cameraStatus": "MovieRecording"]])]]
        do { _ = try await SonyCaptureWorkflow.take(call: mock.call, active: { true }, wait: { _ in }); XCTFail("Busy camera accepted capture") }
        catch { XCTAssertFalse(mock.calls.contains("actTakePicture")); XCTAssertFalse(mock.calls.contains("setShootMode")) }
    }
    @MainActor func testFocusFailureReleasesHalfPressWithoutTakingPhoto() async {
        let mock = ScriptedSony(); mock.methods = ["actTakePicture", "getEvent", "actHalfPressShutter", "cancelHalfPressShutter"]
        mock.replies = ["getEvent": [.success([]), .success([["type": "focusStatus", "focusStatus": "Failed"]])],
                       "actHalfPressShutter": [.success([])], "cancelHalfPressShutter": [.success([])]]
        do { _ = try await SonyCaptureWorkflow.take(call: mock.call, active: { true }, wait: { _ in }); XCTFail("Failed focus accepted") }
        catch { XCTAssertFalse(mock.calls.contains("actTakePicture")); XCTAssertEqual(mock.calls.last, "cancelHalfPressShutter") }
    }
    @MainActor func testTimeoutDoesNotReplayAmbiguousShutter() async {
        let mock = ScriptedSony(); mock.replies = ["actTakePicture": [.failure(URLError(.timedOut))]]
        do { _ = try await SonyCaptureWorkflow.take(call: mock.call, active: { true }, wait: { _ in }); XCTFail("Timeout accepted") }
        catch { XCTAssertEqual(mock.calls.filter { $0 == "actTakePicture" }.count, 1); XCTAssertFalse(mock.calls.contains("awaitTakePicture")) }
    }
    @MainActor func testRefusedOptionalHalfPressAllowsOneNativeCapture() async throws {
        let mock = ScriptedSony(); mock.methods = ["actTakePicture", "actHalfPressShutter", "cancelHalfPressShutter"]
        mock.replies = ["actHalfPressShutter": [.failure(SonyAPIError(method: "actHalfPressShutter", code: 5, detail: ""))],
                       "actTakePicture": [.success([["http://192.168.122.1/photo.jpg"]])]]
        _ = try await SonyCaptureWorkflow.take(call: mock.call, active: { true }, wait: { _ in })
        XCTAssertEqual(mock.calls.filter { $0 == "actTakePicture" }.count, 1)
        XCTAssertFalse(mock.calls.contains("cancelHalfPressShutter"))
    }
    @MainActor func testSourceCancellationDoesNotSendAnyCommand() async {
        let mock = ScriptedSony()
        do { _ = try await SonyCaptureWorkflow.take(call: mock.call, active: { false }, wait: { _ in }); XCTFail("Inactive source accepted") }
        catch { XCTAssertTrue(mock.calls.isEmpty) }
    }
    @MainActor func testAdvertisedStillModeChangeWaitsForCaptureAvailability() async throws {
        let mock = ScriptedSony()
        let initial = ["getShootMode", "getAvailableShootMode", "setShootMode"]
        mock.replies = ["getAvailableApiList": [.success([initial]), .success([initial]), .success([["actTakePicture"]])],
            "getShootMode": [.success(["movie"])], "getAvailableShootMode": [.success(["movie", ["still", "movie"]])],
            "setShootMode": [.success([])], "actTakePicture": [.success([["http://192.168.122.1/photo.jpg"]])]]
        _ = try await SonyCaptureWorkflow.take(call: mock.call, active: { true }, wait: { _ in })
        XCTAssertEqual(mock.calls.filter { $0 == "setShootMode" }.count, 1)
        XCTAssertEqual(mock.calls.filter { $0 == "actTakePicture" }.count, 1)
    }
}
