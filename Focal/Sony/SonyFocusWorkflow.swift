import Foundation

/// User-requested Sony AF only. iPhone subject-tracking autofocus is untouched.
@MainActor
enum SonyFocusWorkflow {
    static func trigger(call:SonySettingWorkflow.Call,supported:Set<String>,active:() -> Bool,
                        wait:(TimeInterval) async throws -> Void = { try await Task.sleep(for:.seconds($0)) }) async throws -> String {
        func check() throws { guard active(),!Task.isCancelled else { throw CancellationError() } }
        try check()
        let methods = try await SonySettingWorkflow.methods(call:call); try check()
        guard methods.contains("actHalfPressShutter"), methods.contains("cancelHalfPressShutter") || supported.contains("cancelHalfPressShutter") else {
            throw SonyRemoteError(message:"Sony does not currently advertise a releasable autofocus trigger.")
        }
        if methods.contains("getFocusMode") {
            let mode = try SonyAPIClient.result(await call("getFocusMode",[],2)).first as? String; try check()
            if mode == "MF" { throw SonyRemoteError(message:"Select autofocus on the Sony camera or lens first.") }
        }
        if methods.contains("getEvent") {
            let state = SonyControlState.from(try SonyAPIClient.result(await call("getEvent",[false],2))); try check()
            guard !state.captureBusy else { throw SonyRemoteError(message:"Sony is busy. Wait for its current operation to finish.") }
        }
        // Even an ambiguous half-press timeout needs a best-effort release.
        do {
            let ack = try SonyAPIClient.result(await call("actHalfPressShutter",[],3)); try check()
            guard SonySettingParser.integer(ack.first) == 0 else { throw SonyRemoteError(message:"Sony did not acknowledge the autofocus trigger.") }
            var message = "Autofocus trigger acknowledged; camera did not confirm focus lock."
            if methods.contains("getEvent") {
                for _ in 0..<12 {
                    let status = SonyControlState.from(try SonyAPIClient.result(await call("getEvent",[false],2))).focusStatus; try check()
                    if status == "Focused" { message = "Sony reported focus locked."; break }
                    if status == "Failed" { throw SonyRemoteError(message:"Sony autofocus failed. Aim at a clear edge or focus on the camera.") }
                    if status == nil { break }
                    try await wait(0.15); try check()
                }
            }
            _ = try await call("cancelHalfPressShutter",[],2); try check()
            return message
        } catch {
            if active() { _ = try? await call("cancelHalfPressShutter",[],2) }
            throw error
        }
    }
}
