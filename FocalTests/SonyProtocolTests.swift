import XCTest
import UIKit
@testable import Focal

final class SonyProtocolTests: XCTestCase {
    private let host = "192.168.122.1"
    // A structurally framed stream fixture; the real ImageIO test below uses an encoded image.
    private let jpeg = Data([0xff,0xd8,0xff,0xda,0,8,1,1,0,0,63,0,0x10,0x20,0xff,0xd9])
    private func packet(_ payload:Data,type:UInt8 = 1,padding:Int = 0) -> Data {
        var bytes = [UInt8](repeating:0,count:136)
        bytes[0] = 0xff; bytes[1] = type
        bytes[8] = 0x24; bytes[9] = 0x35; bytes[10] = 0x68; bytes[11] = 0x79
        bytes[12] = UInt8((payload.count>>16)&0xff); bytes[13] = UInt8((payload.count>>8)&0xff); bytes[14] = UInt8(payload.count&0xff)
        bytes[15] = UInt8(padding)
        return Data(bytes)+payload+Data(repeating:0,count:padding)
    }
    private func descriptor(action:String = "http://192.168.122.1:8080/sony",service:String = "camera") -> Data {
        Data("""
        <root xmlns:av="urn:schemas-sony-com:av"><device><modelName>ILCE-7M3</modelName>
        <av:X_ScalarWebAPI_ServiceList><av:X_ScalarWebAPI_Service>
        <av:X_ScalarWebAPI_ServiceType>\(service)</av:X_ScalarWebAPI_ServiceType>
        <av:X_ScalarWebAPI_ActionList_URL>\(action)</av:X_ScalarWebAPI_ActionList_URL>
        </av:X_ScalarWebAPI_Service></av:X_ScalarWebAPI_ServiceList></device></root>
        """.utf8)
    }
    func testPrivateCameraAddressAndSameHostURLRequired() throws {
        for address in [host,"10.0.0.1","172.16.0.1","169.254.1.2"] { XCTAssertTrue(SonyEndpoint.validHost(address)) }
        for address in ["8.8.8.8","127.0.0.1","192.168..1","192.168.122.01","192.168.122.1.evil","172.32.0.1","256.0.0.1","+192.168.122.1"] { XCTAssertFalse(SonyEndpoint.validHost(address)) }
        XCTAssertNoThrow(try SonyEndpoint.validate(XCTUnwrap(URL(string:"http://\(host):8080/sony/camera")),host:host))
        for text in ["http://example.com/photo.jpg","http://192.168.0.2/live","file:///tmp/photo.jpg","http://user:pass@\(host)/live"] {
            XCTAssertThrowsError(try SonyEndpoint.validate(XCTUnwrap(URL(string:text)),host:host))
        }
    }
    func testDescriptorUsesAdvertisedEndpointAndModel() throws {
        let parsed = try SonyDescriptor.parse(descriptor(),host:host)
        XCTAssertEqual(parsed.model,"ILCE-7M3")
        XCTAssertEqual(parsed.endpoint.absoluteString,"http://192.168.122.1:8080/sony/camera")
        XCTAssertNil(parsed.liveURL)
        XCTAssertEqual(try SonyDescriptor.parse(descriptor(action:"http://\(host)/sony/camera"),host:host).endpoint.path,"/sony/camera")
    }
    func testMissingOrExternalScalarServiceDoesNotInventSonyStream() {
        XCTAssertThrowsError(try SonyDescriptor.parse(descriptor(service:"avContent"),host:host))
        XCTAssertThrowsError(try SonyDescriptor.parse(descriptor(action:"http://example.com/sony"),host:host))
        XCTAssertThrowsError(try SonyDescriptor.parse(Data("broken XML".utf8),host:host))
    }
    func testFragmentedJPEGAndPaddingReassembleExactly() throws {
        var parser = SonyLiveViewParser()
        let data = packet(jpeg,padding:4)
        XCTAssertTrue(try parser.append(Data(data.prefix(5))).isEmpty)
        XCTAssertTrue(try parser.append(Data(data.dropFirst(5).prefix(133))).isEmpty)
        XCTAssertEqual(try parser.append(Data(data.dropFirst(138))),[jpeg])
    }
    func testMetadataPacketsAreSkippedAndMultipleFramesPreserved() throws {
        var parser = SonyLiveViewParser()
        let data = packet(Data([1,2,3]),type:2)+packet(jpeg)+packet(jpeg,padding:7)
        XCTAssertEqual(try parser.append(data),[jpeg,jpeg])
    }
    func testParserResynchronizesAfterNoise() throws {
        var parser = SonyLiveViewParser()
        XCTAssertEqual(try parser.append(Data(repeating:0,count:251)+packet(jpeg)),[jpeg])
    }
    func testOversizedPacketFailsExplicitly() {
        var parser = SonyLiveViewParser()
        var header = packet(jpeg); header[12] = 0x7f
        XCTAssertThrowsError(try parser.append(header))
    }
    func testEventTelemetryUsesReportedValuesWithoutInventingEV() {
        let values = SonyEventValues.telemetry([["type":"exposureMode","currentExposureMode":"Aperture"],
            ["type":"shutterSpeed","currentShutterSpeed":"1/125"], ["type":"isoSpeedRate","currentIsoSpeedRate":"400"],
            ["type":"fNumber","currentFNumber":"2.8"], ["type":"exposureCompensation","currentExposureCompensation":3]])
        XCTAssertEqual(values.mode,"Aperture"); XCTAssertEqual(values.shutter,"1/125")
        XCTAssertEqual(values.iso,"400"); XCTAssertEqual(values.aperture,"2.8"); XCTAssertNil(values.ev)
        XCTAssertEqual(SonyEventValues.telemetry([["type":"exposureCompensation","currentExposureCompensation":0]]).ev,0)
        XCTAssertEqual(SonyEventValues.telemetry([]),CameraTelemetry())
    }
    func testMissingExposureDoesNotShowFabricatedReadings() {
        XCTAssertNil(CameraTelemetry.shutterLabel(seconds:0)); XCTAssertNil(CameraTelemetry.shutterLabel(seconds:.nan))
        XCTAssertEqual(CameraTelemetry.shutterLabel(seconds:0.04),"1/25")
        XCTAssertEqual(CameraTelemetry.shutterLabel(seconds:2),"2.0 s")
        XCTAssertEqual(CameraTelemetry().evLabel,"—")
    }
    func testSonyWrapperAndTrailerDoNotInvalidateJPEG() throws {
        var parser = SonyLiveViewParser()
        let wrapped = Data([0x01,0x02,0x03]) + jpeg + Data([0,0,0,0])
        XCTAssertEqual(try parser.append(packet(wrapped, padding: 5)), [jpeg])
    }
    func testMarkerOnlyAndSplitSOIStreamsDecode() throws {
        var parser = SonyLiveViewParser()
        XCTAssertTrue(try parser.append(Data([0x11,0x22,0xff])).isEmpty)
        XCTAssertEqual(try parser.append(Data(jpeg.dropFirst()) + jpeg), [jpeg,jpeg])
    }
    func testMalformedFrameRecoversToNextCameraFrame() throws {
        var parser = SonyLiveViewParser()
        let malformed = Data([0xff,0xd8,0x10,0x20,0xff,0xd9])
        XCTAssertEqual(try parser.append(packet(malformed) + packet(jpeg)), [jpeg])
        XCTAssertGreaterThan(parser.discardedFrames, 0)
    }
    func testEXIFThumbnailEOIDoesNotEndOuterJPEG() throws {
        var parser = SonyLiveViewParser()
        let embedded = jpeg
        let segmentLength = embedded.count + 2
        let app = Data([0xff,0xe1,UInt8(segmentLength >> 8),UInt8(segmentLength & 0xff)]) + embedded
        let outer = Data([0xff,0xd8]) + app + Data(jpeg.dropFirst(2))
        XCTAssertEqual(try parser.append(packet(outer)), [outer])
    }
    func testStuffedBytesRestartsAndProgressiveScansArePreserved() throws {
        var parser = SonyLiveViewParser()
        let scanHeader = Data([0xff,0xda,0,8,1,1,0,0,63,0])
        let image = Data([0xff,0xd8]) + scanHeader + Data([0x20,0xff,0,0x30,0xff,0xd0,0x40])
            + scanHeader + Data([0x50,0xff,0xd9])
        var frames = [Data]()
        for byte in image { frames.append(contentsOf: try parser.append(Data([byte]))) }
        XCTAssertEqual(frames, [image])
    }
    func testMetadataAndPaddingContainingMarkersDoNotCreateImages() throws {
        var parser = SonyLiveViewParser()
        var imagePacket = packet(jpeg, padding: 8)
        let offset = 136 + jpeg.count
        imagePacket.replaceSubrange(offset..<offset+8, with: [0xff,0xd8,0x10,0x20,0xff,0xd9,0,0])
        XCTAssertEqual(try parser.append(packet(jpeg, type: 2) + imagePacket), [jpeg])
        XCTAssertEqual(parser.metadataPackets, 1)
    }
    func testTruncatedEntropyFrameCanRecoverAtNewSOI() throws {
        var parser = SonyLiveViewParser()
        XCTAssertTrue(try parser.append(Data(jpeg.dropLast(2))).isEmpty)
        XCTAssertEqual(try parser.append(jpeg), [jpeg])
    }
    @MainActor func testRealEncodedJPEGSurvivesWrappedFragmentedStream() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { _ in
            UIColor.red.setFill(); UIRectFill(CGRect(x: 0,y: 0,width: 320,height: 240))
        }
        let encoded = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let stream = packet(Data([0,1]) + encoded + Data([0,0]), padding: 7)
        var parser = SonyLiveViewParser(), result = [Data]()
        for offset in stride(from: 0, to: stream.count, by: 17) {
            result.append(contentsOf: try parser.append(Data(stream[offset..<min(stream.count,offset+17)])))
        }
        XCTAssertEqual(result, [encoded])
        XCTAssertEqual(try XCTUnwrap(UIImage(data: XCTUnwrap(result.first))).size, CGSize(width: 320,height: 240))
    }

}
