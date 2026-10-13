import XCTest
import UIKit
import CoreImage
@testable import Focal

final class EditorFeatureTests: XCTestCase {
    private func jpeg() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 120, height: 160), format: format).image { _ in
            UIColor.darkGray.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 120, height: 160))
            UIColor.orange.setFill(); UIRectFill(CGRect(x: 30, y: 35, width: 60, height: 80))
        }.jpegData(compressionQuality: 1)!
    }
    func testOlderRecipesDecodeWithNeutralNewControls() throws {
        let bytes = Data("{\"exposure\":0.4,\"contrast\":1.1,\"grain\":0.2,\"quarterTurns\":1}".utf8)
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: bytes)
        XCTAssertEqual(recipe.exposure, 0.4); XCTAssertEqual(recipe.contrast, 1.1)
        XCTAssertEqual(recipe.color, AdvancedColor()); XCTAssertEqual(recipe.effects, FilmEffects())
        XCTAssertEqual(recipe.frame, .none); XCTAssertFalse(recipe.dateStamp)
    }
    func testNewControlsRoundTripWithoutLosingGroupedValues() throws {
        var recipe = EditRecipe(tint: 0.2, whites: 0.3, frame: .specs, dateStamp: true, stampDate: Date(timeIntervalSince1970: 100))
        recipe.color.hsl[7] = HSLAdjustment(hue: -0.2, saturation: 0.3, lightness: 0.1)
        recipe.color.midtones = ColorGrade(hue: 0.7, amount: 0.4)
        recipe.effects.motion = 0.2; recipe.effects.dust = 0.5
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe)), recipe)
    }
    func testMalformedAdvancedControlsNormalizeToFiniteEightBands() {
        var recipe = EditRecipe()
        recipe.color.hsl = [HSLAdjustment(hue: .nan, saturation: 4, lightness: -.infinity)]
        recipe.color.blueHue = .infinity; recipe.effects.motionAngle = 100; recipe.effects.glow = .nan
        let result = recipe.normalized
        XCTAssertEqual(result.color.hsl.count, 8); XCTAssertEqual(result.color.hsl[0].hue, 0)
        XCTAssertEqual(result.color.hsl[0].saturation, 1); XCTAssertEqual(result.effects.motionAngle, .pi)
        XCTAssertEqual(result.effects.glow, 0)
    }
    func testEveryToolHasParametersThatWriteTheCorrectRecipeSlot() {
        for tool in EditorTool.allCases {
            XCTAssertFalse(EditorParameter.choices(for: tool).isEmpty)
            for parameter in EditorParameter.choices(for: tool) {
                for channel in 0..<8 {
                    var recipe = EditRecipe()
                    let value = parameter.range.lowerBound + (parameter.range.upperBound - parameter.range.lowerBound) * 0.73
                    parameter.set(value, in: &recipe, channel: channel)
                    XCTAssertEqual(parameter.value(in: recipe, channel: channel), value, accuracy: 0.000001, "\(tool) / \(parameter)")
                }
            }
        }
    }
    func testUndoRedoRestoresAcrossToolsAndClearsBranch() {
        var history = EditHistory()
        var first = EditRecipe(exposure: 0.5); history.set(first); history.set(first)
        first.effects.glow = 0.3; first.frame = .white; history.set(first)
        history.undo(); XCTAssertEqual(history.current.exposure, 0.5); XCTAssertEqual(history.current.frame, .none)
        history.redo(); XCTAssertEqual(history.current, first)
        history.undo(); history.set(EditRecipe(warmth: 0.5)); XCTAssertFalse(history.canRedo)
        history.undo(); history.undo(); XCTAssertEqual(history.current, .original); XCTAssertFalse(history.canUndo)
    }
    func testDefaultAdvancedColorPreservesRGBAndHSLRoundTrips() {
        for pixel in [EditRGB(r: 0.2, g: 0.7, b: 0.4), EditRGB(r: 0.5, g: 0.5, b: 0.5), EditRGB(r: 1, g: 0, b: 0)] {
            XCTAssertEqual(ColorProcessing.transform(pixel, color: AdvancedColor(), whites: 0, blacks: 0, fade: 0), pixel)
            let hsl = pixel.hsl, restored = EditRGB.fromHSL(hue: hsl.h, saturation: hsl.s, lightness: hsl.l)
            XCTAssertEqual(restored.r, pixel.r, accuracy: 0.000001); XCTAssertEqual(restored.g, pixel.g, accuracy: 0.000001)
            XCTAssertEqual(restored.b, pixel.b, accuracy: 0.000001)
        }
    }
    func testHSLBandChangesRedWithoutChangingDistantBlue() {
        var color = AdvancedColor(); color.hsl[0].hue = 0.7
        let red = EditRGB(r: 1, g: 0, b: 0), blue = EditRGB(r: 0, g: 0, b: 1)
        XCTAssertNotEqual(ColorProcessing.transform(red, color: color, whites: 0, blacks: 0, fade: 0), red)
        XCTAssertEqual(ColorProcessing.transform(blue, color: color, whites: 0, blacks: 0, fade: 0), blue)
    }
    func testAllEffectsRenderFiniteFullSizeOutput() throws {
        let input = try XCTUnwrap(CIImage(data: jpeg()))
        for tool in EditorTool.allCases where tool.isEffect {
            var recipe = EditRecipe(); EditorParameter.choices(for: tool)[0].set(0.8, in: &recipe, channel: 0)
            let result = ImageEditor.render(input, recipe: recipe)
            XCTAssertEqual(result.extent.size, CGSize(width: 120, height: 160), tool.rawValue)
            XCTAssertNotNil(ImageEditor.preview(source: input, recipe: recipe), tool.rawValue)
        }
    }
    func testAdvancedAdjustmentsRenderThroughTheColorCube() throws {
        var recipe = EditRecipe(tint: 0.2, vibrance: 0.4, whites: 0.2, blacks: -0.1, fade: 0.15, curve: 0.5, sharpness: 0.5)
        recipe.color.hsl[1].saturation = -0.4; recipe.color.shadows = ColorGrade(hue: 0.65, amount: 0.3)
        recipe.color.redHue = 0.2
        let result = try XCTUnwrap(UIImage(data: ImageEditor.export(data: jpeg(), recipe: recipe)))
        XCTAssertEqual(result.size, CGSize(width: 120, height: 160))
    }
    func testSeededGrainAndScratchesAreRepeatable() throws {
        let input = try XCTUnwrap(CIImage(data: jpeg()))
        var recipe = EditRecipe(grain: 0.7); recipe.effects.scratches = 0.6; recipe.effects.dust = 0.5
        let first = try XCTUnwrap(ImageEditor.preview(source: input, recipe: recipe)?.pngData())
        XCTAssertEqual(first, ImageEditor.preview(source: input, recipe: recipe)?.pngData())
        recipe.effects.seed += 1
        XCTAssertNotEqual(first, ImageEditor.preview(source: input, recipe: recipe)?.pngData())
    }
    func testFramesAddCanvasWithoutReducingPhotoDimensions() throws {
        for frame in PhotoFrame.allCases {
            let image = try XCTUnwrap(UIImage(data: ImageEditor.export(data: jpeg(), recipe: EditRecipe(frame: frame))))
            let border = frame == .none ? 0 : max(1, (120 * frame.borderRatio).rounded())
            let bottom = frame == .none ? 0 : max(border, (120 * frame.bottomRatio).rounded())
            XCTAssertEqual(Double(image.size.width), 120 + border * 2)
            XCTAssertEqual(Double(image.size.height), 160 + border + bottom)
        }
    }
    func testDateStampUsesChosenDateAndDoesNotResizeOriginalFrame() throws {
        var recipe = EditRecipe(dateStamp: true, stampDate: Date(timeIntervalSince1970: 0))
        let first = try ImageEditor.export(data: jpeg(), recipe: recipe)
        recipe.stampDate = Date(timeIntervalSince1970: 86400 * 365)
        XCTAssertNotEqual(first, try ImageEditor.export(data: jpeg(), recipe: recipe))
        XCTAssertEqual(UIImage(data: first)?.size, CGSize(width: 120, height: 160))
        recipe.dateStamp = false; XCTAssertNil(recipe.normalized.stampDate)
    }
}

@MainActor
final class PhoneEditingLibraryTests: XCTestCase {
    private func photo(origin: String?, demo: Bool = false) -> SavedPhoto {
        var photo = SavedPhoto(id: UUID(), filename: "camera.jpg", createdAt: Date(), mode: "Center", isDemo: demo, isFavorite: false)
        photo.cameraOrigin = origin; return photo
    }
    private func jpeg() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 120, height: 160), format: format).image { _ in
            UIColor.orange.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 120, height: 160))
        }.jpegData(compressionQuality: 1)!
    }
    func testOnlyKnownPhoneCapturesAndOfflineDemoCanUseEditor() {
        XCTAssertTrue(photo(origin: CameraSource.iPhone.rawValue).canUsePhoneEditor)
        XCTAssertFalse(photo(origin: CameraSource.sony.rawValue).canUsePhoneEditor)
        XCTAssertFalse(photo(origin: nil).canUsePhoneEditor)
        XCTAssertTrue(photo(origin: nil, demo: true).canUsePhoneEditor)
        XCTAssertFalse(photo(origin: CameraSource.sony.rawValue, demo: true).canUsePhoneEditor)
    }
    func testReviewUpdatesOneEntryAndPreservesJPEGRAWScanAndBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PhotoLibrary(directory: directory), camera = jpeg(), raw = Data("raw-original".utf8), scan = jpeg()
        let capture = try await library.add(data: camera, mode: "Center", rawData: raw, scanData: scan, cameraOrigin: CameraSource.iPhone.rawValue)
        let edit = EditRecipe(exposure: 0.5, frame: .white), bytes = try ImageEditor.export(data: camera, recipe: edit)
        let saved = try await library.finishPhoneReview(capture, data: bytes, recipe: edit, developedFromRAW: false)
        XCTAssertEqual(library.photos.count, 1); XCTAssertEqual(saved.id, capture.id); XCTAssertEqual(saved.createdAt, capture.createdAt)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(library.editingSourceURL(for: saved))), camera)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(library.originalURL(for: saved))), camera)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(library.rawURL(for: saved))), raw)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(library.scanURL(for: saved))), scan)
        XCTAssertEqual(try Data(contentsOf: library.url(for: saved)), bytes)
        XCTAssertEqual(PhotoLibrary(directory: directory).photos.first, saved)
        let reset = try await library.finishPhoneReview(saved, data: camera, recipe: .original, developedFromRAW: false)
        XCTAssertEqual(try Data(contentsOf: library.url(for: reset)), camera)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.url(for: saved).path))
        try library.delete(reset)
        XCTAssertEqual(library.photos.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.url(for: capture).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(library.rawURL(for: reset)).path))
    }
    func testSonyCaptureRejectsPhoneReviewWithoutWritingDerivative() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PhotoLibrary(directory: directory), bytes = jpeg()
        let capture = try await library.add(data: bytes, mode: "Center", cameraOrigin: CameraSource.sony.rawValue)
        do { _ = try await library.finishPhoneReview(capture, data: bytes, recipe: EditRecipe(exposure: 1), developedFromRAW: false); XCTFail("Sony review must be rejected") }
        catch { XCTAssertEqual(library.photos.first, capture); XCTAssertEqual(try Data(contentsOf: library.url(for: capture)), bytes) }
    }
    func testReviewPreferenceDefaultsOnAndPersistsOptOut() throws {
        let suite = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CameraSettings(defaults: defaults)
        XCTAssertTrue(settings.reviewAfterCapture); settings.reviewAfterCapture = false
        XCTAssertFalse(CameraSettings(defaults: defaults).reviewAfterCapture)
    }
}
