import Foundation
import Combine
import UIKit
import ImageIO

@MainActor
final class SonyRemoteCamera: ObservableObject {
    enum State: Equatable { case disconnected, connecting, streaming, failed }
    @Published private(set) var state: State = .disconnected
    @Published private(set) var frame: UIImage?
    @Published private(set) var model = "Sony camera"
    @Published private(set) var telemetry = CameraTelemetry()
    @Published private(set) var methods = Set<String>()
    @Published private(set) var frameCount = 0
    @Published private(set) var resolution = "—"
    @Published private(set) var isCapturing = false
    @Published private(set) var message: String?
    @Published var host = "192.168.122.1"
    var onJPEG: ((Data)->Void)?
    private var client: SonyAPIClient?
    private var receiver: SonyStreamReceiver?
    private var streamSession: URLSession?
    private var connectionTask: Task<Void,Never>?
    private var monitorTask: Task<Void,Never>?
    private var cleanupTask: Task<Void,Never>?
    private var generation = UUID()
    private var lastFrame: TimeInterval = 0
    private var wantsConnection = false
    var canCapture: Bool { state == .streaming && methods.contains("actTakePicture") && !isCapturing }
    var supportsTouchFocus: Bool { state == .streaming && methods.contains("setTouchAFPosition") }

    func connect() {
        let selectedHost = host.trimmingCharacters(in:.whitespacesAndNewlines)
        guard SonyEndpoint.validHost(selectedHost) else { state = .failed; message = "Enter the camera’s private IPv4 address after joining its DIRECT Wi-Fi."; return }
        close(preserveRequest:false)
        wantsConnection = true; host = selectedHost
        state = .connecting; message = nil; frameCount = 0
        let current = generation
        let previousCleanup = cleanupTask
        connectionTask = Task {
            await previousCleanup?.value
            guard current == generation,!Task.isCancelled else { return }
            do {
                var descriptor: SonyDescriptor?
                var lastError: Error?
                for port in [64321,61000] {
                    try Task.checkCancellation()
                    let url = URL(string:"http://\(selectedHost):\(port)/DmsRmtDesc.xml")!
                    do {
                        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 2.5; config.timeoutIntervalForResource = 3
                        let discovery = URLSession(configuration:config,delegate:SonyLocalSessionDelegate(),delegateQueue:nil)
                        defer { discovery.invalidateAndCancel() }
                        let (data,response) = try await discovery.data(from:url)
                        guard let http = response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else { throw SonyRemoteError(message:"The camera did not return a descriptor.") }
                        descriptor = try SonyDescriptor.parse(data,host:selectedHost); break
                    } catch { lastError = error }
                }
                guard current == generation,!Task.isCancelled else { return }
                guard let descriptor else { throw lastError ?? SonyRemoteError(message:"No advertised Sony wireless service was found.") }
                let api = SonyAPIClient(endpoint:descriptor.endpoint); client = api
                var supported = try await Self.available(api)
                if supported.contains("startRecMode") {
                    _ = try await api.call("startRecMode")
                    try await Task.sleep(for:.milliseconds(350))
                    supported = try await Self.available(api)
                }
                var liveURL = descriptor.liveURL
                if supported.contains("startLiveview") {
                    let result = try SonyAPIClient.result(await api.call("startLiveview"))
                    liveURL = (result.first as? String).flatMap(URL.init(string:))
                }
                guard let liveURL else { throw SonyRemoteError(message:"This camera mode does not advertise a live-view stream. PTP/IP requires a separate adapter.") }
                let validated = try SonyEndpoint.validate(liveURL,host:selectedHost)
                guard current == generation,!Task.isCancelled else { return }
                model = descriptor.model; methods = supported
                openStream(validated,generation:current)
                monitorTask = Task {
                    var lastEvent: TimeInterval = 0
                    while !Task.isCancelled && current == generation {
                        try? await Task.sleep(for:.seconds(1))
                        guard !Task.isCancelled,current == generation else { return }
                        let now = ProcessInfo.processInfo.systemUptime
                        if !isCapturing && now-lastFrame > 8 { fail("Sony live view stopped. Check Wi-Fi and reconnect.",generation:current); return }
                        if supported.contains("getEvent"), !isCapturing,now-lastEvent >= 2 {
                            lastEvent = now
                            do {
                                let result = try SonyAPIClient.result(await api.call("getEvent",params:[false]))
                                guard current == generation else { return }
                                telemetry = SonyEventValues.telemetry(result)
                            } catch { if current == generation { telemetry = CameraTelemetry() } }
                        }
                    }
                }
            } catch {
                guard current == generation,!Task.isCancelled else { return }
                fail("Could not establish Sony live view. Check DIRECT Wi-Fi, Local Network access and camera remote mode. \(error.localizedDescription)",generation:current)
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
        let delegate = SonyStreamReceiver(onFrame:{ [weak self] data in
            guard let source = CGImageSourceCreateWithData(data as CFData,nil),let dimensions = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  let width = dimensions[kCGImagePropertyPixelWidth] as? Int,let height = dimensions[kCGImagePropertyPixelHeight] as? Int,
                  width > 0,height > 0,Int64(width)*Int64(height) <= 16_000_000,
                  let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:2400] as CFDictionary) else { return }
            let image = UIImage(cgImage:cg)
            Task { @MainActor in
                guard let self,current == self.generation else { return }
                self.frame = image; self.state = .streaming; self.frameCount += 1
                self.lastFrame = ProcessInfo.processInfo.systemUptime
                self.resolution = "\(width) × \(height)"
                self.onJPEG?(data)
            }
        },onEnd:{ [weak self] error in
            Task { @MainActor in self?.fail(error?.localizedDescription ?? "Sony ended the live-view stream.",generation:current) }
        })
        receiver = delegate
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 3600
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration:config,delegate:delegate,delegateQueue:queue)
        streamSession = session
        session.dataTask(with:url).resume()
    }
    func focus(at point:UnitPoint2D) {
        guard supportsTouchFocus,let api = client else { return }
        let current = generation
        Task {
            do { _ = try await api.call("setTouchAFPosition",params:[max(0,min(1,point.x))*100,max(0,min(1,point.y))*100]) }
            catch { if current == generation { message = error.localizedDescription } }
        }
    }
    func capture() async throws -> CameraCapture {
        guard canCapture,let api = client else { throw SonyRemoteError(message:"Sony remote capture is not advertised or live view is disconnected.") }
        let current = generation,selectedHost = host
        isCapturing = true; defer { if current == generation { isCapturing = false; lastFrame = ProcessInfo.processInfo.systemUptime } }
        let result = try SonyAPIClient.result(await api.call("actTakePicture",timeout:30))
        guard current == generation else { throw CancellationError() }
        guard let urls = result.first as? [String],let text = urls.first,let url = URL(string:text) else { throw SonyRemoteError(message:"The camera may have taken a photo, but did not return a transferable JPEG URL.") }
        let verified = try SonyEndpoint.validate(url,host:selectedHost)
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        let transfer = URLSession(configuration:config,delegate:SonyLocalSessionDelegate(),delegateQueue:nil); defer { transfer.invalidateAndCancel() }
        let (data,response) = try await transfer.data(from:verified)
        guard current == generation,let http = response as? HTTPURLResponse,(200..<300).contains(http.statusCode),data.prefix(2) == Data([0xff,0xd8]),CGImageSourceCreateWithData(data as CFData,nil) != nil else {
            throw SonyRemoteError(message:"The Sony photo transfer failed. Check the camera’s card for the capture.")
        }
        return CameraCapture(processed:data,raw:nil)
    }
    func pause() { close(preserveRequest:true) }
    func resume() { if wantsConnection { connect() } }
    func disconnect() { close(preserveRequest:false) }
    private func fail(_ message:String,generation current:UUID) {
        guard current == generation else { return }
        close(preserveRequest:true); state = .failed; self.message = message
    }
    private func close(preserveRequest:Bool) {
        generation = UUID(); connectionTask?.cancel(); monitorTask?.cancel()
        connectionTask = nil; monitorTask = nil
        streamSession?.invalidateAndCancel(); streamSession = nil; receiver = nil
        if let api = client {
            let canStop = methods.contains("stopLiveview")
            cleanupTask = Task {
                await api.cancelPendingRequests()
                if canStop { _ = try? await api.call("stopLiveview",timeout:2) }
                await api.shutdown()
            }
        }
        client = nil
        if !preserveRequest { wantsConnection = false }
        frame = nil; telemetry = CameraTelemetry(); methods = []; isCapturing = false; state = .disconnected
    }
}

private final class SonyStreamReceiver: NSObject,URLSessionDataDelegate {
    private var parser = SonyLiveViewParser()
    private var lastDelivery: TimeInterval = -.infinity
    private let onFrame:(Data)->Void
    private let onEnd:(Error?)->Void
    init(onFrame:@escaping(Data)->Void,onEnd:@escaping(Error?)->Void) { self.onFrame = onFrame; self.onEnd = onEnd }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void) {
        guard let http = response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else {
            completionHandler(.cancel); onEnd(SonyRemoteError(message:"Sony live-view HTTP request was rejected.")); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        do {
            let frames = try parser.append(data)
            let now = ProcessInfo.processInfo.systemUptime
            if now-lastDelivery >= 0.1,let latest = frames.last { lastDelivery = now; onFrame(latest) }
        }
        catch { session.invalidateAndCancel(); onEnd(error) }
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) { onEnd(error) }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,
                    newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) { completionHandler(nil) }

}
