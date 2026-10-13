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
    /// Defined technical index, never an objective aesthetic/RAW quality rating.
    var previewHeadroomIndex:Double { 100*max(0,1-measurements.highlightFraction-measurements.shadowFraction) }
}

actor PhotoInsightService {
    static let shared = PhotoInsightService()
    private struct Key:Hashable { let path:String; let modification:Date?; let bytes:Int?; let intent:String }
    private var cache:[Key:PhotoInsight] = [:]
    private var order:[Key] = []
    private let renderer = CIContext(options:[.cacheIntermediates:false,.priorityRequestLow:true])
    func analyze(_ url:URL,intent:PhotographyIntent = .auto) throws -> PhotoInsight {
        try Task.checkCancellation()
        let attributes = try url.resourceValues(forKeys:[.contentModificationDateKey,.fileSizeKey])
        let key = Key(path:url.path,modification:attributes.contentModificationDate,bytes:attributes.fileSize,intent:intent.rawValue)
        if let cached = cache[key] { return cached }
        let report = try autoreleasepool { try inspect(url,intent:intent) }
        try Task.checkCancellation()
        cache[key] = report; order.append(key)
        while order.count > 12 { cache.removeValue(forKey:order.removeFirst()) }
        return report
    }
    private func inspect(_ url:URL,intent:PhotographyIntent) throws -> PhotoInsight {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:768] as CFDictionary) else { throw AnalysisError.invalidImage }
        var created:CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault,image.width,image.height,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[String:Any]()] as CFDictionary,&created) == kCVReturnSuccess,
              let buffer = created else { throw AnalysisError.invalidImage }
        renderer.render(CIImage(cgImage:image),to:buffer)
        guard let measured = PhotoMeasurements.from(buffer:buffer) else { throw AnalysisError.invalidImage }
        let tracker = SubjectTracker()
        let config = SubjectSelectionConfiguration(intent:intent)
        let candidates = tracker.inspectStillImage(buffer,intent:intent).sorted { ($0.score(configuration:config) ?? 0) > ($1.score(configuration:config) ?? 0) }
        let candidate = candidates.first
        let subject = candidate.map { c in InsightSubject(name:c.label,classificationScore:c.classificationConfidence,x:Double(c.bounds.minX),y:Double(1-c.bounds.maxY),width:Double(c.bounds.width),height:Double(c.bounds.height)) }
        let aspect = Double(image.width)/Double(image.height)
        let projection = PreviewProjection(imageAspect:aspect,previewAspect:aspect)
        let evidence = SubjectImageEvidence.sample(buffer).flatMap { SceneCompositionEvidence(image:$0,projection:projection,timestamp:0) }
        let proposed:String?
        var suggestions = [String]()
        if let advice = measured.lightingAdvice { suggestions.append(advice) }
        if let candidate, let evidence {
            let box = CGRect(x:candidate.bounds.minX,y:1-candidate.bounds.maxY,width:candidate.bounds.width,height:candidate.bounds.height)
            let others = candidates.map { c in CompositionContextSubject(bounds:CGRect(x:c.bounds.minX,y:1-c.bounds.maxY,width:c.bounds.width,height:c.bounds.height),label:c.label,confidence:c.confidence) }
            let layouts = SceneCompositionPlanner.compare(subject:box,evidence:evidence,others:others,maximumScale:1,intent:intent)
            proposed = layouts.first?.technique.rawValue
            if let best = layouts.first { suggestions.append("Explore \(best.technique.rawValue.lowercased()): \(best.explanation).") }
            let regional = PhotoMeasurements.from(buffer:buffer,subject:box)
            if let advice = regional?.clutterAdvice { suggestions.append(advice) }
            if box.width*box.height < 0.03 { suggestions.append("The selected candidate occupies less than 3% of this image. Consider a tighter view if context is not important.") }
        } else if let scene = tracker.scene, scene.isLandscape, let evidence, let line = evidence.horizontalBoundary() {
            proposed = CompositionTechnique.horizon.rawValue
            suggestions.append(String(format:"A candidate landscape boundary is %.0f%% down this image. Explore sky/foreground balance without forcing an object box.",(line.start.y+line.end.y)*50))
        } else { proposed = nil }
        if suggestions.isEmpty { suggestions.append("No strong clipping or isolated-subject issue was measured. Review the photograph's intent and context yourself.") }
        return .init(measurements:measured,metadata:PhotoMetadata.read(url),subject:subject,proposedComposition:proposed,suggestions:suggestions,aspectRatio:aspect)
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
