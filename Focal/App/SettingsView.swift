import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: CameraSettings
    @EnvironmentObject private var library: PhotoLibrary
    @ObservedObject var camera: CameraController
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
                            Text("Focal · All features available").foregroundStyle(Palette.yellow)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                        }.padding(.horizontal, 15).frame(height: 44).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                    }
                    section("CAMERA") {
                        settingToggle("Grid", value: $settings.grid)
                        separator
                        settingToggle("Level", value: $settings.level)
                        separator
                        settingToggle("Automatic framing", value: $settings.autoFrame)
                        separator
                        settingToggle("Shutter Sound", value: Binding(
                            get: { camera.canMuteShutter ? settings.shutterSound : true },
                            set: { settings.shutterSound = $0 }
                        )).disabled(!camera.canMuteShutter)
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
                    Text("Preview: \(camera.previewResolution) · Auto zoom limit: \(String(format: "%.1f×", camera.qualityZoomLimit))\nAutomatic framing zooms once after centering. Pinch zoom takes control; scan starts a new frame.")
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
                    Text("Focal 1.3 · Personal build\nRAW capture requires a compatible camera. RAW originals retain the full sensor frame.")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4).padding(.horizontal, 15)
                }
                .padding(.horizontal, 15).padding(.bottom, 32)
            }
        }
        .foregroundStyle(.white).background(.black).tint(Palette.yellow)
        .sheet(isPresented: $showGuide) { FieldGuideView().presentationDragIndicator(.visible) }
        .sheet(isPresented: $showPrivacy) {
            NavigationStack {
                ScrollView {
                    Text("Camera frames, subject classification and tracking are processed on your iPhone using Apple Vision. Focal has no accounts, analytics or cloud AI. Photos, optional scans, and RAW originals are stored locally. Device backups may include this library.\n\nAlso Save to Photos requests add-only Photos access and saves new captures automatically when enabled. Sharing and feedback happen only when you initiate them.\n\nSubject labels and composition suggestions can be inaccurate. Focal is an independent personal app.")
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
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 15)
            VStack(spacing: 0, content: content).background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
