import Vision
import CoreVideo
import Foundation

/// Real detectors propose regions; relevance and temporal evidence select one.
/// Tracking retains it; tap intent bypasses automatic relevance, never boundaries.
final class SubjectTracker {
    private struct Detection { var observation: VNDetectedObjectObservation; var candidate: SubjectCandidate }
    private let requestLock = NSLock()
    private var activeRequests: [VNRequest] = []
    private var sequence = VNSequenceRequestHandler()
    private var tracking: VNTrackObjectRequest?
    private var candidates: [Detection] = []
    private var trackedCandidate: SubjectCandidate?
    private var selector = SubjectSelector()
    private var health = SubjectTrackingHealth()
    private var selectedPoint: CGPoint?
    private var lastDetection: TimeInterval = -.infinity
    private var lastScene: TimeInterval = -.infinity
    private(set) var manual = false
    private(set) var label = "Auto subject"
    private(set) var scene: SubjectScene?

    func cancelInference(includeTracking: Bool = true) {
        requestLock.lock(); let requests = activeRequests; requestLock.unlock()
        requests.filter { includeTracking || !($0 is VNTrackObjectRequest) }.forEach { $0.cancel() }
    }
    func performRequests(_ requests: [VNRequest], canContinue: () -> Bool = { true }, work: () throws -> Void) throws {
        requests.forEach { $0.preferBackgroundProcessing = true }
        requestLock.lock(); activeRequests = requests; requestLock.unlock()
        defer { requestLock.lock(); activeRequests = []; requestLock.unlock() }
        guard canContinue() else { throw CancellationError() }
        try work()
    }

    func setThreshold(_ value: Double) {
        selector.configuration.threshold = max(0.55, min(0.85, value))
        selector.reset()
    }
    func reset() {
        sequence = VNSequenceRequestHandler(); tracking = nil; trackedCandidate = nil
        candidates = []; selectedPoint = nil; selector.reset(); health.reset()
        lastDetection = -.infinity; lastScene = -.infinity; scene = nil
        manual = false; label = "Auto subject"
    }
    func select(at imagePoint: UnitPoint2D) {
        let point = CGPoint(x: imagePoint.x, y: 1 - imagePoint.y)
        selectedPoint = point; manual = true
        sequence = VNSequenceRequestHandler(); tracking = nil; trackedCandidate = nil
        selector.reset(); health.reset(); label = "Your subject"
        if ProcessInfo.processInfo.systemUptime - lastDetection < 2,
           let index = selector.select(candidates.map(\.candidate), timestamp: ProcessInfo.processInfo.systemUptime, manualPoint: point) {
            start(candidates[index])
        }
        lastDetection = -.infinity
    }

    func observation(in buffer: CVPixelBuffer, timestamp: TimeInterval,
                     visibleRegion: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), trackingOnly: Bool = false, canContinue: () -> Bool = { true }) -> VNDetectedObjectObservation? {
        guard canContinue() else { return nil }
        var retained: VNDetectedObjectObservation?
        if let tracking {
            do {
                try performRequests([tracking], canContinue: canContinue) { try sequence.perform([tracking], on: buffer, orientation: .up) }
                guard canContinue() else { return nil }
                if let result = tracking.results?.first as? VNDetectedObjectObservation,
                   result.confidence >= 0.45, valid(result.boundingBox),
                   visibleRegion.contains(CGPoint(x: result.boundingBox.midX, y: result.boundingBox.midY)) {
                    tracking.inputObservation = result; retained = result
                    trackedCandidate?.bounds = result.boundingBox; trackedCandidate?.confidence = Double(result.confidence)
                }
            } catch { /* Do not display an old rectangle as a new observation. */ }
            if health.lost(reliable: retained != nil, timestamp: timestamp) {
                self.tracking = nil; trackedCandidate = nil; sequence = VNSequenceRequestHandler()
                selector.reset(); candidates = []; label = manual ? "Your subject" : "Auto subject"
            } else if retained == nil { return nil }
        }
        // During a lens ramp, only verify the chosen subject. No new acquisition
        // or semantic switching can silently redirect an automatic zoom.
        if trackingOnly { return retained }
        let interval: TimeInterval = retained == nil ? 0.75 : 2.5
        guard timestamp - lastDetection >= interval, !manual || retained == nil else { return retained }
        lastDetection = timestamp
        let detected = detect(in: buffer, timestamp: timestamp, visibleRegion: visibleRegion, canContinue: canContinue)
        guard canContinue() else { return nil }
        candidates = detected
        if let index = selector.select(detected.map(\.candidate), timestamp: timestamp,
                                       current: retained == nil ? nil : trackedCandidate, manualPoint: manual ? selectedPoint : nil) {
            start(detected[index]); return detected[index].observation
        }
        return retained
    }

    private func detect(in buffer: CVPixelBuffer, timestamp: TimeInterval, visibleRegion: CGRect, canContinue: () -> Bool) -> [Detection] {
        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest(); people.upperBodyOnly = false
        let animals = VNRecognizeAnimalsRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        do {
            try performRequests([faces, people, animals, saliency], canContinue: canContinue) {
                try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([faces, people, animals, saliency])
            }
            guard canContinue() else { return [] }
            guard let evidence = SubjectImageEvidence.sample(buffer) else { return [] }
            var detections = [Detection]()
            func append(_ observation: VNDetectedObjectObservation, category: SubjectCategory, label: String, semanticConfidence: Double) {
                guard valid(observation.boundingBox), observation.confidence >= 0.5,
                      visibleRegion.contains(CGPoint(x: observation.boundingBox.midX, y: observation.boundingBox.midY)) else { return }
                let prominence = SubjectSaliencyEvidence.prominence(observation.boundingBox, buffer: saliency.results?.first?.pixelBuffer)
                let features = evidence.features(for: observation.boundingBox, saliencyProminence: prominence)
                let candidate = SubjectCandidate(bounds: observation.boundingBox, confidence: Double(observation.confidence), category: category,
                    label: label, classificationConfidence: semanticConfidence, prominence: features.prominence, isolation: features.isolation,
                    detail: features.detail, textureDensity: features.texture, visibleRegion: visibleRegion)
                detections.append(Detection(observation: observation, candidate: candidate))
            }
            for person in people.results ?? [] { append(person, category: .person, label: "Person", semanticConfidence: Double(person.confidence)) }
            for face in faces.results ?? [] { append(face, category: .face, label: "Person", semanticConfidence: Double(face.confidence)) }
            for animal in animals.results ?? [] {
                guard let recognized = animal.labels.first, recognized.confidence >= 0.55 else { continue }
                append(animal, category: .pet, label: recognized.identifier.capitalized, semanticConfidence: Double(recognized.confidence))
            }
            let objects = (saliency.results?.first?.salientObjects ?? []).filter {
                valid($0.boundingBox) && visibleRegion.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY))
            }.sorted { left, right in
                let a = evidence.features(for: left.boundingBox, saliencyProminence: SubjectSaliencyEvidence.prominence(left.boundingBox, buffer: saliency.results?.first?.pixelBuffer))
                let b = evidence.features(for: right.boundingBox, saliencyProminence: SubjectSaliencyEvidence.prominence(right.boundingBox, buffer: saliency.results?.first?.pixelBuffer))
                return a.isolation + a.prominence > b.isolation + b.prominence
            }
            // Bound classification cost. Saliency confidence alone never declares
            // that a wall, room structure or piece of furniture is a subject.
            for (index, object) in objects.prefix(4).enumerated() {
                guard canContinue() else { return [] }
                var category: SubjectCategory = .object, label = "Subject", confidence = 0.0
                if index < 2 {
                    let request = VNClassifyImageRequest(); request.regionOfInterest = object.boundingBox
                    if (try? performRequests([request], canContinue: canContinue) { try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request]) }) != nil,
                       let result = request.results?.first, result.confidence >= 0.6 {
                        label = result.identifier.components(separatedBy: ",").first?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Subject"
                        let classified = SubjectCategory.classified(result.identifier)
                        // A crop label cannot turn a saliency blob into a true
                        // human/animal boundary. Those need semantic detectors.
                        category = classified.semantic ? .object : classified
                        confidence = Double(result.confidence)
                    }
                }
                append(object, category: category, label: label, semanticConfidence: confidence)
            }
            if canContinue(), retainedSceneNeeded(detections), timestamp - lastScene >= 3 {
                lastScene = timestamp
                let request = VNClassifyImageRequest()
                if (try? performRequests([request], canContinue: canContinue) { try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request]) }) != nil,
                   let result = request.results?.first, result.confidence >= 0.65 {
                    scene = SubjectScene(label: result.identifier, confidence: result.confidence, timestamp: timestamp)
                } else { scene = nil }
            }
            return detections
        } catch { return [] }
    }
    private func retainedSceneNeeded(_ detections: [Detection]) -> Bool {
        !detections.contains { $0.candidate.category.semantic }
    }
    private func start(_ detection: Detection) {
        sequence = VNSequenceRequestHandler(); health.reset()
        let request = VNTrackObjectRequest(detectedObjectObservation: detection.observation)
        request.trackingLevel = .accurate; tracking = request
        trackedCandidate = detection.candidate; label = detection.candidate.label
    }
    func reseed(bounds: CGRect, label: String, manual: Bool) {
        let clipped = bounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, valid(clipped) else { reset(); return }
        var candidate = trackedCandidate ?? SubjectCandidate(bounds: clipped, confidence: 0, category: .object, label: label)
        candidate.bounds = clipped; candidate.label = label
        start(Detection(observation: VNDetectedObjectObservation(boundingBox: clipped), candidate: candidate))
        self.manual = manual
        if manual { selectedPoint = CGPoint(x: clipped.midX, y: clipped.midY) }
    }
    private func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0.015 && rect.height > 0.015 && rect.width * rect.height < 0.98
            && rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1
    }
}
