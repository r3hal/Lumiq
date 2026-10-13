import XCTest
import UIKit
import ImageIO
@testable import Focal

final class SonyPreviewTests: XCTestCase {
    func testSlowDecodeRetainsOnlyNewestPendingFrame() {
        let mailbox = LatestFrameMailbox<Int>()
        XCTAssertTrue(mailbox.offer(1))
        XCTAssertEqual(mailbox.take(), 1)
        for frame in 2...60 { XCTAssertFalse(mailbox.offer(frame)) }
        XCTAssertEqual(mailbox.take(), 60)
        XCTAssertNil(mailbox.take())
        XCTAssertTrue(mailbox.offer(61)); XCTAssertEqual(mailbox.take(), 61)
    }
    func testDisconnectClosesOldDeliveryBeforeReconnect() {
        let old = LatestFrameMailbox<Int>()
        XCTAssertTrue(old.offer(1)); old.close()
        XCTAssertNil(old.take()); XCTAssertFalse(old.offer(2))
        let new = LatestFrameMailbox<Int>()
        XCTAssertTrue(new.offer(3)); XCTAssertEqual(new.take(), 3)
    }
    func testOnlyAdvertisedSonySizesCanBeNegotiated() {
        XCTAssertEqual(SonyLiveViewSize.largest(in: ["M", ["S", "M", "L"]]), "L")
        XCTAssertEqual(SonyLiveViewSize.largest(in: [["S", "M"]]), "M")
        XCTAssertEqual(SonyLiveViewSize.largest(in: ["M", ["S"]]), "S")
        XCTAssertNil(SonyLiveViewSize.largest(in: ["L", ["unknown"]]))
        XCTAssertNil(SonyLiveViewSize.largest(in: []))
    }
    @MainActor func testReceivedPixelsAreNotDownsampledOrUpscaled() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 424), format: format).image { context in
            UIColor.red.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 640, height: 424))
        }
        let data = try XCTUnwrap(original.jpegData(compressionQuality: 0.95))
        let frame = try XCTUnwrap(SonyDecodedFrame.decode(data, receivedAt: 1))
        XCTAssertEqual(frame.image.width, 640); XCTAssertEqual(frame.image.height, 424)
        let projection = PreviewProjection(imageAspect: frame.aspect, previewAspect: frame.aspect)
        XCTAssertEqual(projection.visiblePoint(.init(x: 0.1, y: 0.9)).x, 0.1, accuracy: 0.001)
        XCTAssertNil(SonyDecodedFrame.decode(Data([0xff, 0xd8, 0xff, 0xd9]), receivedAt: 1))
    }
    @MainActor func testEXIFRotationKeepsNativePixelDimensionsAndGeometry() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 424), format: format).image { context in
            UIColor.blue.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 640, height: 424))
        }
        let image = try XCTUnwrap(original.cgImage)
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes as CFMutableData, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let frame = try XCTUnwrap(SonyDecodedFrame.decode(bytes as Data, receivedAt: 1))
        XCTAssertEqual(frame.image.width, 424); XCTAssertEqual(frame.image.height, 640)
        XCTAssertEqual(frame.aspect, 424.0 / 640, accuracy: 0.001)
    }
}
