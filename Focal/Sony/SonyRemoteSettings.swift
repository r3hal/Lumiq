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

struct SonyRemoteSettingState {
    var current: SonySettingValue?
    var choices: [SonySettingValue] = []
    var issue: String?
    var readAt: Date?
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
        var s = SonyRemoteSettingState(readAt:Date())
        switch setting {
        case .iso,.aperture,.shutter:
            if let text = result.first as? String, !text.isEmpty { s.current = .text(text) }
            if available, result.count > 1, let list = result[1] as? [String] {
                s.choices = Array(list.prefix(1024)).filter { !$0.isEmpty }.map(SonySettingValue.text)
            }
        case .whiteBalance:
            if let value = result.first as? [String:Any], let mode = value["whiteBalanceMode"] as? String {
                let t = integer(value["colorTemperature"])
                s.current = .whiteBalance(mode:mode,temperature:t.flatMap { $0 > 0 ? $0 : nil })
            }
            if available, result.count > 1, let modes = result[1] as? [[String:Any]] {
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
                s.choices = (min...max).map { .compensation(index:$0,step:step) }
            }
        }
        if s.current == nil { s.issue = "Camera returned an unrecognized current value." }
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
            result = [item["current"+setting.suffix] ?? NSNull(),item[setting.eventType+"Candidates"] ?? []]
        case .whiteBalance:
            result = [["whiteBalanceMode":item["currentWhiteBalanceMode"] ?? NSNull(),"colorTemperature":item["currentColorTemperature"] ?? -1],
                      item["whiteBalanceCandidates"] ?? []]
        case .compensation:
            result = [item["currentExposureCompensation"] ?? NSNull(),item["maxExposureCompensation"] ?? NSNull(),
                item["minExposureCompensation"] ?? NSNull(),item["stepIndexOfExposureCompensation"] ?? NSNull()]
        }
        return parse(setting,result:result,available:true)
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
    static func read(_ setting:SonyRemoteSetting,methods:Set<String>,call:Call) async throws -> SonyRemoteSettingState {
        if methods.contains(setting.available) {
            return SonySettingParser.parse(setting,result:try SonyAPIClient.result(await call(setting.available,[],2)),available:true)
        }
        if methods.contains("getEvent"), let s = SonySettingParser.event(setting,values:try SonyAPIClient.result(await call("getEvent",[false],2))), s.current != nil { return s }
        if methods.contains(setting.getter) {
            return SonySettingParser.parse(setting,result:try SonyAPIClient.result(await call(setting.getter,[],2)),available:false)
        }
        return SonyRemoteSettingState(issue:"No readable value is advertised in this camera mode.")
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
