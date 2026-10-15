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
    @Published private(set) var telemetry = CameraTelemetry()
    @Published private(set) var methods = Set<String>()
    private(set) var capabilities = Set<String>()
    let diagnostics = SonyDiagnostics()
    @Published private(set) var remoteSettings: [SonyRemoteSetting:SonyRemoteSettingState] = [:]
    @Published private(set) var pendingSetting: SonyRemoteSetting?
    @Published private(set) var isRefreshingSettings = false
    @Published private(set) var controlFeedback: String?
    private var settingTask: Task<Void,Never>?
    private var refreshTask: Task<Void,Never>?
    var isConnected: Bool { state == .connected || state == .streaming }
    var controlsBusy: Bool { isCapturing || isFocusing || pendingSetting != nil || isRefreshingSettings || controlState.captureBusy }
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
        if controlsBusy { return "Wait for the current camera operation to finish." }
        return (remoteSettings[setting] ?? SonyRemoteSettingState()).disabledReason(setting:setting,available:methods,supported:capabilities)
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
    @Published private(set) var controlState = SonyControlState()
    @Published private(set) var isFocusing = false
    var canCapture: Bool { isConnected && methods.contains("actTakePicture") && !controlsBusy }
    var supportsTouchFocus: Bool { state == .streaming && methods.contains("setTouchAFPosition") }

    func connect(automatic: Bool = false) {
        let selectedHost = host.trimmingCharacters(in:.whitespacesAndNewlines)
        guard SonyEndpoint.validHost(selectedHost) else { state = .failed; message = "Enter the camera’s private IPv4 address after joining its DIRECT Wi-Fi."; return }
        if !automatic { recovery.reset() }
        close(preserveRequest:false)
        wantsConnection = true; host = selectedHost
        diagnostics.record("connection.started",["host":selectedHost,"automatic":String(automatic)])
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
                        diagnostics.record("discovery.descriptor",["host":selectedHost,"port":String(url.port ?? 80),"model":descriptor?.model ?? ""]); break
                    } catch { lastError = error; diagnostics.record("discovery.descriptor.failed",["port":String(url.port ?? 80),"error":error.localizedDescription]) }
                }
                guard current == generation,!Task.isCancelled else { return }
                guard let descriptor else { throw lastError ?? SonyRemoteError(message:"No advertised Sony wireless service was found.") }
                UserDefaults.standard.set(selectedHost,forKey:"sony.lastCameraHost")
                let api = SonyAPIClient(endpoint:descriptor.endpoint,diagnostics:diagnostics); client = api
                diagnostics.record("connection.endpoint",["url":descriptor.endpoint.absoluteString])
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
                        capabilities = SonyMethodCapabilities.names(result)
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
                model = descriptor.model; methods = supported; capabilities.formUnion(supported)
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
                if let liveURL {
                    do { openStream(try SonyEndpoint.validate(liveURL,host:selectedHost),generation:current) }
                    catch { message = "Remote controls connected, but Sony returned an invalid live-view address." }
                } else if message == nil { message = "Remote controls connected. This mode does not advertise a live-view stream." }
                refreshSettings()
                monitorTask = Task {
                    var lastEvent: TimeInterval = 0
                    var lastSettings: TimeInterval = ProcessInfo.processInfo.systemUptime
                    var controlFailures = 0
                    while !Task.isCancelled && current == generation {
                        try? await Task.sleep(for:.seconds(1))
                        guard !Task.isCancelled,current == generation else { return }
                        let now = ProcessInfo.processInfo.systemUptime
                        if streamSession != nil && !isCapturing && now-lastFrame > 8 {
                            let problem = frameCount == 0 ? "Sony sent no decodable live-view image." : "Sony live view stopped."
                            fail(problem + " " + streamDiagnostics, generation: current, recoverable: true); return
                        }
                        if !isCapturing, !isFocusing, pendingSetting == nil, !isRefreshingSettings, now-lastEvent >= 2 {
                            lastEvent = now
                            do {
                                let available = try await Self.available(api)
                                guard current == generation else { return }
                                guard pendingSetting == nil,!isCapturing,!isFocusing,!isRefreshingSettings else { continue }
                                let changed = methods != available
                                methods = available
                                capabilities.formUnion(available)
                                if changed { remoteSettings = [:] }
                                var modeChanged = false
                                if available.contains("getEvent") {
                                    let result = try SonyAPIClient.result(await api.call("getEvent",params:[false],timeout:2))
                                    guard current == generation else { return }
                                    guard pendingSetting == nil,!isCapturing,!isFocusing,!isRefreshingSettings else { continue }
                                    let reported = SonyEventValues.telemetry(result)
                                    modeChanged = reported.mode != nil && reported.mode != telemetry.mode
                                    if modeChanged { remoteSettings = [:] }
                                    telemetry = reported
                                    for setting in SonyRemoteSetting.allCases {
                                        if var value = SonySettingParser.event(setting,values:result) {
                                            if !changed, !modeChanged, value.choices.isEmpty, available.contains(setting.available), let previous = remoteSettings[setting] {
                                                value.choices = previous.choices
                                            }
                                            remoteSettings[setting] = value
                                        }
                                    }
                                    controlState = SonyControlState.from(result)
                                    if let available = controlState.availableMethods { methods = available }
                                    diagnostics.record("camera.feedback",["status":controlState.cameraStatus ?? "not reported","focus":controlState.focusStatus ?? "not reported","mode":telemetry.mode ?? "not reported"])
                                }
                                controlFailures = 0
                                if changed || modeChanged || now-lastSettings >= 10 {
                                    lastSettings = now; refreshSettings()
                                }
                            } catch {
                                guard current == generation else { return }
                                controlFailures += 1
                                diagnostics.record("connection.poll.failed",["error":error.localizedDescription,"count":String(controlFailures)])
                                // Never leave stale values enabled after failed feedback.
                                remoteSettings = [:]; methods = []; controlState = SonyControlState()
                                if controlFailures >= 3 { fail("Sony stopped responding. Camera may be asleep or Wi-Fi disconnected.",generation:current,recoverable:true); return }
                            }
                        }
                    }
                }
            } catch {
                guard current == generation,!Task.isCancelled else { return }
                fail("Could not establish Sony remote connection. Check DIRECT Wi-Fi, Local Network access and camera remote mode. \(error.localizedDescription)",generation:current, recoverable:error is URLError)
            }
        }
    }
    private static func available(_ api:SonyAPIClient) async throws -> Set<String> {
        let result = try SonyAPIClient.result(await api.call("getAvailableApiList"))
        guard let list = result.first as? [String],!list.isEmpty else { throw SonyRemoteError(message:"Sony did not advertise any available controls.") }
        return Set(list)
    }
    private func openStream(_ url:URL,generation current:UUID) {
        lastFrame = ProcessInfo.processInfo.systemUptime
        let delegate = SonyStreamReceiver(onFrame: { [weak self] decoded in
            // The receiver coalesces its main-thread handoff as well as decode.
            guard let self, current == self.generation else { return }
            self.previewFeed.display(decoded.image)
            if !self.hasFrame { self.hasFrame = true; self.state = .streaming }
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
        let current = generation; isFocusing = true
        focusTask = Task {
            defer { if current == generation { isFocusing = false; focusTask = nil } }
            do { _ = try await api.call("setTouchAFPosition", params: [max(0,min(1,point.x))*100,max(0,min(1,point.y))*100], timeout: 2) }
            catch { if current == generation { message = error.localizedDescription } }
        }
    }
    func capture() async throws -> CameraCapture {
        guard canCapture,let api = client else { throw SonyRemoteError(message:"Sony remote capture is not currently available or the camera is busy.") }
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
        guard isConnected, !controlsBusy, let api = client else { return }
        let current = generation
        isRefreshingSettings = true
        refreshTask = Task {
            defer { if current == generation { isRefreshingSettings = false; refreshTask = nil } }
            do {
                let available = try await Self.available(api)
                guard current == generation,!Task.isCancelled else { return }
                methods = available
                capabilities.formUnion(available)
                if available.contains("getExposureMode"), let data = try? await api.call("getExposureMode",timeout:2), let mode = try? SonyAPIClient.result(data).first as? String {
                    guard current == generation,!Task.isCancelled else { return }
                    telemetry.mode = mode
                }
                for setting in SonyRemoteSetting.allCases {
                    guard current == generation,!Task.isCancelled else { return }
                    do {
                        let value = try await SonySettingWorkflow.read(setting,methods:available,call:{ method,params,timeout in
                            guard current == self.generation,!Task.isCancelled else { throw CancellationError() }
                            return try await api.call(method,params:params,timeout:timeout)
                        })
                        guard current == generation,!Task.isCancelled else { return }
                        remoteSettings[setting] = value
                    } catch {
                        guard current == generation,!Task.isCancelled else { return }
                        remoteSettings[setting] = SonyRemoteSettingState(issue:error.localizedDescription)
                    }
                }
                updateExposureTelemetry()
                diagnostics.record("settings.refreshed",["model":model,"mode":telemetry.mode ?? "not reported"])
            } catch {
                guard current == generation,!Task.isCancelled else { return }
                remoteSettings = [:]; methods = []; controlFeedback = error.localizedDescription
            }
        }
    }
    func change(_ setting:SonyRemoteSetting,to value:SonySettingValue) {
        guard settingDisabledReason(setting) == nil,let api = client else { return }
        let current = generation; pendingSetting = setting; controlFeedback = nil
        diagnostics.record("setting.requested",["setting":setting.rawValue,"requested":value.label,"previous":remoteSettings[setting]?.current?.label ?? "unknown"])
        settingTask = Task {
            defer { if current == generation { pendingSetting = nil; settingTask = nil } }
            do {
                let feedback = try await SonySettingWorkflow.change(setting,to:value,call:{ method,params,timeout in
                    guard current == self.generation,!Task.isCancelled else { throw CancellationError() }
                    return try await api.call(method,params:params,timeout:timeout)
                },active:{ current == self.generation })
                guard current == generation,!Task.isCancelled else { return }
                remoteSettings[setting] = feedback; updateExposureTelemetry()
                controlFeedback = "\(setting.title) confirmed by camera: \(feedback.current?.label ?? "—")"
                diagnostics.record("setting.verified",["setting":setting.rawValue,"value":feedback.current?.label ?? "unknown"])
            } catch {
                guard current == generation,!Task.isCancelled else { return }
                // A write timeout is ambiguous. Clear the stale value, then poll;
                // never display the requested value as a confirmed value.
                remoteSettings[setting] = SonyRemoteSettingState(issue:"Refresh to read the camera's actual value.")
                controlFeedback = error.localizedDescription
                diagnostics.record("setting.unconfirmed",["setting":setting.rawValue,"error":error.localizedDescription])
            }
        }
    }
    func triggerAutofocus() {
        guard canTriggerAF,let api = client else { return }
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
    private func updateExposureTelemetry() {
        telemetry.iso = remoteSettings[.iso]?.current?.label
        telemetry.aperture = remoteSettings[.aperture]?.current?.label
        telemetry.shutter = remoteSettings[.shutter]?.current?.label
        if case .compensation(let index,let step) = remoteSettings[.compensation]?.current { telemetry.ev = SonySettingValue.ev(index:index,step:step) }
        else { telemetry.ev = nil }
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
        generation = UUID(); connectionTask?.cancel(); monitorTask?.cancel(); recoveryTask?.cancel(); focusTask?.cancel()
        settingTask?.cancel(); refreshTask?.cancel(); settingTask = nil; refreshTask = nil
        remoteSettings = [:]; pendingSetting = nil; isRefreshingSettings = false; controlFeedback = nil
        model = "Sony camera"; resolution = "—"; streamFPS = nil; imageAspect = 3.0/2
        connectionTask = nil; monitorTask = nil; recoveryTask = nil; focusTask = nil
        healthySince = nil; streamInterruption = nil; isFocusing = false; controlState = SonyControlState()
        receiver?.close(); streamSession?.invalidateAndCancel(); streamSession = nil; receiver = nil
        if let api = client {
            let canStop = methods.contains("stopLiveview")
            let canRelease = methods.contains("cancelHalfPressShutter") || capabilities.contains("cancelHalfPressShutter")
            cleanupTask = Task {
                await api.cancelPendingRequests()
                if canRelease { _ = try? await api.call("cancelHalfPressShutter",timeout:2) }
                if canStop { _ = try? await api.call("stopLiveview",timeout:2) }
                await api.shutdown()
            }
        }
        client = nil
        if !preserveRequest { wantsConnection = false }
        previewFeed.display(nil); hasFrame = false; telemetry = CameraTelemetry(); methods = []; capabilities = []; isCapturing = false; state = .disconnected
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
