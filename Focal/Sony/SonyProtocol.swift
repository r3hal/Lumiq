import Foundation
import ImageIO

struct SonyRemoteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Only the manually selected local camera may supply control, stream or photo URLs.
enum SonyEndpoint {
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

/// Sony live-view common header (8), payload header (128), JPEG and padding.
struct SonyLiveViewParser {
    private var buffer = Data()
    mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        guard buffer.count <= 8*1024*1024 else { throw SonyRemoteError(message:"Sony live-view data exceeded the buffer limit.") }
        var frames = [Data]()
        while buffer.count >= 136 {
            if buffer[0] != 0xff || ![1,2].contains(buffer[1]) || Array(buffer[8..<12]) != [0x24,0x35,0x68,0x79] {
                var next: Int?
                if buffer.count > 136 {
                    for i in 1...(buffer.count-136) {
                        if buffer[i] == 0xff && [1,2].contains(buffer[i+1]) && Array(buffer[i+8..<i+12]) == [0x24,0x35,0x68,0x79] { next = i; break }
                    }
                }
                if let next { buffer = Data(buffer.dropFirst(next)); continue }
                buffer = Data(buffer.suffix(135)); break
            }
            let size = Int(buffer[12])<<16 | Int(buffer[13])<<8 | Int(buffer[14])
            let padding = Int(buffer[15]), total = 136+size+padding
            guard size <= 4*1024*1024 else { throw SonyRemoteError(message:"Sony live-view frame is too large.") }
            guard buffer.count >= total else { break }
            if buffer[1] == 1 {
                let jpeg = Data(buffer[136..<136+size])
                guard jpeg.count >= 4,jpeg.prefix(2) == Data([0xff,0xd8]),jpeg.suffix(2) == Data([0xff,0xd9]) else {
                    throw SonyRemoteError(message:"Sony sent an invalid live-view JPEG.")
                }
                frames.append(jpeg)
            }
            buffer = Data(buffer.dropFirst(total))
        }
        return frames
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
                    // Sony often reports a step index, not EV. Zero is unambiguous;
                    // nonzero remains unknown until a verified conversion is available.
                    if let value = item["currentExposureCompensation"] as? NSNumber,value.doubleValue == 0 { telemetry.ev = 0 }
                default: break
                }
            }
        }
        result.forEach(walk); return telemetry
    }
}
