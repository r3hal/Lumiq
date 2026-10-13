import SwiftUI

struct PrecisionOverlayView: View {
    let reading: PrecisionReading?
    let options: PrecisionOptions
    let recommendations: [AutoTuneRecommendation]
    let apply: (AutoTuneRecommendation) -> Void
    let canApply: (AutoTuneRecommendation) -> Bool
    var body: some View {
        ZStack(alignment:.topLeading) {
            if options.highlights, let image = reading?.zebra { Image(decorative:image,scale:1).resizable().interpolation(.none).allowsHitTesting(false).accessibilityHidden(true) }
            if options.peaking, let image = reading?.peaking { Image(decorative:image,scale:1).resizable().interpolation(.none).allowsHitTesting(false).accessibilityHidden(true) }
            VStack(alignment:.leading,spacing:8) {
                if options.histogram, let reading { LiveHistogramView(bins:reading.histogram,measurements:reading.measurements).frame(width:130,height:70).allowsHitTesting(false) }
                if options.autoTune, let recommendation = recommendations.first {
                    VStack(alignment:.leading,spacing:6) {
                        Label(recommendation.title,systemImage:"slider.horizontal.3").font(.caption.weight(.semibold))
                        Text(recommendation.reason).font(.caption2).fixedSize(horizontal:false,vertical:true)
                        if let ev = recommendation.exposureBias {
                            Button(String(format:"Try %+.1f EV",ev)) { apply(recommendation) }
                                .font(.caption.weight(.medium)).frame(minHeight:32)
                                .disabled(!canApply(recommendation))
                        }
                    }.padding(10).frame(maxWidth:220,alignment:.leading).background(Palette.ink.opacity(0.88),in:RoundedRectangle(cornerRadius:12)).foregroundStyle(Palette.text)
                }
                if options.peaking { Text("EDGE ASSIST · APPROXIMATE").font(.system(size:9,design:.monospaced)).padding(5).background(Palette.ink.opacity(0.8)).foregroundStyle(Palette.muted).allowsHitTesting(false) }
            }.padding(12)
        }
    }
}

struct LiveHistogramView: View {
    let bins:[Int]
    let measurements:PhotoMeasurements
    var body: some View {
        VStack(alignment:.leading,spacing:4) {
            Text("PREVIEW LUMA").font(.system(size:9,design:.monospaced)).foregroundStyle(Palette.muted)
            GeometryReader { geometry in
                let highest = max(1,bins.max() ?? 1)
                Path { path in
                    for (i,count) in bins.enumerated() {
                        let x = Double(i)/Double(max(1,bins.count))*geometry.size.width
                        let width = geometry.size.width/Double(max(1,bins.count))
                        let height = Double(count)/Double(highest)*geometry.size.height
                        path.addRect(CGRect(x:x,y:geometry.size.height-height,width:max(1,width),height:height))
                    }
                }.fill(Palette.yellow.opacity(0.85))
            }
            Text(String(format:"SH %.0f%% · HI %.0f%%",measurements.shadowFraction*100,measurements.highlightFraction*100)).font(.system(size:8,design:.monospaced)).foregroundStyle(Palette.muted)
        }.padding(8).background(Palette.ink.opacity(0.85),in:RoundedRectangle(cornerRadius:10))
            .accessibilityElement(children:.ignore).accessibilityLabel("Preview luminance histogram")
            .accessibilityValue(String(format:"Average luminance %.0f percent. Near-white pixels %.0f percent. Deep shadows %.0f percent.",measurements.brightness*100,measurements.highlightFraction*100,measurements.shadowFraction*100))
    }
}
