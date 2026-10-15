import Foundation
import ImageIO

struct SonyRemoteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Only the manually selected local camera may supply control, stream or photo URLs.
enum SonyEndpoint {
    static func initialHost(previous: String?) -> String {
        let saved = previous?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return validHost(saved) ? saved : "192.168.122.1"
    }
    static func validHost(_ host: String) -> Bool {
        let segments = host.split(separator:".",omittingEmptySubsequences:false)
        let parts = segments.compactMap { Int($0) }
        guard segments.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) && ($0.count == 1 || $0.first != "0") }),parts.count == 4, segments.count == 4,parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
    }
    static func validate(_ url: URL,host: String) throws -> URL {
        guard validHost(host),url.host == host,["http","https"].contains(url.scheme ?? ""),url.user == nil,url.password == nil else {
            throw SonyRemoteError(message:"The camera returned a URL outside its selected local address.")
        }
        return url
    }
}

struct SonyDescriptor {
    let model: String
    let endpoint: URL
    let liveURL: URL?
    static func parse(_ data: Data,host: String) throws -> Self {
        guard data.count <= 512*1024 else { throw SonyRemoteError(message:"Camera descriptor is too large.") }
        let delegate = DescriptorParser()
        let parser = XMLParser(data:data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), let base = delegate.cameraURL.flatMap(URL.init(string:)) else {
            throw SonyRemoteError(message:"This camera mode did not advertise Sony ScalarWebAPI. PTP/IP support is a separate integration; iPhone preview will not be substituted.")
        }
        let endpoint = base.lastPathComponent == "camera" ? base : base.appendingPathComponent("camera")
        let live = try delegate.liveURL.flatMap { text -> URL? in
            guard let url = URL(string:text) else { return nil }; return try SonyEndpoint.validate(url,host:host)
        }
        return try Self(model:delegate.model ?? "Model not reported",endpoint:SonyEndpoint.validate(endpoint,host:host),liveURL:live)
    }
    private final class DescriptorParser: NSObject,XMLParserDelegate {
        var model: String?, cameraURL: String?, liveURL: String?
        private var element = "", text = "", service = "", action = ""
        func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
            element = name.components(separatedBy:":").last ?? name; text = ""
            if element == "X_ScalarWebAPI_Service" { service = ""; action = "" }
        }
        func parser(_ parser:XMLParser,foundCharacters value:String) { text += value }
        func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?) {
            let tag = name.components(separatedBy:":").last ?? name
            let value = text.trimmingCharacters(in:.whitespacesAndNewlines)
            switch tag {
            case "modelName": model = value.isEmpty ? nil : value
            case "X_ScalarWebAPI_ServiceType": service = value
            case "X_ScalarWebAPI_ActionList_URL": action = value
            case "X_ScalarWebAPI_LiveView_URL": liveURL = value.isEmpty ? nil : value
            case "X_ScalarWebAPI_Service": if service == "camera" && !action.isEmpty { cameraURL = action }
            default: break
            }
            text = ""
        }
    }
}

/// A bounded, incremental JPEG reader. Segment lengths skip APP/EXIF data
/// (which can contain a thumbnail's own SOI/EOI); entropy stuffing/restarts and
/// progressive scans are handled before accepting the outer EOI.
struct SonyJPEGFrameScanner {
    enum Result { case incomplete, complete(Int), invalid(Int) }
    private var cursor = 2
    private var entropy = false
    mutating func reset() { cursor = 2; entropy = false }
    mutating func scan(_ bytes: Data) -> Result {
        guard bytes.count >= 2, bytes[0] == 0xff, bytes[1] == 0xd8 else { return .invalid(1) }
        while cursor < bytes.count {
            if entropy {
                while cursor < bytes.count && bytes[cursor] != 0xff { cursor += 1 }
                if cursor == bytes.count { return .incomplete }
            }
            guard bytes[cursor] == 0xff else { return .invalid(cursor + 1) }
            let start = cursor
            var markerIndex = cursor + 1
            while markerIndex < bytes.count && bytes[markerIndex] == 0xff { markerIndex += 1 }
            guard markerIndex < bytes.count else { return .incomplete }
            let marker = bytes[markerIndex]
            if marker == 0xd9 { return .complete(markerIndex + 1) }
            if marker == 0xd8 { return .invalid(start) } // A newer frame can recover a truncated one.
            if entropy && (marker == 0 || (0xd0...0xd7).contains(marker)) {
                cursor = markerIndex + 1; continue
            }
            if marker == 0 { return .invalid(markerIndex + 1) }
            if marker == 1 || (0xd0...0xd7).contains(marker) { cursor = markerIndex + 1; continue }
            guard markerIndex + 2 < bytes.count else { return .incomplete }
            let length = Int(bytes[markerIndex + 1]) << 8 | Int(bytes[markerIndex + 2])
            guard length >= 2 else { return .invalid(markerIndex + 3) }
            let end = markerIndex + 1 + length
            guard end <= bytes.count else { return .incomplete }
            cursor = end
            entropy = marker == 0xda || (entropy && marker == 0xdc)
        }
        return .incomplete
    }
}

/// Scalar packets and marker-framed JPEG streams share the same decoder.
/// Binary camera wrappers/padding are not assumed to be JPEG image bytes.
struct SonyLiveViewParser {
    private var buffer = Data()
    private var scanner = SonyJPEGFrameScanner()
    private var payloadRemaining: Int?
    private var packetPadding = 0
    private var skipTrailer = 0
    private(set) var discardedFrames = 0
    private(set) var metadataPackets = 0
    private(set) var imageFrames = 0
    private(set) var framing = "detecting"
    private let maximumFrame = 4 * 1024 * 1024
    private let soi = Data([0xff, 0xd8])

    mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        guard buffer.count <= 8 * 1024 * 1024 else { throw SonyRemoteError(message: "Sony live-view data exceeded the buffer limit.") }
        var frames = [Data]()
        while !buffer.isEmpty {
            if skipTrailer > 0 {
                let count = min(skipTrailer, buffer.count)
                skipTrailer -= count; discard(count)
                continue
            }
            if isPacket(at: 0) {
                guard buffer.count >= 136 else { break }
                let size = Int(buffer[12]) << 16 | Int(buffer[13]) << 8 | Int(buffer[14])
                let bufferHeaderPadding = buffer[15]
                guard size <= maximumFrame else { throw SonyRemoteError(message: "Sony live-view frame is too large.") }
                framing = "Sony packets"
                if buffer[1] == 2 {
                    let total = 136 + size + Int(buffer[15])
                    guard buffer.count >= total else { break }
                    payloadRemaining = nil; packetPadding = 0
                    discard(total); metadataPackets += 1; continue
                }
                // JPEG itself determines its end. A packet may include wrapper
                // bytes, alignment, or a misleading declared payload length.
                discard(136); payloadRemaining = size; packetPadding = Int(bufferHeaderPadding)
                continue
            }
            let imageStart = buffer.range(of: soi)?.lowerBound
            let packetStart = nextPacket(before: imageStart)
            if let packetStart { discard(packetStart); continue }
            guard let imageStart else {
                // Preserve enough bytes for a split 12-byte packet signature or SOI.
                if buffer.count > 11 { discard(buffer.count - 11) }
                break
            }
            if imageStart > 0 { discard(imageStart); continue }
            if framing == "detecting" { framing = "JPEG markers" }
            switch scanner.scan(buffer) {
            case .incomplete:
                guard buffer.count <= maximumFrame else { throw SonyRemoteError(message: "Sony JPEG exceeded the frame limit before completing.") }
                return frames
            case .complete(let end):
                guard end <= maximumFrame else { throw SonyRemoteError(message: "Sony JPEG exceeded the frame limit.") }
                frames.append(Data(buffer.prefix(end))); imageFrames += 1; discard(end)
                if let remaining = payloadRemaining, remaining >= 0 { skipTrailer = remaining + packetPadding }
                payloadRemaining = nil; packetPadding = 0
            case .invalid(let offset):
                discardedFrames += 1; payloadRemaining = nil; packetPadding = 0
                discard(max(2, offset))
            }
        }
        return frames
    }
    private func isPacket(at index: Int) -> Bool {
        guard index >= 0, index + 12 <= buffer.count else { return false }
        return buffer[index] == 0xff && (buffer[index + 1] == 1 || buffer[index + 1] == 2)
            && buffer[index + 8] == 0x24 && buffer[index + 9] == 0x35
            && buffer[index + 10] == 0x68 && buffer[index + 11] == 0x79
    }
    private func nextPacket(before imageStart: Int?) -> Int? {
        let end = min(imageStart ?? buffer.count, max(0, buffer.count - 11))
        guard end > 0 else { return nil }
        for index in 0..<end { if isPacket(at: index) { return index } }
        return nil
    }
    private mutating func discard(_ count: Int) {
        let removed = min(count, buffer.count)
        if let remaining = payloadRemaining { payloadRemaining = remaining - removed }
        buffer = Data(buffer.dropFirst(removed)); scanner.reset()
    }
}

struct SonyEventValues {
    static func telemetry(_ result:[Any]) -> CameraTelemetry {
        var telemetry = CameraTelemetry()
        func walk(_ value:Any) {
            if let array = value as? [Any] { array.forEach(walk) }
            else if let item = value as? [String:Any], let type = item["type"] as? String {
                func text(_ key:String) -> String? {
                    if let value = item[key] as? String,!value.isEmpty { return value }
                    if let value = item[key] as? NSNumber { return value.stringValue }
                    return nil
                }
                switch type {
                case "exposureMode": telemetry.mode = text("currentExposureMode")
                case "shutterSpeed": telemetry.shutter = text("currentShutterSpeed")
                case "isoSpeedRate": telemetry.iso = text("currentIsoSpeedRate")
                case "fNumber": telemetry.aperture = text("currentFNumber")
                case "exposureCompensation":
                    if let index = SonySettingParser.integer(item["currentExposureCompensation"]) {
                        telemetry.ev = SonySettingValue.ev(index:index,step:SonySettingParser.integer(item["stepIndexOfExposureCompensation"]))
                    }
                default: break
                }
            }
        }
        result.forEach(walk); return telemetry
    }
}
