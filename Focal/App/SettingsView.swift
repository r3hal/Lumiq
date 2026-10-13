import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: CameraSettings
    @EnvironmentObject private var library: PhotoLibrary
    @ObservedObject var camera: CameraController
    var source: CameraSource = .iPhone
    var sonyResolution = "—"
    var sonyModel = "Model not reported"
    var sonyPreviewInfo = ""
    @Environment(\.dismiss) private var dismiss
    @State private var showPrivacy = false
    @State private var showGuide = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 28, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 18, weight: .medium))
                        .frame(width: 34, height: 34).background(Palette.panel, in: Circle())
                }.accessibilityLabel("Close settings")
            }
            .padding(.horizontal, 22).padding(.top, 72).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Button { showGuide = true } label: {
                        HStack {
                            Text("Focal · Personal camera").foregroundStyle(Palette.yellow)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                        }.padding(.horizontal, 15).frame(height: 44).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                    }
                    section("CAMERA") {
                        settingToggle("AI Guidance", value: $settings.guide)
                        separator
                        subjectSelectivity
                        separator
                        settingToggle("Optional grid", value: $settings.grid)
                        separator
                        settingToggle("Optional level", value: $settings.level)
                        separator
                        settingToggle("Automatic zoom", value: $settings.autoFrame).disabled(source == .sony)
                        separator
                        VStack(alignment:.leading) {
                            Text(String(format:"Hold steady: %.1f s",settings.holdDuration)).font(.subheadline)
                            Slider(value:$settings.holdDuration,in:0.5...2,step:0.1).tint(Palette.yellow)
                        }.padding(15).disabled(source == .sony)
                        separator
                        settingToggle("Smart shutter",value: $settings.smartShutter).disabled(source == .sony)
                        separator
                        settingToggle("Measured coach",value: $settings.coach)
                        separator
                        Picker("Photo series",selection: $settings.burstCount) {
                            Text("Single").tag(1); Text("3 shots").tag(3); Text("5 shots").tag(5)
                        }.padding(15)
                        separator
                        settingToggle("Shutter Sound", value: Binding(
                            get: { camera.canMuteShutter ? settings.shutterSound : true },
                            set: { settings.shutterSound = $0 }
                        )).disabled(!camera.canMuteShutter || source == .sony)
                        separator
                        settingToggle("Save the scan", value: $settings.saveScan)
                        separator
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Caption").font(.subheadline).foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(CaptionStyle.allCases) { style in
                                        Button { settings.caption = style } label: {
                                            VStack(spacing: 9) {
                                                Text("What I see").font(style.font).foregroundStyle(Palette.yellow)
                                                Text(style.rawValue).font(.caption).foregroundStyle(settings.caption == style ? .white : .secondary)
                                            }
                                            .frame(width: 100, height: 65)
                                            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
                                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.caption == style ? Palette.yellow : Color.white.opacity(0.15), lineWidth: 1.5))
                                        }.accessibilityAddTraits(settings.caption == style ? .isSelected : [])
                                    }
                                }
                            }
                        }.padding(15)
                    }
                    if !camera.canMuteShutter {
                        Text("This iPhone/iOS combination controls the camera shutter sound.")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 15)
                    }
                    if source == .sony { Text("Sony mode uses actual received frames and advertised controls. Lens zoom and exposure adjustment remain on the camera; iPhone capture options do not control Sony.").font(.caption).foregroundStyle(.secondary).padding(.horizontal,15) }
                    Text("Optional grid/level guides are off by default. AI Guidance starts off for iPhone and turns on when you select Sony. The yellow footer button turns it off/on. Specific subject names require repeated recognition; uncertain regions stay unlabelled. Pan in the arrow direction to place the subject on the target mark. Coach analysis runs only while AI Guidance is on. Pinch always takes control. ISO, shutter and lens aperture in the expanded camera strip are read-only; only iPhone EV is adjustable.").font(.caption).foregroundStyle(.secondary).padding(.horizontal,15)
                    Text("Smart shutter is off by default and takes one shot/series per armed AI session when the guide is ready. Photo series are sequential full-quality captures, not a high-speed burst. The coach uses measured pixels and detected joints, not a generative AI service.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal,15)
                    Text(previewDiagnosticText)
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 15)
                    section("LIBRARY") {
                        settingToggle("Also Save to Photos", value: $settings.autoSaveToPhotos)
                        separator
                        settingToggle("Keep RAW originals", value: $settings.keepRAW)
                        separator
                        HStack {
                            Text("Storage")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: library.storageBytes, countStyle: .file)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 15).frame(height: 44)
                    }
                    section("FOCAL") {
                        Button { showGuide = true } label: { navigationRow("How to use Focal") }
                        separator
                        Link(destination: URL(string: "https://github.com/r3hal/focal-private/issues/new")!) { navigationRow("Send Feedback") }
                        separator
                        Button { showPrivacy = true } label: { navigationRow("Privacy Policy") }
                    }
                    Text("Focal 1.7 · Personal build\nRAW capture requires a compatible camera. RAW originals retain the full sensor frame.")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4).padding(.horizontal, 15)
                }
                .padding(.horizontal, 15).padding(.bottom, 32)
            }
        }
        .foregroundStyle(.white).background(.black).tint(Palette.yellow)
        .sheet(isPresented: $showGuide) { NavigationStack { FieldGuideView() }.presentationDragIndicator(.visible) }
        .sheet(isPresented: $showPrivacy) {
            NavigationStack {
                ScrollView {
                    Text("Camera frames, subject classification and tracking are processed on your iPhone using Apple Vision. Focal has no accounts, analytics or cloud AI. Optional Sony mode communicates only with the local camera address you select for received live view and advertised controls. Analysis still runs on your iPhone. Photos, optional scans, and RAW originals are stored locally. Device backups may include this library.\n\nAlso Save to Photos requests add-only Photos access and saves new captures automatically when enabled. Sharing and feedback happen only when you initiate them. Reference photos are imported locally through the system photo picker. Recipes, collections, practice counts and technical measurements are stored locally. Golden-hour location is requested only when you ask; it is not stored, uploaded or added to photos.\n\nSubject labels and composition suggestions can be inaccurate. Focal is an independent personal app.")
                        .padding(24).lineSpacing(5)
                }.navigationTitle("Privacy Policy").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showPrivacy = false } } }
            }
        }
    }

    private var separator: some View { Divider().overlay(Color.white.opacity(0.06)).padding(.horizontal, 15) }
    private func settingToggle(_ title: String, value: Binding<Bool>) -> some View {
        Toggle(title, isOn: value).padding(.horizontal, 15).frame(minHeight: 44)
    }
    private func navigationRow(_ title: String) -> some View {
        HStack { Text(title); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
            .padding(.horizontal, 15).frame(height: 44).foregroundStyle(.white)
    }
    private var previewDiagnosticText: String {
        if source == .sony {
            return "Sony live view: \(sonyModel) · \(sonyResolution)\n\(sonyPreviewInfo)\nCamera frame shows the full received image. Stream quality is set by Sony; lens zoom stays on the camera."
        }
        let cadence = camera.previewFPS.map { String(format: "%.0f fps last observed", $0) } ?? "measuring cadence"
        let limit = String(format: "%.1f×", camera.qualityZoomLimit)
        return "Preview: \(camera.previewResolution) · \(cadence) · Auto zoom limit: \(limit)\nMotion preview uses a fixed cadence. Low light can require higher ISO. Pinch takes control; restart AI Guidance or use Automatic subject selection to rearm."
    }

    private var subjectSelectivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subject selectivity").font(.subheadline)
            Slider(value: $settings.subjectThreshold, in: 0.55...0.85, step: 0.01).tint(Palette.yellow)
            Text("Higher values require stronger relevance evidence. Manual selection bypasses this threshold.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(15)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 15)
            VStack(spacing: 0, content: content).background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
