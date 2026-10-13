import SwiftUI

private enum ComparisonPresentation:String,CaseIterable,Identifiable {
    case side = "Side by side", swipe = "Slider"
    var id:Self { self }
}
struct PhotoCompareView: View {
    let first:SavedPhoto
    let second:SavedPhoto
    @EnvironmentObject private var library:PhotoLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var original = true
    @State private var presentation:ComparisonPresentation = .side
    @State private var fraction = 0.5
    @State private var comparison:PhotoComparison?
    @State private var error:String?
    private var firstURL:URL { original ? library.originalURL(for:first) ?? library.url(for:first) : library.url(for:first) }
    private var secondURL:URL { original ? library.originalURL(for:second) ?? library.url(for:second) : library.url(for:second) }
    private var analysisID:String { firstURL.path+"|"+secondURL.path }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    Text("FOCAL COMPARE").font(.system(.caption,design:.monospaced,weight:.medium)).tracking(3).foregroundStyle(Palette.yellow)
                    Toggle("Original files",isOn:$original)
                    Text(original ? "Uses camera originals when retained; otherwise the saved capture." : "Uses current saved derivatives. Originals stay preserved.").font(.caption).foregroundStyle(Palette.muted)
                    Picker("Comparison presentation",selection:$presentation) { ForEach(ComparisonPresentation.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    comparisonImages
                    if presentation == .swipe { Slider(value:$fraction,in:0...1).accessibilityLabel("Image B reveal amount") }
                    if let comparison { measurements(comparison); metadata(comparison) }
                    else if let error { Text(error).foregroundStyle(Palette.muted) }
                    else { ProgressView("Measuring both images…").frame(maxWidth:.infinity) }
                    Text("Read-only comparison. No automatic winner, deletion or image modification.").font(.caption).foregroundStyle(Palette.muted)
                }.padding(18)
            }.background(Palette.ink).foregroundStyle(Palette.text).navigationTitle("Compare").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Done") { dismiss() } } }
                .task(id:analysisID) {
                    comparison = nil; error = nil
                    do {
                        let a = try await PhotoInsightService.shared.analyze(firstURL,intent:PhotographyIntent(rawValue:first.photographyIntent ?? "") ?? .auto)
                        try Task.checkCancellation()
                        let b = try await PhotoInsightService.shared.analyze(secondURL,intent:PhotographyIntent(rawValue:second.photographyIntent ?? "") ?? .auto)
                        guard !Task.isCancelled else { return }
                        comparison = .init(first:a,second:b)
                    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
        }.tint(Palette.yellow)
    }
    private var comparisonImages: some View {
        Group {
            if presentation == .side {
                HStack(alignment:.top,spacing:8) {
                    VStack { Text("A").font(.caption); PhotoImage(url:firstURL,maxPixels:1200).frame(maxWidth:.infinity) }
                    VStack { Text("B").font(.caption); PhotoImage(url:secondURL,maxPixels:1200).frame(maxWidth:.infinity) }
                }
            } else {
                GeometryReader { geometry in
                    ZStack(alignment:.leading) {
                        PhotoImage(url:firstURL,maxPixels:1600).frame(width:geometry.size.width,height:geometry.size.height)
                        PhotoImage(url:secondURL,maxPixels:1600).frame(width:geometry.size.width,height:geometry.size.height)
                            .mask(alignment:.leading) { Rectangle().frame(width:geometry.size.width*fraction) }
                        Rectangle().fill(Palette.yellow).frame(width:2).offset(x:geometry.size.width*fraction)
                        VStack { HStack { Text("B"); Spacer(); Text("A") }; Spacer() }.font(.caption.weight(.semibold)).padding(10)
                    }
                }.frame(height:340).clipped().background(Palette.panel,in:RoundedRectangle(cornerRadius:12))
            }
        }.accessibilityLabel("Two real saved images, A and B")
    }
    private func measurements(_ c:PhotoComparison) -> some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Measured differences · B minus A").font(.headline)
            difference("Mean luminance",a:c.first.measurements.brightness*100,b:c.second.measurements.brightness*100,delta:c.brightnessDifference*100,unit:"pp")
            difference("Near-white pixels",a:c.first.measurements.highlightFraction*100,b:c.second.measurements.highlightFraction*100,delta:c.highlightsDifference*100,unit:"pp")
            difference("Deep shadows",a:c.first.measurements.shadowFraction*100,b:c.second.measurements.shadowFraction*100,delta:c.shadowsDifference*100,unit:"pp")
            Text(String(format:"Local edge energy: A %.4f · B %.4f · Δ %+.4f",c.first.measurements.detail,c.second.measurements.detail,c.detailDifference)).font(.system(.caption,design:.monospaced))
            Text("A layout: \(c.first.proposedComposition ?? "No supported subject layout")").font(.caption)
            Text("B layout: \(c.second.proposedComposition ?? "No supported subject layout")").font(.caption)
            if let subject = c.first.subject { Text(String(format:"A %@ center: %.0f%% across, %.0f%% down",subject.name,subject.centerX*100,subject.centerY*100)).font(.caption) }
            if let subject = c.second.subject { Text(String(format:"B %@ center: %.0f%% across, %.0f%% down",subject.name,subject.centerX*100,subject.centerY*100)).font(.caption) }
            ForEach(Array(c.notes.enumerated()),id:\.offset) { _,note in Text(note).font(.caption2).foregroundStyle(Palette.muted) }
        }.padding(16).background(Palette.panel,in:RoundedRectangle(cornerRadius:16))
    }
    private func difference(_ title:String,a:Double,b:Double,delta:Double,unit:String) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(title).font(.caption.weight(.medium))
            Text(String(format:"A %.1f%% · B %.1f%% · Δ %+.1f %@",a,b,delta,unit)).font(.system(.caption,design:.monospaced)).foregroundStyle(Palette.yellow)
        }
    }
    private func metadata(_ c:PhotoComparison) -> some View {
        let a = Dictionary(uniqueKeysWithValues:c.first.metadata?.rows ?? []), b = Dictionary(uniqueKeysWithValues:c.second.metadata?.rows ?? [])
        let keys = Array(Set(a.keys).union(b.keys)).sorted()
        return VStack(alignment:.leading,spacing:10) {
            Text("File metadata · A / B").font(.headline)
            ForEach(keys,id:\.self) { key in
                VStack(alignment:.leading,spacing:3) {
                    Text(key).font(.caption.weight(.semibold))
                    Text("\(a[key] ?? "Not reported") / \(b[key] ?? "Not reported")").font(.caption).foregroundStyle(Palette.muted)
                }
            }
        }.padding(16).background(Palette.panel,in:RoundedRectangle(cornerRadius:16))
    }
}
