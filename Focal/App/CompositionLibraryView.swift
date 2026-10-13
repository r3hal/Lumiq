import SwiftUI

struct CompositionLibraryView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:16) {
                Text("Explore different ways to frame a scene. Focal compares layouts supported by what it can measure; you choose the photograph.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(CompositionTechnique.allCases) { technique in
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Text(technique.rawValue).font(.headline)
                            Spacer()
                            Text(technique.automatic ? "Measured cues" : "Explore").font(.caption2).foregroundStyle(Palette.yellow)
                        }
                        Text(technique.advice).font(.subheadline)
                        Text(technique.evidenceDescription).font(.caption).foregroundStyle(.secondary)
                    }.padding(16).background(Palette.panel,in:RoundedRectangle(cornerRadius:16))
                }
                VStack(alignment:.leading,spacing:10) {
                    Text("Further reading").font(.headline)
                    Link("Nikon · Composition guidelines",destination:URL(string:"https://www.nikonusa.com/learn-and-explore/c/tips-and-techniques/5-easy-composition-guidelines")!)
                    Link("Adobe · Symmetry and balance",destination:URL(string:"https://lightroom.adobe.com/academy/principles/composition/symmetry")!)
                    Link("Adobe · Leading lines",destination:URL(string:"https://lightroom.adobe.com/academy/principles/composition/leading-lines")!)
                }.font(.subheadline).tint(Palette.yellow).padding(.vertical,10)
            }.padding(18)
        }.background(Palette.ink).foregroundStyle(.white)
            .navigationTitle("Composition").navigationBarTitleDisplayMode(.inline)
    }
}
