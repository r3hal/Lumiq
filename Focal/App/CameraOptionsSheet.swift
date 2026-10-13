import SwiftUI

private enum CameraSheetRoute: Hashable { case source, sony, ai, precision, settings, help }

struct CameraOptionsSheet: View {
    @ObservedObject var camera: CameraController
    @ObservedObject var sony: SonyRemoteCamera
    @EnvironmentObject private var settings: CameraSettings
    @Environment(\.dismiss) private var dismiss
    @Binding var source: CameraSource
    @Binding var mode: CompositionMode
    @Binding var corner: Int?
    @Binding var sonyFullFrame: Bool
    var startsWithSony = false
    var startsWithSettings = false
    @State private var seeded = false
    let openReference: () -> Void
    let openExplore: () -> Void
    @State private var path = [CameraSheetRoute]()
    @State private var detent: PresentationDetent = .fraction(0.78)

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 18) {
                    mainRows
                    extraRows
                }.padding(18)
            }.background(Palette.ink).navigationTitle("Menu").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7)) }.accessibilityLabel("Close camera menu") } }
                .navigationDestination(for: CameraSheetRoute.self) { route in destination(route) }
        }.onAppear { if !seeded { seeded = true; if startsWithSony { path = [.source, .sony] } else if startsWithSettings { path = [.settings] } } }
            .onChange(of: path) { _, routes in detent = routes.isEmpty ? .fraction(0.78) : .large }
            .tint(Palette.yellow).preferredColorScheme(.dark)
            .presentationDragIndicator(.visible).presentationBackground(Palette.ink)
            .presentationCornerRadius(28).presentationDetents([.fraction(0.78), .large], selection: $detent)
    }
    private var mainRows: some View {
        VStack(spacing: 0) {
            Button { path.append(.source) } label: { row("Camera Source", symbol: "camera", value: source == .iPhone ? "iPhone Camera" : "Sony Camera") }
            divider
            Menu {
                if source == .sony { Button("Full camera frame") { sonyFullFrame = true } }
                ForEach(PhotoAspect.allCases) { aspect in Button(aspect.rawValue) { sonyFullFrame = false; settings.aspect = aspect } }
            } label: { row("Aspect Ratio", symbol: "aspectratio", value: source == .sony && sonyFullFrame ? "Camera frame" : settings.aspect.rawValue) }
            divider
            if source == .iPhone {
                Toggle(isOn: $settings.raw) { Label(camera.supportsProRAW ? "ProRAW" : "RAW", systemImage: "rectangle.portrait") }
                    .font(.system(size: 14)).padding(.horizontal, 15).frame(minHeight: 54).disabled(source == .sony || !camera.supportsRAW)
                divider
                Menu {
                    ForEach(CameraFlash.allCases) { flash in Button(flash.label) { settings.flash = flash } }
                } label: { row("Flash", symbol: "bolt", value: settings.flash.label) }.disabled(source == .sony || !camera.supportsFlash)
                divider
            }
            Button { path.append(.settings) } label: { row("Camera Settings", symbol: "gearshape") }
            divider
            Button { path.append(.ai) } label: { row("AI Settings", symbol: "sparkles") }
            divider
            Button { path.append(.precision) } label: { row("Focal Precision",symbol:"waveform.path") }
            divider
            Button { path.append(.help) } label: { row("Help & Guides", symbol: "questionmark.circle") }
        }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white)
    }
    private var extraRows: some View {
        VStack(spacing: 0) {
            Button { camera.findSubject(); dismiss() } label: { row("Find another subject", symbol: "viewfinder") }.disabled(!settings.guide)
            divider
            Button { camera.switchCamera(); dismiss() } label: { row("Flip iPhone camera", symbol: "camera.rotate") }.disabled(source == .sony || !camera.isRunning)
            divider
            Picker("Composition", selection: $mode) {
                Text("Automatic").tag(CompositionMode.automatic)
                Text("Center").tag(CompositionMode.centered); Text("Thirds").tag(CompositionMode.thirds)
            }.font(.system(size: 14)).padding(15)
            Button {
                corner = ((CompositionEngine.thirdsTargets.firstIndex(of: camera.reading.target) ?? 0) + 1) % 4
            } label: { row("Change thirds corner", symbol: "square.grid.2x2") }.disabled(mode != .thirds)
            divider
            Button { openReference(); dismiss() } label: { row("Reference overlay", symbol: "photo.on.rectangle") }
            divider
            Button { openExplore(); dismiss() } label: { row("Explore & practice", symbol: "sun.max") }
            if source == .sony {
                divider
                Button { sony.disconnect(); camera.findSubject(); dismiss() } label: { row("Disconnect Sony", symbol: "wifi.slash") }.foregroundStyle(.red)
            }
        }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white)
    }
    @ViewBuilder private func destination(_ route: CameraSheetRoute) -> some View {
        switch route {
        case .source:
            CameraSourceSelectionView(source: source, choosePhone: { source = .iPhone; dismiss() }, chooseSony: { source = .sony; path.append(.sony) })
        case .sony:
            SonyConnectionView(camera: sony, returnToPhone: { source = .iPhone; dismiss() }, openCamera: { dismiss() })
        case .ai: AIPhotographyView(source: source)
        case .precision: PrecisionSettingsView()
        case .settings:
            SettingsView(camera: camera, source: source, sonyResolution: sony.resolution, sonyModel: sony.model,
                         sonyPreviewInfo: sony.qualityStatus + " · " + sony.streamDiagnostics).toolbar(.hidden, for: .navigationBar)
        case .help: FieldGuideView()
        }
    }
    private func row(_ title: String, symbol: String, value: String = "") -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).frame(width: 21)
            Text(title).font(.system(size: 14))
            Spacer(minLength: 6)
            Text(value).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }.padding(.horizontal, 15).frame(minHeight: 54).contentShape(Rectangle())
    }
    private var divider: some View { Divider().overlay(.white.opacity(0.05)).padding(.leading, 48) }
}

private struct CameraSourceSelectionView: View {
    let source: CameraSource
    let choosePhone: () -> Void
    let chooseSony: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            sourceCard("iPhone Camera", detail: "Use your iPhone’s built-in cameras.", symbol: "iphone", selected: source == .iPhone, action: choosePhone)
            sourceCard("Sony Camera", detail: "Connect your Sony Alpha camera over Wi-Fi.", symbol: "camera", selected: source == .sony, action: chooseSony)
            Text("Sony A7 III is the initial target. A6100 support is planned and needs separate hardware testing.").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            Spacer()
        }.padding(20).background(Palette.ink).foregroundStyle(.white)
            .navigationTitle("Camera Source").navigationBarTitleDisplayMode(.inline)
    }
    private func sourceCard(_ title: String, detail: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(selected ? Palette.yellow : .white).frame(width: 42)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right").foregroundStyle(selected ? Palette.yellow : .secondary)
            }.padding(20).frame(maxWidth: .infinity).background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(CameraPressStyle()).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
