import SwiftUI

struct FieldGuideView: View {
    private let notes: [(String, String, String, String)] = [
        ("01", "viewfinder", "Find your subject.", "Look for a person, a shape, or a little detail. Focal uses on-device visual attention detection to suggest the main subject."),
        ("02", "circle.dotted.circle", "Give it some space.", "In Thirds mode, bring the white subject dot into the green ring. Center mode puts your subject right in the middle. Follow the direction above the shutter."),
        ("03", "level", "Keep an even keel.", "The center line follows your phone’s tilt. Make it level, then hold your frame for a moment. A green check means the subject is aligned and the phone is level."),
        ("04", "camera.aperture", "Make the call.", "The guide is a suggestion. Take the shot whenever it feels right, or turn guidance off. Tap anywhere in the preview to set focus and exposure.")
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
