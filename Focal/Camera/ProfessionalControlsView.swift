import SwiftUI
import AVFoundation

struct ProfessionalControlsView: View {
    @ObservedObject var camera: CameraController
    @State private var selected: CameraParameter?
    @State private var draft: Double = 0
    @State private var tint: Double = 0
    @State private var magnify = false
    let busy: Bool

    var body: some View {
        VStack(spacing:10) {
            if let selected { adjustment(selected).transition(.opacity.combined(with:.move(edge:.bottom))) }
            HStack(spacing: 4) {
              ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:6) {
                    ForEach(CameraParameter.allCases.filter { camera.controls.supports($0) }) { parameter in
                        Button { choose(parameter) } label: {
                            VStack(spacing:4) {
                                Text(parameter.rawValue).font(.system(.caption2,design:.monospaced))
                                Text(label(parameter)).font(.system(.caption,design:.monospaced,weight:.medium))
                                Text(parameter == .ev ? "COMP" : isAutomatic(parameter) ? "AUTO" : "LOCKED").font(.system(size:8,design:.monospaced)).foregroundStyle(Palette.muted)
                            }.frame(minWidth:65,minHeight:46).padding(.horizontal,5)
                                .foregroundStyle(selected == parameter ? Palette.yellow : Palette.text)
                                .background(selected == parameter ? Palette.yellow.opacity(0.10) : .clear,in:RoundedRectangle(cornerRadius:10))
                        }.accessibilityLabel("Adjust \(parameter.rawValue), \(label(parameter))")
                    }
                }
              }
              lensMenu
            }
            if camera.controls.isoRange == nil && camera.controls.durationRange == nil {
                Text("Custom exposure is unavailable on this selected device. Check a physical camera in LENS.").font(.caption2).foregroundStyle(Palette.muted)
            }
        }.padding(10).background(Palette.panel,in:RoundedRectangle(cornerRadius:16)).tint(Palette.yellow)
            .disabled(busy).animation(.easeInOut(duration:0.18),value:selected)
            .onChange(of:camera.controls.mode) { _,mode in if mode == .auto { selected = nil; magnify = false } }
            .onChange(of:camera.controls.lensID) { _,_ in selected = nil; magnify = false }
    }
    private var lensMenu: some View {
        Menu {
            Button { camera.selectLens(nil) } label: {
                if camera.controls.usesAutomaticLenses { Label("Automatic lenses", systemImage: "checkmark") }
                else { Text("Automatic lenses") }
            }
            ForEach(camera.controls.lenses) { lens in
                Button { camera.selectLens(lens.id) } label: {
                    if camera.controls.lensID == lens.id && !camera.controls.usesAutomaticLenses { Label(lens.label, systemImage: "checkmark") }
                    else { Text(lens.label) }
                }
            }
        } label: {
            Label("LENS",systemImage:"camera.aperture").font(.caption).frame(minHeight:46).padding(.horizontal,10)
        }.accessibilityLabel("Change camera lens, or return to automatic lenses")
    }
    private func isAutomatic(_ parameter:CameraParameter) -> Bool {
        switch parameter {
        case .iso,.shutter: return !camera.controls.manualExposure
        case .whiteBalance: return !camera.controls.manualWhiteBalance
        case .focus: return !camera.controls.manualFocus
        case .ev: return true
        }
    }
    private func choose(_ parameter: CameraParameter) {
        UISelectionFeedbackGenerator().selectionChanged()
        if selected == parameter { selected = nil; magnify = false; return }
        selected = parameter
        let current: Double
        switch parameter {
        case .iso: current = camera.controls.iso ?? range(parameter).lowerBound
        case .shutter: current = log2(max(0.000001,camera.controls.seconds ?? 1/60.0))
        case .ev: current = Double(camera.exposureBias)
        case .whiteBalance: current = camera.controls.temperature ?? 5000
        case .focus: current = camera.controls.lensPosition ?? 0.5
        }
        draft = min(range(parameter).upperBound,max(range(parameter).lowerBound,current))
        tint = min(150,max(-150,camera.controls.tint ?? 0))
    }
    private func range(_ parameter: CameraParameter) -> ClosedRange<Double> {
        switch parameter {
        case .iso: return camera.controls.isoRange ?? (1...2)
        case .shutter:
            let limits = camera.controls.durationRange ?? ((1/1000.0)...(1/30.0))
            return log2(limits.lowerBound)...log2(limits.upperBound)
        case .ev: return Double(camera.exposureRange.lowerBound)...Double(camera.exposureRange.upperBound)
        case .whiteBalance: return 2000...10000 // Requested temperature; device gains enforce actual support.
        case .focus: return 0...1
        }
    }
    private func label(_ parameter: CameraParameter) -> String {
        let c = camera.controls
        switch parameter {
        case .iso: return c.iso.map { String(format:"%.0f",$0) } ?? "—"
        case .shutter: return c.seconds.flatMap { CameraTelemetry.shutterLabel(seconds:$0) } ?? "—"
        case .ev: return camera.telemetry.evLabel
        case .whiteBalance: return c.temperature.map { String(format:"%.0fK",$0) } ?? "—"
        case .focus: return c.lensPosition.map { String(format:"%.2f",$0) } ?? "—"
        }
    }
    private func apply(_ parameter: CameraParameter) {
        switch parameter {
        case .iso: camera.setManualISO(draft)
        case .shutter: camera.setManualShutter(pow(2,draft))
        case .ev: camera.setExposure(Float(draft))
        case .whiteBalance: camera.setManualWhiteBalance(draft,tint:tint)
        case .focus: camera.setManualFocus(draft)
        }
    }
    private func automatic(_ parameter: CameraParameter) {
        switch parameter {
        case .iso: camera.setManualISO(nil)
        case .shutter: camera.setManualShutter(nil)
        case .ev: camera.setExposure(0)
        case .whiteBalance: camera.setManualWhiteBalance(nil)
        case .focus: camera.setManualFocus(nil)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private func adjustment(_ parameter: CameraParameter) -> some View {
        VStack(spacing:8) {
            HStack {
                Text("\(parameter.rawValue) · \(label(parameter))").font(.system(.caption,design:.monospaced))
                Spacer()
                Button("AUTO") { automatic(parameter) }.font(.caption.weight(.semibold))
                Button("Reset") { automatic(parameter); selected = nil; magnify = false }.font(.caption)
                Button { selected = nil; magnify = false } label: { Image(systemName:"xmark").frame(width:32,height:32) }.accessibilityLabel("Close parameter adjustment")
            }
            Slider(value:Binding(get:{draft},set:{draft = $0; apply(parameter)}),in:range(parameter),onEditingChanged:{ editing in if !editing { UISelectionFeedbackGenerator().selectionChanged() } })
                .accessibilityLabel(parameter.rawValue)
            if parameter == .whiteBalance {
                HStack { Text("Tint").font(.caption); Slider(value:Binding(get:{tint},set:{tint = $0; apply(parameter)}),in:-150...150) }
                Text("Requested temperature; actual device gains and measured WB are shown.").font(.caption2).foregroundStyle(Palette.muted)
            }
            if parameter == .iso || parameter == .shutter {
                Text("Manual exposure locks ISO and shutter together. AUTO resets both. Long shutter times can reduce preview cadence.")
                    .font(.caption2).foregroundStyle(Palette.muted)
            }
            if parameter == .focus {
                HStack { Text("Lens position · near 0 / far 1").font(.caption2).foregroundStyle(Palette.muted); Spacer(); Button(magnify ? "Hide loupe" : "Focus loupe") { magnify.toggle() }.font(.caption) }
                if magnify { NativeFocusLoupe(session:camera.session,mirrored:camera.isFrontCamera).frame(height:120).clipShape(RoundedRectangle(cornerRadius:10)).overlay(alignment:.topLeading) { Text("CENTER · 2× VIEW").font(.caption2).padding(8).background(.black.opacity(0.6)) } }
            }
        }.padding(.horizontal,4)
    }
}

private final class FocusLoupeSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
}
private struct NativeFocusLoupe: UIViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool
    func makeUIView(context:Context) -> UIView {
        let container = UIView(); container.clipsToBounds = true
        let surface = FocusLoupeSurface(); surface.tag = 77; container.addSubview(surface)
        container.isAccessibilityElement = true; container.accessibilityLabel = "Magnified center of the real camera preview. Capture zoom is unchanged."
        return container
    }
    func updateUIView(_ container:UIView,context:Context) {
        guard let surface = container.viewWithTag(77), let layer = surface.layer as? AVCaptureVideoPreviewLayer else { return }
        layer.session = session; layer.videoGravity = .resizeAspectFill
        // Layout is deferred until SwiftUI assigns the representable's bounds.
        DispatchQueue.main.async {
            surface.frame = container.bounds.insetBy(dx:-container.bounds.width/2,dy:-container.bounds.height/2)
            if let connection = layer.connection {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = mirrored }
            }
        }
    }
}
