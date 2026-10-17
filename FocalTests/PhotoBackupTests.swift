import XCTest
@testable import Focal
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor FixtureCredentials:BackupCredentialStore {
    var value = String(repeating:"test-device-",count:4)
    func token(for destination:BackupDestination) throws -> String { guard !value.isEmpty else { throw BackupProblem.authorization };return value }
    func save(_ token:String,for destination:BackupDestination) { value = token }
    func remove(for destination:BackupDestination) { value = "" }
}
private actor FixtureTransfers:BackupTransferTransport {
    var transfers:[BackupTransfer] = []
    var tags:Set<String> = []
    var cancellations = 0
    func start(_ transfer:BackupTransfer) { transfers.append(transfer);tags.insert(transfer.tag) }
    func activeTags() -> Set<String> { tags }
    func cancelAll() { tags = [];cancellations += 1 }
    func latest() -> BackupTransfer? { transfers.last }
    func count() -> Int { transfers.count }
    func setTags(_ values:Set<String>) { tags = values }
}
private actor FixtureBackend:BackupHTTPTransport {
    var records:[String:[String:Any]] = [:]
    var failure:BackupProblem?
    var statusCode:Int?
    var requests:[URLRequest] = []
    func setFailure(_ problem:BackupProblem?) { failure = problem }
    func setStatus(_ value:Int?) { statusCode = value }
    func count() -> Int { requests.count }
    func send(_ request:URLRequest) throws -> BackupHTTPResult {
        requests.append(request)
        if let failure { throw failure }
        if let statusCode { return .init(status:statusCode,headers:["Retry-After":"120"],data:Data("{\"error\":\"rate_limit\"}".utf8)) }
        let path = request.url!.path
        if path == "/v1/resources",let data = request.httpBody {
            let body = try JSONSerialization.jsonObject(with:data) as! [String:Any]
            let id = body["resourceId"] as! String
            if records[id] == nil {
                records[id] = ["resourceId":id,"destinationId":body["destinationId"]!,"state":"uploading",
                    "offset":0,"size":body["size"]!,"sha256":body["sha256"]!]
            }
            return try response(records[id]!)
        }
        let id = request.url!.pathComponents.dropFirst(3).first ?? ""
        if request.httpMethod == "POST" { return .init(status:200,data:Data("{}".utf8)) }
        guard let row = records[id] else { return .init(status:404) }
        return try response(row)
    }
    func setRecord(id:String,state:String,offset:Int64,driveID:String? = nil,badSize:Bool = false,badHash:Bool = false) throws -> BackupHTTPResult {
        var row = records[id]!
        row["state"] = state;row["offset"] = offset;row["driveFileId"] = driveID
        if badSize { row["size"] = -1 }
        if badHash { row["sha256"] = "invalid" }
        records[id] = row;return try response(row)
    }
    private func response(_ row:[String:Any]) throws -> BackupHTTPResult { .init(status:200,data:try JSONSerialization.data(withJSONObject:row)) }
}
private final class BackupFixture {
    let directory:URL
    let disk:BackupDiskStore
    let credentials = FixtureCredentials()
    let http = FixtureBackend()
    let transfers = FixtureTransfers()
    let destination = BackupDestination(id:"fixture-owner",deviceID:"fixture-device",label:"Fixture owner",server:URL(string:"https://backup.example")!)
    let engine:BackupEngine
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let originals = directory.appendingPathComponent("Originals")
        try FileManager.default.createDirectory(at:originals,withIntermediateDirectories:true)
        disk = .init(root:directory.appendingPathComponent("Queue"),originals:originals)
        engine = .init(disk:disk,api:.init(http:http,credentials:credentials),transfers:transfers)
    }
    deinit { try? FileManager.default.removeItem(at:directory) }
    func start() async throws { await engine.bootstrap();try await engine.connect(destination) }
    func capture(bytes:Data = Data("fixture-original-EXIF".utf8),ext:String = "jpg",role:BackupSource.Role = .photo) throws -> BackupCapture {
        let id = UUID(),filename = UUID().uuidString+"."+ext
        try bytes.write(to:disk.originals.appendingPathComponent(filename))
        return .init(id:id,createdAt:Date(),enrollment:.init(destinationID:destination.id,deviceID:destination.deviceID,server:destination.server,
            datePath:"2026/10/17",sources:[.init(role:role,filename:filename)]),metadata:Data("{\"fixture\":true}".utf8))
    }
    func enable(_ capture:BackupCapture) async throws { await engine.enroll(capture);try await engine.enable(true) }
    func receipt(_ transfer:BackupTransfer,state:String = "pendingDrive",badSize:Bool = false,badHash:Bool = false,driveID:String? = nil) async throws -> BackupHTTPResult {
        let job = await engine.snapshot().jobs.first{$0.id == transfer.resourceID}!
        return try await http.setRecord(id:job.id,state:state,offset:job.size!,driveID:driveID,badSize:badSize,badHash:badHash)
    }
}

final class PhotoBackupTests:XCTestCase {
    func testCaptureInsertionIsPersistentAndIdempotent() async throws {
        let f = try BackupFixture();try await f.start();let capture = try f.capture()
        await f.engine.enroll(capture);await f.engine.enroll(capture)
        let saved = try f.disk.load();XCTAssertEqual(saved.jobs.count,2);XCTAssertEqual(saved.jobs.first?.captureID,capture.id)
        XCTAssertFalse(saved.enabled);let count = await f.http.count();XCTAssertEqual(count,0)
    }
    func testOfflineCapturePersistsWithDelayedRetry() async throws {
        let f = try BackupFixture();try await f.start();let capture = try f.capture();await f.http.setFailure(.offline)
        try await f.enable(capture)
        let queue = await f.engine.snapshot();XCTAssertEqual(queue.jobs[0].state,.retry);XCTAssertEqual(queue.jobs[0].problem,.offline)
        XCTAssertGreaterThan(queue.jobs[0].nextAttempt,Date());XCTAssertTrue(FileManager.default.fileExists(atPath:try f.disk.source(queue.jobs[0]).path))
        XCTAssertEqual(try f.disk.load().jobs[0].state,.retry)
    }
    func testFileBackedUploadUsesExactHEICBytesAndRealRange() async throws {
        let f = try BackupFixture();try await f.start();let bytes = Data([0,1,2,3,4,255]);try await f.enable(f.capture(bytes:bytes,ext:"heic"))
        let transfer = await f.transfers.latest();let t = try XCTUnwrap(transfer)
        XCTAssertEqual(try Data(contentsOf:t.file),bytes);XCTAssertEqual(t.request.value(forHTTPHeaderField:"Content-Range"),"bytes 0-5/6")
        XCTAssertNil(t.request.httpBody);XCTAssertEqual(t.request.url?.host,"backup.example")
    }
    func testRAWIsNotReencodedOrReplacedByPreview() async throws {
        let f = try BackupFixture();try await f.start();let bytes = Data((0..<8192).map{UInt8($0%255)})
        try await f.enable(f.capture(bytes:bytes,ext:"dng",role:.raw))
        let transfer = await f.transfers.latest();XCTAssertEqual(try Data(contentsOf:XCTUnwrap(transfer).file),bytes)
        let queue = await f.engine.snapshot();XCTAssertEqual(queue.jobs[0].source.mimeType,"image/x-adobe-dng")
    }
    func testBackendReceiptDoesNotMeanDriveCompleted() async throws {
        let f = try BackupFixture();try await f.start();try await f.enable(f.capture());let t = await f.transfers.latest()!
        let result = try await f.receipt(t);await f.engine.completed(tag:t.tag,result:result,problem:nil)
        let job = await f.engine.snapshot().jobs.first{$0.id == t.resourceID}!
        XCTAssertEqual(job.state,.verifying);XCTAssertNil(job.completedAt);XCTAssertNil(job.remoteID)
        XCTAssertFalse(FileManager.default.fileExists(atPath:t.file.path))
    }
    func testOnlyVerifiedDriveFileCompletesBackup() async throws {
        let f = try BackupFixture();try await f.start();try await f.enable(f.capture());let t = await f.transfers.latest()!
        let result = try await f.receipt(t,state:"complete",driveID:"verified-drive-fixture")
        await f.engine.completed(tag:t.tag,result:result,problem:nil)
        let job = await f.engine.snapshot().jobs.first{$0.id == t.resourceID}!
        XCTAssertEqual(job.state,.complete);XCTAssertEqual(job.remoteID,"verified-drive-fixture");XCTAssertNotNil(job.completedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath:try f.disk.source(job).path))
    }
    func testMissingDriveIDCannotComplete() async throws { try await rejectReceipt(badSize:false,badHash:false) }
    func testWrongSizeCannotComplete() async throws { try await rejectReceipt(badSize:true,badHash:false) }
    func testWrongHashCannotComplete() async throws { try await rejectReceipt(badSize:false,badHash:true) }
    private func rejectReceipt(badSize:Bool,badHash:Bool) async throws {
        let f = try BackupFixture();try await f.start();try await f.enable(f.capture());let t = await f.transfers.latest()!
        let result = try await f.receipt(t,state:"complete",badSize:badSize,badHash:badHash,driveID:badSize || badHash ? "fixture-id" : nil)
        await f.engine.completed(tag:t.tag,result:result,problem:nil)
        let job = await f.engine.snapshot().jobs.first{$0.id == t.resourceID}!
        XCTAssertEqual(job.state,.failed);XCTAssertEqual(job.problem,.integrity);XCTAssertNil(job.completedAt)
    }
    func testRestartRecoversInterruptedUploadByProbingServer() async throws {
        let f = try BackupFixture();try await f.start();try await f.enable(f.capture());await f.transfers.setTags([])
        let restarted = BackupEngine(disk:f.disk,api:.init(http:f.http,credentials:f.credentials),transfers:f.transfers)
        await restarted.bootstrap();let state = await restarted.snapshot()
        XCTAssertEqual(state.jobs[0].state,.retry);XCTAssertTrue(state.jobs[0].needsStatusProbe)
        await restarted.pump();let count = await f.transfers.count();XCTAssertEqual(count,2)
    }
    func testBackgroundTaskIsAdoptedWithoutDuplicateTransfer() async throws {
        let f = try BackupFixture();try await f.start();try await f.enable(f.capture())
        let restarted = BackupEngine(disk:f.disk,api:.init(http:f.http,credentials:f.credentials),transfers:f.transfers)
        await restarted.bootstrap();await restarted.pump();let count = await f.transfers.count();XCTAssertEqual(count,1)
    }
    func testUnexpectedBackgroundTaskIsCancelled() async throws {
        let f = try BackupFixture();await f.transfers.setTags(["unrecognized-old-task"]);await f.engine.bootstrap()
        let tags = await f.transfers.activeTags();XCTAssertTrue(tags.isEmpty)
    }
    func testDisablingCancelsTransferAndRejectsStaleCompletion() async throws {
        let f = try BackupFixture();try await f.start();try await f.enable(f.capture());let t = await f.transfers.latest()!
        let result = try await f.receipt(t,state:"complete",driveID:"fixture-id");try await f.engine.enable(false)
        await f.engine.completed(tag:t.tag,result:result,problem:nil)
        let state = await f.engine.snapshot();XCTAssertFalse(state.enabled);XCTAssertNotEqual(state.jobs[0].state,.complete)
        let tags = await f.transfers.activeTags();XCTAssertTrue(tags.isEmpty)
    }
    func testOwnerSwitchCannotRerouteQueuedPhotos() async throws { try await switchDestination(owner:"different-owner",device:"fixture-device",host:"backup.example") }
    func testDeviceSwitchCannotInheritOldGrantQueue() async throws { try await switchDestination(owner:"fixture-owner",device:"different-device",host:"backup.example") }
    func testServerSwitchCannotInheritOldQueue() async throws { try await switchDestination(owner:"fixture-owner",device:"fixture-device",host:"different.example") }
    private func switchDestination(owner:String,device:String,host:String) async throws {
        let f = try BackupFixture();try await f.start();await f.engine.enroll(try f.capture())
        try await f.engine.connect(.init(id:owner,deviceID:device,label:"Other",server:URL(string:"https://"+host)!));try await f.engine.enable(true)
        let count = await f.transfers.count();XCTAssertEqual(count,0);let summary = await f.engine.summary();XCTAssertEqual(summary.otherDestinationPending,2)
    }
    func testAuthorizationFailureStopsRatherThanRetryLoop() async throws {
        let f = try BackupFixture();try await f.start();await f.http.setStatus(401);try await f.enable(f.capture())
        let queue = await f.engine.snapshot();XCTAssertEqual(queue.jobs[0].state,.failed);XCTAssertEqual(queue.jobs[0].problem,.authorization)
    }
    func testRevokedCredentialPausesWholeQueueAcrossRestart() async throws {
        let f = try BackupFixture();try await f.start();await f.http.setStatus(401);try await f.enable(f.capture())
        for _ in 0..<10 { await f.engine.pump(now:Date().addingTimeInterval(3600)) }
        let count = await f.http.count();XCTAssertEqual(count,1)
        let restarted = BackupEngine(disk:f.disk,api:.init(http:f.http,credentials:f.credentials),transfers:f.transfers)
        await restarted.bootstrap();await restarted.pump(now:Date().addingTimeInterval(7200))
        let after = await f.http.count();XCTAssertEqual(after,1)
        let summary = await restarted.summary();XCTAssertEqual(summary.problem,.authorization)
    }
    func testOptOutPersistenceFailureCancelsAndRemovesCredential() async throws {
        let f = try BackupFixture();try await f.start();try await f.enable(f.capture())
        let bytes = try Data(contentsOf:f.disk.manifest)
        try FileManager.default.removeItem(at:f.disk.manifest)
        try FileManager.default.createDirectory(at:f.disk.manifest,withIntermediateDirectories:false)
        do { try await f.engine.enable(false);XCTFail("Storage failure must be reported") } catch {}
        let tags = await f.transfers.activeTags();XCTAssertTrue(tags.isEmpty)
        do { _ = try await f.credentials.token(for:f.destination);XCTFail("Old enabled manifest must lose upload access") } catch {}
        try FileManager.default.removeItem(at:f.disk.manifest);try bytes.write(to:f.disk.manifest)
        let state = await f.engine.snapshot();XCTAssertFalse(state.enabled)
    }
    func testQuotaResponseHonorsRetryAfter() async throws {
        let f = try BackupFixture();try await f.start();await f.http.setStatus(429);try await f.enable(f.capture())
        let state = await f.engine.snapshot();XCTAssertEqual(state.jobs[0].state,.retry);XCTAssertGreaterThan(state.jobs[0].nextAttempt.timeIntervalSinceNow,110)
    }
    func testDuplicateCaptureReconciliationDoesNotResetProgress() async throws {
        let f = try BackupFixture();try await f.start();let c = try f.capture();try await f.enable(c);let before = await f.engine.snapshot()
        await f.engine.enroll(c);let after = await f.engine.snapshot();XCTAssertEqual(before.jobs,after.jobs)
    }
    func testDeletingCaptureRemovesQueueAndKeepsUnrelatedOriginals() async throws {
        let f = try BackupFixture();try await f.start();let c = try f.capture();await f.engine.enroll(c);await f.engine.removeCapture(c.id)
        let state = await f.engine.snapshot();XCTAssertTrue(state.jobs.isEmpty);XCTAssertTrue(FileManager.default.fileExists(atPath:f.disk.originals.appendingPathComponent(c.enrollment.sources[0].filename).path))
    }
    func testDeletedPhotoCannotBeReenrolledByDelayedSaveTask() async throws {
        let f = try BackupFixture();try await f.start();let capture = try f.capture()
        await f.engine.removeCapture(capture.id);await f.engine.enroll(capture)
        let state = await f.engine.snapshot();XCTAssertTrue(state.jobs.isEmpty)
    }
    func testCorruptQueueIsPreservedAndCannotBeOverwrittenByConnect() async throws {
        let f = try BackupFixture();try f.disk.prepare();let bytes = Data("{broken".utf8);try bytes.write(to:f.disk.manifest)
        await f.engine.bootstrap();do { try await f.engine.connect(f.destination);XCTFail("Must fail closed") } catch {}
        XCTAssertEqual(try Data(contentsOf:f.disk.manifest),bytes)
    }
    func testSourcePathCannotEscapeOriginalDirectory() throws {
        let f = try BackupFixture();let c = try f.capture();var job = BackupJob(id:"fixture",destinationID:"owner",deviceID:"device",server:f.destination.server,captureID:c.id,createdAt:c.createdAt,datePath:"2026/10/17",source:.init(role:.photo,filename:"../secret.jpg"))
        XCTAssertThrowsError(try f.disk.source(job));let outside = f.directory.appendingPathComponent("outside.jpg");try Data([1]).write(to:outside)
        let link = f.disk.originals.appendingPathComponent("link.jpg");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
        job = .init(id:"fixture",destinationID:"owner",deviceID:"device",server:f.destination.server,captureID:c.id,createdAt:c.createdAt,datePath:"2026/10/17",source:.init(role:.photo,filename:"link.jpg"))
        XCTAssertThrowsError(try f.disk.source(job))
    }
    func testSHA256MatchesKnownDigest() throws {
        let f = try BackupFixture();let url = f.directory.appendingPathComponent("hash");try Data("abc".utf8).write(to:url)
        let hash = try BackupHash.file(url);XCTAssertEqual(hash.size,3);XCTAssertEqual(hash.sha256,"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testLargeRAWUsesBoundedChunksAndResumesAtAcknowledgedOffset() async throws {
        let f = try BackupFixture();try await f.start()
        let bytes = Data(repeating:0xA7,count:Int(BackupQueue.chunkBytes)+123)
        try await f.enable(f.capture(bytes:bytes,ext:"dng",role:.raw))
        let first = await f.transfers.latest()!
        XCTAssertEqual(try Data(contentsOf:first.file).count,Int(BackupQueue.chunkBytes))
        let result = try await f.http.setRecord(id:first.resourceID,state:"uploading",offset:BackupQueue.chunkBytes)
        await f.engine.completed(tag:first.tag,result:result,problem:nil)
        for _ in 0..<100 { if await f.transfers.count() >= 2 { break };try await Task.sleep(nanoseconds:10_000_000) }
        let next = await f.transfers.latest()!
        XCTAssertNotEqual(next.tag,first.tag)
        XCTAssertEqual(try Data(contentsOf:next.file),Data(bytes.suffix(123)))
        XCTAssertEqual(next.request.value(forHTTPHeaderField:"Content-Range"),"bytes 4194304-4194426/4194427")
        let queue = await f.engine.snapshot();XCTAssertEqual(queue.jobs[0].attempts,0)
    }
    func testLostAcknowledgementProbesAcceptedOffsetInsteadOfDuplicatingChunk() async throws {
        let f = try BackupFixture();try await f.start()
        try await f.enable(f.capture(bytes:Data(repeating:0x5A,count:Int(BackupQueue.chunkBytes)+17),ext:"dng",role:.raw))
        let first = await f.transfers.latest()!
        _ = try await f.http.setRecord(id:first.resourceID,state:"uploading",offset:BackupQueue.chunkBytes)
        await f.engine.completed(tag:first.tag,result:nil,problem:.offline)
        // The queue may use the retry delay to upload this capture's metadata.
        // A single active transfer must finish before the original can resume.
        var resumed:BackupTransfer?
        var acknowledged = Set<String>()
        for _ in 0..<100 {
            await f.engine.pump(now:Date().addingTimeInterval(180))
            if let next = await f.transfers.latest(),next.tag != first.tag {
                if next.resourceID == first.resourceID { resumed = next;break }
                if acknowledged.insert(next.tag).inserted {
                    let result = try await f.receipt(next,state:"complete",driveID:"fixture-metadata-drive")
                    await f.engine.completed(tag:next.tag,result:result,problem:nil)
                }
            }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        let next = try XCTUnwrap(resumed)
        XCTAssertEqual(next.request.value(forHTTPHeaderField:"Content-Range"),"bytes 4194304-4194320/4194321")
        XCTAssertEqual(try Data(contentsOf:next.file).count,17)
    }
    func testMissingOriginalFailsWithoutDeletingOtherResources() async throws {
        let f = try BackupFixture();try await f.start();let capture = try f.capture()
        try FileManager.default.removeItem(at:f.disk.originals.appendingPathComponent(capture.enrollment.sources[0].filename))
        try await f.enable(capture)
        let queue = await f.engine.snapshot();XCTAssertEqual(queue.jobs[0].state,.failed)
        XCTAssertEqual(queue.jobs[0].problem,.missingOriginal);XCTAssertEqual(queue.jobs.count,2)
    }
    func testRetriesAreBoundedAndDelayCapped() {
        XCTAssertEqual(BackupRetry.maximumAttempts,8);XCTAssertEqual(BackupRetry.delay(attempt:99),21600)
        XCTAssertEqual(BackupRetry.delay(attempt:1,retryAfter:999999),86400);XCTAssertFalse(BackupRetry.retryable(.authorization))
        XCTAssertFalse(BackupRetry.retryable(.integrity));XCTAssertTrue(BackupRetry.retryable(.offline))
    }
    func testUnsafeServerAndRedirectOriginsAreRejected() {
        for text in ["http://backup.example","https://user:pass@backup.example","https://backup.example?token=private","https://backup.example/path","https://localhost"] {
            XCTAssertFalse(OwnerBackupURLs.validServer(URL(string:text)!))
        }
        XCTAssertFalse(OwnerBackupURLs.permitted(URL(string:"https://attacker.example/v1/resources")!,server:URL(string:"https://backup.example")!))
    }
    func testOffsetConflictCanRecoverByAuthoritativeProbe() {
        XCTAssertThrowsError(try OwnerBackupAPI.check(.init(status:409,data:Data("{\"error\":\"offset_mismatch\"}".utf8)))) { error in
            XCTAssertEqual((error as? BackupWireFailure)?.problem,.temporaryService)
        }
    }
}
