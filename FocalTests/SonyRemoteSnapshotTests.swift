import XCTest
@testable import Focal

@MainActor private final class SonySnapshotFixture {
    var methods = ["getAvailableIsoSpeedRate","setIsoSpeedRate","getExposureMode"]
    var calls = [String]()
    var responses: [String:[Result<[Any],Error>]] = [:]
    var after:((String) -> Void)?
    func call(_ method:String,_ params:[Any],_ timeout:TimeInterval) async throws -> Data {
        calls.append(method); after?(method)
        let result:[Any]
        if var queue = responses[method], !queue.isEmpty {
            let value = queue.removeFirst(); responses[method] = queue; result = try value.get()
        } else if method == "getAvailableApiList" { result = [methods] }
        else { throw SonyRemoteError(message:"Unexpected snapshot fixture: \(method)") }
        return try JSONSerialization.data(withJSONObject:["result":result])
    }
    func mode(_ first:String,_ final:String? = nil) {
        responses["getExposureMode"] = [.success([first]),.success([final ?? first])]
        responses["getAvailableIsoSpeedRate"] = [.success(["400",["100","400","800"]])]
    }
}

final class SonyRemoteSnapshotTests: XCTestCase {
    private func snapshot(mode:String = "M") -> SonyRemoteSnapshot {
        var value = SonyRemoteSnapshot()
        value.telemetry.mode = mode
        value.applyMethods(["getEvent","getExposureMode","getAvailableIsoSpeedRate","setIsoSpeedRate","getAvailableFNumber","setFNumber","getAvailableShutterSpeed","setShutterSpeed"])
        value.supported = value.methods; value.supportComplete = true
        value.merge(.iso,SonySettingParser.parse(.iso,result:["400",["100","400","800"]],available:true))
        value.merge(.aperture,SonySettingParser.parse(.aperture,result:["4.0",["2.8","4.0","5.6"]],available:true))
        value.merge(.shutter,SonySettingParser.parse(.shutter,result:["1/125",["1/60","1/125"]],available:true))
        return value
    }
    func testMissingEventFieldsKeepConfirmedValuesChoicesAndAvailability() {
        var value = snapshot(), previous = value
        value.applyEvent([NSNull(),["type":"focusStatus","focusStatus":"Focused"]])
        XCTAssertEqual(value.settings,previous.settings); XCTAssertEqual(value.methods,previous.methods)
        for key in [SonyRemoteSetting.iso,.aperture,.shutter] { XCTAssertEqual(value.status(key),.available) }
        previous = value
        value.applyEvent([["type":"isoSpeedRate"]])
        XCTAssertEqual(value,previous)
    }
    func testPartialCurrentValueKeepsAvailableOptions() {
        var value = snapshot()
        value.applyEvent([["type":"isoSpeedRate","currentIsoSpeedRate":"800"]])
        XCTAssertEqual(value.settings[.iso]?.current,.text("800"))
        XCTAssertEqual(value.settings[.iso]?.choices,[.text("100"),.text("400"),.text("800")])
        XCTAssertEqual(value.status(.iso),.available)
    }
    func testExplicitEmptyOptionsDisableWithoutErasingCurrentValue() {
        var value = snapshot()
        value.applyEvent([["type":"fNumber","fNumberCandidates":[]]])
        XCTAssertEqual(value.settings[.aperture]?.current,.text("4.0"))
        XCTAssertTrue(value.settings[.aperture]!.choices.isEmpty)
        XCTAssertEqual(value.status(.aperture).name,"TemporarilyUnavailable")
        XCTAssertEqual(value.status(.iso),.available)
    }
    func testMissingApiListDoesNotRemoveSettersButExplicitRemovalDoes() {
        var value = snapshot()
        value.applyEvent([["type":"availableApiList"]])
        XCTAssertEqual(value.status(.aperture),.available)
        value.applyEvent([["type":"availableApiList","names":["setIsoSpeedRate"]]])
        XCTAssertEqual(value.status(.aperture).name,"TemporarilyUnavailable")
        XCTAssertEqual(value.status(.iso),.available)
    }
    func testGetterOrSupportedRangeAloneNeverEnablesASetter() {
        var value = snapshot()
        value.applyMethods(["getFNumber","getSupportedFNumber","getAvailableFNumber"])
        value.supported.remove("setFNumber")
        XCTAssertEqual(value.status(.aperture),.unsupported)
        XCTAssertNotNil(value.status(.aperture).reason)
    }
    func testUnknownCapabilitiesAreNotLabeledUnsupported() {
        var value = SonyRemoteSnapshot()
        XCTAssertEqual(value.status(.iso),.unknown)
        value.applyMethods(["getIsoSpeedRate"])
        XCTAssertEqual(value.status(.iso).name,"TemporarilyUnavailable")
        XCTAssertFalse(value.supportComplete)
    }
    func testPollingTimeoutPreservesTappableConfirmedControl() {
        var value = snapshot(), original = value
        value.noteFailure(URLError(.timedOut))
        XCTAssertEqual(value.status(.iso),.available); XCTAssertEqual(value.status(.aperture),.available)
        XCTAssertEqual(value.settings[.iso]?.current,original.settings[.iso]?.current)
        if case .connectionError = value.settings[.iso]!.readStatus {} else { XCTFail("Missing connection read warning") }
        XCTAssertTrue(value.settings[.iso]!.displayValue.contains("400"))
        XCTAssertNotNil(value.settings[.iso]?.issue)
        original.noteFailure(URLError(.timedOut)); XCTAssertEqual(value,original)
    }
    func testPendingWriteDisablesOnlyItsOwnControl() {
        let value = snapshot()
        XCTAssertEqual(value.status(.aperture,pending:true),.commandInProgress)
        XCTAssertEqual(value.status(.iso,pending:false),.available)
        XCTAssertEqual(value.status(.shutter,pending:false),.available)
    }
    func testReadStatesDistinguishLoadingUnsupportedUnavailableAndErrors() {
        XCTAssertEqual(SonyRemoteSettingState(readStatus:.loading).displayValue,"Loading…")
        XCTAssertEqual(SonyRemoteSettingState(readStatus:.unsupported).displayValue,"Unsupported")
        XCTAssertEqual(SonyRemoteSettingState(readStatus:.unavailable("mode")).displayValue,"Unavailable")
        XCTAssertEqual(SonyRemoteSettingState.failure(URLError(.timedOut)).displayValue,"Connection error")
        XCTAssertEqual(SonyRemoteSettingState.failure(SonyRemoteError(message:"parse failed")).displayValue,"Read failed")
    }
    func testIdenticalReadIgnoresTimestampToPreventViewChurn() {
        let first = SonySettingParser.parse(.iso,result:["400",["100","400"]],available:true)
        var second = first; second.readAt = Date.distantFuture
        XCTAssertEqual(first,second)
        var value = snapshot(), before = value
        value.merge(.iso,first); before.merge(.iso,second); XCTAssertEqual(value,before)
    }
    func testPartialEvAndTemperatureEventsKeepKnownConversionDetails() {
        var value = snapshot()
        value.merge(.compensation,SonySettingParser.parse(.compensation,result:[0,6,-6,1],available:true))
        value.applyEvent([["type":"exposureCompensation","currentExposureCompensation":3]])
        XCTAssertEqual(value.settings[.compensation]?.current,.compensation(index:3,step:1))
        XCTAssertEqual(value.telemetry.ev,1)
        value.merge(.whiteBalance,SonySettingParser.parse(.whiteBalance,result:[["whiteBalanceMode":"Color Temperature","colorTemperature":4500]],available:false))
        value.applyEvent([["type":"whiteBalance","currentWhiteBalanceMode":"Color Temperature"]])
        XCTAssertEqual(value.settings[.whiteBalance]?.current,.whiteBalance(mode:"Color Temperature",temperature:4500))
    }
    func testMalformedCurrentValueDoesNotEraseLastConfirmedValue() {
        var value = snapshot()
        value.applyEvent([["type":"isoSpeedRate","currentIsoSpeedRate":["unexpected":"object"]]])
        XCTAssertEqual(value.settings[.iso]?.current,.text("400")); XCTAssertEqual(value.status(.iso),.available)
        XCTAssertNotNil(value.settings[.iso]?.issue)
    }
    func testPollPolicyDoesNotReconnectOnEventTimeoutOrProtocolError() {
        var policy = SonyRemotePollPolicy()
        for _ in 0..<20 {
            XCTAssertFalse(policy.failed(URLError(.timedOut),recentLiveFrame:false))
            XCTAssertFalse(policy.failed(SonyAPIError(method:"getEvent",code:5,detail:"mode"),recentLiveFrame:false))
        }
        XCTAssertEqual(policy.hardFailures,0)
    }
    func testRepeatedHardDisconnectNeedsThreeFailuresWithoutLiveFrames() {
        var policy = SonyRemotePollPolicy()
        XCTAssertFalse(policy.failed(URLError(.networkConnectionLost),recentLiveFrame:true))
        XCTAssertFalse(policy.failed(URLError(.networkConnectionLost),recentLiveFrame:false))
        XCTAssertFalse(policy.failed(URLError(.networkConnectionLost),recentLiveFrame:false))
        XCTAssertTrue(policy.failed(URLError(.networkConnectionLost),recentLiveFrame:false))
        policy.success(); XCTAssertEqual(policy.hardFailures,0)
    }
    func testCapabilitiesRefreshIsSlowAndEventPollHasOneSchedule() {
        var policy = SonyRemotePollPolicy()
        policy.snapshotRead(at:10)
        XCTAssertEqual(policy.nextSnapshot,25); XCTAssertEqual(policy.nextEvent,13)
        policy.eventRead(at:13)
        XCTAssertEqual(policy.nextSnapshot,25); XCTAssertEqual(policy.nextEvent,16)
    }
    @MainActor func testMAndAAndSUseAdvertisedSettersWithAtomicSnapshots() async throws {
        for mode in ["M","A","S"] {
            let fixture = SonySnapshotFixture(); fixture.mode(mode)
            fixture.methods += ["getAvailableFNumber","getAvailableShutterSpeed"]
            if mode != "S" { fixture.methods.append("setFNumber") }
            if mode != "A" { fixture.methods.append("setShutterSpeed") }
            fixture.responses["getAvailableFNumber"] = [.success(["4.0",["4.0","5.6"]])]
            fixture.responses["getAvailableShutterSpeed"] = [.success(["1/125",["1/125","1/250"]])]
            let before = snapshot()
            let next = try await SonySnapshotWorkflow.read(previous:before,call:fixture.call,active:{true})
            XCTAssertEqual(before.status(.aperture),.available)
            XCTAssertEqual(next.telemetry.mode,mode); XCTAssertEqual(next.status(.iso),.available)
            XCTAssertEqual(next.status(.aperture).name,mode == "S" ? "TemporarilyUnavailable" : "Available")
            XCTAssertEqual(next.status(.shutter).name,mode == "A" ? "TemporarilyUnavailable" : "Available")
            XCTAssertEqual(fixture.calls.filter { $0 == "getAvailableApiList" }.count,1)
            XCTAssertEqual(fixture.calls.filter { $0 == "getEvent" }.count,0)
        }
    }
    @MainActor func testModeChangedDuringSnapshotDiscardsCandidate() async {
        let fixture = SonySnapshotFixture(); fixture.mode("A","S")
        let before = snapshot()
        do { _ = try await SonySnapshotWorkflow.read(previous:before,call:fixture.call,active:{true}); XCTFail("Mixed-mode snapshot accepted") }
        catch { XCTAssertTrue(error is SonyModeChangedDuringRead) }
        XCTAssertEqual(before.telemetry.mode,"M"); XCTAssertEqual(before.status(.aperture),.available)
    }
    @MainActor func testStaleSessionStopsBeforeAnySettingRead() async {
        let fixture = SonySnapshotFixture(); var active = true
        fixture.after = { if $0 == "getAvailableApiList" { active = false } }
        do { _ = try await SonySnapshotWorkflow.read(previous:snapshot(),call:fixture.call,active:{active}); XCTFail("Stale snapshot") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.calls,["getAvailableApiList"])
    }
    @MainActor func testAvailableGetterFailureFallsBackToRealIsoGetter() async throws {
        let fixture = SonySnapshotFixture(); fixture.methods += ["getIsoSpeedRate"]
        fixture.responses["getAvailableIsoSpeedRate"] = [.failure(SonyAPIError(method:"getAvailableIsoSpeedRate",code:5,detail:"unavailable"))]
        fixture.responses["getIsoSpeedRate"] = [.success(["800"])]
        let read = try await SonySettingWorkflow.read(.iso,methods:Set(fixture.methods),allowEventRequest:false,call:fixture.call)
        XCTAssertEqual(read.current,.text("800")); XCTAssertEqual(fixture.calls,["getAvailableIsoSpeedRate","getIsoSpeedRate"])
    }
    @MainActor func testMalformedAvailableResponseFallsBackWithoutFakeValue() async throws {
        let fixture = SonySnapshotFixture()
        fixture.responses["getAvailableIsoSpeedRate"] = [.success([NSNull(),["100","400"]])]
        fixture.responses["getIsoSpeedRate"] = [.success(["400"])]
        let read = try await SonySettingWorkflow.read(.iso,methods:["getAvailableIsoSpeedRate","getIsoSpeedRate"],call:fixture.call)
        XCTAssertEqual(read.current,.text("400")); XCTAssertEqual(read.choices,[.text("100"),.text("400")])
    }
    @MainActor func testOneEventSnapshotIsSharedByAllSettings() async throws {
        let fixture = SonySnapshotFixture(); fixture.methods = ["getAvailableIsoSpeedRate","setIsoSpeedRate","getExposureMode","getEvent"]
        fixture.mode("M")
        fixture.responses["getEvent"] = [.success([["type":"fNumber","currentFNumber":"4.0","fNumberCandidates":["4.0","5.6"]]])]
        let next = try await SonySnapshotWorkflow.read(previous:snapshot(),call:fixture.call,active:{true})
        XCTAssertEqual(next.settings[.aperture]?.current,.text("4.0"))
        XCTAssertEqual(fixture.calls.filter { $0 == "getEvent" }.count,1)
        XCTAssertLessThan(try XCTUnwrap(fixture.calls.firstIndex(of:"getAvailableIsoSpeedRate")),fixture.calls.count-1)
    }
    @MainActor func testEventTimeoutCannotHideSuccessfulIsoRead() async throws {
        let fixture = SonySnapshotFixture(); fixture.mode("M"); fixture.methods.append("getEvent")
        fixture.responses["getEvent"] = [.failure(URLError(.timedOut))]
        let next = try await SonySnapshotWorkflow.read(previous:snapshot(),call:fixture.call,active:{true})
        XCTAssertEqual(next.settings[.iso]?.current,.text("400")); XCTAssertEqual(next.status(.iso),.available)
    }
    func testDiagnosticExportRedactsNetworkAndCredentialDetails() throws {
        let log = SonyDiagnostics()
        log.record("fixture",["host":"192.168.122.1","password":"secret-phrase","error":"failed http://192.168.122.1/camera token=hiddenvalue","model":"ILCE-7M3","extra":"password=\"private phrase\"; ssid=\"DIRECT private\""])
        let url = try log.export(); defer { try? FileManager.default.removeItem(at:url) }
        let text = try String(contentsOf:url,encoding:.utf8)
        XCTAssertFalse(text.contains("192.168.122.1")); XCTAssertFalse(text.contains("secret-phrase")); XCTAssertFalse(text.contains("hiddenvalue"))
        XCTAssertTrue(text.contains("ILCE-7M3")); XCTAssertFalse(text.contains("private phrase")); XCTAssertFalse(text.contains("DIRECT private"))
    }
    func testEventErrorsCannotStarveDirectValueRefresh() {
        var policy = SonyRemotePollPolicy(); policy.snapshotRead(at:0)
        for time in [3.0,6,9,12] { policy.backoff(snapshot:false,at:time) }
        XCTAssertEqual(policy.nextSnapshot,15)
        policy.backoff(snapshot:true,at:15); XCTAssertEqual(policy.nextSnapshot,30)
    }
    func testExplicitUnsupportedSetterStaysDisabledWhileOtherControlsWork() {
        var value = snapshot()
        value.writeFailed(.aperture,error:SonyAPIError(method:"setFNumber",code:12,detail:"unsupported"))
        XCTAssertEqual(value.status(.aperture),.unsupported); XCTAssertEqual(value.status(.iso),.available)
        value.applyMethods(value.methods)
        XCTAssertEqual(value.status(.aperture),.unsupported)
        var removed = value.methods; removed.remove("setFNumber"); value.applyMethods(removed)
        removed.insert("setFNumber"); value.applyMethods(removed)
        XCTAssertEqual(value.status(.aperture),.available)
    }
    @MainActor func testUnchangedSnapshotsRemainEqualAcrossRepeatedReads() async throws {
        var previous = snapshot(mode:"A")
        for index in 0..<4 {
            let fixture = SonySnapshotFixture(); fixture.mode("A")
            let next = try await SonySnapshotWorkflow.read(previous:previous,call:fixture.call,active:{true})
            if index > 0 { XCTAssertEqual(next,previous) }
            previous = next
        }
    }

    @MainActor func testFailedFinalModeProbeCannotReplaceConfirmedSnapshot() async {
        let fixture = SonySnapshotFixture(); fixture.mode("A")
        fixture.responses["getExposureMode"] = [.success(["A"]),.failure(URLError(.timedOut))]
        let previous = snapshot()
        do { _ = try await SonySnapshotWorkflow.read(previous:previous,call:fixture.call,active:{true}); XCTFail("Unverified mode snapshot accepted") }
        catch { XCTAssertEqual((error as? URLError)?.code,.timedOut) }
        XCTAssertEqual(previous.telemetry.mode,"M"); XCTAssertEqual(previous.status(.aperture),.available)
    }

    @MainActor func testObservedEventModeProtectsSnapshotWhenFirstModeGetterFails() async {
        let fixture = SonySnapshotFixture(); fixture.mode("A"); fixture.methods.append("getEvent")
        fixture.responses["getEvent"] = [.success([["type":"exposureMode","currentExposureMode":"A"]])]
        fixture.responses["getExposureMode"] = [.failure(SonyAPIError(method:"getExposureMode",code:5,detail:"temporarily unavailable")),.success(["S"])]
        do { _ = try await SonySnapshotWorkflow.read(previous:snapshot(),call:fixture.call,active:{true}); XCTFail("Changed event mode accepted") }
        catch { XCTAssertTrue(error is SonyModeChangedDuringRead) }
    }
    @MainActor func testMissingEventValueIsNotProofOfUnsupportedReading() async throws {
        let fixture = SonySnapshotFixture(); fixture.mode("M"); fixture.methods.append("getEvent")
        fixture.responses["getEvent"] = [.success([])]
        var previous = SonyRemoteSnapshot(); previous.supported = Set(fixture.methods); previous.supportComplete = true
        let next = try await SonySnapshotWorkflow.read(previous:previous,call:fixture.call,active:{true})
        XCTAssertNotEqual(next.settings[.aperture]?.readStatus,.unsupported)
        XCTAssertEqual(next.settings[.aperture]?.displayValue,"Unavailable")
    }

    func testSameMonitorUsesAdvertisedModeGetterWhenEventsAreUnavailable() {
        XCTAssertEqual(SonyRemotePollPolicy.feedbackMethod(["getEvent","getExposureMode"]),"getEvent")
        XCTAssertEqual(SonyRemotePollPolicy.feedbackMethod(["getExposureMode"]),"getExposureMode")
        XCTAssertNil(SonyRemotePollPolicy.feedbackMethod(["getIsoSpeedRate"]))
    }

}
