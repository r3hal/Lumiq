import Foundation
import CoreImage
import CoreVideo
import ImageIO

struct InsightSubject: Sendable {
    let name:String
    let classificationScore:Double
    let x:Double
    let y:Double
    let width:Double
    let height:Double
    var centerX:Double { x+width/2 }
    var centerY:Double { y+height/2 }
}
struct PhotoInsight: Sendable {
    let measurements:PhotoMeasurements
    let metadata:PhotoMetadata?
    let subject:InsightSubject?
    let proposedComposition:String?
    let suggestions:[String]
    let aspectRatio:Double
    var aestheticScore: Double? = nil
    var utilityImage: Bool? = nil
    var assessment: AssessmentMeasurements? = nil
    /// Defined technical index, never an objective aesthetic/RAW quality rating.
    var previewHeadroomIndex:Double { 100*max(0,1-measurements.highlightFraction-measurements.shadowFraction) }
}

actor PhotoInsightService {
    static let shared = PhotoInsightService()
    private struct Key:Hashable { let path:String; let modification:Date?; let bytes:Int?; let intent:String }
    private var cache:[Key:PhotoInsight] = [:]
    private var order:[Key] = []
    func analyze(_ url:URL,intent:PhotographyIntent = .auto) async throws -> PhotoInsight {
        try Task.checkCancellation()
        let attributes = try url.resourceValues(forKeys:[.contentModificationDateKey,.fileSizeKey])
        let key = Key(path:url.path,modification:attributes.contentModificationDate,bytes:attributes.fileSize,intent:intent.rawValue)
        if let cached = cache[key] { return cached }
        let report = try await inspect(url,intent:intent)
        try Task.checkCancellation()
        cache[key] = report; order.append(key)
        while order.count > 12 { cache.removeValue(forKey:order.removeFirst()) }
        return report
    }
    private func inspect(_ url:URL,intent:PhotographyIntent) async throws -> PhotoInsight {
        let analyzed = try await SceneAnalyzer.shared.analyze(url,intent:intent,includeAesthetics:true)
        let subject = analyzed.selected.map { c in InsightSubject(name:c.label,classificationScore:c.classificationConfidence,x:c.x,y:c.y,width:c.width,height:c.height) }
        let context = analyzed.contextSubjects.map { CompositionContextSubject(bounds:$0.bounds,label:$0.label,confidence:$0.confidence) }
        let measured = CompositionAssessment.evaluate(bounds:analyzed.selected?.bounds,confidence:analyzed.selected?.confidence ?? 0,
            label:analyzed.selected?.label ?? "Subject",intent:intent,stable:true,exposure:analyzed.subjectMeasurements,
            evidence:analyzed.evidence,others:context,anatomy:analyzed.anatomy)
        let plan:SceneCompositionPlan?
        if let selected = analyzed.selected, let evidence = analyzed.evidence {
            let options = SceneCompositionPlanner.compare(subject:selected.bounds,evidence:evidence,others:context,enclosingFrames:analyzed.enclosingFrames,maximumScale:1,intent:intent,label:selected.label)
            plan = options.first.map { SceneCompositionPlan(selected:$0,alternatives:Array(options.dropFirst().prefix(3)),subjectLabel:selected.label,timestamp:0) }
        } else { plan = nil }
        let reading = CompositionReading(state:.ready,subjectBounds:analyzed.selected?.bounds,subjectConfidence:Float(analyzed.selected?.confidence ?? 0),target:plan?.target ?? .init(x:0.5,y:0.5))
        let decision = ActionFeasibility.recommend(assessment:measured,reading:reading,intent:intent,plan:plan,rollReliable:false,previewAspect:analyzed.aspect)
        let scene = ActionFeasibility.sceneRecommendation(landscape:analyzed.landscape,stable:true,roll:0,rollReliable:false,measurements:analyzed.measurements,evidence:analyzed.evidence,timestamp:0,previewAspect:analyzed.aspect)
        let advice = analyzed.selected != nil ? decision.text : scene?.text ?? "No reliable subject adjustment identified."
        return .init(measurements:analyzed.measurements,metadata:PhotoMetadata.read(url),subject:subject,
                     proposedComposition:plan.map { $0.selected.isCurrentFrame ? "Keep current framing" : $0.selected.technique.rawValue },suggestions:[advice],aspectRatio:analyzed.aspect,
                     aestheticScore:analyzed.aestheticScore,utilityImage:analyzed.utilityImage,assessment:AssessmentMeasurements(measured))
    }
    enum AnalysisError:LocalizedError { case invalidImage; var errorDescription:String? { "This image could not be decoded for analysis. Its file remains unchanged." } }
}

struct PhotoComparison {
    let first:PhotoInsight
    let second:PhotoInsight
    var brightnessDifference:Double { second.measurements.brightness-first.measurements.brightness }
    var highlightsDifference:Double { second.measurements.highlightFraction-first.measurements.highlightFraction }
    var shadowsDifference:Double { second.measurements.shadowFraction-first.measurements.shadowFraction }
    var detailDifference:Double { second.measurements.detail-first.measurements.detail }
    var notes:[String] {
        var result = ["Differences describe rendered image pixels, not sensor exposure, RAW headroom or artistic quality. Edge energy can increase with noise or sharpening."]
        if abs(first.aspectRatio-second.aspectRatio) > 0.02 { result.append("The aspect ratios differ. Cropping/content can change these measurements; the images are not registered automatically.") }
        if first.subject?.name != second.subject?.name { result.append("Different primary candidates were detected. Subject positioning is not a like-for-like comparison.") }
        return result
    }
}
