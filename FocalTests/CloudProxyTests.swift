import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Focal

private struct ProxyFixtureCredentials:CloudProxyCredentialProviding {
    var expired = false
    func credential() async throws -> CloudProxyCredential {
        .init(accessToken:String(repeating:"fixture-device-",count:3),expiresAt:Date().addingTimeInterval(expired ? -1 : 300))
    }
}
private actor ProxyFixtureTransport:CloudHTTPTransport {
    let response:Result<CloudHTTPResponse,Error>
    let delayed:Bool
    var requests = [URLRequest]()
    init(_ response:Result<CloudHTTPResponse,Error>,delayed:Bool = false) { self.response = response; self.delayed = delayed }
    func send(_ request:URLRequest) async throws -> CloudHTTPResponse {
        requests.append(request)
        if delayed { try await Task.sleep(nanoseconds:5_000_000_000) }
        return try response.get()
    }
    func count() -> Int { requests.count }
}

final class CloudProxyTests:XCTestCase {
    private let endpoint = URL(string:"https://composition.example/v1/composition-scans")!
    private func capture() -> CloudScanCapture {
        .init(requestID:UUID(),jpeg:Data([0xff,0xd8,0xff,0xd9]),evidence:.init(observedAt:10,sessionRevision:1,isIPhone:true,
            mode:.automatic,trackingReference:"chair-A",label:"Chair",bounds:.init(x:0.3,y:0.3,width:0.4,height:0.4),
            confidence:0.95,zoom:1,minimumZoom:0.5,maximumZoom:3,previewAspect:1,scene:nil,rollReliable:true,rollDegrees:0))
    }
    private func reply(_ id:UUID) throws -> Data {
        let result: [String:Any] = ["sceneCategory":"product","photographicIntent":"Auto","primarySubjectDescription":"Chair",
            "localSubjectID":"selected","subjectBoundingBox":["x":0.3,"y":0.3,"width":0.4,"height":0.4],
            "recommendedCompositionTechnique":"centered","normalizedTargetPosition":["x":0.5,"y":0.5],
            "recommendedZoomRange":["minimum":1,"maximum":2],"rollSuggestion":NSNull(),
            "explanation":"Keep room around the selected chair.","confidence":0.9,"alternatives":[]]
        return try JSONSerialization.data(withJSONObject:["requestId":id.uuidString.lowercased(),"modelVersion":"fixture-model-v1","result":result])
    }
    private func wait(_ transport:ProxyFixtureTransport) async throws {
        for _ in 0..<100 {
            if await transport.count() > 0 { return }
            try await Task.sleep(nanoseconds:1_000_000)
        }
        XCTFail("Fixture transport was never reached")
    }
    func testAuthenticatedProxyUsesOneBoundedRequestWithoutProviderCredentials() async throws {
        let image = capture(); let transport = ProxyFixtureTransport(.success(.init(data:try reply(image.requestID),status:200)))
        let service = CloudCompositionProxyService(endpoint:endpoint,credentials:ProxyFixtureCredentials(),transport:transport)
        let result = try await service.scan(image); XCTAssertEqual(result.primarySubjectDescription,"Chair")
        let requests = await transport.requests; XCTAssertEqual(requests.count,1)
        XCTAssertTrue(requests[0].value(forHTTPHeaderField:"Authorization")?.hasPrefix("Bearer fixture-device-") == true)
        XCTAssertNil(requests[0].value(forHTTPHeaderField:"x-goog-api-key")); XCTAssertNil(requests[0].url?.query)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField:"Idempotency-Key"),image.requestID.uuidString.lowercased())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(requests[0].httpBody)) as? [String:Any])
        XCTAssertEqual(Set(body.keys),["requestId","mimeType","image","facts"])
    }
    func testDuplicateExplicitRequestIDDoesNotUploadTwice() async throws {
        let image = capture(); let transport = ProxyFixtureTransport(.success(.init(data:try reply(image.requestID),status:200)))
        let service = CloudCompositionProxyService(endpoint:endpoint,credentials:ProxyFixtureCredentials(),transport:transport)
        _ = try await service.scan(image)
        do { _ = try await service.scan(image); XCTFail() } catch { XCTAssertEqual(error as? CloudCompositionError,.stale) }
        let count = await transport.count(); XCTAssertEqual(count,1)
    }
    func testExpiredDeviceAuthorizationCannotSendImage() async throws {
        let transport = ProxyFixtureTransport(.failure(CloudCompositionError.offline))
        let service = CloudCompositionProxyService(endpoint:endpoint,credentials:ProxyFixtureCredentials(expired:true),transport:transport)
        do { _ = try await service.scan(capture()); XCTFail() } catch { XCTAssertEqual(error as? CloudCompositionError,.unauthorized) }
        let count = await transport.count(); XCTAssertEqual(count,0)
    }
    func testUnsafeEndpointsAreRejectedBeforeNetworking() {
        for value in ["http://composition.example/v1/composition-scans","https://composition.example/other", "https://user:pass@composition.example/v1/composition-scans", "https://composition.example/v1/composition-scans?key=private", "https://127.0.0.1/v1/composition-scans"] {
            XCTAssertFalse(CloudCompositionProxyService.valid(URL(string:value)!))
        }
        XCTAssertTrue(CloudCompositionProxyService.valid(endpoint))
    }
    func testWrongRequestIDAndExtraResponseFieldsCannotReplaceComposition() throws {
        let image = capture()
        XCTAssertThrowsError(try CloudCompositionProxyService.result(reply(UUID()),requestID:image.requestID))
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with:reply(image.requestID)) as? [String:Any]); body["ready"] = true
        XCTAssertThrowsError(try CloudCompositionProxyService.result(JSONSerialization.data(withJSONObject:body),requestID:image.requestID))
    }
    func testOfflineAndTimeoutDoNotAutomaticallyRetryImageUpload() async throws {
        for failure in [CloudCompositionError.offline,.timeout] {
            let image = capture(); let transport = ProxyFixtureTransport(.failure(failure))
            let service = CloudCompositionProxyService(endpoint:endpoint,credentials:ProxyFixtureCredentials(),transport:transport)
            do { _ = try await service.scan(image); XCTFail() } catch { XCTAssertEqual(error as? CloudCompositionError,failure) }
            do { _ = try await service.scan(image); XCTFail() } catch { XCTAssertEqual(error as? CloudCompositionError,.stale) }
            let count = await transport.count(); XCTAssertEqual(count,1)
        }
    }
    func testCancellationAndOverlappingScanDoNotCreateSecondUpload() async throws {
        let image = capture(); let transport = ProxyFixtureTransport(.success(.init(data:try reply(image.requestID),status:200)),delayed:true)
        let service = CloudCompositionProxyService(endpoint:endpoint,credentials:ProxyFixtureCredentials(),transport:transport)
        let task = Task { try await service.scan(image) }; try await wait(transport)
        do { _ = try await service.scan(capture()); XCTFail() } catch { XCTAssertEqual(error as? CloudCompositionError,.quota) }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.count(); XCTAssertEqual(count,1)
    }
    func testSonyFrameCannotBeUploadedThroughPhoneProxy() throws {
        let image = capture(); var evidence = image.evidence; evidence.isIPhone = false
        XCTAssertThrowsError(try CloudCompositionProxyService.body(.init(requestID:image.requestID,jpeg:image.jpeg,evidence:evidence)))
    }
}
