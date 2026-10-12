import XCTest
@testable import Focal

final class SonyProtocolTests: XCTestCase {
    private let host = "192.168.122.1"
    private let jpeg = Data([0xff,0xd8,0x10,0x20,0xff,0xd9])
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
    func testOversizedOrInvalidJPEGFailsExplicitly() {
        var parser = SonyLiveViewParser()
        XCTAssertThrowsError(try parser.append(packet(Data([0,1,2,3]))))
        parser = SonyLiveViewParser()
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
}
