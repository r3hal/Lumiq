import Foundation
import Vision
import CoreImage
import CoreVideo
import ImageIO

struct AnalyzedSubject: Codable, Sendable {
    let label: String
    let confidence: Double
    let classificationConfidence: Double
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    var origin: String? = nil
    var measurements: PhotoMeasurements? = nil
    var bounds: CGRect { CGRect(x:x,y:y,width:width,height:height) }
}
struct SceneAnalysisResult: Sendable {
    let subjects: [AnalyzedSubject]
    let nativeCandidates: [SubjectCandidate]
    let contextSubjects: [AnalyzedSubject]
    let enclosingFrames: [CGRect]
    let selected: AnalyzedSubject?
    let measurements: PhotoMeasurements
    let subjectMeasurements: PhotoMeasurements?
    let evidence: SceneCompositionEvidence?
    let sceneLabel: String?
    let sceneConfidence: Double?
    let landscape: Bool
    let anatomy: SubjectAnatomy?
    let aestheticScore: Double?
    let utilityImage: Bool?
    let inferenceMilliseconds: Double
    let aspect: Double
}

/// Single-image analysis shares native detectors, selection and projection with
/// live iPhone/Sony guidance. It cannot establish motion or tracking stability.
actor SceneAnalyzer {
    static let shared = SceneAnalyzer()
    private let renderer = CIContext(options:[.cacheIntermediates:false,.priorityRequestLow:true])
    func analyze(_ url: URL, intent: PhotographyIntent, manualRegion: CGRect? = nil, includeAesthetics: Bool = false) throws -> SceneAnalysisResult {
        try Task.checkCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        guard let source = CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:768] as CFDictionary) else { throw PhotoInsightService.AnalysisError.invalidImage }
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault,image.width,image.height,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[String:Any]()] as CFDictionary,&created) == kCVReturnSuccess,
              let buffer = created else { throw PhotoInsightService.AnalysisError.invalidImage }
        renderer.render(CIImage(cgImage:image),to:buffer)
        guard let measured = PhotoMeasurements.from(buffer:buffer) else { throw PhotoInsightService.AnalysisError.invalidImage }
        let aspect = Double(image.width)/Double(image.height), projection = PreviewProjection(imageAspect:aspect,previewAspect:aspect)
        let tracker = SubjectTracker()
        let native: [SubjectCandidate]
        if intent == .landscape {
            tracker.setIntent(intent)
            _ = tracker.observation(in:buffer,timestamp:started,canContinue:{ !Task.isCancelled })
            native = []
        } else { native = tracker.inspectStillImage(buffer,intent:intent,selectedOnly:false) }
        try Task.checkCancellation()
        func subject(_ candidate:SubjectCandidate) -> AnalyzedSubject {
            .init(label:candidate.label,confidence:candidate.confidence,classificationConfidence:candidate.classificationConfidence,
                  x:Double(candidate.bounds.minX),y:Double(1-candidate.bounds.maxY),width:Double(candidate.bounds.width),height:Double(candidate.bounds.height))
        }
        let config = SubjectSelectionConfiguration(intent:intent)
        let meaningful = native.filter { ($0.score(configuration:config) ?? 0) >= config.threshold }
        let selected: SubjectCandidate?
        if let manualRegion {
            selected = native.filter { $0.manuallySelectable && subject($0).bounds.intersects(manualRegion) }.max(by: { a,b in
                func overlap(_ candidate:SubjectCandidate) -> CGFloat {
                    let box = subject(candidate).bounds, intersection = box.intersection(manualRegion)
                    let union = box.width*box.height+manualRegion.width*manualRegion.height-intersection.width*intersection.height
                    return union > 0 ? intersection.width*intersection.height/union : 0
                }
                return overlap(a) < overlap(b)
            })
        } else { selected = meaningful.max { ($0.score(configuration:config) ?? 0) < ($1.score(configuration:config) ?? 0) } }
        let primary: AnalyzedSubject?
        if let selected { primary = subject(selected) }
        else if let manualRegion, manualRegion.width > 0.015, manualRegion.height > 0.015,
                SceneCompositionEvidence.full.contains(manualRegion) {
            primary = .init(label:"Selected subject",confidence:1,classificationConfidence:0,
                x:Double(manualRegion.minX),y:Double(manualRegion.minY),width:Double(manualRegion.width),height:Double(manualRegion.height),origin:"manual region, not detector confidence")
        } else { primary = nil }
        let evidence = SubjectImageEvidence.sample(buffer).flatMap { SceneCompositionEvidence(image:$0,projection:projection,timestamp:0) }
        let regional = primary.flatMap { PhotoMeasurements.fromSubject(buffer:buffer,region:$0.bounds) }
        var anatomy = tracker.anatomy(for:selected?.bounds,projection:projection,at:ProcessInfo.processInfo.systemUptime)
        anatomy?.timestamp = 0 // Still-image snapshot, not a live temporal observation.
        var aesthetics: Double?, utility: Bool?
        // Apple's supplementary whole-image score is deliberately excluded
        // from movement directions and from live capture-frame processing.
        if includeAesthetics, #available(iOS 18.0, *) {
            let request = VNCalculateImageAestheticsScoresRequest()
            if (try? tracker.performRequests([request],canContinue:{ !Task.isCancelled }) {
                try VNImageRequestHandler(cvPixelBuffer:buffer,orientation:.up).perform([request])
            }) != nil, let score = request.results?.first, score.overallScore.isFinite {
                aesthetics = Double(score.overallScore); utility = score.isUtility
            }
        }
        try Task.checkCancellation()
        let context = native.filter { $0.score(configuration:config) != nil }.map(subject)
        let frames = tracker.inspectedEnclosingFrames.map { CGRect(x:$0.minX,y:1-$0.maxY,width:$0.width,height:$0.height) }
        let observed = native.map { candidate -> AnalyzedSubject in
            var result = subject(candidate)
            result.measurements = PhotoMeasurements.fromSubject(buffer:buffer,region:result.bounds)
            return result
        }
        return .init(subjects:observed,nativeCandidates:native,contextSubjects:context,enclosingFrames:frames,selected:primary,measurements:measured,subjectMeasurements:regional,evidence:evidence,
                     sceneLabel:tracker.scene?.label,sceneConfidence:tracker.scene.map { Double($0.confidence) },landscape:intent == .landscape || tracker.scene?.isLandscape == true,anatomy:anatomy,
                     aestheticScore:aesthetics,utilityImage:utility,inferenceMilliseconds:(ProcessInfo.processInfo.systemUptime-started)*1000,aspect:aspect)
    }
}
