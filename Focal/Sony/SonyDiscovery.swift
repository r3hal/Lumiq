import Foundation
import Combine
import Darwin

struct SonyDiscoveredCamera: Identifiable, Sendable {
    let host:String
    let model:String
    let descriptorURL:URL
    var id:String { host }
}

/// Bounded unicast discovery on the actual Wi-Fi subnet. No fixed camera IP,
/// multicast entitlement, guessed successful connection or SDK dependency.
enum SonyDiscovery {
    static func ipv4(_ address:UInt32) -> String {
        "\((address >> 24)&255).\((address >> 16)&255).\((address >> 8)&255).\(address&255)"
    }
    static func number(_ host:String) -> UInt32? {
        guard SonyEndpoint.validHost(host) else { return nil }
        return host.split(separator:".").compactMap { UInt32($0) }.reduce(0) { ($0 << 8)|$1 }
    }
    static func candidates(address:UInt32,mask:UInt32,previous:String? = nil) -> [String] {
        let inverse = ~mask
        guard mask != 0, inverse >= 3, inverse & (inverse+1) == 0, SonyEndpoint.validHost(ipv4(address)) else { return [] }
        let network = address&mask, broadcast = network|inverse
        var values = [UInt32]()
        func add(_ candidate:UInt32) {
            guard candidate > network, candidate < broadcast, candidate != address,
                  SonyEndpoint.validHost(ipv4(candidate)), !values.contains(candidate) else { return }
            values.append(candidate)
        }
        if let previous, let candidate = number(previous), candidate&mask == network { add(candidate) }
        for offset in 1...32 {
            let candidate = UInt64(network)+UInt64(offset)
            if candidate < UInt64(broadcast) { add(UInt32(candidate)) }
        }
        for offset in -16...16 {
            let candidate = Int64(address)+Int64(offset)
            if candidate >= 0 && candidate <= Int64(UInt32.max) { add(UInt32(candidate)) }
        }
        return Array(values.prefix(64)).map(ipv4)
    }
    static func wifiSubnet() -> (address:UInt32,mask:UInt32)? {
        var interfaces:UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        while let pointer = current {
            let interface = pointer.pointee
            current = interface.ifa_next
            guard String(cString:interface.ifa_name) == "en0", let address = interface.ifa_addr, let mask = interface.ifa_netmask,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let a = address.withMemoryRebound(to:sockaddr_in.self,capacity:1) { UInt32(bigEndian:$0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to:sockaddr_in.self,capacity:1) { UInt32(bigEndian:$0.pointee.sin_addr.s_addr) }
            if SonyEndpoint.validHost(ipv4(a)) { return (a,m) }
        }
        return nil
    }
    static func discover(previous:String?) async throws -> [SonyDiscoveredCamera] {
        guard let subnet = wifiSubnet() else { throw SonyRemoteError(message:"Join the camera's Wi-Fi in iPhone Settings, then search again. You can also enter its actual address manually.") }
        let hosts = candidates(address:subnet.address,mask:subnet.mask,previous:previous)
        return await withTaskGroup(of:SonyDiscoveredCamera?.self) { group in
            var index = 0, found = [SonyDiscoveredCamera]()
            for _ in 0..<min(4,hosts.count) {
                let host = hosts[index]; index += 1
                group.addTask { await probe(host) }
            }
            while let result = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                if let result { found.append(result) }
                if index < hosts.count {
                    let host = hosts[index]; index += 1
                    group.addTask { await probe(host) }
                }
            }
            return found.sorted { $0.host < $1.host }
        }
    }
    private static func probe(_ host:String) async -> SonyDiscoveredCamera? {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false; config.timeoutIntervalForRequest = 0.8; config.timeoutIntervalForResource = 1.2
        config.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration:config,delegate:SonyLocalSessionDelegate(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        for port in [64321,61000] {
            guard !Task.isCancelled, let url = URL(string:"http://\(host):\(port)/DmsRmtDesc.xml") else { return nil }
            do {
                let (data,response) = try await session.data(from:url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 512*1024 else { continue }
                let descriptor = try SonyDescriptor.parse(data,host:host)
                return .init(host:host,model:descriptor.model,descriptorURL:url)
            } catch { if Task.isCancelled { return nil } }
        }
        return nil
    }
}

@MainActor
final class SonyDiscoveryModel: ObservableObject {
    @Published private(set) var searching = false
    @Published private(set) var cameras:[SonyDiscoveredCamera] = []
    @Published private(set) var message:String?
    private var operation:Task<Void,Never>?
    private var generation = UUID()
    func search(previous:String?,diagnostics:SonyDiagnostics? = nil) {
        cancel(); let token = generation
        searching = true; cameras = []; message = "Checking advertised camera descriptors on your Wi-Fi subnet…"
        diagnostics?.record("discovery.started")
        operation = Task {
            do {
                let results = try await SonyDiscovery.discover(previous:previous)
                guard token == generation, !Task.isCancelled else { return }
                cameras = results; searching = false
                diagnostics?.record("discovery.completed",["count":String(results.count),"cameras":results.map { $0.model+" · "+$0.host }.joined(separator:",")])
                message = results.isEmpty ? "No compatible descriptor found in this bounded search. Check the camera mode and use its address manually if needed." : "Descriptor found. Connect to verify the actual live view."
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                searching = false; message = error.localizedDescription
                diagnostics?.record("discovery.failed",["error":error.localizedDescription])
            }
        }
    }
    func cancel() { generation = UUID(); operation?.cancel(); operation = nil; searching = false }
}
