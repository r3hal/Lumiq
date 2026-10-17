import Foundation
import Combine
import UIKit
import Network

@MainActor
protocol PhotoBackupRecording:AnyObject {
    func enrollment(for photo:SavedPhoto) -> BackupEnrollment?
    func saved(_ photo:SavedPhoto)
    func deleted(_ id:UUID)
}

@MainActor
final class PhotoBackupCoordinator:ObservableObject,PhotoBackupRecording {
    static let shared = PhotoBackupCoordinator()
    @Published private(set) var summary = BackupSummary()
    @Published private(set) var busy = false
    @Published private(set) var statusProblem:BackupProblem?
    @Published private(set) var ownerDriveConnected:Bool?
    private weak var library:PhotoLibrary?
    let background:BackupBackgroundSession
    private let credentials:BackupKeychain
    private let api:OwnerBackupAPI
    private let engine:BackupEngine
    private let monitor = NWPathMonitor()
    private var started = false
    private var timer:Task<Void,Never>?
    private var bootstrap:Task<Void,Never>?
    private init() {
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "Focal"
        let credentials = BackupKeychain(service:bundle+".owner-backup.device")
        let background = BackupBackgroundSession(identifier:bundle+".owner-backup.background.v1")
        let api = OwnerBackupAPI(http:EphemeralBackupHTTP(),credentials:credentials)
        let engine = BackupEngine(disk:.init(root:support.appendingPathComponent("FocalOwnerBackup",isDirectory:true),
            originals:support.appendingPathComponent("Focal",isDirectory:true)),api:api,transfers:background)
        self.credentials = credentials;self.background = background;self.api = api;self.engine = engine
        background.install { tag,result,problem in await engine.completed(tag:tag,result:result,problem:problem) }
    }
    func attach(_ library:PhotoLibrary) {
        self.library = library;library.backupCoordinator = self;start()
    }
    func start() {
        guard !started else { return };started = true
        let engine = self.engine
        bootstrap = Task(priority:.utility) {
            await engine.observe { [weak self] summary in Task { @MainActor in self?.summary = summary } }
            await engine.bootstrap()
        }
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                Task { @MainActor in
                    guard let self else { return }
                    await self.bootstrap?.value
                    await self.engine.networkRestored()
                    self.foreground()
                }
            }
        }
        monitor.start(queue:DispatchQueue(label:"Focal.backup.connectivity",qos:.utility))
    }
    func foreground() {
        start();timer?.cancel()
        let engine = self.engine
        timer = Task(priority:.utility) { [weak self] in
            await self?.bootstrap?.value
            if let photos = self?.library?.photos { await Self.reconcile(photos,engine:engine) }
            await self?.checkConnection()
            while !Task.isCancelled {
                await engine.pump()
                try? await Task.sleep(nanoseconds:15_000_000_000)
            }
        }
    }
    func backgrounded() { timer?.cancel();timer = nil }
    func connect(serverText:String,code:String) async {
        guard !busy else { return };busy = true;defer{busy = false}
        do {
            start();await bootstrap?.value
            guard var components = URLComponents(string:serverText.trimmingCharacters(in:.whitespacesAndNewlines)),
                  let supplied = components.url,OwnerBackupURLs.validServer(supplied) else { throw BackupProblem.configuration }
            components.path = "";if components.port == 443 { components.port = nil }
            guard let server = components.url else { throw BackupProblem.configuration }
            let (destination,token) = try await api.enroll(server:server,code:code.trimmingCharacters(in:.whitespacesAndNewlines))
            try await credentials.save(token,for:destination)
            try await engine.connect(destination)
            summary = await engine.summary()
            statusProblem = nil;await checkConnection()
        } catch { statusProblem = Self.problem(error) }
    }
    func setEnabled(_ enabled:Bool) async {
        guard !busy else { return };busy = true;defer{busy = false}
        do {
            await bootstrap?.value;try await engine.enable(enabled)
            summary = await engine.summary();statusProblem = nil
            if enabled,let library { await Self.reconcile(library.photos,engine:engine) }
        } catch { statusProblem = Self.problem(error) }
    }
    func disconnect() async {
        guard !busy else { return };busy = true;defer{busy = false}
        do { try await engine.disconnect();summary = await engine.summary();ownerDriveConnected = nil;statusProblem = nil }
        catch { statusProblem = Self.problem(error) }
    }
    func retry() async {
        guard !busy else { return };busy = true;defer{busy = false}
        await bootstrap?.value
        await engine.retryFailed()
        if let library { await Self.reconcile(library.photos,engine:engine) }
        await checkConnection()
    }
    private func checkConnection() async {
        let summary = await engine.summary()
        guard let destination = summary.destination else { return }
        do {
            let result = try await api.status(destination)
            guard (await engine.summary()).destination == destination else { return }
            ownerDriveConnected = result.driveConnected;statusProblem = result.driveConnected ? nil : .ownerAuthorization
        } catch { statusProblem = Self.problem(error) }
    }
    func enrollment(for photo:SavedPhoto) -> BackupEnrollment? {
        guard summary.enabled,let destination = summary.destination,!photo.isDemo,
              photo.cameraOrigin == CameraSource.iPhone.rawValue else { return nil }
        var sources = [BackupSource(role:.photo,filename:photo.filename)]
        if let filename = photo.originalFilename { sources.append(.init(role:.original,filename:filename)) }
        if let filename = photo.rawFilename { sources.append(.init(role:.raw,filename:filename)) }
        if let filename = photo.scanFilename { sources.append(.init(role:.scan,filename:filename)) }
        if let filename = photo.widePreviewFilename { sources.append(.init(role:.widePreview,filename:filename)) }
        return .init(destinationID:destination.id,deviceID:destination.deviceID,server:destination.server,
            datePath:BackupEnrollment.day(photo.createdAt),sources:sources)
    }
    /// Called only after all local bytes AND the library manifest have committed.
    /// Do not await hashing, network, staging or queue persistence on the shutter path.
    func saved(_ photo:SavedPhoto) {
        let engine = self.engine,ready = bootstrap
        Task.detached(priority:.utility) {
            await ready?.value
            guard let capture = Self.capture(photo) else { return }
            await engine.enroll(capture);await engine.pump()
        }
    }
    func deleted(_ id:UUID) { let engine = self.engine,ready = bootstrap;Task(priority:.utility){ await ready?.value;await engine.removeCapture(id) } }
    nonisolated static func capture(_ photo:SavedPhoto) -> BackupCapture? {
        guard let enrollment = photo.backupEnrollment,!photo.isDemo,photo.cameraOrigin == CameraSource.iPhone.rawValue else { return nil }
        var metadata = photo;metadata.backupEnrollment = nil // No enrollment/credential information in the Drive sidecar.
        guard let bytes = try? JSONEncoder().encode(metadata) else { return nil }
        return .init(id:photo.id,createdAt:photo.createdAt,enrollment:enrollment,metadata:bytes)
    }
    nonisolated private static func reconcile(_ photos:[SavedPhoto],engine:BackupEngine) async {
        await Task.detached(priority:.utility) { await engine.reconcile(photos.compactMap{capture($0)}) }.value
    }
    private static func problem(_ error:Error) -> BackupProblem { (error as? BackupWireFailure)?.problem ?? BackupProblem.safe(error) }
}

@MainActor
final class FocalBackupAppDelegate:NSObject,UIApplicationDelegate {
    func application(_ application:UIApplication,handleEventsForBackgroundURLSession identifier:String,completionHandler:@escaping()->Void) {
        let backup = PhotoBackupCoordinator.shared
        guard identifier == backup.background.identifier else { completionHandler();return }
        backup.background.handleEvents { Task { @MainActor in completionHandler() } }
        backup.start()
    }
}
