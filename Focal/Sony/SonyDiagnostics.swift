import Foundation

/// Bounded structured local diagnostics. No preview pixels or photo URLs.
final class SonyDiagnostics: @unchecked Sendable {
    struct Entry: Codable { let time:Date; let event:String; let fields:[String:String] }
    private let lock = NSLock()
    private var entries = [Entry]()
    func record(_ event:String,_ fields:[String:String] = [:]) {
        let bounded = fields.mapValues { String($0.prefix(1500)) }
        lock.lock(); defer { lock.unlock() }
        entries.append(.init(time:Date(),event:event,fields:bounded))
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
