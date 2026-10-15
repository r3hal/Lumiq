import SwiftUI

struct SonyRemoteControlsView: View {
    @ObservedObject var camera: SonyRemoteCamera
    @EnvironmentObject private var library: PhotoLibrary
    @EnvironmentObject private var settings: CameraSettings
    @State private var captureTask: Task<Void,Never>?
    @State private var captureFeedback: String?
    @State private var diagnosticURL: URL?

    var body: some View {
        List {
            Section {
                VStack(alignment:.leading,spacing:8) {
                    Text(camera.model).font(.headline)
                    Label(camera.hasFrame ? "Connected · Live view" : camera.isConnected ? "Connected · Remote controls" : "Disconnected",
                          systemImage:"circle.fill").font(.caption).foregroundStyle(camera.isConnected ? Palette.mint : Palette.muted)
                    Text("Mode: \(camera.telemetry.mode ?? "Not reported") · \(camera.controlState.cameraStatus ?? "Status not reported")")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical,4)
                if camera.hasFrame {
                    SonyPreviewSurface(feed:camera.previewFeed).aspectRatio(camera.imageAspect,contentMode:.fit)
                        .clipShape(RoundedRectangle(cornerRadius:12)).accessibilityLabel("Real Sony live view")
                } else {
                    Text(camera.message ?? "No live-view frames are available. Controls use the camera's separate remote API.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.listRowBackground(Palette.panel)
            Section {
                ForEach(SonyRemoteSetting.allCases) { setting in
                    SonySettingRow(camera:camera,setting:setting)
                }
            } header: { Text("Camera exposure") } footer: {
                Text("Values and choices come from the camera and attached lens. A change is confirmed only after camera readback. Change shooting mode on the camera to enable unavailable controls.")
            }.listRowBackground(Palette.panel)
            Section {
                Button { camera.triggerAutofocus() } label: {
                    Label(camera.isFocusing ? "Focusing…" : "Trigger autofocus",systemImage:"viewfinder")
                }.disabled(!camera.canTriggerAF)
                if let reason = camera.autofocusUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Button(action:takePhoto) {
                    Label(camera.isCapturing ? "Taking photo…" : "Release shutter",systemImage:"camera.aperture")
                }.disabled(!camera.canCapture || captureTask != nil)
                if !camera.methods.contains("actTakePicture") {
                    Text("Remote still capture is not currently advertised. Select still-photo mode on the camera.").font(.caption).foregroundStyle(.secondary)
                }
                if let feedback = camera.controlFeedback {
                    Text(feedback).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let feedback = captureFeedback {
                    Text(feedback).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: { Text("Capture") } footer: {
                Text("The shutter takes one photo only when you press it. The transferred camera JPEG is saved in Focal; originals remain subject to the Sony camera's card settings. Zoom is controlled on the camera or lens.")
            }.listRowBackground(Palette.panel)
            Section {
                Button(camera.isRefreshingSettings ? "Reading camera…" : "Refresh camera values",systemImage:"arrow.clockwise") { camera.refreshSettings() }
                    .disabled(!camera.isConnected || camera.controlsBusy)
                Button("Export connection diagnostics",systemImage:"doc.text") {
                    do { diagnosticURL = try camera.diagnostics.export() }
                    catch { captureFeedback = error.localizedDescription }
                }
                if let diagnosticURL { ShareLink("Share diagnostics",item:diagnosticURL) }
                Button("Disconnect",role:.destructive) { camera.disconnect() }.disabled(!camera.isConnected)
                if !camera.isConnected { Button("Reconnect camera") { camera.connect() }.disabled(camera.state == .connecting || camera.state == .reconnecting) }
            }.listRowBackground(Palette.panel)
        }.scrollContentBackground(.hidden).background(Palette.ink).tint(Palette.yellow)
            .navigationTitle("Sony Remote Controls").navigationBarTitleDisplayMode(.inline)
            .onAppear { camera.refreshSettings() }
    }
    private func takePhoto() {
        guard captureTask == nil else { return }
        captureFeedback = nil
        captureTask = Task {
            defer { captureTask = nil }
            do {
                let result = try await camera.capture()
                let photo = try await library.add(data:result.processed,mode:"Sony remote",cameraOrigin:CameraSource.sony.rawValue)
                captureFeedback = "Saved in Focal."
                if settings.autoSaveToPhotos {
                    do { try await library.saveToPhotos(photo) }
                    catch { captureFeedback = "Saved in Focal. Photos export: \(error.localizedDescription)" }
                }
            } catch { captureFeedback = error.localizedDescription }
        }
    }
}

private struct SonySettingRow: View {
    @ObservedObject var camera: SonyRemoteCamera
    let setting: SonyRemoteSetting
    private var reason: String? { camera.settingDisabledReason(setting) }
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            NavigationLink {
                SonySettingChoicesView(camera:camera,setting:setting)
            } label: {
                HStack {
                    Text(setting.title)
                    Spacer()
                    Text(camera.remoteSettings[setting]?.current?.label ?? "Not reported")
                        .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    if camera.pendingSetting == setting { ProgressView() }
                }
            }.disabled(reason != nil)
            if camera.pendingSetting == setting {
                Text("Waiting for camera confirmation…").font(.caption).foregroundStyle(Palette.yellow)
            } else if let reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical,3)
    }
}

private struct SonySettingChoicesView: View {
    @ObservedObject var camera: SonyRemoteCamera
    let setting: SonyRemoteSetting
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var choices: [SonySettingValue] {
        (camera.remoteSettings[setting]?.choices ?? []).filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            if let reason = camera.settingDisabledReason(setting) { Text(reason).font(.caption).foregroundStyle(.secondary) }
            ForEach(choices) { value in
                Button {
                    camera.change(setting,to:value); dismiss()
                } label: {
                    HStack {
                        Text(value.label).foregroundStyle(.white)
                        Spacer()
                        if camera.remoteSettings[setting]?.current == value { Image(systemName:"checkmark").foregroundStyle(Palette.yellow) }
                    }
                }.disabled(camera.settingDisabledReason(setting) != nil).listRowBackground(Palette.panel)
            }
        }.searchable(text:$search,prompt:"Camera-reported values")
            .scrollContentBackground(.hidden).background(Palette.ink).tint(Palette.yellow)
            .navigationTitle(setting.title).navigationBarTitleDisplayMode(.inline)
    }
}
