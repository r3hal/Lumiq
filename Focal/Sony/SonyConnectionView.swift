import SwiftUI

struct SonyConnectionView: View {
    @ObservedObject var camera: SonyRemoteCamera
    let returnToPhone: () -> Void
    var openCamera: (() -> Void)? = nil
    @State private var showGuide = false
    private var connected: Bool { camera.state == .streaming && camera.hasFrame }
    private var busy: Bool { camera.state == .connecting || camera.state == .reconnecting }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                statusHeader
                cameraIllustration
                if connected { connectedDetails } else { connectionSteps }
                actions
                if let message = camera.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if !connected {
                    Text("Sony A7 III is the initial target. The camera must advertise a compatible remote API. A6100 support needs separate verification.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Button("Use iPhone Camera", action: returnToPhone).font(.subheadline).foregroundStyle(.white.opacity(0.8))
            }.padding(22)
        }.background(.black).foregroundStyle(.white).tint(Palette.yellow)
            .navigationTitle(connected ? "Sony Camera" : "Connect Sony Camera").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showGuide) {
                NavigationStack { SonySetupGuide().toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showGuide = false } } } }
                    .preferredColorScheme(.dark).presentationDragIndicator(.visible)
            }
    }
    private var statusHeader: some View {
        VStack(spacing: 8) {
            if connected {
                Label("Connected", systemImage: "circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.mint)
            } else if busy {
                HStack { ProgressView().tint(Palette.yellow); Text(camera.state == .reconnecting ? "Restoring live view…" : "Connecting…").font(.subheadline) }
            }
            Text(connected ? camera.model : "Sony A7 III").font(.system(size: 20, weight: .semibold))
            if !connected { Text("Wi-Fi camera connection").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var cameraIllustration: some View {
        Image(systemName: "camera.fill").font(.system(size: 92, weight: .light))
            .foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity).frame(height: 135)
            .background(RadialGradient(colors: [Color(white: 0.16), .black], center: .center, startRadius: 0, endRadius: 150))
            .accessibilityHidden(true)
    }
    private var connectionSteps: some View {
        VStack(alignment: .leading, spacing: 13) {
            step(1, "Enable Ctrl w/ Smartphone on your Sony.")
            step(2, "Join the camera’s DIRECT network in iPhone Settings → Wi-Fi.")
            step(3, "Return to Focal and allow Local Network access.")
            step(4, "Check the camera address, then tap Connect Camera.")
            TextField("Camera IP address", text: $camera.host).keyboardType(.decimalPad)
                .textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(size: 15, design: .monospaced))
                .padding(14).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Sony private network address").disabled(busy)
        }
    }
    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(String(number)).font(.system(size: 11, weight: .semibold)).frame(width: 23, height: 23).background(Color(white: 0.2), in: Circle())
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.82)).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var connectedDetails: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                stat("Live view", value: camera.resolution)
                stat("Frames", value: String(camera.frameCount))
                stat("Link", value: "Live", green: true)
            }
            Text("\(camera.qualityStatus) · \(camera.streamFPS.map { String(format: "%.0f fps", $0) } ?? "measuring cadence")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func stat(_ title: String, value: String, green: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(green ? Palette.mint : .white).lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(13).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
    }
    private var actions: some View {
        VStack(spacing: 11) {
            if connected {
                if let openCamera { action("Open Camera", primary: true, action: openCamera) }
                action("Disconnect", primary: false) { camera.disconnect() }
            } else {
                action(busy ? "Connecting…" : "Connect Camera", primary: true) { camera.connect() }.disabled(busy)
                if busy { action("Cancel connection", primary: false) { camera.disconnect() } }
                else { action("View Full Guide", primary: false) { showGuide = true } }
            }
        }
    }
    private func action(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 48)
                .foregroundStyle(primary ? .black : .white)
                .background(primary ? Palette.yellow : Palette.panel, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(CameraPressStyle())
    }
}

private struct SonySetupGuide: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connect directly to your Sony").font(.title2.bold())
                Text("On the A7 III, enable Network → Ctrl w/ Smartphone. Open iPhone Settings → Wi-Fi and join the DIRECT network shown by the camera. Use the password shown on the Sony.")
                Text("Return to Focal, enter the private camera address if it differs from the default, and choose Connect Camera. Allow Local Network access when prompted. If permission was denied, enable it in iPhone Settings → Focal.")
                Text("Connected is shown only after Focal receives and decodes a real live-view frame. The app negotiates only advertised controls and stream sizes. Sony firmware and remote mode determine the available functions and wireless preview quality.")
                Text("Focus, zoom, shooting mode and exposure may need adjustment on the camera. If Sony does not advertise a compatible remote API in this mode, Focal cannot establish this live view. A6100 support is planned and requires independent hardware testing.")
            }.font(.subheadline).lineSpacing(4).padding(22)
        }.background(.black).foregroundStyle(.white).navigationTitle("Sony Wi-Fi Guide").navigationBarTitleDisplayMode(.inline)
    }
}

struct SonyTelemetryStrip: View {
    let telemetry: CameraTelemetry
    private var values: [String] {
        [telemetry.shutter, telemetry.aperture, telemetry.iso.map { "ISO " + $0 }, telemetry.ev.map { String(format: "%+.1f EV", $0) }].compactMap { $0 }
    }
    var body: some View {
        HStack(spacing: 10) {
            if values.isEmpty { Text("Exposure not reported").foregroundStyle(.secondary) }
            ForEach(Array(values.enumerated()), id: \.offset) { item in
                Text(item.element).foregroundStyle(item.element == telemetry.aperture ? Palette.yellow : .white.opacity(0.9))
            }
        }.font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75).frame(maxWidth: .infinity).frame(height: 24)
            .accessibilityLabel("Sony exposure, read only").accessibilityValue(values.joined(separator: ", "))
    }
}
