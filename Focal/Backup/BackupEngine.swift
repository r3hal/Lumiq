import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct BackupTransfer:Sendable {
    let resourceID:String
    let operationID:UUID
    let revision:Int
    let request:URLRequest
    let file:URL
    var tag:String { resourceID+"|"+operationID.uuidString+"|"+String(revision) }
}
protocol BackupTransferTransport:Sendable {
    func start(_ transfer:BackupTransfer) async throws
    func activeTags() async -> Set<String>
    func cancelAll() async
}

/// One durable state machine for capture enrollment, resumable device uploads
/// and owner-Drive receipt verification. It never imports or controls a camera.
actor BackupEngine {
    private let disk:BackupDiskStore
    private let api:OwnerBackupAPI
    private let transfers:any BackupTransferTransport
    private var state = BackupQueue()
    private var loaded = false
    private var usable = true
    private var running = false
    private var runAgain = false
    private var removedCaptures = Set<UUID>()
    private var onChange:(@Sendable(BackupSummary) -> Void)?
    init(disk:BackupDiskStore,api:OwnerBackupAPI,transfers:any BackupTransferTransport) {
        self.disk = disk;self.api = api;self.transfers = transfers
    }
    func observe(_ handler:@escaping @Sendable(BackupSummary)->Void) { onChange = handler;publish() }
    func summary() -> BackupSummary { state.summary }
    func snapshot() -> BackupQueue { state }
    func bootstrap() async {
        guard !loaded else { return };loaded = true
        do {
            state = try disk.load();publish()
            let active = await transfers.activeTags()
            let expected = Set(state.jobs.filter{state.enabled && $0.state == .uploading && $0.destinationID == state.destination?.id && $0.deviceID == state.destination?.deviceID && $0.server == state.destination?.server}.compactMap{job in job.operationID.map{job.id+"|"+$0.uuidString+"|"+String(state.revision)}})
            let unexpected = !active.subtracting(expected).isEmpty
            if unexpected { await transfers.cancelAll() }
            for i in state.jobs.indices {
                let job = state.jobs[i]
                let tag = job.operationID.map{job.id+"|"+$0.uuidString+"|"+String(state.revision)}
                if job.state == .uploading,(unexpected || tag.map({active.contains($0)}) != true) {
                    state.jobs[i].state = .retry;state.jobs[i].operationID = nil
                    state.jobs[i].needsStatusProbe = true
                } else if job.state == .preparing { state.jobs[i].state = .retry }
            }
            try disk.cleanUnreferenced(keeping:Set(state.jobs.filter{$0.state != .complete}.map(\.id)))
            try save()
        } catch { usable = false;state.problem = BackupProblem.safe(error);publish() }
    }
    func connect(_ destination:BackupDestination) async throws {
        guard usable,OwnerBackupURLs.validServer(destination.server) else { throw BackupProblem.configuration }
        // Invalidate the persisted generation BEFORE cancelling asynchronous work.
        state.revision += 1;state.enabled = false;state.destination = destination;state.problem = nil;state.authorizationPaused = false
        for i in state.jobs.indices where state.jobs[i].state == .uploading || state.jobs[i].state == .preparing {
            state.jobs[i].state = .retry;state.jobs[i].operationID = nil;state.jobs[i].needsStatusProbe = true
        }
        do { try save() } catch { await failClosed(destination);throw error };await transfers.cancelAll()
    }
    func enable(_ enabled:Bool) async throws {
        guard usable,state.destination != nil else { throw BackupProblem.configuration }
        state.revision += 1;state.enabled = enabled;state.problem = nil
        if enabled { state.authorizationPaused = false }
        for i in state.jobs.indices where state.jobs[i].state == .uploading || state.jobs[i].state == .preparing {
            state.jobs[i].state = .retry;state.jobs[i].operationID = nil;state.jobs[i].needsStatusProbe = true
        }
        do { try save() } catch { await failClosed(state.destination);throw error };await transfers.cancelAll()
        if enabled { await pump() }
    }
    func disconnect() async throws {
        guard usable else { throw BackupProblem.integrity }
        let destination = state.destination
        state.revision += 1;state.enabled = false;state.destination = nil
        for i in state.jobs.indices where state.jobs[i].state == .uploading || state.jobs[i].state == .preparing {
            state.jobs[i].state = .retry;state.jobs[i].operationID = nil;state.jobs[i].needsStatusProbe = true
        }
        do { try save() } catch { await failClosed(destination);throw error };await transfers.cancelAll()
        if let destination { await api.credentials.remove(for:destination) }
    }
    func enroll(_ capture:BackupCapture) {
        guard loaded,usable,!removedCaptures.contains(capture.id),OwnerBackupURLs.validServer(capture.enrollment.server),BackupEnrollment.validDay(capture.enrollment.datePath) else { return }
        let old = state
        let sources = capture.enrollment.sources+[BackupSource(role:.metadata,filename:capture.id.uuidString.lowercased()+".focal.json")]
        let additions = sources.filter{source in !state.jobs.contains{$0.id == Self.resourceID(capture.id,source.role)}}
        guard !additions.isEmpty else { return }
        guard state.jobs.count+additions.count <= BackupQueue.maximumJobs,
              state.jobs.filter({$0.state != .complete}).count+additions.count <= BackupQueue.maximumPending else {
            state.problem = .queueFull;try? save();return
        }
        for source in additions {
            guard BackupSource.safeFilename(source.filename) else { state.problem = .integrity;publish();return }
            state.jobs.append(.init(id:Self.resourceID(capture.id,source.role),destinationID:capture.enrollment.destinationID,
                deviceID:capture.enrollment.deviceID,server:capture.enrollment.server,captureID:capture.id,createdAt:capture.createdAt,datePath:capture.enrollment.datePath,
                source:source,inlineMetadata:source.role == .metadata ? capture.metadata : nil))
        }
        if state.problem == .queueFull { state.problem = nil }
        do { try save() } catch { state = old;state.problem = BackupProblem.safe(error);publish() }
    }
    static func resourceID(_ capture:UUID,_ role:BackupSource.Role) -> String { capture.uuidString.lowercased()+"-"+role.rawValue }
    func removeCapture(_ id:UUID) async {
        removedCaptures.insert(id) // Reject a delayed post-save handoff after local deletion.
        let affected = state.jobs.filter{$0.captureID == id}
        let hadActive = affected.contains{$0.state == .uploading}
        if hadActive {
            state.revision += 1
            for i in state.jobs.indices where state.jobs[i].state == .uploading {
                state.jobs[i].state = .retry;state.jobs[i].operationID = nil;state.jobs[i].needsStatusProbe = true
            }
        }
        state.jobs.removeAll{$0.captureID == id}
        do { try save() } catch { state.problem = .storage;publish() }
        if hadActive { await transfers.cancelAll() }
        for job in affected { disk.clean(job.id) }
    }
    func reconcile(_ captures:[BackupCapture]) async {
        guard loaded,usable else { return }
        let valid = Set(captures.map(\.id))
        for id in Set(state.jobs.filter{!valid.contains($0.captureID)}.map(\.captureID)) { await removeCapture(id) }
        for capture in captures { enroll(capture) }
        await pump()
    }
    /// A fresh network opportunity releases only connectivity failures, never
    /// revoked grants, quota, integrity errors, or another destination's queue.
    func networkRestored() async {
        guard loaded,usable,let destination = state.destination else { return }
        var changed = false
        for i in state.jobs.indices {
            let job = state.jobs[i]
            guard job.destinationID == destination.id,job.deviceID == destination.deviceID,job.server == destination.server,
                  job.problem == .offline,[BackupJobState.failed,.retry].contains(job.state) else { continue }
            state.jobs[i].state = .retry;state.jobs[i].attempts = 0;state.jobs[i].problem = nil
            state.jobs[i].nextAttempt = .distantPast;state.jobs[i].needsStatusProbe = true;changed = true
        }
        if changed {
            do { try save() } catch { state.problem = .storage;publish();return }
        }
        await pump()
    }
    func retryFailed() async {
        guard let destination = state.destination,usable else { return }
        let revision = state.revision
        state.authorizationPaused = false;state.problem = nil
        let failed = state.jobs.filter{$0.state == .failed && $0.destinationID == destination.id && $0.deviceID == destination.deviceID && $0.server == destination.server}
        for job in failed {
            do {
                if job.sha256 != nil { try await api.retry(job,destination:destination) }
                guard revision == state.revision else { return }
                if let i = state.jobs.firstIndex(where:{$0.id == job.id}) {
                    state.jobs[i].state = .retry;state.jobs[i].attempts = 0;state.jobs[i].problem = nil
                    state.jobs[i].nextAttempt = .distantPast;state.jobs[i].needsStatusProbe = true
                }
            } catch {
                state.problem = Self.problem(error);publish()
                if state.problem == .authorization || state.problem == .destinationMismatch {
                    state.authorizationPaused = true;try? save();return
                }
            }
        }
        try? save();await pump()
    }
    func pump(now:Date = Date()) async {
        guard loaded,usable,state.enabled,state.authorizationPaused != true,let destination = state.destination else { return }
        if running { runAgain = true;return };running = true
        defer { running = false;if runAgain { runAgain = false;Task{await self.pump()} } }
        // One file transfer at a time. Receipt polling cannot starve new captures.
        guard !state.jobs.contains(where:{$0.state == .uploading}) else { return }
        let candidates = state.jobs.indices.filter{state.eligible(state.jobs[$0],at:now)}
        guard let index = candidates.first(where:{state.jobs[$0].state != .verifying}) ?? candidates.first else { return }
        let id = state.jobs[index].id,revision = state.revision
        state.jobs[index].state = state.jobs[index].state == .verifying ? .verifying : .preparing
        state.jobs[index].operationID = nil
        do {
            try save()
            var job = state.jobs[index]
            if job.size == nil || job.sha256 == nil {
                let facts = try disk.measuredSource(job)
                job.size = facts.1;job.sha256 = facts.2;try replace(job,revision:revision)
            }
            let status:BackendResourceStatus
            if job.needsStatusProbe || job.state == .verifying {
                do { status = try await api.resource(job,destination:destination) }
                catch let error as BackupWireFailure where error.problem == .missingOriginal {
                    status = try await api.reserve(job,destination:destination)
                }
            } else { status = try await api.reserve(job,destination:destination) }
            guard context(revision,destination:destination),state.jobs.contains(where:{$0.id == id}) else { return }
            try apply(status,to:&job,now:now)
            if job.state == .complete || job.state == .verifying || job.state == .failed {
                try replace(job,revision:revision);if job.state == .complete { disk.clean(job.id) }
                runAgain = true;return
            }
            let source = job.inlineMetadata != nil ? try disk.measuredSource(job).0 : try disk.source(job)
            let chunk = try disk.makeChunk(job:job,source:source)
            let bytes = min(BackupQueue.chunkBytes,(job.size ?? 0)-job.offset)
            let request = try await api.uploadRequest(job,destination:destination,bytes:bytes)
            guard context(revision,destination:destination),state.jobs.contains(where:{$0.id == id}) else { disk.clean(id);return }
            let operation = UUID();job.state = .uploading;job.operationID = operation;job.problem = nil
            try replace(job,revision:revision) // Durable intent exists before URLSession creation.
            try await transfers.start(.init(resourceID:id,operationID:operation,revision:revision,request:request,file:chunk))
        } catch {
            guard revision == state.revision else { return }
            fail(id,error:error,now:now);runAgain = true
        }
    }
    func completed(tag:String,result:BackupHTTPResult?,problem:BackupProblem?,now:Date = Date()) async {
        let parts = tag.split(separator:"|").map(String.init)
        guard parts.count == 3,let revision = Int(parts[2]),revision == state.revision,
              let index = state.jobs.firstIndex(where:{$0.id == parts[0]}),
              state.jobs[index].operationID?.uuidString == parts[1],state.jobs[index].state == .uploading else { return }
        let id = state.jobs[index].id
        do {
            if let problem { throw problem }
            guard let result else { throw BackupProblem.invalidResponse }
            try OwnerBackupAPI.check(result)
            let status = try OwnerBackupAPI.decode(BackendResourceStatus.self,result.data)
            var job = state.jobs[index];try status.verify(job);try apply(status,to:&job,now:now)
            job.operationID = nil;try replace(job,revision:revision);disk.clean(id)
        } catch { fail(id,error:error,now:now) }
        Task { await self.pump(now:now) }
    }
    private func apply(_ status:BackendResourceStatus,to job:inout BackupJob,now:Date) throws {
        try status.verify(job);job.offset = status.offset;job.needsStatusProbe = false;job.problem = nil;job.attempts = 0
        switch status.state {
        case "complete": job.state = .complete;job.remoteID = status.driveFileId;job.completedAt = now;job.inlineMetadata = nil
        case "pendingDrive", "uploadingDrive":
            job.state = .verifying;job.nextAttempt = now.addingTimeInterval(60)
            if status.error == "owner_authorization" { job.problem = .ownerAuthorization }
            else if status.error == "drive_quota" { job.problem = .quota }
        case "uploading":
            guard status.offset < status.size else { throw BackupProblem.invalidResponse }
            job.state = .queued;job.nextAttempt = .distantPast
        case "failed": job.state = .failed;job.problem = status.error == "integrity" ? .integrity : status.error == "drive_quota" ? .quota : status.error == "owner_storage" ? .ownerStorage : .temporaryService
        default: throw BackupProblem.invalidResponse
        }
    }
    private func failClosed(_ destination:BackupDestination?) async {
        usable = false;state.enabled = false;state.problem = .storage;publish()
        await transfers.cancelAll()
        // If opt-out cannot persist, destroy the credential too. An old on-disk
        // enabled flag must not silently regain upload access after restart.
        if let destination { await api.credentials.remove(for:destination) }
    }
    private func context(_ revision:Int,destination:BackupDestination) -> Bool {
        revision == state.revision && state.enabled && state.destination == destination
    }
    private func replace(_ job:BackupJob,revision:Int) throws {
        guard revision == state.revision,let index = state.jobs.firstIndex(where:{$0.id == job.id}) else { throw BackupProblem.cancelled }
        state.jobs[index] = job;try save()
    }
    private func fail(_ id:String,error:Error,now:Date) {
        guard let index = state.jobs.firstIndex(where:{$0.id == id}) else { return }
        let problem = Self.problem(error)
        if problem == .authorization || problem == .destinationMismatch { state.problem = problem;state.authorizationPaused = true }
        state.jobs[index].operationID = nil;state.jobs[index].problem = problem;state.jobs[index].needsStatusProbe = true
        state.jobs[index].attempts += 1
        let retry = BackupRetry.retryable(problem) && state.jobs[index].attempts < BackupRetry.maximumAttempts
        state.jobs[index].state = retry ? .retry : .failed
        state.jobs[index].nextAttempt = now.addingTimeInterval(BackupRetry.delay(attempt:state.jobs[index].attempts,retryAfter:(error as? BackupWireFailure)?.retryAfter))
        do { try save() } catch { state.problem = .storage;publish() }
        disk.clean(id)
    }
    private static func problem(_ error:Error) -> BackupProblem { (error as? BackupWireFailure)?.problem ?? BackupProblem.safe(error) }
    private func save() throws { try disk.save(state);publish() }
    private func publish() { onChange?(state.summary) }
}
