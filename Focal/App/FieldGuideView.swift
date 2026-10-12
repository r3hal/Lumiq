import SwiftUI

struct FieldGuideView: View {
    @Environment(\.dismiss) private var dismiss
    private let notes: [(String, String, String, String)] = [
        ("01", "viewfinder", "Find your subject.", "Focal finds a face or visually prominent object and follows it. The green label names the subject when on-device classification is confident. Labels can be wrong. Tap to select and focus, or use the yellow scan button to find a new subject."),
        ("02", "circle.dotted.circle", "Give it some space.", "The yellow cross marks the suggested composition point. Follow the instruction below the preview. Automatic framing first asks you to center the subject, then zooms once after you hold steady. The aperture menu switches between Thirds and Center when you frame manually."),
        ("03", "level", "Keep an even keel.", "The center line follows your phone’s tilt. Make it level, then hold your frame for a moment. The green center tick marks level. The instruction changes when the subject is aligned and you hold steady."),
        ("04", "camera.aperture", "Get a little closer.", "Pinch the preview to zoom, or tap a lens button. This cancels automatic framing until you scan again. Available lenses depend on your iPhone. Zoom between lens positions can crop the image and reduce detail. Automatic framing can zoom, but it cannot move your phone. It limits the crop using preview resolution and available lenses."),
        ("05", "photo", "Keep the detail.", "The aspect menu selects 3:4, 4:5, square or 9:16 and enables RAW on supported cameras. Crops retain the original JPEG. In Settings, choose scan saving, caption style, RAW retention, and automatic Photos export. Open the thumbnail to view or share Photo, Scan, Original, and RAW files.")
    ]

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 12) {
                        Eyebrow(text: "A pocket field guide").foregroundStyle(Palette.mint)
                        Text("See a little\ndifferently.")
                            .font(.system(size: 43, weight: .regular, design: .serif)).tracking(-1)
                        Text("A few small moves. A whole new perspective.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)
                    ForEach(notes, id: \.0) { note in
                        HStack(alignment: .top, spacing: 18) {
                            Image(systemName: note.1).font(.title3).foregroundStyle(Palette.mint)
                                .frame(width: 48, height: 48).background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 9) {
                                Eyebrow(text: note.0).foregroundStyle(.secondary)
                                Text(note.2).font(.system(.title3, design: .serif))
                                Text(note.3).font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Private by design", systemImage: "lock.shield").font(.headline)
                        Text("Camera frames are processed on your iPhone using Apple Vision. No accounts, uploads, analytics, or cloud AI. Your shots stay in Focal unless you enable automatic Photos export or choose to save or share them. iOS device backups may include your local library.")
                            .font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                        Text("Guidance works best with one clear subject. It can miss faces, scenes, or small details, and it does not judge artistic quality. The level measures phone tilt; it does not detect a horizon in the photo.")
                            .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                    }
                    .padding(22).background(Palette.panel, in: RoundedRectangle(cornerRadius: 22))
                    Text("FOCAL / KEEP LOOKING")
                        .font(.system(.caption2, design: .monospaced)).tracking(3)
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .padding(.horizontal, 24)
            }
            .background(Palette.ink)
            .navigationTitle("Field guide").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
    }
}
