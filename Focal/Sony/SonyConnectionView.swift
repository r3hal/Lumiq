import SwiftUI

struct SonyConnectionView: View {
    @ObservedObject var camera: SonyRemoteCamera
    let returnToPhone: ()->Void
    var body: some View {
        VStack(spacing:16) {
            Image(systemName:"camera").font(.system(size:32,weight:.light)).foregroundStyle(Palette.yellow)
            Text(camera.state == .connecting ? "Connecting to Sony…" : "Sony wireless camera").font(.headline)
            if camera.state == .connecting {
                ProgressView().tint(Palette.yellow)
                Text(camera.streamDiagnostics).font(.caption2).foregroundStyle(.secondary)
            }
            Text("On the camera, enable Ctrl w/ Smartphone. In iPhone Settings → Wi-Fi, join the camera’s DIRECT network. Return here and connect.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("Camera IP address",text:$camera.host).keyboardType(.decimalPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(10).background(Palette.panel,in:RoundedRectangle(cornerRadius:8))
            Button("Connect") { camera.connect() }.buttonStyle(.borderedProminent).tint(Palette.yellow).disabled(camera.state == .connecting)
            if let message = camera.message { Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            Text("Experimental, capability-discovered live view. A7 III firmware/mode compatibility requires a real camera test. No phone preview is used here.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Return to iPhone camera",action:returnToPhone).font(.caption).foregroundStyle(Palette.yellow)
        }.padding(24)
    }
}
