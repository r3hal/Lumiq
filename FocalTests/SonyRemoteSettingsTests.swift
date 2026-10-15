import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Focal

@MainActor private final class SonySettingFixture {
    var methods = ["getAvailableIsoSpeedRate","setIsoSpeedRate"]
    var calls = [(String,[Any])]()
    var responses = [String:[Result<[Any],Error>]]()
    var afterCall: ((String) -> Void)?
    func call(_ method:String,_ params:[Any],_ timeout:TimeInterval) async throws -> Data {
        calls.append((method,params)); afterCall?(method)
        let result:[Any]
        if var queue = responses[method], !queue.isEmpty {
            let next = queue.removeFirst(); responses[method] = queue; result = try next.get()
        } else if method == "getAvailableApiList" { result = [methods] }
        else { throw SonyRemoteError(message:"Unexpected fixture command: \(method)") }
        return try JSONSerialization.data(withJSONObject:["result":result])
    }
    func iso(_ values:[String],current:String = "100") {
        responses["getAvailableIsoSpeedRate"] = [.success([current,values])]
    }
}

/// Exercises the production URLSession/JSON-RPC client without a Sony device.
private final class SonyWireFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var payload = Data()
    private static var captured: URLRequest?
    private static var capturedBody: Data?
    static func install(_ data:Data) { lock.lock(); defer { lock.unlock() }; payload = data; captured = nil; capturedBody = nil }
    static func lastRequest() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return captured }
    static func lastBody() -> Data? { lock.lock(); defer { lock.unlock() }; return capturedBody }
    static func body(of request:URLRequest) throws -> Data? {
        if let bytes = request.httpBody { return bytes }
        guard let stream = request.httpBodyStream else { return nil }
        // Darwin URLSession can replace httpBody with httpBodyStream before
        // handing a request to URLProtocol. Consume it once at interception.
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating:0,count:4096)
        while true {
            let count = stream.read(&buffer,maxLength:buffer.count)
            guard count >= 0 else { throw stream.streamError ?? SonyRemoteError(message:"Cannot read fixture request body.") }
            if count == 0 { return data }
            guard data.count + count <= 1_048_576 else { throw SonyRemoteError(message:"Unexpectedly large fixture request body.") }
            data.append(contentsOf:buffer.prefix(count))
        }
    }
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body:Data?
        do { body = try Self.body(of:request) }
        catch { client?.urlProtocol(self,didFailWithError:error); return }
        Self.lock.lock(); let data = Self.payload; Self.captured = request; Self.capturedBody = body; Self.lock.unlock()
        let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SonyRemoteSettingsTests: XCTestCase {
    func testAllRequestedSettingsUseDocumentedLegacyCommands() {
        XCTAssertEqual(SonyRemoteSetting.allCases.map(\.setter),["setIsoSpeedRate","setFNumber","setShutterSpeed","setWhiteBalance","setExposureCompensation"])
        XCTAssertFalse(SonyRemoteSetting.allCases.contains { $0.setter.lowercased().contains("zoom") })
    }
    func testLensAperturesComeOnlyFromCameraReportedValues() {
        let sigma = SonySettingParser.parse(.aperture,result:["2.8",["2.8","4.0","5.6","8.0"]],available:true)
        let sony = SonySettingParser.parse(.aperture,result:["4.0",["4.0","5.6","8.0","11"]],available:true)
        XCTAssertEqual(sigma.current,.text("2.8")); XCTAssertEqual(sony.current,.text("4.0"))
        XCTAssertTrue(sigma.choices.contains(.text("2.8"))); XCTAssertFalse(sony.choices.contains(.text("2.8")))
    }
    func testShutterStringsArePreservedExactly() {
        let state = SonySettingParser.parse(.shutter,result:["1/125",["1/125","0.5\"","BULB"]],available:true)
        XCTAssertEqual(state.choices,[.text("1/125"),.text("0.5\""),.text("BULB")])
        XCTAssertEqual(state.current,.text("1/125"))
    }
    func testWhiteBalanceUsesCameraKelvinRangeAndThreeParameters() {
        let state = SonySettingParser.parse(.whiteBalance,result:[["whiteBalanceMode":"Auto WB","colorTemperature":-1],
            [["whiteBalanceMode":"Auto WB","colorTemperatureRange":[]],
             ["whiteBalanceMode":"Color Temperature","colorTemperatureRange":[3000,2500,250]]]],available:true)
        XCTAssertEqual(state.current,.whiteBalance(mode:"Auto WB",temperature:nil))
        XCTAssertEqual(state.choices.count,4)
        XCTAssertEqual(state.choices.last,.whiteBalance(mode:"Color Temperature",temperature:3000))
        let mode = SonySettingValue.whiteBalance(mode:"Auto WB",temperature:nil).parameters
        XCTAssertEqual(mode[0] as? String,"Auto WB"); XCTAssertEqual(mode[1] as? Bool,false); XCTAssertEqual(mode[2] as? Int,-1)
        let kelvin = SonySettingValue.whiteBalance(mode:"Color Temperature",temperature:2750).parameters
        XCTAssertEqual(kelvin[1] as? Bool,true); XCTAssertEqual(kelvin[2] as? Int,2750)
    }
    func testMalformedAndUnboundedWhiteBalanceRangesAreNotInvented() {
        for range in [[2000,3000,100],[9900,2500,0],[999999,1,1],[3000,2500]] {
            let state = SonySettingParser.parse(.whiteBalance,result:[["whiteBalanceMode":"Auto WB"],[["whiteBalanceMode":"Temperature","colorTemperatureRange":range]]],available:true)
            XCTAssertTrue(state.choices.isEmpty)
        }
    }
    func testExposureCompensationUsesReportedIndexStepAndRange() {
        let thirds = SonySettingParser.parse(.compensation,result:[2,9,-9,1],available:true)
        XCTAssertEqual(thirds.current,.compensation(index:2,step:1)); XCTAssertEqual(thirds.choices.count,19)
        XCTAssertEqual(SonySettingValue.ev(index:2,step:1)!,2.0/3,accuracy:0.0001)
        XCTAssertEqual(SonySettingValue.ev(index:-3,step:2),-1.5)
        XCTAssertEqual(SonySettingValue.compensation(index:-3,step:2).parameters.first as? Int,-3)
    }
    func testUnknownEvStepIsReadOnlyWithoutFabricatedEV() {
        let state = SonySettingParser.parse(.compensation,result:[3,9,-9,0],available:true)
        XCTAssertTrue(state.choices.isEmpty); XCTAssertNil(SonySettingValue.ev(index:3,step:0))
        XCTAssertEqual(SonySettingValue.ev(index:0,step:nil),0)
        XCTAssertTrue(state.current!.label.contains("not reported"))
    }
    func testBooleanCannotMasqueradeAsSettingIndexOrAcknowledgment() {
        XCTAssertNil(SonySettingParser.integer(true)); XCTAssertEqual(SonySettingParser.integer(0),0)
        XCTAssertNil(SonySettingParser.integer(0.5)); XCTAssertNil(SonySettingParser.integer("1"))
    }
    func testEventsReportRealValuesAndAvailableChoices() {
        let event:[Any] = [["type":"isoSpeedRate","currentIsoSpeedRate":"400","isoSpeedRateCandidates":["100","400"]],
                           ["type":"fNumber","currentFNumber":"5.6","fNumberCandidates":["4.0","5.6"]],
                           ["type":"whiteBalance","currentWhiteBalanceMode":"Daylight","whiteBalanceCandidates":[["whiteBalanceMode":"Daylight","colorTemperatureRange":[]]]]]
        XCTAssertEqual(SonySettingParser.event(.iso,values:event)?.current,.text("400"))
        XCTAssertEqual(SonySettingParser.event(.aperture,values:event)?.choices,[.text("4.0"),.text("5.6")])
        XCTAssertEqual(SonySettingParser.event(.whiteBalance,values:event)?.current,.whiteBalance(mode:"Daylight",temperature:nil))
        XCTAssertNil(SonySettingParser.event(.shutter,values:event))
    }
    func testEventCompensationTelemetryDoesNotGuessUnknownStep() {
        let event:[Any] = [["type":"exposureCompensation","currentExposureCompensation":3,"maxExposureCompensation":9,"minExposureCompensation":-9,"stepIndexOfExposureCompensation":1]]
        XCTAssertEqual(SonySettingParser.event(.compensation,values:event)?.choices.count,19)
        XCTAssertEqual(SonyEventValues.telemetry(event).ev,1)
        XCTAssertNil(SonyEventValues.telemetry([["type":"exposureCompensation","currentExposureCompensation":3]]).ev)
    }
    func testUnsupportedAndModeUnavailableHaveDistinctReasons() {
        let state = SonyRemoteSettingState(current:.text("100"),choices:[.text("100")])
        XCTAssertTrue(state.disabledReason(setting:.iso,available:[],supported:["setIsoSpeedRate"])!.contains("shooting mode"))
        XCTAssertTrue(state.disabledReason(setting:.iso,available:[],supported:[])!.contains("does not advertise"))
        XCTAssertNil(state.disabledReason(setting:.iso,available:["setIsoSpeedRate"],supported:[]))
        XCTAssertNotNil(SonyRemoteSettingState(current:.text("100")).disabledReason(setting:.iso,available:["setIsoSpeedRate"],supported:[]))
    }
    func testMethodTypesPluralResultsAreParsedWithoutDroppingCapabilities() throws {
        let data = try JSONSerialization.data(withJSONObject:["results":[["setFNumber",["string"],["int"],"1.0"]]])
        XCTAssertEqual(SonyMethodCapabilities.names(try SonyAPIClient.result(data)),["setFNumber"])
        XCTAssertThrowsError(try SonyAPIClient.result(Data("{\"error\":[12,\"unsupported\"]}".utf8)))
    }
    @MainActor func testReadOnlyGetterDoesNotInventAvailableChoices() async throws {
        let f = SonySettingFixture(); f.responses["getFNumber"] = [.success(["4.0"])]
        let state = try await SonySettingWorkflow.read(.aperture,methods:["getFNumber"],call:f.call)
        XCTAssertEqual(state.current,.text("4.0")); XCTAssertTrue(state.choices.isEmpty)
        XCTAssertEqual(f.calls.map { $0.0 },["getFNumber"])
    }
    @MainActor func testReadFallsBackToDocumentedEvents() async throws {
        let f = SonySettingFixture(); f.responses["getEvent"] = [.success([["type":"shutterSpeed","currentShutterSpeed":"1/60","shutterSpeedCandidates":["1/60","1/125"]]])]
        let state = try await SonySettingWorkflow.read(.shutter,methods:["getEvent"],call:f.call)
        XCTAssertEqual(state.current,.text("1/60")); XCTAssertEqual(state.choices.count,2)
    }
    @MainActor func testChangeRequiresCameraAcknowledgmentAndDelayedReadback() async throws {
        let f = SonySettingFixture()
        f.responses = ["getAvailableIsoSpeedRate":[.success(["100",["100","400"]]),.success(["100",["100","400"]]),.success(["400",["100","400"]])],"setIsoSpeedRate":[.success([0])]]
        let state = try await SonySettingWorkflow.change(.iso,to:.text("400"),call:f.call,active:{true},wait:{ _ in })
        XCTAssertEqual(state.current,.text("400")); XCTAssertNotNil(state.readAt)
        XCTAssertEqual(f.calls.filter { $0.0 == "setIsoSpeedRate" }.count,1)
        XCTAssertEqual(f.calls.filter { $0.0 == "getAvailableIsoSpeedRate" }.count,3)
    }
    @MainActor func testUnconfirmedAcknowledgmentNeverReturnsRequestedValue() async {
        let f = SonySettingFixture(); f.responses["getAvailableIsoSpeedRate"] = Array(repeating:.success(["100",["100","400"]]),count:6)
        f.responses["setIsoSpeedRate"] = [.success([0])]
        do { _ = try await SonySettingWorkflow.change(.iso,to:.text("400"),call:f.call,active:{true},wait:{ _ in }); XCTFail("Unconfirmed write accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not confirm")) }
        XCTAssertEqual(f.calls.filter { $0.0 == "setIsoSpeedRate" }.count,1)
    }
    @MainActor func testModeChangeRejectsWriteBeforeCommand() async {
        let f = SonySettingFixture(); f.methods = ["getAvailableIsoSpeedRate"]
        do { _ = try await SonySettingWorkflow.change(.iso,to:.text("400"),call:f.call,active:{true},wait:{ _ in }); XCTFail("Unavailable write") } catch { }
        XCTAssertFalse(f.calls.contains { $0.0 == "setIsoSpeedRate" })
    }
    @MainActor func testChangedLensRejectsStaleApertureChoice() async {
        let f = SonySettingFixture(); f.methods = ["setFNumber","getAvailableFNumber"]
        f.responses["getAvailableFNumber"] = [.success(["4.0",["4.0","5.6"]])]
        do { _ = try await SonySettingWorkflow.change(.aperture,to:.text("2.8"),call:f.call,active:{true},wait:{ _ in }); XCTFail("Unavailable lens aperture") } catch { }
        XCTAssertFalse(f.calls.contains { $0.0 == "setFNumber" })
    }
    @MainActor func testAmbiguousSettingTimeoutNeverReplaysWrite() async {
        let f = SonySettingFixture(); f.iso(["100","400"]); f.responses["setIsoSpeedRate"] = [.failure(URLError(.timedOut))]
        do { _ = try await SonySettingWorkflow.change(.iso,to:.text("400"),call:f.call,active:{true},wait:{ _ in }); XCTFail("Timeout") } catch { }
        XCTAssertEqual(f.calls.filter { $0.0 == "setIsoSpeedRate" }.count,1)
    }
    @MainActor func testBusyResponseIsNotConfirmedOrRetried() async {
        let f = SonySettingFixture(); f.iso(["100","400"]); f.responses["setIsoSpeedRate"] = [.failure(SonyAPIError(method:"setIsoSpeedRate",code:40401,detail:"busy"))]
        do { _ = try await SonySettingWorkflow.change(.iso,to:.text("400"),call:f.call,active:{true},wait:{ _ in }); XCTFail("Busy") }
        catch { XCTAssertTrue(error.localizedDescription.contains("40401")) }
        XCTAssertEqual(f.calls.filter { $0.0 == "setIsoSpeedRate" }.count,1)
    }
    @MainActor func testInvalidAcknowledgmentCannotConfirmASetting() async {
        let f = SonySettingFixture(); f.iso(["100","400"]); f.responses["setIsoSpeedRate"] = [.success([1])]
        do { _ = try await SonySettingWorkflow.change(.iso,to:.text("400"),call:f.call,active:{true},wait:{ _ in }); XCTFail("Invalid acknowledgment") } catch { }
        XCTAssertEqual(f.calls.filter { $0.0 == "getAvailableIsoSpeedRate" }.count,1)
    }
    @MainActor func testUnchangedValueDoesNotSendWrite() async throws {
        let f = SonySettingFixture(); f.iso(["100","400"])
        let state = try await SonySettingWorkflow.change(.iso,to:.text("100"),call:f.call,active:{true},wait:{ _ in })
        XCTAssertEqual(state.current,.text("100")); XCTAssertFalse(f.calls.contains { $0.0 == "setIsoSpeedRate" })
    }
    @MainActor func testDisconnectedSessionCannotSendASetting() async {
        let f = SonySettingFixture()
        do { _ = try await SonySettingWorkflow.change(.iso,to:.text("400"),call:f.call,active:{false},wait:{ _ in }); XCTFail("Inactive") } catch { }
        XCTAssertTrue(f.calls.isEmpty)
    }
    @MainActor func testDisconnectAfterAcknowledgmentRejectsStaleFeedback() async {
        let f = SonySettingFixture(); f.iso(["100","400"]); f.responses["setIsoSpeedRate"] = [.success([0])]
        var active = true; f.afterCall = { if $0 == "setIsoSpeedRate" { active = false } }
        do { _ = try await SonySettingWorkflow.change(.iso,to:.text("400"),call:f.call,active:{active},wait:{ _ in }); XCTFail("Stale result") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(f.calls.last?.0,"setIsoSpeedRate")
    }
    @MainActor func testAFTriggerUsesCameraStatusAndReleasesWithoutShutter() async throws {
        let f = SonySettingFixture(); f.methods = ["actHalfPressShutter","cancelHalfPressShutter","getEvent"]
        f.responses = ["getEvent":[.success([["type":"cameraStatus","cameraStatus":"IDLE"]]),.success([["type":"focusStatus","focusStatus":"Focusing"]]),.success([["type":"focusStatus","focusStatus":"Focused"]])],"actHalfPressShutter":[.success([0])],"cancelHalfPressShutter":[.success([0])]]
        let message = try await SonyFocusWorkflow.trigger(call:f.call,supported:[],active:{true},wait:{ _ in })
        XCTAssertTrue(message.contains("focus locked")); XCTAssertEqual(f.calls.last?.0,"cancelHalfPressShutter")
        XCTAssertFalse(f.calls.contains { $0.0 == "actTakePicture" })
    }
    @MainActor func testAFWithoutStatusReportsAcknowledgmentNotFocusLock() async throws {
        let f = SonySettingFixture(); f.methods = ["actHalfPressShutter","cancelHalfPressShutter"]
        f.responses = ["actHalfPressShutter":[.success([0])],"cancelHalfPressShutter":[.success([0])]]
        let message = try await SonyFocusWorkflow.trigger(call:f.call,supported:[],active:{true},wait:{ _ in })
        XCTAssertTrue(message.contains("did not confirm focus lock"))
    }
    @MainActor func testAFFailureAlwaysReleasesHalfPress() async {
        let f = SonySettingFixture(); f.methods = ["actHalfPressShutter","cancelHalfPressShutter","getEvent"]
        f.responses = ["getEvent":[.success([]),.success([["type":"focusStatus","focusStatus":"Failed"]])],"actHalfPressShutter":[.success([0])],"cancelHalfPressShutter":[.success([0])]]
        do { _ = try await SonyFocusWorkflow.trigger(call:f.call,supported:[],active:{true},wait:{ _ in }); XCTFail("Failed AF") } catch { }
        XCTAssertEqual(f.calls.last?.0,"cancelHalfPressShutter")
    }
    @MainActor func testManualSonyFocusModeBlocksAFTrigger() async {
        let f = SonySettingFixture(); f.methods = ["actHalfPressShutter","cancelHalfPressShutter","getFocusMode"]
        f.responses = ["getFocusMode":[.success(["MF"])]]
        do { _ = try await SonyFocusWorkflow.trigger(call:f.call,supported:[],active:{true},wait:{ _ in }); XCTFail("MF") } catch { }
        XCTAssertFalse(f.calls.contains { $0.0 == "actHalfPressShutter" })
    }
    @MainActor func testAFRequiresReleaseCapabilityBeforeHalfPress() async {
        let f = SonySettingFixture(); f.methods = ["actHalfPressShutter"]
        do { _ = try await SonyFocusWorkflow.trigger(call:f.call,supported:[],active:{true},wait:{ _ in }); XCTFail("No release") } catch { }
        XCTAssertFalse(f.calls.contains { $0.0 == "actHalfPressShutter" })
    }
    func testDiagnosticsAreBoundedStructuredJSON() throws {
        let diagnostics = SonyDiagnostics()
        for index in 0..<450 { diagnostics.record("fixture",["index":String(index),"value":String(repeating:"x",count:2000)]) }
        let url = try diagnostics.export(); defer { try? FileManager.default.removeItem(at:url) }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [[String:Any]])
        XCTAssertEqual(rows.count,400)
        let fields = try XCTUnwrap(rows.first?["fields"] as? [String:String])
        XCTAssertEqual(fields["index"],"50"); XCTAssertEqual(fields["value"]?.count,1500)
    }
    func testProductionWireClientAcceptsLegacyMethodTypesAndSendsVersionOne() async throws {
        SonyWireFixture.install(try JSONSerialization.data(withJSONObject:["results":[["setFNumber",["string"],["int"],"1.0"]]]))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SonyWireFixture.self]
        let api = SonyAPIClient(endpoint:URL(string:"http://192.168.122.1:8080/sony/camera")!,configuration:config)
        let data = try await api.call("getMethodTypes",params:[""])
        XCTAssertEqual(SonyMethodCapabilities.names(try SonyAPIClient.result(data)),["setFNumber"])
        let request = try XCTUnwrap(SonyWireFixture.lastRequest())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(SonyWireFixture.lastBody(),"URLProtocol must capture the real JSON-RPC body, including streamed bodies")) as? [String:Any])
        XCTAssertEqual(body["version"] as? String,"1.0"); XCTAssertEqual(body["method"] as? String,"getMethodTypes")
        XCTAssertEqual(request.httpMethod,"POST"); await api.shutdown()
    }
    func testWireFixtureCapturesIdenticalDataAndStreamBodies() throws {
        let bytes = try JSONSerialization.data(withJSONObject:["method":"getMethodTypes","params":[""],"version":"1.0","id":1])
        for streamed in [false,true] {
            var request = URLRequest(url:URL(string:"http://192.168.122.1/sony/camera")!)
            if streamed { request.httpBodyStream = InputStream(data:bytes) } else { request.httpBody = bytes }
            XCTAssertEqual(try SonyWireFixture.body(of:request),bytes)
        }
    }
    func testProductionWireClientRejectsCameraErrorsAndRecordsFailure() async throws {
        SonyWireFixture.install(Data("{\"error\":[40401,\"busy\"],\"id\":1}".utf8))
        let diagnostics = SonyDiagnostics(),config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SonyWireFixture.self]
        let api = SonyAPIClient(endpoint:URL(string:"http://192.168.122.1/sony/camera")!,diagnostics:diagnostics,configuration:config)
        do { _ = try await api.call("setFNumber",params:["5.6"]); XCTFail("Camera error accepted") }
        catch let error as SonyAPIError { XCTAssertEqual(error.code,40401); XCTAssertEqual(error.method,"setFNumber") }
        let url = try diagnostics.export(); defer { try? FileManager.default.removeItem(at:url) }
        let text = try String(contentsOf:url,encoding:.utf8)
        XCTAssertTrue(text.contains("command.failed")); XCTAssertTrue(text.contains("40401")); await api.shutdown()
    }
    func testProductionWireClientDoesNotExportPhotoTransferURLs() async throws {
        let privatePhoto = "http://192.168.122.1/private-photo.jpg"
        SonyWireFixture.install(try JSONSerialization.data(withJSONObject:["result":[[privatePhoto]]]))
        let diagnostics = SonyDiagnostics(),config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SonyWireFixture.self]
        let api = SonyAPIClient(endpoint:URL(string:"http://192.168.122.1/sony/camera")!,diagnostics:diagnostics,configuration:config)
        _ = try await api.call("actTakePicture")
        let url = try diagnostics.export(); defer { try? FileManager.default.removeItem(at:url) }
        let text = try String(contentsOf:url,encoding:.utf8)
        XCTAssertTrue(text.contains("command.completed")); XCTAssertFalse(text.contains("private-photo")); await api.shutdown()
    }

}
