import Foundation
import CoreFoundation

enum SonyRemoteSetting: String, CaseIterable, Identifiable {
    case iso, aperture, shutter, whiteBalance, compensation
    var id: Self { self }
    var title: String {
        switch self {
        case .iso: return "ISO"
        case .aperture: return "Aperture"
        case .shutter: return "Shutter speed"
        case .whiteBalance: return "White balance"
        case .compensation: return "Exposure compensation"
        }
    }
    var suffix: String {
        switch self {
        case .iso: return "IsoSpeedRate"
        case .aperture: return "FNumber"
        case .shutter: return "ShutterSpeed"
        case .whiteBalance: return "WhiteBalance"
        case .compensation: return "ExposureCompensation"
        }
    }
    var getter: String { "get"+suffix }
    var available: String { "getAvailable"+suffix }
    var setter: String { "set"+suffix }
    var eventType: String { suffix.prefix(1).lowercased()+suffix.dropFirst() }
}

enum SonySettingValue: Hashable, Identifiable {
    case text(String)
    case whiteBalance(mode:String,temperature:Int?)
    case compensation(index:Int,step:Int?)
    var id: String {
        switch self {
        case .text(let s): return s
        case .whiteBalance(let mode,let temperature): return mode+":"+(temperature.map(String.init) ?? "none")
        case .compensation(let index,let step): return "\(index):\(step ?? 0)"
        }
    }
    var label: String {
        switch self {
        case .text(let s): return s
        case .whiteBalance(let mode,let t): return t.map { "\(mode) · \($0) K" } ?? mode
        case .compensation(let index,let step):
            if let ev = Self.ev(index:index,step:step) { return String(format:"%+.2f EV",ev) }
            return "Index \(index) · EV step not reported"
        }
    }
    static func ev(index:Int,step:Int?) -> Double? {
        step == 1 ? Double(index)/3 : step == 2 ? Double(index)/2 : index == 0 ? 0 : nil
    }
    var parameters: [Any] {
        switch self {
        case .text(let s): return [s]
        case .whiteBalance(let mode,let temperature): return [mode,temperature != nil,temperature ?? -1]
        case .compensation(let index,_): return [index]
        }
    }
}

enum SonySettingReadStatus: Equatable {
    case unknown, loading, available, unsupported
    case unavailable(String), connectionError(String), error(String)
    var label:String {
        switch self {
        case .unknown: return "Unknown"
        case .loading: return "Loading…"
        case .available: return "Available"
        case .unsupported: return "Unsupported"
        case .unavailable: return "Unavailable"
        case .connectionError: return "Connection error"
        case .error: return "Read failed"
        }
    }
}

enum SonyRemoteControlStatus: Equatable {
    case unknown, available, unsupported, commandInProgress
    case temporarilyUnavailable(String), error(String)
    var reason:String? {
        switch self {
        case .available: return nil
        case .unknown: return "Waiting for the camera's control information."
        case .unsupported: return "The camera's supported-method list does not include this setter."
        case .commandInProgress: return "Waiting for this setting's camera confirmation…"
        case .temporarilyUnavailable(let reason), .error(let reason): return reason
        }
    }
    var name:String {
        switch self {
        case .unknown: return "Unknown"
        case .available: return "Available"
        case .unsupported: return "Unsupported"
        case .commandInProgress: return "CommandInProgress"
        case .temporarilyUnavailable: return "TemporarilyUnavailable"
        case .error: return "Error"
        }
    }
}

struct SonyRemoteSettingState: Equatable {
    var current: SonySettingValue?
    var choices: [SonySettingValue] = []
    var issue: String?
    var readAt: Date?
    var readStatus: SonySettingReadStatus = .unknown
    var choicesReported = false
    var temperatureReported = false
    var sourceMethod:String?
    var displayValue:String { current?.label ?? readStatus.label }
    // Reading the same values again must not publish a new SwiftUI snapshot.
    static func ==(lhs:Self,rhs:Self) -> Bool {
        lhs.current == rhs.current && lhs.choices == rhs.choices && lhs.issue == rhs.issue && lhs.readStatus == rhs.readStatus && lhs.choicesReported == rhs.choicesReported
    }
    func merging(_ update:Self) -> Self {
        var next = self
        if let current = update.current {
            if case .compensation(let index,nil) = current, case .compensation(_,let step) = next.current {
                next.current = .compensation(index:index,step:step)
            } else if case .whiteBalance(let mode,nil) = current, !update.temperatureReported,
                      case .whiteBalance(let oldMode,let temperature) = next.current, mode == oldMode {
                next.current = .whiteBalance(mode:mode,temperature:temperature)
            } else { next.current = current }
            next.readAt = update.readAt
        }
        if update.choicesReported { next.choices = update.choices; next.choicesReported = true }
        if let method = update.sourceMethod { next.sourceMethod = method }
        // Missing event fields are not explicit read failures.
        if update.readStatus != .unknown { next.readStatus = update.readStatus; next.issue = update.issue }
        return next
    }
    static func failure(_ error:Error) -> Self {
        let status:SonySettingReadStatus
        if error is URLError { status = .connectionError(error.localizedDescription) }
        else if let api = error as? SonyAPIError, api.code == 12 { status = .unsupported }
        else if let api = error as? SonyAPIError, [5,403,40401].contains(api.code) { status = .unavailable(error.localizedDescription) }
        else { status = .error(error.localizedDescription) }
        return .init(issue:error.localizedDescription,readStatus:status)
    }
    func disabledReason(setting:SonyRemoteSetting,available:Set<String>,supported:Set<String>) -> String? {
        if !available.contains(setting.setter) {
            return supported.contains(setting.setter) ? "Unavailable in the camera's current shooting mode." : "This camera connection does not advertise this control."
        }
        if let issue { return issue }
        if current == nil { return "The camera has not reported a current value." }
        if choices.isEmpty { return "No currently available values were reported. Adjust this on the camera." }
        return nil
    }
}

/// Sony Camera Remote API beta v2.40, documented version-1.0 wire formats.
/// Supported ranges are never substituted for currently available lens/mode values.
enum SonySettingParser {
    static func integer(_ value:Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue.rounded() == n.doubleValue, abs(n.doubleValue) < 1_000_000 else { return nil }
        return n.intValue
    }
    static func parse(_ setting:SonyRemoteSetting,result:[Any],available:Bool) -> SonyRemoteSettingState {
        var s = SonyRemoteSettingState(readAt:Date(),sourceMethod:available ? setting.available : setting.getter)
        switch setting {
        case .iso,.aperture,.shutter:
            if let text = result.first as? String, !text.isEmpty { s.current = .text(text) }
            if available, result.count > 1, let list = result[1] as? [String] {
                s.choicesReported = true
                s.choices = Array(list.prefix(1024)).filter { !$0.isEmpty }.map(SonySettingValue.text)
            }
        case .whiteBalance:
            if let value = result.first as? [String:Any], let mode = value["whiteBalanceMode"] as? String {
                let t = integer(value["colorTemperature"])
                s.temperatureReported = value["colorTemperature"] != nil
                s.current = .whiteBalance(mode:mode,temperature:t.flatMap { $0 > 0 ? $0 : nil })
            }
            if available, result.count > 1, let modes = result[1] as? [[String:Any]] {
                s.choicesReported = true
                for mode in modes.prefix(64) {
                    guard let name = mode["whiteBalanceMode"] as? String, !name.isEmpty,
                          let range = mode["colorTemperatureRange"] as? [Any] else { continue }
                    if range.isEmpty { s.choices.append(.whiteBalance(mode:name,temperature:nil)); continue }
                    guard range.count == 3, let max = integer(range[0]), let min = integer(range[1]),
                          let step = integer(range[2]), min > 0, max >= min, step > 0, (max-min)/step < 512 else { continue }
                    s.choices += stride(from:min,through:max,by:step).map { .whiteBalance(mode:name,temperature:$0) }
                }
            }
        case .compensation:
            let step = available && result.count >= 4 ? integer(result[3]) : nil
            if let index = integer(result.first) { s.current = .compensation(index:index,step:step) }
            if available, result.count >= 4, let max = integer(result[1]), let min = integer(result[2]),
               max >= min, max-min <= 128, step == 1 || step == 2 {
                s.choicesReported = true
                s.choices = (min...max).map { .compensation(index:$0,step:step) }
            }
        }
        if s.current == nil { s.issue = "Camera returned an unrecognized current value."; s.readStatus = .error(s.issue!) }
        else { s.readStatus = .available }
        var seen = Set<SonySettingValue>(); s.choices = s.choices.filter { seen.insert($0).inserted }
        return s
    }
    static func event(_ setting:SonyRemoteSetting,values:[Any]) -> SonyRemoteSettingState? {
        var found: [String:Any]?
        func walk(_ v:Any) {
            if let list = v as? [Any] { list.forEach(walk) }
            else if let item = v as? [String:Any], item["type"] as? String == setting.eventType { found = item }
        }
        values.forEach(walk)
        guard let item = found else { return nil }
        let result:[Any]
        switch setting {
        case .iso,.aperture,.shutter:
            result = [item["current"+setting.suffix] ?? NSNull(),item[setting.eventType+"Candidates"] ?? NSNull()]
        case .whiteBalance:
            result = [["whiteBalanceMode":item["currentWhiteBalanceMode"] ?? NSNull(),"colorTemperature":item["currentColorTemperature"] ?? -1],
                      item["whiteBalanceCandidates"] ?? NSNull()]
        case .compensation:
            result = [item["currentExposureCompensation"] ?? NSNull(),item["maxExposureCompensation"] ?? NSNull(),
                item["minExposureCompensation"] ?? NSNull(),item["stepIndexOfExposureCompensation"] ?? NSNull()]
        }
        var parsed = parse(setting,result:result,available:true)
        parsed.sourceMethod = "getEvent"
        if setting == .whiteBalance { parsed.temperatureReported = item["currentColorTemperature"] != nil }
        let currentKey = setting == .whiteBalance ? "currentWhiteBalanceMode" : "current"+setting.suffix
        if item[currentKey] == nil { parsed.issue = nil; parsed.readStatus = .unknown }
        return parsed
    }
}

@MainActor
enum SonySettingWorkflow {
    typealias Call = (String,[Any],TimeInterval) async throws -> Data
    static func methods(call:Call) async throws -> Set<String> {
        guard let list = try SonyAPIClient.result(await call("getAvailableApiList",[],2)).first as? [String] else {
            throw SonyRemoteError(message:"Sony did not report currently available commands.")
        }
        return Set(list)
    }
    static func read(_ setting:SonyRemoteSetting,methods:Set<String>,event:[Any]? = nil,allowEventRequest:Bool = true,
                     call:Call) async throws -> SonyRemoteSettingState {
        var failure:Error?
        var partial = SonyRemoteSettingState()
        // A refused/malformed availability getter must not hide a working
        // current-value getter. Direct ISO read is always attempted before events.
        for method in [setting.available,setting.getter] where methods.contains(method) {
            do {
                let parsed = SonySettingParser.parse(setting,result:try SonyAPIClient.result(await call(method,[],3)),available:method == setting.available)
                partial = partial.merging(parsed)
                if partial.current != nil, partial.choicesReported { return partial }
                if parsed.current == nil { failure = SonyRemoteError(message:parsed.issue ?? "Unrecognized Sony setting response.") }
            } catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        var values = event
        if values == nil, allowEventRequest, methods.contains("getEvent") {
            do { values = try SonyAPIClient.result(await call("getEvent",[false],3)) }
            catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        if let values, let parsed = SonySettingParser.event(setting,values:values) {
            if partial.current == nil { partial = partial.merging(parsed) }
            else if parsed.choicesReported { partial.choices = parsed.choices; partial.choicesReported = true }
        }
        if partial.current != nil { return partial }
        if let failure { throw failure }
        return .init(issue:"No readable value is currently advertised in this camera mode.",readStatus:.unavailable("No readable value is currently advertised in this camera mode."))
    }
    static func change(_ setting:SonyRemoteSetting,to value:SonySettingValue,call:Call,active:() -> Bool,
                       wait:(TimeInterval) async throws -> Void = { try await Task.sleep(for:.seconds($0)) }) async throws -> SonyRemoteSettingState {
        func check() throws { guard active(), !Task.isCancelled else { throw CancellationError() } }
        try check()
        let available = try await methods(call:call); try check()
        guard available.contains(setting.setter) else { throw SonyRemoteError(message:"\(setting.title) is unavailable in the camera's current mode.") }
        let before = try await read(setting,methods:available,call:call); try check()
        guard before.current != nil, before.choices.contains(value) else { throw SonyRemoteError(message:"That value is not currently available from this camera and lens. Refresh the controls.") }
        if before.current == value { return before }
        // Send once. A network timeout is ambiguous; do not replay a write.
        let ack = try SonyAPIClient.result(await call(setting.setter,value.parameters,3)); try check()
        guard SonySettingParser.integer(ack.first) == 0 else { throw SonyRemoteError(message:"Sony did not acknowledge the change. Refresh to read the actual setting.") }
        for i in 0..<5 {
            if i > 0 { try await wait(0.25) }
            try check()
            let currentMethods = try await methods(call:call); try check()
            let feedback = try await read(setting,methods:currentMethods,call:call); try check()
            if feedback.current == value { return feedback }
        }
        throw SonyRemoteError(message:"Sony acknowledged the request but did not confirm the new value. Refresh the controls; the change may still have applied.")
    }
}
