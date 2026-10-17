import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supplied by a future authenticated account/device enrollment implementation,
/// independently of photo-backup consent. Never a bundled shared app secret.
struct CloudProxyCredential:Sendable {
    let accessToken:String
    let expiresAt:Date
}
protocol CloudProxyCredentialProviding {
    func credential() async throws -> CloudProxyCredential
}

/// Production adapter seam. No default endpoint, credentials or automatic calls.
/// The host must implement the authenticated contract in CLOUD_COMPOSITION_PROXY.
/// A successful response remains a proposal: CameraController matches it locally.
actor CloudCompositionProxyService:CloudCompositionService {
    private let endpoint:URL
    private let credentials:any CloudProxyCredentialProviding
    private let transport:any CloudHTTPTransport
    private var active = false
    private var attempted = [UUID]()
    init(endpoint:URL,credentials:any CloudProxyCredentialProviding,transport:any CloudHTTPTransport = EphemeralCloudHTTPTransport()) {
        self.endpoint = endpoint; self.credentials = credentials; self.transport = transport
    }
    func scan(_ capture:CloudScanCapture) async throws -> CloudCompositionResult {
        guard Self.valid(endpoint) else { throw CloudCompositionError.notConfigured }
        guard !active else { throw CloudCompositionError.quota }
        guard !attempted.contains(capture.requestID) else { throw CloudCompositionError.stale }
        try Task.checkCancellation()
        let body = try Self.body(capture)
        active = true; defer { active = false }
        let credential = try await credentials.credential()
        try Task.checkCancellation()
        guard credential.expiresAt.timeIntervalSinceNow > 30,
              (32...8192).contains(credential.accessToken.utf8.count),
              !credential.accessToken.unicodeScalars.contains(where:{CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)}) else {
            throw CloudCompositionError.unauthorized
        }
        var request = URLRequest(url:endpoint,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:20)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("Bearer "+credential.accessToken,forHTTPHeaderField:"Authorization")
        request.setValue(capture.requestID.uuidString.lowercased(),forHTTPHeaderField:"Idempotency-Key")
        // Never retry an image after uncertain delivery. A new explicit scan
        // has a new ID; server-side idempotency is mandatory across app restarts.
        attempted.append(capture.requestID); attempted = Array(attempted.suffix(128))
        let response = try await transport.send(request)
        try Task.checkCancellation()
        switch response.status {
        case 200: break
        case 401,403: throw CloudCompositionError.unauthorized
        case 408,504: throw CloudCompositionError.timeout
        case 429: throw CloudCompositionError.quota
        default: throw CloudCompositionError.serviceUnavailable
        }
        return try Self.result(response.data,requestID:capture.requestID)
    }
    static func valid(_ endpoint:URL) -> Bool {
        guard let p = URLComponents(url:endpoint,resolvingAgainstBaseURL:false),
              p.scheme == "https", let host = p.host, host.contains("."), host != "localhost", !host.hasSuffix(".local"),
              host.range(of:"^[A-Za-z0-9.-]+$",options:.regularExpression) != nil,
              host.contains(where:{$0.isLetter}), p.port == nil || p.port == 443,
              p.user == nil, p.password == nil, p.query == nil, p.fragment == nil,
              p.path == "/v1/composition-scans" else { return false }
        return true
    }
    static func body(_ capture:CloudScanCapture) throws -> Data {
        let local = capture.evidence
        guard local.isIPhone, local.mode == .automatic else { throw CloudCompositionError.unsupportedSource }
        guard !capture.jpeg.isEmpty, capture.jpeg.count <= 163_840, capture.jpeg.prefix(2) == Data([0xff,0xd8]),
              local.zoom.isFinite, local.minimumZoom.isFinite, local.maximumZoom.isFinite,
              local.minimumZoom > 0, local.minimumZoom <= local.zoom, local.zoom <= local.maximumZoom,
              local.confidence.isFinite, (0...1).contains(local.confidence) else { throw CloudCompositionError.unavailableFrame }
        var facts:[String:Any] = ["currentZoom":local.zoom,"minimumZoom":local.minimumZoom,"maximumZoom":local.maximumZoom,"intent":local.intent.rawValue]
        if local.freshTrack, let b = local.bounds {
            guard CloudCompositionResult.safeText(local.label,maximum:120) else { throw CloudCompositionError.invalidResponse }
            facts["subject"] = ["id":"selected","label":local.label,"confidence":local.confidence,
                "box":["x":Double(b.minX),"y":Double(b.minY),"width":Double(b.width),"height":Double(b.height)]]
        } else { facts["subject"] = NSNull() }
        return try JSONSerialization.data(withJSONObject:["requestId":capture.requestID.uuidString.lowercased(),
            "mimeType":"image/jpeg","image":capture.jpeg.base64EncodedString(),"facts":facts],options:.sortedKeys)
    }
    static func result(_ data:Data,requestID:UUID) throws -> CloudCompositionResult {
        guard data.count <= 131_072, let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(root.keys) == ["requestId","modelVersion","result"],
              let id = root["requestId"] as? String, UUID(uuidString:id) == requestID,
              let model = root["modelVersion"] as? String, CloudCompositionResult.safeText(model,maximum:120),
              let result = root["result"] as? [String:Any] else { throw CloudCompositionError.invalidResponse }
        return try CloudCompositionResult.decode(JSONSerialization.data(withJSONObject:result))
    }
}
