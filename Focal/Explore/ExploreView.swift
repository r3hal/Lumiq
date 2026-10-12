import SwiftUI

struct PracticeChallenge: Identifiable {
    let id: String
    let title: String
    let instruction: String
    static let all = [
        Self(id: "thirds",title: "Find the thirds",instruction: "Place one clear subject near a thirds intersection. Turn off automatic framing if you want to compose it manually."),
        Self(id: "background",title: "Simplify the background",instruction: "Make three frames from different angles. Keep the subject, remove distracting edges."),
        Self(id: "light",title: "Follow the light",instruction: "Photograph the same subject in three lighting positions. Compare highlights and shadows."),
        Self(id: "distance",title: "Tell it in three distances",instruction: "Make a wide frame, a medium frame and a detail. Moving closer can preserve more detail than digital zoom.")
    ]
}

struct ExploreView: View {
    @EnvironmentObject private var library: PhotoLibrary
    @EnvironmentObject private var settings: CameraSettings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading,spacing: 24) {
                    Text("Explore").font(.largeTitle.bold())
                    Text("Practical ideas for your next frame.").foregroundStyle(.secondary)
                    NavigationLink { FieldGuideView() } label: { Label("Composition field guide",systemImage: "viewfinder") }
                    NavigationLink { GoldenHourView() } label: { Label("Plan golden light",systemImage: "sun.horizon") }
                    Text("PRACTICE").font(.caption).foregroundStyle(.secondary)
                    ForEach(PracticeChallenge.all) { challenge in
                        VStack(alignment: .leading,spacing: 12) {
                            Text(challenge.title).font(.headline)
                            Text(challenge.instruction).font(.subheadline).foregroundStyle(.secondary)
                            let count = library.photos.filter { !$0.isDemo && $0.challenge == challenge.id }.count
                            Text("\(min(count,3))/3 saved practice captures").font(.caption).foregroundStyle(Palette.mint)
                            Button(settings.challenge == challenge.id ? "Continue practice" : "Start practice") { settings.challenge = challenge.id; dismiss() }.buttonStyle(.bordered)
                        }.padding(18).frame(maxWidth: .infinity,alignment: .leading).background(Palette.panel,in: RoundedRectangle(cornerRadius: 16))
                    }
                    if !settings.challenge.isEmpty { Button("End current practice") { settings.challenge = "" }.foregroundStyle(Palette.yellow) }
                    Text("Counts track retained photos taken during practice. They do not certify composition or artistic quality.").font(.caption).foregroundStyle(.secondary)
                }.padding(22)
            }.background(.black).tint(Palette.yellow)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
