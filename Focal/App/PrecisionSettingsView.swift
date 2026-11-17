import SwiftUI

struct PrecisionSettingsView: View {
    @EnvironmentObject private var settings: CameraSettings
    var body: some View {
        Form {
            Section {
                Toggle("Live histogram",isOn:$settings.histogram)
                Toggle("Highlight warnings",isOn:$settings.highlightWarnings)
                Toggle("Focus peaking",isOn:$settings.focusPeaking)
            } header: {
                Text("Lumiq Precision")
            } footer: { Text("These tools sample the real preview independently of AI. Zebra stripes indicate near-white preview pixels, which can differ from RAW clipping. Peaking highlights strong local edges; it is an approximate focus aid, not proof of optical sharpness.") }
            Section {
                Toggle("Settings recommendations",isOn:$settings.autoTune)
            } header: {
                Text("Lumiq AutoTune")
            } footer: { Text("Uses preview luminance, actual exposure and phone rotation when available. Recommendations do not change PRO settings. In AUTO, you can explicitly try a suggested EV adjustment. Sony receives image-based suggestions with no settings changes.") }
            Section("Manual focus") {
                Text("In PRO, choose FOCUS to adjust the actual lens position and open the center loupe. Some virtual camera devices do not expose manual focus: choose a supported physical lens from LENS. The loupe magnifies the live preview without changing capture zoom.")
            }
        }.scrollContentBackground(.hidden).background(Palette.ink).foregroundStyle(Palette.text).tint(Palette.yellow)
            .navigationTitle("Lumiq Precision").navigationBarTitleDisplayMode(.inline)
    }
}
