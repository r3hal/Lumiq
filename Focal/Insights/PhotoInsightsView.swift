import SwiftUI

struct PhotoInsightsView: View {
    let url:URL
    var intent:PhotographyIntent = .auto
    @Environment(\.dismiss) private var dismiss
    @State private var report:PhotoInsight?
    @State private var error:String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    Text("FOCAL INSIGHTS").font(.system(.caption,design:.monospaced,weight:.medium)).tracking(3).foregroundStyle(Palette.yellow)
                    if let report {
                        PhotoImage(url:url,maxPixels:1600).aspectRatio(report.aspectRatio,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:16))
                            .overlay { subjectIndicator(report) }.accessibilityLabel("Actual analyzed image")
                        exposure(report)
                        composition(report)
                        VStack(alignment:.leading,spacing:8) {
                            Text("Sharpness / local contrast").font(.headline)
                            Text(String(format:"Mean neighboring luminance difference: %.4f",report.measurements.detail)).font(.system(.caption,design:.monospaced))
                            Text("An edge-energy proxy sampled at a normalized size. Noise, texture, resizing and sharpening can raise it; it cannot prove optical focus.").font(.caption).foregroundStyle(Palette.muted)
                        }.padding(16).background(Palette.panel,in:RoundedRectangle(cornerRadius:16))
                        VStack(alignment:.leading,spacing:10) {
                            Text("Measured suggestions").font(.headline)
                            ForEach(Array(report.suggestions.enumerated()),id:\.offset) { _,text in Text(text).font(.subheadline) }
                        }.padding(16).background(Palette.panel,in:RoundedRectangle(cornerRadius:16))
                        if let metadata = report.metadata {
                            VStack(alignment:.leading,spacing:10) {
                                Text("File metadata").font(.headline)
                                ForEach(metadata.rows,id:\.0) { row in HStack { Text(row.0); Spacer(); Text(row.1).foregroundStyle(Palette.muted) }.font(.caption) }
                            }.padding(16).background(Palette.panel,in:RoundedRectangle(cornerRadius:16))
                        }
                    } else if let error { ContentUnavailableView("Analysis unavailable",systemImage:"photo.badge.exclamationmark",description:Text(error)) }
                    else { ProgressView("Analyzing the captured image…").frame(maxWidth:.infinity).padding(40) }
                    Text("Local analysis of this file. Composition suggestions are heuristics; no objective aesthetic rating or photo modification.").font(.caption).foregroundStyle(Palette.muted)
                }.padding(18)
            }.background(Palette.ink).foregroundStyle(Palette.text).navigationTitle("Insights").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Done") { dismiss() } } }
                .task(id:url) {
                    report = nil; error = nil
                    do { let value = try await PhotoInsightService.shared.analyze(url,intent:intent); guard !Task.isCancelled else { return }; report = value }
                    catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
        }.tint(Palette.yellow)
    }
    private func exposure(_ report:PhotoInsight) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Exposure assessment").font(.headline)
            Text(String(format:"Rendered headroom index %.0f / 100",report.previewHeadroomIndex)).font(.system(.subheadline,design:.monospaced)).foregroundStyle(Palette.yellow)
            Text(String(format:"Mean luminance %.0f%% · near white %.1f%% · deep shadows %.1f%%",report.measurements.brightness*100,report.measurements.highlightFraction*100,report.measurements.shadowFraction*100)).font(.caption)
            Text("100 × (1 − near-white fraction − near-black fraction), from sampled rendered pixels. This measures tonal occupancy, not whether the intended exposure is correct.").font(.caption2).foregroundStyle(Palette.muted)
        }.padding(16).background(Palette.panel,in:RoundedRectangle(cornerRadius:16))
    }
    private func composition(_ report:PhotoInsight) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Composition assessment").font(.headline)
            if let subject = report.subject {
                Text("Candidate: \(subject.name)").font(.subheadline)
                Text(String(format:"Center %.0f%% across / %.0f%% down · area %.1f%%",subject.centerX*100,subject.centerY*100,subject.width*subject.height*100)).font(.caption)
                Text(String(format:"Classifier score %.2f (not an aesthetic score)",subject.classificationScore)).font(.caption2).foregroundStyle(Palette.muted)
            } else { Text("No sufficiently supported subject candidate. Scene-wide exposure measurements still apply.").font(.subheadline).foregroundStyle(Palette.muted) }
            if let proposed = report.proposedComposition { Text("Suggested layout: \(proposed)").font(.subheadline).foregroundStyle(Palette.yellow) }
            if let facts = report.assessment {
                if let margin = facts.minimumMargin { Text(String(format:"Minimum visible margin %.1f%%",margin*100)).font(.caption) }
                if let headroom = facts.headroom { Text(String(format:"Margin above observed head region %.1f%%",headroom*100)).font(.caption) }
                if let angle = facts.candidateBoundaryDegrees { Text(String(format:"Candidate scene boundary %.1f°; not a confirmed horizon",angle)).font(.caption) }
                if let yaw = facts.headYawRadians { Text(String(format:"Head yaw estimate %.2f radians; eye gaze is not measured",yaw)).font(.caption2) }
            }
            if let score = report.aestheticScore {
                Text(String(format:"Apple whole-image aesthetics signal %.2f (−1…1)",score)).font(.caption)
                Text("Supplementary model signal; never used to invent camera directions or prove quality.").font(.caption2).foregroundStyle(Palette.muted)
            }
        }.padding(16).background(Palette.panel,in:RoundedRectangle(cornerRadius:16))
    }
    @ViewBuilder private func subjectIndicator(_ report:PhotoInsight) -> some View {
        if let subject = report.subject {
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius:5).stroke(Palette.yellow,lineWidth:1)
                    .frame(width:subject.width*geometry.size.width,height:subject.height*geometry.size.height)
                    .position(x:subject.centerX*geometry.size.width,y:subject.centerY*geometry.size.height)
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
