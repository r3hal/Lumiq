import Foundation

struct SonyAPIError: LocalizedError {
    let method: String
    let code: Int
    let detail: String
    var errorDescription: String? {
        let action = method == "actTakePicture" || method == "awaitTakePicture" ? "take the photo" : method == "setTouchAFPosition" ? "set touch focus" : "complete \(method)"
        let explanation: String
        switch code {
        case 5, 403: explanation = "Sony refused to \(action) in its current mode. Select still-photo mode and let the camera finish its current operation."
        case 40400: explanation = "Sony could not take the photo. Focus on a clear edge, check the memory card and shooting mode, then try again."
        case 40401: explanation = "Sony is not ready yet. Let focus or the current operation finish, then try again."
        case 40403: explanation = "Sony is still processing this photo. Check the camera card before taking another."
        case 12: explanation = "This Sony mode does not support \(method)."
        default: explanation = "Sony could not \(action)."
        }
        let reported = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return explanation + " (\(method), code \(code))" + (reported.isEmpty ? "" : "\n\(reported)")
    }
    static func parse(_ object: [String: Any], method: String) -> Self? {
        guard let values = object["error"] as? [Any], let number = values.first as? NSNumber else { return nil }
        return Self(method: method, code: number.intValue, detail: values.dropFirst().compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

struct SonyControlState {
    var cameraStatus: String?
    var focusStatus: String?
    var availableMethods: Set<String>?
    var captureBusy: Bool {
        guard let cameraStatus else { return false }
        return ["StillCapturing", "StillSaving", "MovieRecording", "AudioRecording", "IntervalRecording", "NotReady", "ContentsTransfer"].contains(cameraStatus)
    }
    static func from(_ values: [Any]) -> Self {
        var state = Self()
        func walk(_ value: Any) {
            if let values = value as? [Any] { values.forEach(walk) }
            else if let item = value as? [String: Any] {
                switch item["type"] as? String {
                case "cameraStatus": state.cameraStatus = item["cameraStatus"] as? String
                case "focusStatus": state.focusStatus = item["focusStatus"] as? String
                case "availableApiList":
                    if let names = item["names"] as? [String] { state.availableMethods = Set(names) }
                default: break
                }
            }
        }
        values.forEach(walk); return state
    }
}

enum SonyMethodCapabilities {
    static func names(_ result: [Any]) -> Set<String> {
        var names = Set<String>()
        func walk(_ value: Any) {
            guard let array = value as? [Any] else { return }
            if array.count >= 4, let method = array.first as? String,
               array[1] is [Any], array[2] is [Any], array[3] is String { names.insert(method) }
            else { array.forEach(walk) }
        }
        result.forEach(walk); return names
    }
}

struct SonyReconnectPolicy {
    private(set) var attempts = 0
    mutating func reset() { attempts = 0 }
    mutating func nextDelay(requested: Bool) -> TimeInterval? {
        guard requested, attempts < 3 else { return nil }
        let delay = pow(2.0, Double(attempts)); attempts += 1; return delay
    }
}

/// Exactly one shutter command per user action. A pending capture uses
/// awaitTakePicture; it must never resend actTakePicture after a timeout.
@MainActor
enum SonyCaptureWorkflow {
    typealias Call = (String, [Any], TimeInterval) async throws -> Data
    typealias Wait = (TimeInterval) async throws -> Void
    static func take(call: Call, supported: Set<String> = [], active: () -> Bool, wait: Wait = { try await Task.sleep(for: .seconds($0)) }) async throws -> [String] {
        func check() throws { guard active(), !Task.isCancelled else { throw CancellationError() } }
        func result(_ method: String, _ params: [Any] = [], timeout: TimeInterval = 3) async throws -> [Any] {
            try check(); let data = try await call(method, params, timeout); try check()
            return try SonyAPIClient.result(data)
        }
        func available() async throws -> Set<String> {
            guard let values = try await result("getAvailableApiList").first as? [String] else { throw SonyRemoteError(message: "Sony did not report its current controls.") }
            return Set(values)
        }
        var methods = try await available()
        if methods.contains("getEvent") {
            let state = SonyControlState.from(try await result("getEvent", [false]))
            guard !state.captureBusy else { throw SonyRemoteError(message: "Sony is busy (\(state.cameraStatus ?? "current operation")). Finish that operation before taking a photo.") }
        }
        if methods.contains("getShootMode"), let mode = try await result("getShootMode").first as? String, mode != "still" {
            guard methods.contains("setShootMode"), methods.contains("getAvailableShootMode"),
                  let modes = try await result("getAvailableShootMode").last as? [String], modes.contains("still") else {
                throw SonyRemoteError(message: "Select still-photo mode on Sony, then try the shutter again.")
            }
            _ = try await result("setShootMode", ["still"])
            methods.remove("actTakePicture")
        }
        for _ in 0..<8 where !methods.contains("actTakePicture") {
            try await wait(0.2); methods = try await available()
        }
        guard methods.contains("actTakePicture") else { throw SonyRemoteError(message: "Sony has not enabled still capture in this mode. Select still-photo mode and wait for it to become ready.") }
        let focusMode = methods.contains("getFocusMode") ? (try? await result("getFocusMode").first as? String) : nil
        let halfPress = focusMode != "MF" && methods.contains("actHalfPressShutter") && (methods.contains("cancelHalfPressShutter") || supported.contains("cancelHalfPressShutter"))
        var halfPressed = false
        do {
            if halfPress {
                do { _ = try await result("actHalfPressShutter"); halfPressed = true }
                catch let error as SonyAPIError where error.code == 5 || error.code == 12 {
                    // Optional AF preparation was explicitly refused; a single
                    // normal capture can still work with native/manual focus.
                }
                if halfPressed && methods.contains("getEvent") {
                    for _ in 0..<12 {
                        let status = SonyControlState.from(try await result("getEvent", [false])).focusStatus
                        if status == "Focused" { break }
                        if status == "Failed" { throw SonyRemoteError(message: "Sony autofocus did not lock. Aim at a clear edge or focus manually on the camera, then try again.") }
                        if status == nil { try await wait(0.5); break }
                        try await wait(0.15)
                    }
                } else if halfPressed { try await wait(0.5) }
            }
            var capture: [Any]
            do { capture = try await result("actTakePicture", timeout: 30) }
            catch let error as SonyAPIError where error.code == 40403 {
                let current = try await available()
                guard current.contains("awaitTakePicture") else { throw error }
                capture = try await result("awaitTakePicture", timeout: 30)
            }
            if halfPressed { _ = try? await call("cancelHalfPressShutter", [], 2); halfPressed = false }
            try check()
            guard let urls = capture.first as? [String], !urls.isEmpty else {
                throw SonyRemoteError(message: "Sony may have taken the photo but returned no transfer URL. Check the camera card before shooting again.")
            }
            return urls
        } catch {
            if halfPressed, active() { _ = try? await call("cancelHalfPressShutter", [], 2) }
            throw error
        }
    }
}
