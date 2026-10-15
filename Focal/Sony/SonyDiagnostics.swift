import Foundation

/// Bounded structured local diagnostics. No preview pixels or photo URLs.
final class SonyDiagnostics: @unchecked Sendable {
    struct Entry: Codable { let time:Date; let event:String; let fields:[String:String] }
    private let lock = NSLock()
    private var entries = [Entry]()
    private static func sanitized(_ value:String) -> String {
        var text = value.replacingOccurrences(of:#"(?i)https?://[^\s\"<>]+"#,with:"[camera URL]",options:.regularExpression)
        text = text.replacingOccurrences(of:#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,with:"[address]",options:.regularExpression)
        text = text.replacingOccurrences(of:#"(?i)(password|ssid|authorization|token|cookie)["\']?\s*[:=]\s*(?:"[^"]*"|\'[^\']*\'|[^\s,;]+)"#,with:"$1=[redacted]",options:.regularExpression)
        return String(text.prefix(1500))
    }
    func record(_ event:String,_ fields:[String:String] = [:]) {
        let privateKeys = Set(["host","url","ssid","password","authorization","token","cookie"])
        let bounded = fields.map { key,value in (key,privateKeys.contains(key.lowercased()) ? "[redacted]" : Self.sanitized(value)) }
        lock.lock(); defer { lock.unlock() }
        entries.append(.init(time:Date(),event:event,fields:Dictionary(uniqueKeysWithValues:bounded)))
        if entries.count > 400 { entries.removeFirst(entries.count-400) }
    }
    func export() throws -> URL {
        lock.lock(); let copy = entries; lock.unlock()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Focal-Sony-\(UUID().uuidString).json")
        try encoder.encode(copy).write(to:url,options:.atomic)
        return url
    }
}
