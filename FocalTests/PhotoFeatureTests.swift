import XCTest
import UIKit
@testable import Focal

@MainActor
final class PhotoFeatureTests: XCTestCase {
    private func jpeg() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 120, height: 160), format: format).image { _ in
            UIColor.red.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 120, height: 160))
        }.jpegData(compressionQuality: 0.98)!
    }

    func testStandardAspectPreservesCameraBytes() throws {
        let original = jpeg()
        XCTAssertEqual(try PhotoRenderer.crop(original, to: .standard), original)
    }

    func testSelectedAspectProducesMatchingPixelDimensions() throws {
        for aspect in PhotoAspect.allCases {
            let data = try PhotoRenderer.crop(jpeg(), to: aspect)
            let image = try XCTUnwrap(UIImage(data: data))
            XCTAssertEqual(Double(image.size.width / image.size.height), aspect.ratio, accuracy: 0.015)
            XCTAssertLessThanOrEqual(image.size.width, 120)
            XCTAssertLessThanOrEqual(image.size.height, 160)
        }
    }

    func testCaptionStylesAddScanCaptionWithoutChangingOriginal() throws {
        let original = jpeg()
        for style in CaptionStyle.allCases {
            let data = try XCTUnwrap(PhotoRenderer.captionedScan(original, style: style))
            let image = try XCTUnwrap(UIImage(data: data))
            XCTAssertEqual(image.size.width, 120)
            XCTAssertGreaterThan(image.size.height, 160)
        }
        XCTAssertEqual(UIImage(data: original)?.size.height, 160)
    }

    func testOldLibraryEntriesRemainDecodable() throws {
        let data = Data("""
        {"id":"12345678-1234-1234-1234-123456789012","filename":"photo.jpg","createdAt":0,"mode":"Thirds","isDemo":false,"isFavorite":false}
        """.utf8)
        let photo = try JSONDecoder().decode(SavedPhoto.self, from: data)
        XCTAssertNil(photo.rawFilename)
        XCTAssertNil(photo.scanFilename)
        XCTAssertNil(photo.originalFilename)
    }

    func testPairedFilesPersistAndDeleteTogether() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PhotoLibrary(directory: directory)
        let processed = jpeg()
        let raw = Data("test RAW bytes".utf8)
        let original = Data("test original bytes".utf8)
        let scan = try XCTUnwrap(PhotoRenderer.captionedScan(processed, style: .bold))
        let photo = try await library.add(data: processed, mode: "Thirds", rawData: raw, originalData: original,
                                          scanData: scan, aspect: "3:4", subject: "Keyboard")
        XCTAssertEqual(try Data(contentsOf: library.url(for: photo)), processed)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(library.rawURL(for: photo))), raw)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(library.originalURL(for: photo))), original)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(library.scanURL(for: photo))), scan)
        XCTAssertGreaterThan(library.storageBytes, Int64(processed.count))
        let reopened = PhotoLibrary(directory: directory)
        XCTAssertEqual(reopened.photos.first, photo)
        try reopened.delete(photo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.url(for: photo).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(library.rawURL(for: photo)).path))
    }

    func testCameraSettingsPersist() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CameraSettings(defaults: defaults)
        settings.aspect = .square
        settings.caption = .garamond
        settings.saveScan = false
        settings.autoSaveToPhotos = true
        settings.raw = true
        let reopened = CameraSettings(defaults: defaults)
        XCTAssertEqual(reopened.aspect, .square)
        XCTAssertEqual(reopened.caption, .garamond)
        XCTAssertFalse(reopened.saveScan)
        XCTAssertTrue(reopened.autoSaveToPhotos)
        XCTAssertTrue(reopened.raw)
    }
}
