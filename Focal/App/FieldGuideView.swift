import SwiftUI

struct FieldGuideView: View {
    private let notes: [(String, String, String, String)] = [
        ("01", "viewfinder", "Find your subject.", "Focal automatically finds a face or a visually prominent object, focuses on it, and follows it. The dashed box shows the tracked area. Tap your subject to choose it yourself; use Rescan to return to automatic selection."),
        ("02", "circle.dotted.circle", "Give it some space.", "In Thirds mode, pan the phone in the suggested direction to bring the white subject dot into the green ring. The corner button switches between the four intersections. Center mode uses the middle of the frame."),
        ("03", "level", "Keep an even keel.", "The center line follows your phone’s tilt. Make it level, then hold your frame for a moment. A green check means the subject is aligned and the phone is level."),
        ("04", "camera.aperture", "Get a little closer.", "Pinch the preview to zoom, or tap a lens button. Available lenses depend on your iPhone. Zoom between lens positions can crop the image and reduce detail. The guide suggests a composition; it cannot move your phone."),
        ("05", "photo", "Keep the detail.", "Captures request the highest supported resolution and quality processing. The original camera file is saved without resizing or re-encoding. Open a shot to see its actual pixel dimensions and export the original to Photos.")
    ]

    var body: some View {
        NavigationStack {
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
                        Text("Camera frames are processed on your iPhone using Apple Vision. No accounts, uploads, analytics, or cloud AI. Your shots stay in Focal until you choose to save or share them. iOS device backups may include your local library.")
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
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
