import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(BackupTestCrypto)
import BackupTestCrypto
#endif

enum BackupHash {
    static func file(_ url:URL) throws -> (size:Int64,sha256:String) {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        var hash = SHA256(),size:Int64 = 0
        while let data = try handle.read(upToCount:65_536),!data.isEmpty { hash.update(data:data); size += Int64(data.count) }
        return (size,hash.finalize().map{String(format:"%02x",$0)}.joined())
        #elseif canImport(BackupTestCrypto)
        var bytes = [CChar](repeating:0,count:65),size:Int64 = 0
        guard focal_backup_hash_file(url.path,&bytes,&size) == 1 else { throw BackupProblem.missingOriginal }
        return (size,String(cString:bytes))
        #else
        throw BackupProblem.configuration
        #endif
    }
    static func token() -> String {
        var random = SystemRandomNumberGenerator()
        return Data((0..<32).map{_ in UInt8.random(in:0...255,using:&random)}).base64EncodedString()
            .replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    }
}

/// Used exclusively on the backup actor, not the camera/main queue.
struct BackupDiskStore {
    let root:URL
    let originals:URL
    var manifest:URL { root.appendingPathComponent("queue.json") }
    var staging:URL { root.appendingPathComponent("Staging",isDirectory:true) }
    func prepare() throws {
        try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true)
        #if os(iOS)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = root; try mutable.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:root.path)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:staging.path)
        #endif
    }
    func load() throws -> BackupQueue {
        try prepare()
        guard FileManager.default.fileExists(atPath:manifest.path) else { return BackupQueue() }
        let size = (try manifest.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
        guard size <= BackupQueue.maximumManifestBytes else { throw BackupProblem.queueFull }
        let state:BackupQueue
        do { state = try JSONDecoder().decode(BackupQueue.self,from:Data(contentsOf:manifest)) }
        catch { throw BackupProblem.integrity }
        guard state.version == 1,state.jobs.count <= BackupQueue.maximumJobs,
              Set(state.jobs.map(\.id)).count == state.jobs.count else { throw BackupProblem.integrity }
        return state
    }
    func save(_ state:BackupQueue) throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= BackupQueue.maximumManifestBytes else { throw BackupProblem.queueFull }
        #if os(iOS)
        try data.write(to:manifest,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to:manifest,options:.atomic)
        #endif
    }
    func source(_ job:BackupJob) throws -> URL {
        guard BackupSource.safeFilename(job.source.filename) else { throw BackupProblem.integrity }
        let url = originals.appendingPathComponent(job.source.filename)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == originals.resolvingSymlinksInPath().path else { throw BackupProblem.integrity }
        return url
    }
    func metadataURL(_ id:String) throws -> URL {
        guard OwnerBackupURLs.validID(id) else { throw BackupProblem.integrity }
        return staging.appendingPathComponent(id+".metadata")
    }
    func measuredSource(_ job:BackupJob) throws -> (URL,Int64,String) {
        let url:URL
        if let bytes = job.inlineMetadata {
            url = try metadataURL(job.id)
            try bytes.write(to:url,options:.atomic)
            try protect(url)
        } else { url = try source(job) }
        let facts = try BackupHash.file(url)
        guard facts.size > 0 else { throw BackupProblem.integrity }
        return (url,facts.size,facts.sha256)
    }
    func makeChunk(job:BackupJob,source:URL) throws -> URL {
        guard let total = job.size,job.offset >= 0,job.offset < total,OwnerBackupURLs.validID(job.id) else { throw BackupProblem.integrity }
        let length = min(BackupQueue.chunkBytes,total-job.offset)
        let attributes = try FileManager.default.attributesOfFileSystem(forPath:root.path)
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let staged = try FileManager.default.contentsOfDirectory(at:staging,includingPropertiesForKeys:[.fileSizeKey])
            .reduce(Int64(0)){$0+Int64((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)}
        guard free-length >= BackupQueue.freeSpaceReserve,staged+length <= BackupQueue.maximumStagingBytes else { throw BackupProblem.storage }
        let input = try FileHandle(forReadingFrom:source); defer { try? input.close() }
        try input.seek(toOffset:UInt64(job.offset))
        guard let bytes = try input.read(upToCount:Int(length)),bytes.count == Int(length) else { throw BackupProblem.integrity }
        let chunk = staging.appendingPathComponent(job.id+".chunk")
        try bytes.write(to:chunk,options:.atomic); try protect(chunk)
        return chunk
    }
    func clean(_ id:String) {
        guard OwnerBackupURLs.validID(id) else { return }
        for ext in ["chunk","metadata"] { try? FileManager.default.removeItem(at:staging.appendingPathComponent(id+"."+ext)) }
    }
    func cleanUnreferenced(keeping ids:Set<String>) throws {
        for url in try FileManager.default.contentsOfDirectory(at:staging,includingPropertiesForKeys:nil) {
            if !ids.contains(url.deletingPathExtension().lastPathComponent) { try? FileManager.default.removeItem(at:url) }
        }
    }
    private func protect(_ url:URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.path)
        #endif
    }
}
