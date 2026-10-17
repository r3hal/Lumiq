import Foundation

enum BackupProblem: String, Codable, Error, Sendable {
    case offline, temporaryService, quota, authorization, ownerAuthorization, destinationMismatch, integrity
    case missingOriginal, storage, ownerStorage, queueFull, invalidResponse, permission, cancelled, configuration
    var explanation:String {
        switch self {
        case .offline: return "Waiting for an internet connection. Originals remain on this iPhone."
        case .temporaryService: return "Google Drive is temporarily unavailable. Backup will retry."
        case .quota: return "Google Drive storage or quota is full. Free space, then retry."
        case .ownerAuthorization: return "The backup owner must reconnect Google Drive on the server. No Google login is needed on this iPhone."
        case .authorization: return "Reconnect this device to the owner backup server to resume."
        case .destinationMismatch: return "These photos belong to a different backup destination. Reconnect the original destination to resume."
        case .integrity: return "File verification failed. The local original has been preserved."
        case .missingOriginal: return "An original is no longer available locally. Other photos are preserved."
        case .storage: return "Not enough available iPhone staging space. Free space, then retry."
        case .ownerStorage: return "The owner backup server has reached its storage limit. Ask the owner to free server space, then retry."
        case .queueFull: return "The backup queue has reached its safety limit. Finish pending backups or remove confirmed backed-up photos from the local library, then retry."
        case .invalidResponse: return "Google Drive returned an unexpected response. No backup was marked complete."
        case .permission: return "The backup server refused this operation. Ask the owner to check this device authorization."
        case .cancelled: return "Backup is paused."
        case .configuration: return "Connect an owner backup server in Settings first."
        }
    }
    static func safe(_ error:Error) -> Self {
        if let problem = error as? Self { return problem }
        let e = error as NSError
        if e.domain == NSURLErrorDomain {
            if e.code == URLError.cancelled.rawValue { return .cancelled }
            return .offline
        }
        if e.domain == NSCocoaErrorDomain {
            if e.code == CocoaError.fileReadNoSuchFile.rawValue || e.code == CocoaError.fileNoSuchFile.rawValue { return .missingOriginal }
            return .storage
        }
        return .temporaryService
    }
}

struct BackupDestination: Codable, Equatable, Sendable {
    let id:String // Immutable owner destination, supplied by the authenticated backend.
    let deviceID:String
    let label:String
    let server:URL
}

struct BackupEnrollment: Codable, Equatable, Sendable {
    let destinationID:String
    let deviceID:String
    let server:URL
    let datePath:String // Capture-local calendar date, fixed before local manifest commit.
    let sources:[BackupSource]
    static func day(_ date:Date,timeZone:TimeZone = .current) -> String {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year,.month,.day],from:date)
        return String(format:"%04d/%02d/%02d",c.year ?? 1970,c.month ?? 1,c.day ?? 1)
    }
    static func validDay(_ value:String) -> Bool {
        guard value.range(of:"^[0-9]{4}/[0-9]{2}/[0-9]{2}$",options:.regularExpression) != nil else { return false }
        let parts = value.split(separator:"/").compactMap{Int($0)}
        return parts.count == 3 && (1...12).contains(parts[1]) && (1...31).contains(parts[2])
    }
}

struct BackupSource: Codable, Equatable, Sendable {
    enum Role:String,Codable,Sendable { case photo, original, raw, scan, widePreview, metadata }
    let role:Role
    let filename:String
    var mimeType:String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "heic", "heif": return "image/heic"
        case "dng": return "image/x-adobe-dng"
        case "json": return "application/json"
        default: return "image/jpeg"
        }
    }
    static func safeFilename(_ value:String) -> Bool {
        !value.isEmpty && value.utf8.count <= 220 && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
            && !value.unicodeScalars.contains{CharacterSet.controlCharacters.contains($0)}
    }
}

struct BackupCapture: Sendable {
    let id:UUID
    let createdAt:Date
    let enrollment:BackupEnrollment
    let metadata:Data
}

enum BackupJobState:String,Codable,Sendable {
    case queued, preparing, uploading, verifying, retry, failed, complete
}

struct BackupJob: Codable, Equatable, Sendable, Identifiable {
    let id:String
    let destinationID:String
    let deviceID:String
    let server:URL
    let captureID:UUID
    let createdAt:Date
    let datePath:String
    let source:BackupSource
    var inlineMetadata:Data?
    var state:BackupJobState = .queued
    var size:Int64?
    var sha256:String?
    var remoteID:String?
    var offset:Int64 = 0
    var operationID:UUID?
    var attempts = 0
    var nextAttempt:Date = .distantPast
    var problem:BackupProblem?
    var completedAt:Date?
    var needsStatusProbe = false
}

struct BackupQueue: Codable, Sendable {
    var version = 1
    var destination:BackupDestination?
    var enabled = false
    var revision = 0
    var jobs:[BackupJob] = []
    var problem:BackupProblem?
    static let maximumJobs = 20_000
    static let maximumPending = 5_000
    static let maximumManifestBytes = 32*1024*1024
    static let maximumStagingBytes:Int64 = 64*1024*1024
    static let freeSpaceReserve:Int64 = 256*1024*1024
    static let chunkBytes:Int64 = 4*1024*1024 // Bounded background file transfers.
    func eligible(_ job:BackupJob,at now:Date) -> Bool {
        enabled && job.destinationID == destination?.id && job.deviceID == destination?.deviceID && job.server == destination?.server && [.queued,.retry,.preparing,.verifying].contains(job.state) && job.nextAttempt <= now
    }
    var summary:BackupSummary {
        let own = jobs.filter{$0.destinationID == destination?.id && $0.deviceID == destination?.deviceID && $0.server == destination?.server}
        return .init(destination:destination,enabled:enabled,
            pending:own.filter{$0.state != .complete && $0.state != .failed}.count,
            failed:own.filter{$0.state == .failed}.count,
            otherDestinationPending:jobs.filter{($0.destinationID != destination?.id || $0.deviceID != destination?.deviceID || $0.server != destination?.server) && $0.state != .complete}.count,
            lastSuccess:own.compactMap(\.completedAt).max(),problem:problem ?? own.first(where:{$0.problem != nil && $0.state != .complete})?.problem)
    }
}

struct BackupSummary:Equatable,Sendable {
    var destination:BackupDestination?
    var enabled = false
    var pending = 0
    var failed = 0
    var otherDestinationPending = 0
    var lastSuccess:Date?
    var problem:BackupProblem?
}

enum BackupRetry {
    static let maximumAttempts = 8
    static func delay(attempt:Int,retryAfter:TimeInterval? = nil) -> TimeInterval {
        let exponential = min(21_600,30*pow(2,Double(max(0,min(10,attempt-1)))))
        return min(86_400,max(exponential,retryAfter.flatMap{$0.isFinite && $0 >= 0 ? $0 : nil} ?? 0))
    }
    static func retryable(_ problem:BackupProblem) -> Bool { [.offline,.temporaryService,.storage,.ownerStorage,.cancelled].contains(problem) }
}

struct BackupHTTPResult:Sendable {
    let status:Int
    let headers:[String:String]
    let data:Data
    init(status:Int,headers:[String:String] = [:],data:Data = Data()) {
        self.status = status; self.headers = Dictionary(headers.map{($0.key.lowercased(),$0.value)},uniquingKeysWith:{$1}); self.data = data
    }
}

enum OwnerBackupURLs {
    static func validServer(_ url:URL) -> Bool {
        guard url.scheme == "https",let host = url.host,!host.isEmpty,
              url.user == nil,url.password == nil,url.query == nil,url.fragment == nil,
              url.port == nil || url.port == 443,url.path.isEmpty || url.path == "/" else { return false }
        return host != "localhost" && host != "127.0.0.1" && host != "::1"
    }
    static func permitted(_ url:URL,server:URL) -> Bool {
        validServer(server) && url.scheme == "https" && url.host == server.host && url.port == server.port
            && url.user == nil && url.password == nil && url.fragment == nil && url.query == nil && url.path.hasPrefix("/v1/")
    }
    static func validID(_ value:String) -> Bool { value.range(of:"^[A-Za-z0-9_-]{1,128}$",options:.regularExpression) != nil }
}
