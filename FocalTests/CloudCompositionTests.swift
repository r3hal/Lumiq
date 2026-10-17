import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Focal

final class CloudCompositionTests: XCTestCase {
    private func evidence(at time:Double = 10,brightness:Double = 0.4) throws -> CloudLocalEvidence {
        let pixels = (0..<48*48).map { index -> SubjectImageEvidence.Pixel in
            let value = min(1,brightness+(index%5 == 0 ? 0.04 : 0))
            return .init(red:value,green:value*0.9,blue:value*0.8)
        }
        let scene = try XCTUnwrap(SceneCompositionEvidence(image:.init(pixels:pixels,width:48,height:48),projection:.init(imageAspect:1,previewAspect:1),timestamp:time))
        return .init(observedAt:time,sessionRevision:7,isIPhone:true,mode:.automatic,trackingReference:"person-A",label:"Person",
            bounds:CGRect(x:0.35,y:0.35,width:0.3,height:0.3),confidence:0.95,zoom:1,minimumZoom:0.5,maximumZoom:3,previewAspect:1,scene:scene,rollReliable:true,rollDegrees:0)
    }
    private func proposal() -> CloudCompositionResult {
        .init(sceneCategory:.portrait,photographicIntent:.portrait,primarySubjectDescription:"Person",localSubjectID:"selected",
            subjectBoundingBox:.init(x:0.35,y:0.35,width:0.3,height:0.3),recommendedCompositionTechnique:.ruleOfThirds,
            normalizedTargetPosition:.init(x:1.0/3,y:1.0/3),recommendedZoomRange:.init(minimum:1,maximum:2),rollSuggestion:nil,
            explanation:"Place the observed person near the upper third while keeping room around them.",confidence:0.9,alternatives:[])
    }
    private func json(_ result:CloudCompositionResult? = nil) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(result ?? proposal())) as? [String:Any])
        for key in ["localSubjectID","subjectBoundingBox","rollSuggestion"] where object[key] == nil { object[key] = NSNull() }
        return try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)
    }
    private func capture(_ local:CloudLocalEvidence) -> CloudScanCapture { .init(requestID:UUID(),jpeg:Data([0xff,0xd8,0xff,0xd9]),evidence:local) }
    private func envelope(_ body:Data? = nil,finish:String = "STOP") throws -> Data {
        try JSONSerialization.data(withJSONObject:["candidates":[["finishReason":finish,"content":["parts":[["text":String(data:try body ?? json(),encoding:.utf8)!]]]]]])
    }
    private func locked() throws -> CloudCompositionLock { let local = try evidence(); return try CloudCompositionMatcher.match(proposal(),capture:capture(local),live:local,at:10.1) }
    private func assertError(_ expected:CloudCompositionError,_ body:() throws -> Void,file:StaticString = #filePath,line:UInt = #line) {
        XCTAssertThrowsError(try body(),file:file,line:line) { XCTAssertEqual($0 as? CloudCompositionError,expected,file:file,line:line) }
    }
    func testStrictStructuredSuccess() throws { let result = try CloudCompositionResult.decode(json()); XCTAssertEqual(result.recommendedCompositionTechnique,.ruleOfThirds); XCTAssertEqual(result.confidence,0.9) }
    func testAllRequestedTechniquesAreRepresentable() throws {
        XCTAssertEqual(CloudTechnique.allCases.count,8)
        for technique in CloudTechnique.allCases { var value = proposal(); value.recommendedCompositionTechnique = technique; XCTAssertEqual(try CloudCompositionResult.decode(json(value)).recommendedCompositionTechnique,technique) }
    }
    func testMalformedJSONAndMarkdownAreRejected() { for text in ["broken","[]","{}","```json {}```"] { assertError(.invalidResponse) { _ = try CloudCompositionResult.decode(Data(text.utf8)) } } }
    func testExtraReadyOrCaptureKeysAreRejected() throws {
        for key in ["ready","capture","toolCall"] { var object = try XCTUnwrap(JSONSerialization.jsonObject(with:json()) as? [String:Any]); object[key] = true; assertError(.invalidResponse) { _ = try CloudCompositionResult.decode(JSONSerialization.data(withJSONObject:object)) } }
    }
    func testNonfiniteAndOutOfRangeConfidenceRejected() throws {
        for confidence in [-1.0,0.64,1.1,Double.nan,Double.infinity] { var result = proposal(); result.confidence = confidence; assertError(.invalidResponse) { try result.validate() } }
    }
    func testCoordinatesAndBoundingBoxesFailClosed() throws {
        for point in [CloudPoint(x:-0.01,y:0.5),.init(x:0.5,y:1.01),.init(x:.nan,y:0.5)] { var result = proposal(); result.normalizedTargetPosition = point; assertError(.invalidResponse) { try result.validate() } }
        var result = proposal(); result.subjectBoundingBox = .init(x:0.9,y:0.3,width:0.3,height:0.3); assertError(.invalidResponse) { try result.validate() }
    }
    func testImpossibleAndInvertedZoomRangesRejected() throws {
        for range in [CloudZoomRange(minimum:0.1,maximum:1),.init(minimum:3,maximum:2),.init(minimum:1,maximum:99)] { var result = proposal(); result.recommendedZoomRange = range; assertError(.invalidResponse) { try result.validate() } }
    }
    func testUnknownEnumAndNestedFieldsRejected() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:json()) as? [String:Any]); object["recommendedCompositionTechnique"] = "inventedRule"
        assertError(.invalidResponse) { _ = try CloudCompositionResult.decode(JSONSerialization.data(withJSONObject:object)) }
        object["recommendedCompositionTechnique"] = "centered"; object["normalizedTargetPosition"] = ["x":0.5,"y":0.5,"command":1]
        assertError(.invalidResponse) { _ = try CloudCompositionResult.decode(JSONSerialization.data(withJSONObject:object)) }
    }
    func testUnsafeTextAndTooManyAlternativesRejected() throws {
        var result = proposal(); result.explanation = "Unsafe\ntext"; assertError(.invalidResponse) { try result.validate() }
        result = proposal(); result.alternatives = (0..<4).map { _ in .init(technique:.centered,targetPosition:.init(x:0.5,y:0.5),explanation:"Keep a centered subject") }; assertError(.invalidResponse) { try result.validate() }
    }
    func testUnjustifiedRollAndUnsafeRollRejected() throws {
        var result = proposal(); result.rollSuggestion = .init(degrees:20,justification:"A visible line"); assertError(.invalidResponse) { try result.validate() }
        result.rollSuggestion = .init(degrees:2,justification:"A visible line"); var local = try evidence(); local.rollReliable = false; local.scene?.lines = []
        assertError(.invalidResponse) { _ = try CloudCompositionMatcher.match(result,capture:capture(local),live:local,at:10.1) }
    }
    func testSubjectMatchNeedsSameTrackLabelAndOverlappingScannedBox() throws {
        let local = try evidence(); let scan = capture(local)
        for change in 0..<3 { var live = local; var result = proposal(); if change == 0 { live.trackingReference = "person-B" }; if change == 1 { result.primarySubjectDescription = "Unseen horse" }; if change == 2 { result.subjectBoundingBox = .init(x:0,y:0,width:0.1,height:0.1) }; assertError(.subjectMismatch) { _ = try CloudCompositionMatcher.match(result,capture:scan,live:live,at:10.1) } }
    }
    func testWeakOrMissingTrackCannotProduceArrows() throws {
        var live = try evidence(); let scan = capture(live); live.confidence = 0.4
        assertError(.subjectMismatch) { _ = try CloudCompositionMatcher.match(proposal(),capture:scan,live:live,at:10.1) }
        live.bounds = nil; assertError(.subjectMismatch) { _ = try CloudCompositionMatcher.match(proposal(),capture:scan,live:live,at:10.1) }
    }
    func testCloudCannotExceedLocalZoomBudgetOrPlaceClippedSubject() throws {
        let local = try evidence(); var result = proposal(); result.recommendedZoomRange.maximum = 4
        assertError(.impossiblePlan) { _ = try CloudCompositionMatcher.match(result,capture:capture(local),live:local,at:10.1) }
        result = proposal(); result.normalizedTargetPosition.x = 0.02
        assertError(.impossiblePlan) { _ = try CloudCompositionMatcher.match(result,capture:capture(local),live:local,at:10.1) }
    }
    func testManualCompositionAndSelectedIntentRemainAuthoritative() throws {
        var local = try evidence(); local.mode = .thirds
        assertError(.unsupportedSource) { _ = try CloudCompositionMatcher.match(proposal(),capture:capture(local),live:local,at:10.1) }
        local.mode = .automatic; local.intent = .pet
        assertError(.impossiblePlan) { _ = try CloudCompositionMatcher.match(proposal(),capture:capture(local),live:local,at:10.1) }
    }
    func testSourceChangeRejectsResponseAndSonyIsUnsupported() throws {
        let local = try evidence(); var sony = local; sony.isIPhone = false
        assertError(.unsupportedSource) { _ = try CloudCompositionMatcher.match(proposal(),capture:capture(local),live:sony,at:10.1) }
    }
    func testNewSessionManualZoomAndOldResponseAreRejected() throws {
        let local = try evidence()
        var newer = local; newer.sessionRevision += 1
        assertError(.stale) { _ = try CloudCompositionMatcher.match(proposal(),capture:capture(local),live:newer,at:10.1) }
        newer = local; newer.zoom = 1.5
        assertError(.stale) { _ = try CloudCompositionMatcher.match(proposal(),capture:capture(local),live:newer,at:10.1) }
        newer = try evidence(at:51)
        assertError(.stale) { _ = try CloudCompositionMatcher.match(proposal(),capture:capture(local),live:newer,at:51) }
    }
    func testMajorSceneChangeWhileRequestIsInFlightRejectsPlan() throws {
        let old = try evidence(); let changed = try evidence(at:10.1,brightness:0.9)
        assertError(.stale) { _ = try CloudCompositionMatcher.match(proposal(),capture:capture(old),live:changed,at:10.2) }
    }
    func testNewScanAndOldCompletionCannotClearCurrentScan() {
        let gate = CloudScanRequestGate(); let old = gate.begin(); let newer = gate.begin()
        XCTAssertFalse(gate.accepts(old)); XCTAssertFalse(gate.finish(old)); XCTAssertTrue(gate.accepts(newer)); XCTAssertTrue(gate.finish(newer)); XCTAssertFalse(gate.finish(newer))
        // A rescan can start just after acceptance, before old async cleanup.
        let afterAcceptance = gate.begin()
        XCTAssertFalse(gate.finish(newer)); XCTAssertTrue(gate.accepts(afterAcceptance))
    }
    func testInvalidationRejectsPendingResponse() {
        let gate = CloudScanRequestGate(), id = gate.begin()
        let cancelled = expectation(description:"Context change cancels transport")
        gate.registerCancellation(id) { cancelled.fulfill() }
        gate.invalidate(); XCTAssertFalse(gate.accepts(id))
        let stale = expectation(description:"Late registration cancels immediately")
        gate.registerCancellation(id) { stale.fulfill() }
        wait(for:[cancelled,stale],timeout:0.1)
    }
    func testLockRetainsIdentityTargetAndTechniqueAcrossGoodFrames() throws {
        var held = try locked(); let id = held.id
        for t in [10.2,10.4,10.6] { XCTAssertEqual(held.observe(try evidence(at:t),at:t),.retained); let plan = held.plan(at:t,zoom:1); XCTAssertEqual(plan.id,id); XCTAssertEqual(plan.selected.technique,.thirds); XCTAssertEqual(plan.target,held.target) }
    }
    func testSubjectLossHasRecoveryThenUnlockAndCanRecoverBeforeDeadline() throws {
        var held = try locked(); var missing = try evidence(at:10.2); missing.bounds = nil
        XCTAssertEqual(held.observe(missing,at:10.2),.recovering)
        XCTAssertEqual(held.observe(try evidence(at:10.5),at:10.5),.retained)
        missing.observedAt = 11; XCTAssertEqual(held.observe(missing,at:11),.recovering)
        missing.observedAt = 12.6; XCTAssertEqual(held.observe(missing,at:12.6),.invalid)
    }
    func testCloudLockExpiresOnSceneSourceAndLifetimeChanges() throws {
        var held = try locked(); XCTAssertEqual(held.observe(try evidence(at:10.2,brightness:0.9),at:10.2),.invalid)
        held = try locked(); var sony = try evidence(at:10.2); sony.isIPhone = false; XCTAssertEqual(held.observe(sony,at:10.2),.invalid)
        held = try locked(); XCTAssertEqual(held.observe(try evidence(at:311),at:311),.invalid)
    }
    func testManualZoomPreservesPlanButDisarmsCloudMotor() throws {
        var held = try locked(); let id = held.id; let target = held.target
        let option = CompositionOption(technique:.thirds,target:target,crop:CGRect(x:0.1,y:0.1,width:0.8,height:0.8),score:0.9,explanation:"Measured candidate",zoomScale:1.5,measuredImprovement:0.2)
        XCTAssertTrue(held.useMeasuredMotorOption(option)); XCTAssertTrue(held.plan(at:10.1,zoom:1).permitsZoom)
        held.preserveManualZoom(); XCTAssertEqual(held.plan(at:10.2,zoom:1.25).id,id); XCTAssertEqual(held.target,target); XCTAssertFalse(held.plan(at:10.2,zoom:1.25).permitsZoom)
        var grace = ManualZoomGrace(); grace.begin(at:10); XCTAssertFalse(grace.permitsAutomaticZoom(at:100)); grace.end(at:100); XCTAssertFalse(grace.permitsAutomaticZoom(at:102.9)); XCTAssertTrue(grace.permitsAutomaticZoom(at:103.1))
    }
    func testCloudConfidenceAndZoomAdviceDoNotGrantMotorOrReady() throws {
        var held = try locked(); var director = FramingPlanner(continuousRecovery:true)
        XCTAssertFalse(held.plan(at:10.1,zoom:1).permitsZoom); XCTAssertFalse(director.currentFrameVerified); XCTAssertFalse(director.shotVerified)
        let unmeasured = CompositionOption(technique:.thirds,target:held.target,crop:CGRect(x:0,y:0,width:1,height:1),score:1,explanation:"Cloud claims perfect",zoomScale:1.5,measuredImprovement:0)
        XCTAssertFalse(held.useMeasuredMotorOption(unmeasured))
        let original = try evidence()
        let originalBounds = try XCTUnwrap(original.bounds)
        let facts = CompositionAssessment.evaluate(bounds:originalBounds,confidence:0.95,label:"Person",intent:.portrait,stable:true,exposure:nil,evidence:nil)
        let unaligned = ShotReadiness.measuredManualFrame(mode:.thirds,bounds:originalBounds,target:held.target,roll:0,aspect:1,assessment:facts,stable:true)
        XCTAssertFalse(unaligned)
        for time in [10.2,10.8] { director.confirmCurrentFrame(eligible:unaligned,timestamp:time,holdDuration:0.5) }
        XCTAssertFalse(director.currentFrameVerified)
        let alignedBounds = CGRect(x:held.target.x-0.15,y:held.target.y-0.15,width:0.3,height:0.3)
        let alignedFacts = CompositionAssessment.evaluate(bounds:alignedBounds,confidence:0.95,label:"Person",intent:.portrait,stable:true,exposure:nil,evidence:nil)
        let locallyEligible = ShotReadiness.measuredManualFrame(mode:.thirds,bounds:alignedBounds,target:held.target,roll:0,aspect:1,assessment:alignedFacts,stable:true)
        XCTAssertTrue(locallyEligible)
        director.confirmCurrentFrame(eligible:locallyEligible,timestamp:11,holdDuration:0.5); XCTAssertFalse(director.currentFrameVerified)
        director.confirmCurrentFrame(eligible:locallyEligible,timestamp:11.6,holdDuration:0.5); XCTAssertTrue(director.currentFrameVerified)
    }
    func testOfflineLockRemainsUsableOnlyWithFreshLocalEvidence() throws {
        var held = try locked(); XCTAssertEqual(held.observe(try evidence(at:20),at:20),.retained)
        var stale = try evidence(at:20); stale.observedAt = 18
        XCTAssertEqual(held.observe(stale,at:20.1),.recovering); XCTAssertEqual(held.observe(stale,at:21.7),.invalid)
    }
    func testWideSceneAdviceHasNoInventedSubjectOrDirectionTarget() throws {
        var local = try evidence(); local.bounds = nil; local.trackingReference = nil
        var result = proposal(); result.subjectBoundingBox = nil; result.localSubjectID = nil; result.primarySubjectDescription = "Whole scene"; result.sceneCategory = .forest; result.recommendedCompositionTechnique = .forestPath; result.normalizedTargetPosition = .init(x:0.5,y:0.5)
        var held = try CloudCompositionMatcher.match(result,capture:capture(local),live:local,at:10.1)
        let id = held.id
        let attractiveForeground = try evidence(at:10.2)
        XCTAssertEqual(held.observe(attractiveForeground,at:10.2),.retained)
        XCTAssertEqual(held.plan(at:10.2,zoom:1).id,id)
        var staleScene = attractiveForeground; staleScene.observedAt = 12
        XCTAssertEqual(held.observe(staleScene,at:12),.recovering)
        staleScene.observedAt = 13.6
        XCTAssertEqual(held.observe(staleScene,at:13.6),.invalid)
        XCTAssertTrue(held.isWholeScene); XCTAssertFalse(held.plan(at:10.1,zoom:1).permitsZoom); XCTAssertFalse(OutdoorCompositionPlanner.instruction(held.plan(at:10.1,zoom:1),mirrored:false).1?.isAdjustment == true)
        result.normalizedTargetPosition.x = 0.8
        assertError(.subjectMismatch) { _ = try CloudCompositionMatcher.match(result,capture:capture(local),live:local,at:10.1) }
    }
    func testEnvelopeMustFinishAndContainOnlyOneTextResult() throws {
        assertError(.invalidResponse) { _ = try GeminiCloudCompositionService.result(envelope(finish:"MAX_TOKENS")) }
        assertError(.invalidResponse) { _ = try GeminiCloudCompositionService.result(Data(repeating:32,count:140_000)) }
        XCTAssertEqual(try GeminiCloudCompositionService.result(envelope()).recommendedCompositionTechnique,.ruleOfThirds)
    }
    func testConfigurationRejectsModelPathInjection() {
        for model in ["../secret","gemini-3.8-flash?key=anything","gemini-%2f"] { assertError(.notConfigured) { try GeminiCloudConfiguration(apiKey:"unit-test-only",model:model).validate() } }
    }
    func testRequestContainsOneInlineJPEGAndStrictSchema() throws {
        let request = try GeminiCloudCompositionService.body(capture(evidence()))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with:request) as? [String:Any])
        let contents = try XCTUnwrap(root["contents"] as? [[String:Any]]); XCTAssertEqual(contents.count,1)
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String:Any]]); XCTAssertEqual(parts.count,2); XCTAssertNotNil(parts[1]["inlineData"])
        XCTAssertNil(root["tools"]); XCTAssertNotNil(root["generationConfig"]); XCTAssertFalse(String(decoding:request,as:UTF8.self).contains("apiKey"))
    }
    func testServiceMakesOneGenerationAndCachesModelCapability() async throws {
        let meta = Data(#"{"name":"models/gemini-3.8-flash","supportedGenerationMethods":["generateContent"]}"#.utf8)
        let transport = CloudTestTransport([.success(.init(data:meta,status:200)),.success(.init(data:try envelope(),status:200)),.success(.init(data:try envelope(),status:200))])
        let service = GeminiCloudCompositionService(configuration:.init(apiKey:"unit-test-only",model:"gemini-3.8-flash"),transport:transport)
        _ = try await service.scan(capture(evidence())); _ = try await service.scan(capture(evidence()))
        let requests = await transport.requests; XCTAssertEqual(requests.map(\.httpMethod),["GET","POST","POST"])
        XCTAssertTrue(requests.allSatisfy { $0.url?.scheme == "https" && $0.url?.query == nil && $0.timeoutInterval == 20 })
    }
    func testTimeoutAndNoInternetReturnWithoutGenerationRetry() async throws {
        for expected in [CloudCompositionError.timeout,.offline] {
            let transport = CloudTestTransport([.failure(expected)])
            let service = GeminiCloudCompositionService(configuration:.init(apiKey:"unit-test-only",model:"gemini-3.8-flash"),transport:transport)
            do { _ = try await service.scan(capture(evidence())); XCTFail("Expected failure") } catch { XCTAssertEqual(error as? CloudCompositionError,expected) }
            let count = await transport.requests.count; XCTAssertEqual(count,1)
        }
    }
    func testQuotaAuthenticationAndModelErrorsAreSanitized() async throws {
        for (status,error) in [(429,CloudCompositionError.quota),(403,.unauthorized),(404,.unavailableModel),(503,.serviceUnavailable)] {
            let transport = CloudTestTransport([.success(.init(data:Data("private upstream error must not be surfaced".utf8),status:status))])
            let service = GeminiCloudCompositionService(configuration:.init(apiKey:"unit-test-only",model:"gemini-3.8-flash"),transport:transport)
            do { _ = try await service.scan(capture(evidence())); XCTFail("Expected failure") } catch let actual as CloudCompositionError { XCTAssertEqual(actual,error); XCTAssertFalse(actual.message.contains("private upstream")) }
        }
    }
    func testUnavailableCapabilityDoesNotUploadImage() async throws {
        let transport = CloudTestTransport([.success(.init(data:Data(#"{"name":"models/gemini-3.8-flash","supportedGenerationMethods":["embedContent"]}"#.utf8),status:200))])
        let service = GeminiCloudCompositionService(configuration:.init(apiKey:"unit-test-only",model:"gemini-3.8-flash"),transport:transport)
        do { _ = try await service.scan(capture(evidence())); XCTFail("Expected model failure") } catch { XCTAssertEqual(error as? CloudCompositionError,.unavailableModel) }
        let requests = await transport.requests; XCTAssertTrue(requests.allSatisfy { $0.httpBody == nil })
    }
    func testCancellationPropagatesToAwaitedTransport() async throws {
        let transport = CloudTestTransport([],delay:true)
        let service = GeminiCloudCompositionService(configuration:.init(apiKey:"unit-test-only",model:"gemini-3.8-flash"),transport:transport)
        let input = capture(try evidence())
        let task = Task { try await service.scan(input) }
        await transport.waitForRequest(); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled scan must not succeed") } catch { XCTAssertTrue(error is CancellationError || error as? CloudCompositionError == .cancelled) }
    }
}

private actor CloudTestTransport: CloudHTTPTransport {
    var requests:[URLRequest] = []
    var responses:[Result<CloudHTTPResponse,CloudCompositionError>]
    let delay:Bool
    private var requestObserver: CheckedContinuation<Void,Never>?
    func waitForRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { requestObserver = $0 }
    }
    init(_ responses:[Result<CloudHTTPResponse,CloudCompositionError>],delay:Bool = false) { self.responses = responses; self.delay = delay }
    func send(_ request:URLRequest) async throws -> CloudHTTPResponse {
        requests.append(request); requestObserver?.resume(); requestObserver = nil
        if delay { try await Task.sleep(nanoseconds:10_000_000_000) }
        guard !responses.isEmpty else { throw CloudCompositionError.serviceUnavailable }
        return try responses.removeFirst().get()
    }
}
