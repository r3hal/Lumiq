import Foundation
import Security

/// One AI decision for the current view, in the style of "tap ✦ → marked shot".
/// `frame` is the part of the visible viewfinder (normalized, top-left origin)
/// that should become the final photo. Width == height in normalized units
/// means it has the same shape as the viewfinder.
struct AIShotSuggestion: Equatable, Sendable {
    var subject: String
    var tip: String
    var technique: String
    var frame: CGRect
    var zoom: Double
    var provider: String
}

enum AIShotError: Error, Equatable {
    case notConfigured, noFrame, offline, timeout, unauthorized, quota, invalidResponse, server(Int)
    var message: String {
        switch self {
        case .notConfigured: return "Add a free AI server or Gemini key in Settings › AI Shot."
        case .noFrame: return "No camera frame yet. Try again."
        case .offline: return "No internet connection."
        case .timeout: return "The AI took too long. Tap ↻ to retry."
        case .unauthorized: return "The AI key or app token was refused. Check Settings › AI Shot."
        case .quota: return "Free AI limit reached for now. Try again in a minute."
        case .invalidResponse: return "The AI answer could not be used. Tap ↻ to retry."
        case .server(let code): return "AI server error \(code). Tap ↻ to retry."
        }
    }
}

struct AIShotRequest: Sendable {
    var jpeg: Data
    var aspect: Double
    var zoom: Double
    var minimumZoom: Double
    var maximumZoom: Double
}

/// Settings for the external, free AI. Server URL and token live in
/// UserDefaults; the optional direct Gemini key lives in the Keychain.
enum AIShotConfiguration {
    static let serverKey = "aiShot.serverURL"
    static let tokenKey = "aiShot.appToken"
    static let geminiKeychainAccount = "aiShot.geminiKey"

    static var serverURL: URL? {
        guard let text = UserDefaults.standard.string(forKey:serverKey)?.trimmingCharacters(in:.whitespacesAndNewlines),
              !text.isEmpty, var components = URLComponents(string:text), components.scheme == "https" || components.host == "localhost" else { return nil }
        if components.path.isEmpty || components.path == "/" { components.path = "/v1/shot" }
        return components.url
    }
    static var appToken: String? {
        let token = UserDefaults.standard.string(forKey:tokenKey)?.trimmingCharacters(in:.whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }
    static var geminiKey: String? { AIShotKeychain.read(geminiKeychainAccount) }
    static var isConfigured: Bool { serverURL != nil || geminiKey != nil }
}

enum AIShotService {
    static func suggest(_ request:AIShotRequest) async throws -> AIShotSuggestion {
        if let url = AIShotConfiguration.serverURL { return try await viaServer(url,request) }
        if let key = AIShotConfiguration.geminiKey { return try await viaGemini(key,request) }
        throw AIShotError.notConfigured
    }

    // MARK: Lumiq AI server (Cloudflare Worker in /ai-server)
    private static func viaServer(_ url:URL,_ request:AIShotRequest) async throws -> AIShotSuggestion {
        var http = URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:25)
        http.httpMethod = "POST"
        http.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if let token = AIShotConfiguration.appToken { http.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization") }
        http.httpBody = try JSONSerialization.data(withJSONObject:[
            "image":request.jpeg.base64EncodedString(),"aspect":request.aspect,"zoom":request.zoom,
            "minZoom":request.minimumZoom,"maxZoom":request.maximumZoom])
        let data = try await send(http)
        guard let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let frame = root["frame"] as? [String:Any] else { throw AIShotError.invalidResponse }
        func number(_ any:Any?) -> Double? { (any as? NSNumber)?.doubleValue }
        guard let x = number(frame["x"]), let y = number(frame["y"]), let w = number(frame["width"]), let h = number(frame["height"]) else { throw AIShotError.invalidResponse }
        return try validated(.init(subject:root["subject"] as? String ?? "your shot",tip:root["tip"] as? String ?? "",
            technique:root["technique"] as? String ?? "",frame:CGRect(x:x,y:y,width:w,height:h),
            zoom:number(root["zoom"]) ?? request.zoom,provider:root["provider"] as? String ?? "server"),request)
    }

    // MARK: Direct Gemini (free key from aistudio.google.com) — no server needed
    private static func viaGemini(_ key:String,_ request:AIShotRequest) async throws -> AIShotSuggestion {
        var lastError: Error = AIShotError.invalidResponse
        for model in ["gemini-flash-latest","gemini-flash-lite-latest"] {
            var http = URLRequest(url:URL(string:"https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!,
                                  cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:25)
            http.httpMethod = "POST"
            http.setValue("application/json",forHTTPHeaderField:"Content-Type")
            http.setValue(key,forHTTPHeaderField:"x-goog-api-key")
            http.httpBody = try JSONSerialization.data(withJSONObject:[
                "contents":[["role":"user","parts":[["text":prompt(request)],["inlineData":["mimeType":"image/jpeg","data":request.jpeg.base64EncodedString()]]]]],
                "generationConfig":["temperature":0.3,"maxOutputTokens":1024,"responseMimeType":"application/json","thinkingConfig":["thinkingBudget":0]]])
            do {
                let data = try await send(http)
                guard let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                      let candidate = (root["candidates"] as? [[String:Any]])?.first,
                      let parts = (candidate["content"] as? [String:Any])?["parts"] as? [[String:Any]] else { throw AIShotError.invalidResponse }
                let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
                return try parseModelJSON(text,request:request,provider:"gemini")
            } catch let error as AIShotError where error == .quota || error == .server(404) || error == .invalidResponse {
                lastError = error; continue
            }
        }
        throw lastError
    }

    static func prompt(_ request:AIShotRequest) -> String {
        """
        You are a world-class photographer standing behind someone holding a phone camera. Look at this live camera view and pick the single most beautiful photo that can be taken from it right now by only pointing the camera and zooming in. Prefer a clear subject with a clean composition: crop out clutter, empty floor, cut-off objects and distracting edges. A tighter, intentional crop usually beats the full view. If the full view is already best, return the whole frame.
        The viewfinder shape is \(String(format:"%.2f",request.aspect)):1 (width:height). Current zoom \(String(format:"%.1f",request.zoom))x; you may zoom in at most \(String(format:"%.1f",request.maximumZoom/request.zoom))x more.
        Return JSON only: {"subject": "2-5 lowercase words", "tip": "one imperative photographer instruction, max 9 words", "technique": "rule of thirds|centered|leading lines|symmetry|negative space|framing|fill the frame|layers|detail", "box_2d": [ymin, xmin, ymax, xmax] ideal photo crop, integers 0-1000, "confidence": 0-1}
        """
    }

    /// Mirrors ai-server/src/index.js `normalize` so both paths behave the same.
    static func parseModelJSON(_ text:String,request:AIShotRequest,provider:String) throws -> AIShotSuggestion {
        guard let start = text.firstIndex(of:"{"), let end = text.lastIndex(of:"}"), start < end,
              let root = try? JSONSerialization.jsonObject(with:Data(text[start...end].utf8)) as? [String:Any],
              let box = (root["box_2d"] ?? root["box"]) as? [NSNumber], box.count == 4 else { throw AIShotError.invalidResponse }
        var values = box.map(\.doubleValue)
        let scale = (values.max() ?? 0) <= 1.0001 ? 1.0 : 1000.0
        values = values.map { min(1,max(0,$0/scale)) }
        let ymin = min(values[0],values[2]), ymax = max(values[0],values[2]), xmin = min(values[1],values[3]), xmax = max(values[1],values[3])
        guard xmax-xmin >= 0.02, ymax-ymin >= 0.02 else { throw AIShotError.invalidResponse }
        return try validated(.init(subject:root["subject"] as? String ?? "your shot",tip:root["tip"] as? String ?? "",
            technique:root["technique"] as? String ?? "",frame:CGRect(x:xmin,y:ymin,width:xmax-xmin,height:ymax-ymin),
            zoom:request.zoom,provider:provider),request,fitShape:true)
    }

    /// Fits the crop to the viewfinder shape, keeps it reachable and on screen.
    static func validated(_ raw:AIShotSuggestion,_ request:AIShotRequest,fitShape:Bool = false) throws -> AIShotSuggestion {
        var s = raw
        let f = s.frame
        guard [f.minX,f.minY,f.width,f.height].allSatisfy(\.isFinite), f.width > 0, f.height > 0 else { throw AIShotError.invalidResponse }
        var size = Double(fitShape ? max(f.width,f.height) : f.width)
        size = min(1,max(size,request.zoom/max(request.maximumZoom,request.zoom),0.12))
        if size > 0.9 { size = 1 }
        let x = min(1-size,max(0,Double(f.midX)-size/2)), y = min(1-size,max(0,Double(f.midY)-size/2))
        s.frame = CGRect(x:x,y:y,width:size,height:size)
        s.zoom = min(request.maximumZoom,max(request.zoom,request.zoom/size))
        s.subject = clean(s.subject,48).lowercased()
        s.tip = clean(s.tip,80)
        if s.subject.isEmpty { s.subject = "your shot" }
        if s.tip.isEmpty { s.tip = "Center the frame and hold steady." }
        return s
    }
    private static func clean(_ text:String,_ maximum:Int) -> String {
        let flat = text.components(separatedBy:.controlCharacters).joined(separator:" ")
            .split(whereSeparator:\.isWhitespace).joined(separator:" ")
        return flat.count > maximum ? String(flat.prefix(maximum-1))+"…" : flat
    }

    private static func send(_ request:URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25; configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration:configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data,response) = try await session.data(for:request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return data
            case 401,403: throw AIShotError.unauthorized
            case 429: throw AIShotError.quota
            case 408,504: throw AIShotError.timeout
            default: throw AIShotError.server(status)
            }
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw AIShotError.timeout
            case .notConnectedToInternet,.networkConnectionLost,.cannotFindHost,.cannotConnectToHost: throw AIShotError.offline
            default: throw AIShotError.server(error.errorCode)
            }
        }
    }
}

enum AIShotKeychain {
    private static func query(_ account:String) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"app.lumiq.aishot",kSecAttrAccount as String:account]
    }
    static func read(_ account:String) -> String? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&item) == errSecSuccess, let data = item as? Data,
              let text = String(data:data,encoding:.utf8), !text.isEmpty else { return nil }
        return text
    }
    static func write(_ value:String?,account:String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let value = value?.trimmingCharacters(in:.whitespacesAndNewlines), !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary,nil)
    }
}
