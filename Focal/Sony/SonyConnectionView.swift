import SwiftUI

struct SonyConnectionView: View {
    @ObservedObject var camera: SonyRemoteCamera
    let returnToPhone: ()->Void
    var body: some View {
        VStack(spacing:16) {
            Image(systemName:"camera").font(.system(size:32,weight:.light)).foregroundStyle(Palette.yellow)
            Text((camera.state == .connecting || camera.state == .reconnecting) ? "Connecting to Sony…" : "Sony wireless camera").font(.headline)
            if (camera.state == .connecting || camera.state == .reconnecting) {
                ProgressView().tint(Palette.yellow)
                Text(camera.qualityStatus).font(.caption2).foregroundStyle(.secondary)
                Text(camera.streamDiagnostics).font(.caption2).foregroundStyle(.secondary)
            }
            Text("On the camera, enable Ctrl w/ Smartphone. In iPhone Settings → Wi-Fi, join the camera’s DIRECT network. Return here and connect.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("Camera IP address",text:$camera.host).keyboardType(.decimalPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(10).background(Palette.panel,in:RoundedRectangle(cornerRadius:8))
            Button("Connect") { camera.connect() }.buttonStyle(.borderedProminent).tint(Palette.yellow).disabled((camera.state == .connecting || camera.state == .reconnecting))
            if let message = camera.message { Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            Text("Sony supplies the wireless preview; its resolution depends on camera firmware and remote mode. Focal requests the largest size the camera advertises.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Return to iPhone camera",action:returnToPhone).font(.caption).foregroundStyle(Palette.yellow)
        }.padding(24)
    }
}
