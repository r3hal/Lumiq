import XCTest
import UIKit
@testable import Focal

@MainActor
private final class BackupPersistenceSpy:PhotoBackupRecording {
    var enrollmentEnabled = true
    let directory:URL
    var savedPhotos:[SavedPhoto] = []
    var deletedIDs:[UUID] = []
    init(_ directory:URL) { self.directory = directory }
    func enrollment(for photo:SavedPhoto) -> BackupEnrollment? {
        guard enrollmentEnabled,!photo.isDemo,photo.cameraOrigin == CameraSource.iPhone.rawValue else { return nil }
        var sources = [BackupSource(role:.photo,filename:photo.filename)]
        if let raw = photo.rawFilename { sources.append(.init(role:.raw,filename:raw)) }
        if let original = photo.originalFilename { sources.append(.init(role:.original,filename:original)) }
        return .init(destinationID:"fixture-owner",deviceID:"fixture-device",server:URL(string:"https://backup.example")!,datePath:"2026/10/17",sources:sources)
    }
    func saved(_ photo:SavedPhoto) {
        // A queue handoff must only happen after source files and library metadata exist.
        XCTAssertTrue(FileManager.default.fileExists(atPath:directory.appendingPathComponent(photo.filename).path))
        let manifest = try? Data(contentsOf:directory.appendingPathComponent("library.json"))
        let persisted = manifest.flatMap{try? JSONDecoder().decode([SavedPhoto].self,from:$0)}
        XCTAssertEqual(persisted?.first?.backupEnrollment,photo.backupEnrollment)
        XCTAssertEqual(persisted?.first?.id,photo.id)
        savedPhotos.append(photo)
    }
    func deleted(_ id:UUID) { deletedIDs.append(id) }
}

@MainActor
final class PhotoBackupPersistenceTests:XCTestCase {
    private func jpeg() throws -> Data {
        let format = UIGraphicsImageRendererFormat();format.scale = 1
        return try XCTUnwrap(UIGraphicsImageRenderer(size:CGSize(width:4,height:4),format:format).image{ctx in
            UIColor.blue.setFill();ctx.fill(CGRect(x:0,y:0,width:4,height:4))
        }.jpegData(compressionQuality:1))
    }
    func testCommittedCaptureHandsOffAfterManifestAndPreservesAllOriginalBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let library = PhotoLibrary(directory:directory),spy = BackupPersistenceSpy(directory);library.backupCoordinator = spy
        let bytes = try jpeg(),raw = Data("fixture-only-RAW".utf8)
        let photo = try await library.add(data:bytes,mode:"Auto",rawData:raw,originalData:bytes,cameraOrigin:CameraSource.iPhone.rawValue)
        XCTAssertEqual(spy.savedPhotos.count,1);XCTAssertNotNil(photo.backupEnrollment)
        XCTAssertEqual(try Data(contentsOf:library.url(for:photo)),bytes)
        XCTAssertEqual(try Data(contentsOf:XCTUnwrap(library.rawURL(for:photo))),raw)
        let reopened = PhotoLibrary(directory:directory)
        XCTAssertEqual(reopened.photos.first?.backupEnrollment,photo.backupEnrollment)
        XCTAssertEqual(PhotoBackupCoordinator.capture(photo)?.enrollment,photo.backupEnrollment)
    }
    func testDisabledBackupDemoAndSonyCannotEnroll() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let library = PhotoLibrary(directory:directory),spy = BackupPersistenceSpy(directory);library.backupCoordinator = spy
        spy.enrollmentEnabled = false
        let off = try await library.add(data:jpeg(),mode:"Auto",cameraOrigin:CameraSource.iPhone.rawValue)
        XCTAssertNil(off.backupEnrollment)
        spy.enrollmentEnabled = true
        let demo = try await library.add(data:jpeg(),mode:"Auto",isDemo:true,cameraOrigin:CameraSource.iPhone.rawValue)
        let sony = try await library.add(data:jpeg(),mode:"Auto",cameraOrigin:CameraSource.sony.rawValue)
        XCTAssertNil(demo.backupEnrollment);XCTAssertNil(sony.backupEnrollment)
        XCTAssertNil(PhotoBackupCoordinator.capture(sony));XCTAssertNil(PhotoBackupCoordinator.capture(demo))
    }
    func testFailedManifestNeverDispatchesBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let library = PhotoLibrary(directory:directory),spy = BackupPersistenceSpy(directory);library.backupCoordinator = spy
        try FileManager.default.createDirectory(at:directory.appendingPathComponent("library.json"),withIntermediateDirectories:false)
        do { _ = try await library.add(data:jpeg(),mode:"Auto",cameraOrigin:CameraSource.iPhone.rawValue);XCTFail("Manifest must fail") }
        catch { XCTAssertTrue(spy.savedPhotos.isEmpty);XCTAssertTrue(library.photos.isEmpty) }
    }
    func testMetadataSidecarDoesNotIncludeEnrollmentOrCredentials() throws {
        let photo = SavedPhoto(id:UUID(),filename:"fixture.jpg",createdAt:Date(),mode:"Auto",isDemo:false,isFavorite:false,cameraOrigin:CameraSource.iPhone.rawValue,
            backupEnrollment:.init(destinationID:"private-owner-identifier",deviceID:"private-device-identifier",server:URL(string:"https://backup.example")!,datePath:"2026/10/17",sources:[]))
        let capture = try XCTUnwrap(PhotoBackupCoordinator.capture(photo))
        let text = String(decoding:capture.metadata,as:UTF8.self)
        XCTAssertFalse(text.contains("private-owner-identifier"));XCTAssertFalse(text.contains("private-device-identifier"));XCTAssertFalse(text.contains("backup.example"))
    }
}
