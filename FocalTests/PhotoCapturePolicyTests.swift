import XCTest
@testable import Focal

/// Capability fixtures test policy, not hardware support or real DNG encoding.
final class PhotoCapturePolicyTests: XCTestCase {
    private let bayer = RAWPhotoFormat(pixelFormat:17,kind:.bayer)
    private let proRAW = RAWPhotoFormat(pixelFormat:29,kind:.appleProRAW)

    func testProRAWIsPreferredOverBayerRegardlessOfAdvertisementOrder() throws {
        let capabilities = PhotoCaptureCapabilities(rawFormats:[bayer,proRAW])
        XCTAssertTrue(capabilities.supportsRAW); XCTAssertTrue(capabilities.supportsProRAW)
        XCTAssertEqual(try capabilities.selection(rawRequested:true,encoding:.jpeg).raw,proRAW)
    }
    func testBayerOnlyCameraUsesItsActualAdvertisedPixelFormat() throws {
        let capabilities = PhotoCaptureCapabilities(rawFormats:[bayer])
        XCTAssertTrue(capabilities.supportsRAW); XCTAssertFalse(capabilities.supportsProRAW)
        XCTAssertEqual(try capabilities.selection(rawRequested:true,encoding:.jpeg).raw?.pixelFormat,17)
    }
    func testMissingFormatsCannotAdvertiseRAWOrProRAW() {
        let capabilities = PhotoCaptureCapabilities()
        XCTAssertFalse(capabilities.supportsRAW); XCTAssertFalse(capabilities.supportsProRAW)
        XCTAssertNil(capabilities.preferredRAW)
    }
    func testPreviewCannotRemovePhotoPresetsRAWCapability() {
        XCTAssertFalse(PhotoCaptureCapabilities().preservesRAW(of:.init(rawFormats:[bayer])))
        XCTAssertFalse(PhotoCaptureCapabilities().preservesRAW(of:.init(rawFormats:[proRAW])))
    }
    func testPreviewCannotDowngradePhotoPresetsProRAWToBayer() {
        XCTAssertFalse(PhotoCaptureCapabilities(rawFormats:[bayer]).preservesRAW(of:.init(rawFormats:[proRAW])))
    }
    func testCompatiblePreviewRetainsOptimizationWithoutInventingSupport() {
        let capabilities = PhotoCaptureCapabilities(rawFormats:[proRAW])
        XCTAssertTrue(capabilities.preservesRAW(of:capabilities))
        XCTAssertTrue(capabilities.preservesRAW(of:.init(rawFormats:[bayer])))
        XCTAssertTrue(PhotoCaptureCapabilities().preservesRAW(of:.init()))
    }
    func testRAWOffAlwaysRequestsProcessedPhotoEvenOnProRAWCamera() throws {
        let selection = try PhotoCaptureCapabilities(rawFormats:[proRAW],encodings:[.jpeg,.heif])
            .selection(rawRequested:false,encoding:.heif)
        XCTAssertNil(selection.raw); XCTAssertEqual(selection.encoding,.heif)
    }
    func testRequestedRAWNeverSilentlyFallsBackToProcessedOnly() {
        XCTAssertThrowsError(try PhotoCaptureCapabilities().selection(rawRequested:true,encoding:.jpeg)) {
            XCTAssertEqual($0 as? PhotoCaptureError,.rawUnavailable)
        }
    }
    func testProRAWRetainsSupportedHEIFCompanion() throws {
        let selection = try PhotoCaptureCapabilities(rawFormats:[proRAW],encodings:[.jpeg,.heif])
            .selection(rawRequested:true,encoding:.heif)
        XCTAssertEqual(selection.raw,proRAW); XCTAssertEqual(selection.encoding,.heif)
        XCTAssertFalse(selection.isBayerRAW)
    }
    func testBayerRAWUsesJPEGCompanionEvenWhenHEIFIsAdvertised() throws {
        let selection = try PhotoCaptureCapabilities(rawFormats:[bayer],encodings:[.jpeg,.heif])
            .selection(rawRequested:true,encoding:.heif)
        XCTAssertEqual(selection.encoding,.jpeg); XCTAssertTrue(selection.isBayerRAW)
    }
    func testUnsupportedHEIFFallsBackWithoutDroppingRequestedRAW() throws {
        let selection = try PhotoCaptureCapabilities(rawFormats:[proRAW]).selection(rawRequested:true,encoding:.heif)
        XCTAssertEqual(selection.encoding,.jpeg); XCTAssertEqual(selection.raw,proRAW)
    }
    func testMissingOrEmptyRequestedDNGFailsDelivery() throws {
        for format in [bayer,proRAW] {
            let selection = try PhotoCaptureCapabilities(rawFormats:[format]).selection(rawRequested:true,encoding:.jpeg)
            for data: Data? in [nil,Data()] {
                XCTAssertThrowsError(try selection.validateDelivery(rawData:data)) {
                    XCTAssertEqual($0 as? PhotoCaptureError,.missingRAW)
                }
            }
        }
    }
    func testRAWDeliveryRequiresDataButProcessedOnlyCaptureDoesNot() throws {
        // Placeholder bytes exercise presence validation, not DNG validity.
        let raw = try PhotoCaptureCapabilities(rawFormats:[proRAW]).selection(rawRequested:true,encoding:.jpeg)
        XCTAssertNoThrow(try raw.validateDelivery(rawData:Data([1,2,3])))
        let processed = try PhotoCaptureCapabilities().selection(rawRequested:false,encoding:.jpeg)
        XCTAssertNoThrow(try processed.validateDelivery(rawData:nil))
    }
    func testCapabilitiesCanRefreshFromUnavailableToAvailableAndBack() throws {
        var current = PhotoCaptureCapabilities()
        XCTAssertThrowsError(try current.selection(rawRequested:true,encoding:.jpeg))
        current = .init(rawFormats:[proRAW])
        XCTAssertEqual(try current.selection(rawRequested:true,encoding:.jpeg).raw,proRAW)
        current = .init()
        XCTAssertThrowsError(try current.selection(rawRequested:true,encoding:.jpeg))
        XCTAssertNil(try current.selection(rawRequested:false,encoding:.jpeg).raw)
    }
}
