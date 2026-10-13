import SwiftUI

struct AIPhotographyView: View {
    @EnvironmentObject private var settings: CameraSettings
    let source: CameraSource
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 0) {
                    row("AI Guidance", subtitle: "Show composition guidance", value: $settings.guide)
                    divider
                    row("Automatic Zoom", subtitle: source == .sony ? "Use the lens controls on your Sony" : "Zoom when framing is ready", value: automaticZoom)
                        .disabled(source == .sony || !settings.subjectTracking)
                    divider
                    holdRow.disabled(source == .sony || !settings.subjectTracking)
                    divider
                    row("Pet Detection", subtitle: "Detect cats and dogs", value: $settings.petDetection)
                    divider
                    row("Subject Tracking", subtitle: "Keep focus on the selected subject", value: $settings.subjectTracking)
                    divider
                    row("Smart Subject Selection", subtitle: "Focus only on meaningful subjects", value: $settings.smartSelection)
                    divider
                    row("Composition Planning", subtitle: "Compare framing, space, lines and balance", value: $settings.compositionPlanning)
                }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
                Text(settings.smartSelection ? "Subjects are selected from real detections. Some scenes may have no suitable subject." : "Tap a detected subject in the viewfinder to select it. Normal autofocus remains active.")
                    .font(.caption).foregroundStyle(.secondary)
                if !settings.subjectTracking { Text("Tracking is off. Subjects are checked with fresh detections; automatic zoom requires tracking.").font(.caption).foregroundStyle(.secondary) }
                if source == .sony { Text("The same on-device guidance analyzes the real Sony live view. Automatic lens zoom and phone motion leveling apply only to iPhone.").font(.caption).foregroundStyle(.secondary) }
                NavigationLink { CompositionLibraryView() } label: {
                    HStack {
                        Image(systemName:"square.stack.3d.up")
                        Text("Composition techniques").font(.subheadline)
                        Spacer()
                        Image(systemName:"chevron.right").font(.caption)
                    }.padding(15).background(Palette.panel,in:RoundedRectangle(cornerRadius:16))
                }.foregroundStyle(Palette.yellow)
                Text("Automatic composition chooses from supported layouts in the visible scene. Center and Thirds in the camera menu override it. Some techniques require your own visual judgment.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 9) {
                    Text("Subject selectivity").font(.subheadline)
                    Slider(value: $settings.subjectThreshold, in: 0.55...0.85, step: 0.01).tint(Palette.yellow)
                    Text("Require stronger evidence before choosing a subject.").font(.caption).foregroundStyle(.secondary)
                }.padding(15).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
            }.padding(18)
        }.background(.black).foregroundStyle(.white).tint(Palette.yellow)
            .navigationTitle("AI Photography").navigationBarTitleDisplayMode(.inline)
    }
    private var automaticZoom: Binding<Bool> {
        Binding(get: { source == .iPhone && settings.autoFrame && settings.subjectTracking }, set: { settings.autoFrame = $0 })
    }
    private func row(_ title: String, subtitle: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 15).padding(.vertical, 13)
    }
    private var holdRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Hold Steady Duration").font(.system(size: 14))
                if ![1.0, 2.0, 3.0].contains(settings.holdDuration) { Text(String(format: "%.1fs", settings.holdDuration)).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                ForEach([1.0, 2.0, 3.0], id: \.self) { duration in
                    Button { settings.holdDuration = duration } label: {
                        Text(String(format: "%.0fs", duration)).font(.system(size: 12, weight: .semibold)).frame(width: 31, height: 30)
                            .foregroundStyle(settings.holdDuration == duration ? .black : .white)
                            .background(settings.holdDuration == duration ? Palette.yellow : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.accessibilityLabel("Hold for \(Int(duration)) seconds")
                        .accessibilityAddTraits(settings.holdDuration == duration ? .isSelected : [])
                }
            }.padding(3).background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 10))
        }.padding(.horizontal, 15).padding(.vertical, 12)
            .accessibilityValue(String(format: "%.1f seconds", settings.holdDuration))
    }
    private var divider: some View { Divider().overlay(.white.opacity(0.05)).padding(.horizontal, 15) }
}
