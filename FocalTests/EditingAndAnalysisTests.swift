import XCTest
import UIKit
import CoreImage
@testable import Focal

final class EditingAndAnalysisTests: XCTestCase {
    private func jpeg() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 121,height: 161),format: format).image { _ in
            UIColor.red.setFill(); UIRectFill(CGRect(x: 0,y: 0,width: 121,height: 161))
        }.jpegData(compressionQuality: 1)!
    }
    func testIdentityExportPreservesOriginalBytes() throws { let data = jpeg(); XCTAssertEqual(try ImageEditor.export(data: data,recipe: .original),data) }
    func testRotationAndCropUseFullResolution() throws {
        let rotated = try XCTUnwrap(UIImage(data: ImageEditor.export(data: jpeg(),recipe: EditRecipe(quarterTurns: 1))))
        XCTAssertEqual(rotated.size.width,161); XCTAssertEqual(rotated.size.height,121)
        let cropped = try XCTUnwrap(UIImage(data: ImageEditor.export(data: jpeg(),recipe: EditRecipe(crop: .square))))
        XCTAssertEqual(cropped.size.width,121); XCTAssertEqual(cropped.size.height,121)
    }
    func testCropNeverExceedsOddSizedImage() {
        for aspect in PhotoAspect.allCases {
            let size = CGSize(width: 121,height: 161)
            let rect = aspect.cropRect(in: size)
            XCTAssertTrue(CGRect(origin: .zero,size: size).contains(rect))
            XCTAssertGreaterThan(rect.width,0); XCTAssertGreaterThan(rect.height,0)
        }
    }
    func testFilmPresetsRenderAndKeepFullSize() throws {
        let data = jpeg()
        for preset in FilmPreset.allCases {
            let image = try XCTUnwrap(UIImage(data: ImageEditor.export(data: data,recipe: preset.recipe)))
            XCTAssertEqual(image.size,CGSize(width: 121,height: 161))
        }
    }
    func testSilverPresetRemovesColor() throws {
        let bytes = try ImageEditor.export(data: jpeg(),recipe: FilmPreset.silver.recipe)
        let source = try XCTUnwrap(CIImage(data: bytes))
        var pixel = [UInt8](repeating:0,count:4)
        pixel.withUnsafeMutableBytes { bytes in
            CIContext().render(source,toBitmap: bytes.baseAddress!,rowBytes:4,bounds:CGRect(x:60,y:80,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        }
        XCTAssertLessThan(abs(Int(pixel[0])-Int(pixel[1])),6)
        XCTAssertLessThan(abs(Int(pixel[1])-Int(pixel[2])),6)
    }
    func testRecipesNormalizeBadValuesAndRoundTrip() throws {
        var recipe = EditRecipe(exposure: .infinity,saturation: -3,quarterTurns: -1)
        recipe = recipe.normalized
        XCTAssertEqual(recipe.exposure,0); XCTAssertEqual(recipe.saturation,0); XCTAssertEqual(recipe.quarterTurns,3)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self,from: JSONEncoder().encode(recipe)),recipe)
    }
    func testMeasurementsReflectActualBrightnessAndEdges() throws {
        let dark = try XCTUnwrap(PhotoMeasurements.from(luma:[Double](repeating:0.02,count:16),width:4,height:4))
        let bright = try XCTUnwrap(PhotoMeasurements.from(luma:[Double](repeating:1,count:16),width:4,height:4))
        let flat = try XCTUnwrap(PhotoMeasurements.from(luma:[Double](repeating:0.5,count:16),width:4,height:4))
        XCTAssertNotNil(dark.lightingAdvice); XCTAssertEqual(dark.shadowFraction,1)
        XCTAssertNotNil(bright.lightingAdvice); XCTAssertEqual(bright.highlightFraction,1)
        XCTAssertNil(flat.lightingAdvice); XCTAssertEqual(flat.detail,0)
        let checker = (0..<16).map { Double(($0/4+$0%4)%2) }
        let edges = try XCTUnwrap(PhotoMeasurements.from(luma:checker,width:4,height:4,subject:CGRect(x:0,y:0,width:0.1,height:0.1)))
        XCTAssertGreaterThan(edges.detail,flat.detail); XCTAssertNotNil(edges.clutterAdvice)
        XCTAssertTrue((0...100).contains(edges.technicalScore))
    }
    func testInvalidMeasurementsAndMissingAlignmentDoNotInventScores() {
        XCTAssertNil(PhotoMeasurements.from(luma:[.nan,0,0,0],width:2,height:2))
        XCTAssertNil(PhotoMeasurements.from(luma:[0,0],width:2,height:2))
        XCTAssertNil(CompositionReading().alignmentPercent(previewAspect:0.75))
        let reading = CompositionReading(state:.ready,subject:.init(x:0.5,y:0.5),target:.init(x:0.5,y:0.5))
        XCTAssertEqual(reading.alignmentPercent(previewAspect:0.75),100)
    }
    func testSmartShutterRequiresArmingReadinessAndForeground() {
        var gate = SmartShutterGate()
        XCTAssertFalse(gate.shouldCapture(enabled:true,ready:true,active:false,busy:false,zooming:false,timestamp:1))
        XCTAssertFalse(gate.shouldCapture(enabled:true,ready:true,active:true,busy:true,zooming:false,timestamp:1))
        XCTAssertFalse(gate.shouldCapture(enabled:true,ready:true,active:true,busy:false,zooming:true,timestamp:1))
        XCTAssertTrue(gate.shouldCapture(enabled:true,ready:true,active:true,busy:false,zooming:false,timestamp:1))
        XCTAssertFalse(gate.shouldCapture(enabled:true,ready:true,active:true,busy:false,zooming:false,timestamp:2))
        gate.reset(timestamp:3)
        XCTAssertFalse(gate.shouldCapture(enabled:true,ready:true,active:true,busy:false,zooming:false,timestamp:3.2))
        XCTAssertTrue(gate.shouldCapture(enabled:true,ready:true,active:true,busy:false,zooming:false,timestamp:4))
    }
    func testSolarGeometryAndWindowsAtEquinox() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from:"2026-03-20T12:00:00Z"))
        XCTAssertGreaterThan(try XCTUnwrap(SolarCalculator.elevation(at:date,latitude:0,longitude:0)),80)
        XCTAssertLessThan(try XCTUnwrap(SolarCalculator.elevation(at:date.addingTimeInterval(-43200),latitude:0,longitude:0)),-80)
        var utc = Calendar(identifier:.gregorian); utc.timeZone = TimeZone(secondsFromGMT:0)!
        let windows = SolarCalculator.goldenWindows(on:date,latitude:0,longitude:0,calendar:utc)
        XCTAssertEqual(windows.count,2)
        for window in windows { XCTAssertGreaterThan(window.duration,0); XCTAssertLessThan(window.duration,7200) }
        XCTAssertNil(SolarCalculator.elevation(at:date,latitude:91,longitude:0))
    }
    func testSolarPolarDayHasNoInventedGoldenWindow() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from:"2026-06-21T12:00:00Z"))
        XCTAssertTrue(SolarCalculator.goldenWindows(on:date,latitude:90,longitude:0).isEmpty)
    }
    func testMirroredPreviewRoundTripsSubjectAndBounds() {
        let projection = PreviewProjection(imageAspect:1,previewAspect:0.75,mirrored:true)
        let point = UnitPoint2D(x:0.375,y:0.3)
        let visible = projection.visiblePoint(point)
        XCTAssertEqual(visible.x,2.0/3,accuracy:0.0001)
        let back = projection.imagePoint(visible)
        XCTAssertEqual(back.x,point.x,accuracy:0.0001)
        let bounds = projection.visibleRect(CGRect(x:0.3,y:0.2,width:0.1,height:0.2))
        XCTAssertGreaterThan(bounds.width,0)
        XCTAssertEqual(bounds.minX,1-((0.4-0.5)*4/3+0.5),accuracy:0.0001)
    }

}
