import Foundation

/// One confirmed camera/mode snapshot. Event omissions never mean removal.
struct SonyRemoteSnapshot: Equatable {
    var methods = Set<String>()
    var supported = Set<String>()
    var supportComplete = false
    var availabilityKnown = false
    var settings: [SonyRemoteSetting:SonyRemoteSettingState] = [:]
    var writeRestrictions: [SonyRemoteSetting:SonyRemoteControlStatus] = [:]
    var telemetry = CameraTelemetry()
    var control = SonyControlState()

    func status(_ setting:SonyRemoteSetting,pending:Bool = false) -> SonyRemoteControlStatus {
        if pending { return .commandInProgress }
        guard availabilityKnown else { return .unknown }
        if let restriction = writeRestrictions[setting] { return restriction }
        if !methods.contains(setting.setter) {
            if supportComplete && !supported.contains(setting.setter) { return .unsupported }
            return .temporarilyUnavailable("The camera does not currently advertise \(setting.setter) in \(telemetry.mode ?? "this shooting mode").")
        }
        guard let value = settings[setting], value.current != nil else {
            let state = settings[setting]
            switch state?.readStatus ?? .unknown {
            case .unknown,.loading: return .unknown
            case .unsupported: return .temporarilyUnavailable("The setter is advertised, but a readable value is unavailable.")
            case .available: return .unknown
            case .unavailable(let reason): return .temporarilyUnavailable(reason)
            case .connectionError(let reason),.error(let reason): return .error(reason)
            }
        }
        guard !value.choices.isEmpty else {
            return .temporarilyUnavailable("No writable values were reported for this camera, lens and mode.")
        }
        // A failed background read is a warning beside the last confirmed value,
        // not evidence that the camera removed a still-advertised setter.
        return .available
    }
    mutating func merge(_ setting:SonyRemoteSetting,_ value:SonyRemoteSettingState) {
        settings[setting] = (settings[setting] ?? SonyRemoteSettingState()).merging(value)
        synchronizeTelemetry()
    }
    mutating func applyMethods(_ available:Set<String>) {
        for setting in SonyRemoteSetting.allCases where !methods.contains(setting.setter) && available.contains(setting.setter) {
            writeRestrictions[setting] = nil
        }
        methods = available; supported.formUnion(available); availabilityKnown = true
    }
    mutating func writeFailed(_ setting:SonyRemoteSetting,error:Error) {
        merge(setting,.failure(error))
        if let api = error as? SonyAPIError, api.method == setting.setter {
            if api.code == 12 { writeRestrictions[setting] = .unsupported }
            else if api.code == 5 || api.code == 403 { writeRestrictions[setting] = .temporarilyUnavailable(api.localizedDescription) }
        }
    }
    /// Call only after checking exposure mode; a mode change needs a new snapshot.
    mutating func applyEvent(_ values:[Any],includeMethods:Bool = true) {
        let event = SonyControlState.from(values)
        if let status = event.cameraStatus { control.cameraStatus = status }
        if let focus = event.focusStatus { control.focusStatus = focus }
        if includeMethods, let available = event.availableMethods { applyMethods(available) }
        control.availableMethods = nil // event deltas are not a second capability cache
        let mode = SonyEventValues.telemetry(values).mode
        if let mode { telemetry.mode = mode }
        for setting in SonyRemoteSetting.allCases {
            if let update = SonySettingParser.event(setting,values:values) { merge(setting,update) }
        }
    }
    mutating func noteFailure(_ error:Error) {
        for setting in SonyRemoteSetting.allCases { merge(setting,.failure(error)) }
    }
    mutating func synchronizeTelemetry() {
        if let value = settings[.iso]?.current { telemetry.iso = value.label }
        if let value = settings[.aperture]?.current { telemetry.aperture = value.label }
        if let value = settings[.shutter]?.current { telemetry.shutter = value.label }
        if case .compensation(let index,let step) = settings[.compensation]?.current { telemetry.ev = SonySettingValue.ev(index:index,step:step) }
    }
}

struct SonyModeChangedDuringRead: Error {}

/// The one service monitor owns background polling. All work here uses its
/// serialized client; it never creates another timer/task or a camera session.
@MainActor
enum SonySnapshotWorkflow {
    static func read(previous:SonyRemoteSnapshot,diagnostics:SonyDiagnostics? = nil,call:SonySettingWorkflow.Call,active:() -> Bool) async throws -> SonyRemoteSnapshot {
        func check() throws { guard active(), !Task.isCancelled else { throw CancellationError() } }
        func request(_ method:String,_ params:[Any] = []) async throws -> [Any] {
            try check(); let data = try await call(method,params,3); try check()
            return try SonyAPIClient.result(data)
        }
        try check()
        let methods = try await SonySettingWorkflow.methods(call:call); try check()
        var next = previous; next.applyMethods(methods)
        var initialEvents:[Any]?
        if methods.contains("getEvent") {
            do { initialEvents = try await request("getEvent",[false]) }
            catch is CancellationError { throw CancellationError() }
            catch { next.noteFailure(error) }
        }
        let firstMode:String?
        if methods.contains("getExposureMode") {
            let queried = try? await request("getExposureMode").first as? String
            firstMode = queried ?? initialEvents.flatMap { SonyEventValues.telemetry($0).mode }
        }
        else { firstMode = initialEvents.flatMap { SonyEventValues.telemetry($0).mode } }
        try check()
        if let firstMode, firstMode != previous.telemetry.mode {
            next.writeRestrictions = [:]
            // Only the completed new-mode candidate loses old-mode choices.
            // The published previous snapshot stays intact during this read.
            for setting in SonyRemoteSetting.allCases {
                next.settings[setting]?.choices = []; next.settings[setting]?.choicesReported = false
            }
            if case .compensation(let index,_) = next.settings[.compensation]?.current {
                next.settings[.compensation]?.current = .compensation(index:index,step:nil)
            }
        }
        if let firstMode { next.telemetry.mode = firstMode }
        if let initialEvents { next.applyEvent(initialEvents,includeMethods:false) }
        // ISO first: use the same verified write/read path as the working control.
        for setting in SonyRemoteSetting.allCases {
            try check()
            do {
                let value = try await SonySettingWorkflow.read(setting,methods:methods,event:initialEvents,allowEventRequest:false,call:call)
                try check(); next.merge(setting,value)
                diagnostics?.record(value.current == nil ? "setting.read.unavailable" : "setting.read.confirmed",
                    ["setting":setting.rawValue,"method":value.sourceMethod ?? "none advertised","current":value.current?.label ?? value.readStatus.label,
                     "choices":String(value.choices.count),"mode":next.telemetry.mode ?? "unknown","issue":value.issue ?? ""])
                if value.current == nil, next.supportComplete, !methods.contains("getEvent"),
                   !next.supported.contains(setting.getter), !next.supported.contains(setting.available) {
                    next.settings[setting]?.readStatus = .unsupported
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try check(); next.merge(setting,.failure(error))
                diagnostics?.record("setting.read.failed",["setting":setting.rawValue,"error":error.localizedDescription,"mode":next.telemetry.mode ?? "unknown"])
            }
        }
        // Mode and availability changes during a multi-request read invalidate
        // the entire candidate, not the last confirmed UI snapshot.
        if methods.contains("getExposureMode") {
            let finalMode = try await request("getExposureMode").first as? String
            try check()
            guard finalMode != nil else { throw SonyRemoteError(message:"Sony returned no readable exposure mode; keeping the previous control snapshot.") }
            if let firstMode, let finalMode, firstMode != finalMode { throw SonyModeChangedDuringRead() }
            if let finalMode { next.telemetry.mode = finalMode }
        } else if methods.contains("getEvent") {
            // When a mode was actually observed, require the final probe to
            // succeed before replacing its confirmed capability snapshot.
            let finalEvent:[Any]?
            if firstMode != nil { finalEvent = try await request("getEvent",[false]) }
            else { finalEvent = try? await request("getEvent",[false]) }
            if let finalEvent {
                let finalMode = SonyEventValues.telemetry(finalEvent).mode
                if let firstMode, let finalMode, firstMode != finalMode { throw SonyModeChangedDuringRead() }
                next.applyEvent(finalEvent,includeMethods:false)
            }
        }
        try check(); return next
    }
}

/// Short non-long-poll getEvent is intentional: this client also carries user
/// controls, so a 30-second long poll would delay shutter/ISO requests.
struct SonyRemotePollPolicy {
    static let eventInterval:TimeInterval = 3
    static let snapshotInterval:TimeInterval = 15
    private(set) var nextEvent:TimeInterval = 0
    private(set) var nextSnapshot:TimeInterval = 0
    private(set) var hardFailures = 0
    static func feedbackMethod(_ methods:Set<String>) -> String? {
        methods.contains("getEvent") ? "getEvent" : methods.contains("getExposureMode") ? "getExposureMode" : nil
    }
    mutating func snapshotRead(at time:TimeInterval) { nextSnapshot = time+Self.snapshotInterval; nextEvent = time+Self.eventInterval }
    mutating func eventRead(at time:TimeInterval) { nextEvent = time+Self.eventInterval }
    mutating func backoff(snapshot:Bool,at time:TimeInterval) {
        if snapshot { snapshotRead(at:time) } else { eventRead(at:time) }
    }
    mutating func success() { hardFailures = 0 }
    mutating func failed(_ error:Error,recentLiveFrame:Bool) -> Bool {
        guard let network = error as? URLError,
              [.notConnectedToInternet,.networkConnectionLost,.cannotConnectToHost,.cannotFindHost].contains(network.code),
              !recentLiveFrame else { return false }
        hardFailures += 1; return hardFailures >= 3
    }
}
