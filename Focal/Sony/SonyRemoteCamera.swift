import Foundation
import Combine
import UIKit
import ImageIO

@MainActor
final class SonyRemoteCamera: ObservableObject {
    enum State: Equatable { case disconnected, connecting, reconnecting, connected, streaming, failed }
    @Published private(set) var state: State = .disconnected
    @Published private(set) var hasFrame = false
    @Published private(set) var imageAspect = 3.0 / 2
    @Published private(set) var streamFPS: Double?
    @Published private(set) var qualityStatus = "Camera default"
    let previewFeed = SonyPreviewFeed()
    @Published private(set) var model = "Sony camera"
    @Published private(set) var remote = SonyRemoteSnapshot()
    var telemetry:CameraTelemetry { remote.telemetry }
    var methods:Set<String> { remote.methods }
    var capabilities:Set<String> { remote.supported }
    var remoteSettings:[SonyRemoteSetting:SonyRemoteSettingState] { remote.settings }
    let diagnostics = SonyDiagnostics()
    @Published private(set) var pendingSettings = Set<SonyRemoteSetting>()
    @Published private(set) var isRefreshingSettings = false
    @Published private(set) var controlFeedback: String?
    private var settingTasks: [SonyRemoteSetting:Task<Void,Never>] = [:]
    private var commandTail: Task<Void,Never>?
    private var pollRevision = 0
    private var refreshRequested = true
    var isConnected: Bool { state == .connected || state == .streaming }
    // Background reads do not make the camera or its controls busy.
    var controlsBusy: Bool { isCapturing || isFocusing || !pendingSettings.isEmpty || controlState.captureBusy }
    var autofocusUnavailableReason: String? {
        guard isConnected else { return "Connect a Sony camera first." }
        guard !controlsBusy else { return "Wait for the current camera operation to finish." }
        guard methods.contains("actHalfPressShutter"), methods.contains("cancelHalfPressShutter") || capabilities.contains("cancelHalfPressShutter") else {
            return "This camera mode does not advertise a releasable AF trigger. Focus on the camera or lens."
        }
        return nil
    }
    var canTriggerAF: Bool { autofocusUnavailableReason == nil }
    func settingDisabledReason(_ setting:SonyRemoteSetting) -> String? {
        guard isConnected else { return "Connect a Sony camera first." }
        if isCapturing || controlState.captureBusy { return "The camera is busy taking or saving a photograph." }
        return remote.status(setting,pending:pendingSettings.contains(setting)).reason
    }
    @Published private(set) var frameCount = 0
    @Published private(set) var streamDiagnostics = "Waiting for camera data"
    @Published private(set) var resolution = "—"
    @Published private(set) var isCapturing = false
    @Published private(set) var message: String?
    @Published var host = SonyEndpoint.initialHost(previous: UserDefaults.standard.string(forKey:"sony.lastCameraHost"))
    var discoveredDescriptorURL:URL?
    var onImage: ((CGImage)->Void)?
    private var deliveredFrames = 0
    private var lastFramePublication: TimeInterval = -.infinity
    private var client: SonyAPIClient?
    private var receiver: SonyStreamReceiver?
    private var streamSession: URLSession?
    private var connectionTask: Task<Void,Never>?
    private var monitorTask: Task<Void,Never>?
    private var cleanupTask: Task<Void,Never>?
    private var generation = UUID()
    private var lastFrame: TimeInterval = 0
    private var wantsConnection = false
    private var recovery = SonyReconnectPolicy()
    private var recoveryTask: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var healthySince: TimeInterval?
    private var streamInterruption: String?
    var controlState:SonyControlState { remote.control }
    @Published private(set) var isFocusing = false
    var canCapture: Bool { isConnected && methods.contains("actTakePicture") && !controlsBusy }
    var supportsTouchFocus: Bool { state == .streaming && methods.contains("setTouchAFPosition") }

    func connect(automatic: Bool = false) {
        let selectedHost = host.trimmingCharacters(in:.whitespacesAndNewlines)
        guard SonyEndpoint.validHost(selectedHost) else { state = .failed; message = "Enter the camera’s private IPv4 address after joining its DIRECT Wi-Fi."; return }
        if !automatic { recovery.reset() }
        close(preserveRequest:false)
        wantsConnection = true; host = selectedHost
        diagnostics.record("connection.started",["automatic":String(automatic)])
        state = automatic ? .reconnecting : .connecting; message = automatic ? "Restoring Sony live view…" : nil; frameCount = 0; deliveredFrames = 0; streamFPS = nil
        qualityStatus = "Camera default"; lastFramePublication = -.infinity; streamDiagnostics = "Waiting for camera data"
        let current = generation
        let previousCleanup = cleanupTask
        connectionTask = Task {
            await previousCleanup?.value
            guard current == generation,!Task.isCancelled else { return }
            do {
                var descriptor: SonyDescriptor?
                var lastError: Error?
                var descriptorURLs:[URL] = []
                if let selected = discoveredDescriptorURL, selected.host == selectedHost {
                    descriptorURLs.append(try SonyEndpoint.validate(selected,host:selectedHost))
                }
                descriptorURLs += [64321,61000].compactMap { URL(string:"http://\(selectedHost):\($0)/DmsRmtDesc.xml") }
                for url in descriptorURLs {
                    try Task.checkCancellation()
                    do {
                        let config = URLSessionConfiguration.ephemeral; config.allowsCellularAccess = false; config.timeoutIntervalForRequest = 2.5; config.timeoutIntervalForResource = 3
                        let discovery = URLSession(configuration:config,delegate:SonyLocalSessionDelegate(),delegateQueue:nil)
                        defer { discovery.invalidateAndCancel() }
                        let (data,response) = try await discovery.data(from:url)
                        guard let http = response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else { throw SonyRemoteError(message:"The camera did not return a descriptor.") }
                        descriptor = try SonyDescriptor.parse(data,host:selectedHost)
                        diagnostics.record("discovery.descriptor",["port":String(url.port ?? 80),"service":"camera","model":descriptor?.model ?? ""]); break
                    } catch { lastError = error; diagnostics.record("discovery.descriptor.failed",["port":String(url.port ?? 80),"error":error.localizedDescription]) }
                }
                guard current == generation,!Task.isCancelled else { return }
                guard let descriptor else { throw lastError ?? SonyRemoteError(message:"No advertised Sony wireless service was found.") }
                UserDefaults.standard.set(selectedHost,forKey:"sony.lastCameraHost")
                let api = SonyAPIClient(endpoint:descriptor.endpoint,diagnostics:diagnostics); client = api
                diagnostics.record("connection.endpoint",["service":"camera","scheme":descriptor.endpoint.scheme ?? "unknown","port":String(descriptor.endpoint.port ?? 80)])
                var supported = try await Self.available(api)
                if supported.contains("startRecMode") && !supported.contains("actTakePicture") {
                    do { _ = try await api.call("startRecMode") }
                    catch let error as SonyAPIError where error.code == 5 { /* Mode may already be active while controls settle. */ }
                    try await Task.sleep(for:.milliseconds(350))
                    supported = try await Self.available(api)
                }
                if supported.contains("getMethodTypes") {
                    if let data = try? await api.call("getMethodTypes", params: [""], timeout: 2),
                       let result = try? SonyAPIClient.result(data) {
                        guard current == generation, !Task.isCancelled else { return }
                        let names = SonyMethodCapabilities.names(result)
                        remote.supported = names; remote.supportComplete = !names.isEmpty
                    }
                }
                // Negotiate only a size the camera actually advertises. Older
                // firmware without this API keeps its working default stream.
                if supported.contains("setLiveviewSize") {
                    let query = supported.contains("getAvailableLiveviewSize") ? "getAvailableLiveviewSize" : "getSupportedLiveviewSize"
                    if supported.contains(query) {
                        do {
                            let sizes = try SonyAPIClient.result(await api.call(query))
                            if let size = SonyLiveViewSize.largest(in: sizes) {
                                _ = try await api.call("setLiveviewSize", params: [size])
                                guard current == generation, !Task.isCancelled else { return }
                                qualityStatus = "Sony size \(size) requested"
                            }
                        } catch {
                            guard current == generation, !Task.isCancelled else { return }
                            qualityStatus = "Camera default (size change unavailable)"
                        }
                    }
                }
                guard current == generation,!Task.isCancelled else { return }
                model = descriptor.model
                var initial = remote; initial.applyMethods(supported)
                for setting in SonyRemoteSetting.allCases { initial.settings[setting] = .init(readStatus:.loading) }
                publish(initial,cause:"connection.getAvailableApiList")
                diagnostics.record("connection.controls",["model":model,"available":supported.sorted().joined(separator:","),"supported":capabilities.sorted().joined(separator:",")])
                var liveURL = descriptor.liveURL
                if supported.contains("startLiveview") {
                    do {
                        let result = try SonyAPIClient.result(await api.call("startLiveview"))
                        liveURL = (result.first as? String).flatMap(URL.init(string:))
                    } catch {
                        guard current == generation,!Task.isCancelled else { return }
                        message = "Remote controls connected. Live view unavailable: \(error.localizedDescription)"
                    }
                }
                guard current == generation,!Task.isCancelled else { return }
                state = .connected
                diagnostics.record("connection.state",["new":"connected","model":model,"cause":"remote API responded"])
                if let liveURL {
                    do { openStream(try SonyEndpoint.validate(liveURL,host:selectedHost),generation:current) }
                    catch { message = "Remote controls connected, but Sony returned an invalid live-view address." }
                } else if message == nil { message = "Remote controls connected. This mode does not advertise a live-view stream." }
                refreshRequested = true
                startMonitor(api:api,generation:current)

            } catch {
                guard current == generation,!Task.isCancelled else { return }
                fail("Could not establish Sony remote connection. Check DIRECT Wi-Fi, Local Network access and camera remote mode. \(error.localizedDescription)",generation:current, recoverable:error is URLError)
            }
        }
    }
    private static func available(_ api:SonyAPIClient) async throws -> Set<String> {
        let result = try SonyAPIClient.result(await api.call("getAvailableApiList"))
        guard let list = result.first as? [String] else { throw SonyRemoteError(message:"Sony did not advertise any available controls.") }
        return Set(list)
    }
    private func openStream(_ url:URL,generation current:UUID) {
        lastFrame = ProcessInfo.processInfo.systemUptime
        let delegate = SonyStreamReceiver(onFrame: { [weak self] decoded in
            // The receiver coalesces its main-thread handoff as well as decode.
            guard let self, current == self.generation else { return }
            self.previewFeed.display(decoded.image)
            if !self.hasFrame {
                self.hasFrame = true; self.state = .streaming
                self.diagnostics.record("connection.state",["new":"streaming","model":self.model,"cause":"decoded real live frame"])
            }
            if abs(self.imageAspect - decoded.aspect) > 0.001 { self.imageAspect = decoded.aspect }
            self.lastFrame = ProcessInfo.processInfo.systemUptime
            if self.healthySince == nil { self.healthySince = self.lastFrame }
            if self.lastFrame - (self.healthySince ?? self.lastFrame) >= 20 { self.recovery.reset(); self.message = nil }
            self.deliveredFrames += 1
            if self.lastFrame - self.lastFramePublication >= 1 {
                self.lastFramePublication = self.lastFrame; self.frameCount = self.deliveredFrames
                self.resolution = "\(decoded.image.width) × \(decoded.image.height)"
            }
            // Reuse already-decoded native pixels. Analysis has independent
            // one-in-flight admission and cannot delay the preview surface.
            if !self.isCapturing { self.onImage?(decoded.image) }
        }, onDiagnostics: { [weak self] detail, fps in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                self.streamDiagnostics = detail; self.streamFPS = fps
            }
        }, onEnd: { [weak self] error in
            Task { @MainActor in self?.streamEnded(error?.localizedDescription ?? "Sony ended the live-view stream.", generation: current) }
        })
        receiver = delegate
        let config = URLSessionConfiguration.ephemeral; config.allowsCellularAccess = false; config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 3600
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
        let session = URLSession(configuration:config,delegate:delegate,delegateQueue:queue)
        streamSession = session
        session.dataTask(with:url).resume()
    }
    func focus(at point: UnitPoint2D) {
        guard supportsTouchFocus, !controlsBusy, let api = client else { return }
        interruptBackgroundRead()
        let current = generation; isFocusing = true
        focusTask = Task {
            defer { if current == generation { isFocusing = false; focusTask = nil } }
            do { _ = try await api.call("setTouchAFPosition", params: [max(0,min(1,point.x))*100,max(0,min(1,point.y))*100], timeout: 2) }
            catch { if current == generation { message = error.localizedDescription } }
        }
    }
    func capture() async throws -> CameraCapture {
        guard canCapture,let api = client else { throw SonyRemoteError(message:"Sony remote capture is not currently available or the camera is busy.") }
        interruptBackgroundRead()
        let current = generation,selectedHost = host
        isCapturing = true
        defer {
            if current == generation {
                isCapturing = false; lastFrame = ProcessInfo.processInfo.systemUptime
                if let interruption = streamInterruption { streamInterruption = nil; fail(interruption, generation: current, recoverable: true) }
            }
        }
        let urls: [String]
        do {
            urls = try await SonyCaptureWorkflow.take(call: { method, params, timeout in
                try await api.call(method, params: params, timeout: timeout)
            }, supported: capabilities, active: { current == self.generation })
        } catch {
            if current == generation, (error as NSError).domain == NSURLErrorDomain {
                streamInterruption = "Connection interrupted during Sony capture."
                throw SonyRemoteError(message: "The Sony connection was interrupted. A photo may already be on the camera card. Check the card before taking another; live view will reconnect.")
            }
            throw error
        }
        guard current == generation else { throw CancellationError() }
        guard let text = urls.first,let url = URL(string:text) else { throw SonyRemoteError(message:"The camera may have taken a photo, but did not return a transferable JPEG URL.") }
        let verified = try SonyEndpoint.validate(url,host:selectedHost)
        let config = URLSessionConfiguration.ephemeral; config.allowsCellularAccess = false; config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        let transfer = URLSession(configuration:config,delegate:SonyLocalSessionDelegate(),delegateQueue:nil); defer { transfer.invalidateAndCancel() }
        let data: Data, response: URLResponse
        do { (data, response) = try await transfer.data(from:verified) }
        catch {
            if current == generation, (error as NSError).domain == NSURLErrorDomain {
                streamInterruption = "Connection interrupted during Sony photo transfer."
                throw SonyRemoteError(message: "Sony took the photo, but the transfer was interrupted. The original should be on the camera card. Live view will reconnect; another shutter press takes a new photo.")
            }
            throw error
        }
        guard current == generation,let http = response as? HTTPURLResponse,(200..<300).contains(http.statusCode),data.prefix(2) == Data([0xff,0xd8]),CGImageSourceCreateWithData(data as CFData,nil) != nil else {
            throw SonyRemoteError(message:"The Sony photo transfer failed. Check the camera’s card for the capture.")
        }
        return CameraCapture(processed:data,raw:nil)
    }
    func refreshSettings() {
        guard isConnected,!isRefreshingSettings else { return }
        // Coalesced by the existing monitor; never create a second read task.
        refreshRequested = true
    }
    private func interruptBackgroundRead() { pollRevision += 1; refreshRequested = true }
    private func publish(_ next:SonyRemoteSnapshot,cause:String) {
        guard next != remote else { return }
        for setting in SonyRemoteSetting.allCases {
            let old = remote.status(setting,pending:pendingSettings.contains(setting))
            let new = next.status(setting,pending:pendingSettings.contains(setting))
            let priorRead = remote.settings[setting]?.readStatus ?? .unknown
            let nextRead = next.settings[setting]?.readStatus ?? .unknown
            if old != new || priorRead != nextRead {
                diagnostics.record("control.transition",["setting":setting.rawValue,"previous":old.name,"new":new.name,
                    "previousRead":priorRead.label,"newRead":nextRead.label,"mode":next.telemetry.mode ?? "unknown", "cause":cause,
                    "reason":new.reason ?? next.settings[setting]?.issue ?? "camera value confirmed",
                    "valueSource":next.settings[setting]?.sourceMethod ?? "none",
                    "addedAPI":next.methods.subtracting(remote.methods).sorted().joined(separator:","),
                    "removedAPI":remote.methods.subtracting(next.methods).sorted().joined(separator:",")])
            }
        }
        remote = next
    }
    private func startMonitor(api:SonyAPIClient,generation current:UUID) {
        guard monitorTask == nil else { return }
        diagnostics.record("poll.started",["eventInterval":"3","capabilityInterval":"15","eventLongPolling":"false"])
        monitorTask = Task {
            var policy = SonyRemotePollPolicy()
            while current == generation,!Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                if streamSession != nil,!isCapturing,now-lastFrame > 8 {
                    fail("Sony live view stopped. "+streamDiagnostics,generation:current,recoverable:true); return
                }
                if !isCapturing,!isFocusing,pendingSettings.isEmpty {
                    let revision = pollRevision
                    let active = { current == self.generation && revision == self.pollRevision && !Task.isCancelled }
                    let readingSnapshot = refreshRequested || now >= policy.nextSnapshot
                    do {
                        if readingSnapshot {
                            refreshRequested = false; isRefreshingSettings = true
                            defer { if current == generation { isRefreshingSettings = false } }
                            let next = try await SonySnapshotWorkflow.read(previous:remote,diagnostics:diagnostics,call:{ method,params,timeout in
                                guard active() else { throw CancellationError() }
                                return try await api.call(method,params:params,timeout:timeout)
                            },active:active)
                            guard active() else { throw CancellationError() }
                            publish(next,cause:"snapshot.readback")
                            policy.snapshotRead(at:ProcessInfo.processInfo.systemUptime); policy.success()
                        } else if let feedbackMethod = SonyRemotePollPolicy.feedbackMethod(methods),now >= policy.nextEvent {
                            // Non-long-poll avoids blocking the same command client for 30 seconds.
                            let result = try SonyAPIClient.result(await api.call(feedbackMethod,params:feedbackMethod == "getEvent" ? [false] : [],timeout:3))
                            guard active() else { throw CancellationError() }
                            let observedMode = feedbackMethod == "getEvent" ? SonyEventValues.telemetry(result).mode : result.first as? String
                            if let observedMode, observedMode != remote.telemetry.mode {
                                diagnostics.record("mode.changed",["previous":remote.telemetry.mode ?? "unknown","new":observedMode,"cause":feedbackMethod])
                                refreshRequested = true
                            } else if feedbackMethod == "getEvent" {
                                var next = remote; next.applyEvent(result)
                                let exposureAPIs = Set(SonyRemoteSetting.allCases.flatMap { [$0.setter,$0.getter,$0.available] })
                                if next.methods.intersection(exposureAPIs) != remote.methods.intersection(exposureAPIs) { refreshRequested = true }
                                publish(next,cause:"getEvent.delta")
                            }
                            policy.eventRead(at:ProcessInfo.processInfo.systemUptime); policy.success()
                        }
                    } catch is CancellationError {
                        guard current == generation,!Task.isCancelled else { return }
                        refreshRequested = true
                        diagnostics.record("poll.stale.ignored")
                    } catch is SonyModeChangedDuringRead {
                        refreshRequested = true
                        diagnostics.record("snapshot.mode.changed",["action":"discard candidate; retain confirmed state"])
                        do { try await Task.sleep(for:.seconds(1)) } catch { return }
                    } catch {
                        guard active() else { continue }
                        var next = remote; next.noteFailure(error); publish(next,cause:"poll.failed")
                        diagnostics.record("poll.failed",["error":error.localizedDescription,"action":"retain confirmed controls"])
                        // An event timeout/parse failure is not a disconnected camera.
                        if policy.failed(error,recentLiveFrame:hasFrame && ProcessInfo.processInfo.systemUptime-lastFrame < 5) {
                            fail("Sony control endpoint is unreachable. Wake the camera and check Wi-Fi.",generation:current,recoverable:true); return
                        }
                        // Failed events must not postpone direct value/capability
                        // reads forever when a camera's event API is unreliable.
                        policy.backoff(snapshot:readingSnapshot,at:ProcessInfo.processInfo.systemUptime)
                    }
                }
                do { try await Task.sleep(for:.milliseconds(250)) } catch { return }
            }
        }
    }
    @discardableResult
    func change(_ setting:SonyRemoteSetting,to value:SonySettingValue) -> Bool {
        guard settingDisabledReason(setting) == nil,let api = client else { return false }
        let current = generation, previous = commandTail, focusing = focusTask
        interruptBackgroundRead(); pendingSettings.insert(setting); controlFeedback = nil
        diagnostics.record("control.transition",["setting":setting.rawValue,"previous":"Available","new":"CommandInProgress","mode":telemetry.mode ?? "unknown","cause":"user.request"])
        let operation = Task {
            await previous?.value; await focusing?.value
            defer {
                if current == generation {
                    pendingSettings.remove(setting); settingTasks[setting] = nil; refreshRequested = true
                    if pendingSettings.isEmpty { commandTail = nil }
                    diagnostics.record("control.transition",["setting":setting.rawValue,"previous":"CommandInProgress","new":remote.status(setting).name,"mode":telemetry.mode ?? "unknown","cause":"command.finished"])
                }
            }
            guard current == generation,!Task.isCancelled else { return }
            do {
                let feedback = try await SonySettingWorkflow.change(setting,to:value,call:{ method,params,timeout in
                    guard current == self.generation,!Task.isCancelled else { throw CancellationError() }
                    return try await api.call(method,params:params,timeout:timeout)
                },active:{ current == self.generation })
                guard current == generation,!Task.isCancelled else { return }
                var next = remote; next.merge(setting,feedback); publish(next,cause:setting.getter+".writeConfirmed")
                controlFeedback = "\(setting.title) confirmed by camera: \(feedback.current?.label ?? "—")"
                diagnostics.record("setting.verified",["setting":setting.rawValue,"value":feedback.current?.label ?? "unknown"])
            } catch {
                guard current == generation,!Task.isCancelled else { return }
                var next = remote; next.writeFailed(setting,error:error); publish(next,cause:setting.setter+".failed")
                controlFeedback = error.localizedDescription
                diagnostics.record("setting.unconfirmed",["setting":setting.rawValue,"error":error.localizedDescription])
            }
        }
        settingTasks[setting] = operation; commandTail = operation
        return true
    }
    func triggerAutofocus() {
        guard canTriggerAF,let api = client else { return }
        interruptBackgroundRead()
        let current = generation; isFocusing = true; controlFeedback = nil
        focusTask = Task {
            defer { if current == generation { isFocusing = false; focusTask = nil } }
            do {
                let result = try await SonyFocusWorkflow.trigger(call:{ method,params,timeout in
                    guard current == self.generation,!Task.isCancelled else { throw CancellationError() }
                    return try await api.call(method,params:params,timeout:timeout)
                },supported:capabilities,active:{ current == self.generation })
                guard current == generation,!Task.isCancelled else { return }
                controlFeedback = result
                diagnostics.record("focus.result",["feedback":result])
            } catch {
                if current == generation,!Task.isCancelled {
                    controlFeedback = error.localizedDescription
                    diagnostics.record("focus.failed",["error":error.localizedDescription])
                }
            }
        }
    }
    func pause() { diagnostics.record("lifecycle.background"); close(preserveRequest:true) }
    func resume() { if wantsConnection && (state == .disconnected || state == .failed) { connect() } }
    func disconnect() { diagnostics.record("connection.disconnected"); close(preserveRequest:false) }
    private func streamEnded(_ detail: String, generation current: UUID) {
        guard current == generation else { return }
        if isCapturing {
            // Camera firmware can stop live view during a still capture. Keep
            // the control/transfer operation alive and reconnect afterwards.
            receiver?.close(); streamSession?.invalidateAndCancel(); receiver = nil; streamSession = nil
            streamInterruption = detail; hasFrame = false; previewFeed.display(nil)
            state = .reconnecting; message = "Live view paused while Sony takes the photo"
        } else { fail(detail, generation: current, recoverable: true) }
    }
    private func fail(_ detail: String, generation current: UUID, recoverable: Bool = false) {
        guard current == generation else { return }
        diagnostics.record("connection.failed",["detail":detail,"recoverable":String(recoverable)])
        let requested = wantsConnection
        close(preserveRequest:true)
        if recoverable, let delay = recovery.nextDelay(requested: requested) {
            state = .reconnecting; message = "Sony connection interrupted. Reconnecting \(recovery.attempts)/3…"
            let revision = generation
            recoveryTask = Task {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard revision == generation, wantsConnection, !Task.isCancelled else { return }
                recoveryTask = nil; connect(automatic: true)
            }
        } else {
            state = .failed; message = detail + (recoverable ? " Rejoin Sony DIRECT Wi-Fi, then tap Connect." : "")
        }
    }
    private func close(preserveRequest:Bool) {
        let closingMethods = methods, closingCapabilities = capabilities
        generation = UUID(); connectionTask?.cancel(); monitorTask?.cancel(); recoveryTask?.cancel(); focusTask?.cancel()
        for task in settingTasks.values { task.cancel() }
        settingTasks = [:]; commandTail = nil; pendingSettings = []; pollRevision += 1; refreshRequested = true
        publish(SonyRemoteSnapshot(),cause:"connection.closed")
        isRefreshingSettings = false; controlFeedback = nil
        model = "Sony camera"; resolution = "—"; streamFPS = nil; imageAspect = 3.0/2
        connectionTask = nil; monitorTask = nil; recoveryTask = nil; focusTask = nil
        healthySince = nil; streamInterruption = nil; isFocusing = false
        receiver?.close(); streamSession?.invalidateAndCancel(); streamSession = nil; receiver = nil
        if let api = client {
            let canStop = closingMethods.contains("stopLiveview")
            let canRelease = closingMethods.contains("cancelHalfPressShutter") || closingCapabilities.contains("cancelHalfPressShutter")
            cleanupTask = Task {
                await api.cancelPendingRequests()
                if canRelease { _ = try? await api.call("cancelHalfPressShutter",timeout:2) }
                if canStop { _ = try? await api.call("stopLiveview",timeout:2) }
                await api.shutdown()
            }
        }
        client = nil
        if !preserveRequest { wantsConnection = false }
        previewFeed.display(nil); hasFrame = false; isCapturing = false; state = .disconnected
    }
}

private final class SonyStreamReceiver: NSObject, URLSessionDataDelegate {
    private struct Batch { var frames: [Data]; var receivedAt: TimeInterval }
    private var parser = SonyLiveViewParser() // Serial network delegate only.
    private let decodeQueue = DispatchQueue(label: "app.focal.sony.decode", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let incoming = LatestFrameMailbox<Batch>()
    private let presentation = LatestFrameMailbox<SonyDecodedFrame>()
    private let onFrame: @MainActor (SonyDecodedFrame) -> Void
    private let onDiagnostics: (String, Double?) -> Void
    private let onEnd: (Error?) -> Void
    private let statsLock = NSLock()
    private var decodedCount = 0
    private var decoderRejections = 0
    private var receivedBytes = 0
    private var lastDiagnostics: TimeInterval?
    private var previousDecoded = 0
    private var previousReceived = 0
    init(onFrame: @escaping @MainActor (SonyDecodedFrame) -> Void,
         onDiagnostics: @escaping (String, Double?) -> Void, onEnd: @escaping (Error?) -> Void) {
        self.onFrame = onFrame; self.onDiagnostics = onDiagnostics; self.onEnd = onEnd
    }
    func close() { incoming.close(); presentation.close() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel); onEnd(SonyRemoteError(message: "Sony live-view HTTP request was rejected.")); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            receivedBytes += data.count
            let frames = try parser.append(data)
            let now = ProcessInfo.processInfo.systemUptime
            if !frames.isEmpty, incoming.offer(Batch(frames: Array(frames.suffix(2)), receivedAt: now)) {
                decodeQueue.async { self.decodeWaitingFrames() }
            }
            if lastDiagnostics == nil { lastDiagnostics = now }
            if let lastDiagnostics, now - lastDiagnostics >= 1 {
                statsLock.lock(); let decoded = decodedCount, rejected = decoderRejections; statsLock.unlock()
                let elapsed = now - lastDiagnostics
                let sourceRate = Double(parser.imageFrames - previousReceived) / elapsed
                let decodeRate = Double(decoded - previousDecoded) / elapsed
                self.lastDiagnostics = now; previousReceived = parser.imageFrames; previousDecoded = decoded
                let rates = String(format: "%.0f incoming / %.0f decoded fps", sourceRate, decodeRate)
                onDiagnostics("\(receivedBytes / 1024) KiB · \(rates) · \(parser.framing) · \(parser.discardedFrames + rejected) rejected", decodeRate)
            }
        } catch { close(); session.invalidateAndCancel(); onEnd(error) }
    }
    private func decodeWaitingFrames() {
        while let batch = incoming.take() {
            autoreleasepool {
                // A stalled decoder must skip stale work, not replay it later.
                guard ProcessInfo.processInfo.systemUptime - batch.receivedAt < 0.5 else { return }
                for data in batch.frames.reversed() {
                    guard let decoded = SonyDecodedFrame.decode(data, receivedAt: batch.receivedAt) else {
                        statsLock.lock(); decoderRejections += 1; statsLock.unlock(); continue
                    }
                    statsLock.lock(); decodedCount += 1; statsLock.unlock()
                    if presentation.offer(decoded) {
                        Task { @MainActor in
                            while let latest = self.presentation.take() {
                                guard ProcessInfo.processInfo.systemUptime - latest.receivedAt < 0.5 else { continue }
                                self.onFrame(latest)
                            }
                        }
                    }
                    break
                }
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { close(); onEnd(error) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
