import Vision
import CoreVideo
import CoreImage
import Foundation

struct SubjectObservation {
    let boundingBox: CGRect
    /// Tracking confidence, or measured proposal support after selection dwell.
    let confidence: Float
    init(_ observation: VNDetectedObjectObservation) {
        boundingBox = observation.boundingBox; confidence = observation.confidence
    }
    init(candidate: SubjectCandidate) {
        boundingBox = candidate.bounds; confidence = Float(min(1, max(0, candidate.confidence)))
    }
}

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
    private var lastPrinted: TimeInterval = -.infinity
    private(set) var manual = false
    private(set) var label = "Auto subject"
    private(set) var scene: SubjectScene?
    private(set) var isRecovering = false
    private(set) var features = SubjectAnalysisFeatures()
    private var enclosingRectangles: [CGRect] = []
    /// Only detector observations fresh enough for scene context. Tracked
    /// subject movement does not make old background detections fresh again.
    func compositionSubjects(at timestamp: TimeInterval) -> [SubjectCandidate] {
        guard timestamp >= lastDetection, timestamp-lastDetection <= 1.5 else { return [] }
        return candidates.map(\.candidate).filter { $0.score(configuration:selector.configuration) != nil }
    }
    func compositionFrames(at timestamp: TimeInterval) -> [CGRect] {
        guard timestamp >= lastDetection, timestamp-lastDetection <= 1.5 else { return [] }
        return enclosingRectangles
    }
    private var petDetection: Bool { features.petDetection }
    private var trackingEnabled: Bool { features.subjectTracking }

    func configure(pets: Bool, tracking: Bool, smartSelection: Bool) {
        features = SubjectAnalysisFeatures(petDetection: pets, subjectTracking: tracking, smartSelection: smartSelection)
        reset()
    }

    func cancelInference(includeTracking: Bool = true) {
        requestLock.lock(); let requests = activeRequests; requestLock.unlock()
        requests.filter { includeTracking || !($0 is VNTrackObjectRequest) }.forEach { $0.cancel() }
    }
    func performRequests(_ requests: [VNRequest], canContinue: () -> Bool = { true }, work: () throws -> Void) throws {
        requests.forEach { $0.preferBackgroundProcessing = false }
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
        candidates = []; enclosingRectangles = []; selectedPoint = nil; selector.reset(); health.reset()
        lastDetection = -.infinity; lastScene = -.infinity; lastPrinted = -.infinity; scene = nil
        manual = false; label = "Auto subject"; isRecovering = false
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
                     visibleRegion: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), detailBuffer: CVPixelBuffer? = nil, trackingOnly: Bool = false, retainSelection: Bool = false, canContinue: () -> Bool = { true }) -> SubjectObservation? {
        isRecovering = false
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
            } else if retained == nil { isRecovering = true; return nil }
        }
        // During a lens ramp, only verify the chosen subject. No new acquisition
        // or semantic switching can silently redirect an automatic zoom.
        if trackingOnly { return retained.map { SubjectObservation($0) } }
        // Manual tap remains available when automatic selection is disabled.
        guard features.allowsAcquisition(manual: manual) else { return retained.map { SubjectObservation($0) } }
        let interval: TimeInterval = !trackingEnabled ? 0 : retained == nil ? 0.65 : 1.1
        guard timestamp - lastDetection >= interval, !manual || retained == nil else { return retained.map { SubjectObservation($0) } }
        lastDetection = timestamp
        let detected = detect(in: buffer, detailBuffer: detailBuffer ?? buffer, timestamp: timestamp, visibleRegion: visibleRegion, canContinue: canContinue)
        guard canContinue() else { return nil }
        candidates = detected
        if retainSelection, let retained { return SubjectObservation(retained) }
        if let index = selector.select(detected.map(\.candidate), timestamp: timestamp,
                                       current: retained == nil ? nil : trackedCandidate, manualPoint: manual ? selectedPoint : nil) {
            start(detected[index])
            // A saliency proposal may have no detector confidence. Verify it
            // with the tracker before displaying it or arming automatic zoom.
            if !trackingEnabled { return SubjectObservation(candidate: detected[index].candidate) }
            return detected[index].observation.confidence >= 0.4 ? SubjectObservation(detected[index].observation) : nil
        }
        if !trackingEnabled, let trackedCandidate,
           let verified = detected.first(where: { $0.candidate.continuesIdentity(trackedCandidate) }) {
            self.trackedCandidate = verified.candidate
            return SubjectObservation(candidate: verified.candidate)
        }
        if !trackingEnabled { self.trackedCandidate = nil; label = manual ? "Your subject" : "Auto subject" }
        return retained.map { SubjectObservation($0) }
    }

    private func detect(in buffer: CVPixelBuffer, detailBuffer: CVPixelBuffer, timestamp: TimeInterval, visibleRegion: CGRect, canContinue: () -> Bool) -> [Detection] {
        guard let evidence = SubjectImageEvidence.sample(buffer) else { return [] }
        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest(); people.upperBodyOnly = false
        let animals = VNRecognizeAnimalsRequest()
        let objectness = VNGenerateObjectnessBasedSaliencyImageRequest()
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 2; rectangles.minimumConfidence = 0.7
        rectangles.minimumSize = 0.12; rectangles.minimumAspectRatio = 0.2; rectangles.quadratureTolerance = 30
        func run(_ requests: [VNRequest]) -> Bool {
            do {
                try performRequests(requests, canContinue: canContinue) {
                    try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform(requests)
                }
                return canContinue()
            } catch { return false }
        }
        // An unsupported/failed request must not discard other detector stages.
        var semanticRequests: [VNRequest] = [faces, people]
        if petDetection { semanticRequests.append(animals) }
        if !run(semanticRequests), canContinue() {
            for request in semanticRequests where canContinue() { _ = run([request]) }
        }
        guard canContinue() else { return [] }
        if !run([objectness, attention, rectangles]), canContinue() {
            _ = run([objectness]); _ = run([attention]); _ = run([rectangles])
        }
        guard canContinue() else { return [] }
        enclosingRectangles = (rectangles.results ?? []).filter { $0.confidence >= 0.75 }.map(\.boundingBox)
        func prominence(_ bounds: CGRect) -> Double? {
            let values = [objectness.results?.first?.pixelBuffer, attention.results?.first?.pixelBuffer]
                .compactMap { SubjectSaliencyEvidence.prominence(bounds, buffer: $0) }
            return values.max()
        }
        var detections = [Detection]()
        func append(_ observation: VNDetectedObjectObservation, category: SubjectCategory, label: String, semanticConfidence: Double, localized: Bool = false) {
            guard valid(observation.boundingBox),
                  visibleRegion.contains(CGPoint(x: observation.boundingBox.midX, y: observation.boundingBox.midY)) else { return }
            let features = evidence.features(for: observation.boundingBox, saliencyProminence: prominence(observation.boundingBox))
            let support = localized ? max(Double(observation.confidence), features.prominence) : Double(observation.confidence)
            let regionProminence = localized ? max(features.prominence, Double(observation.confidence) * 0.7) : features.prominence
            guard support >= 0.5 else { return }
            let candidate = SubjectCandidate(bounds: observation.boundingBox, confidence: support, category: category,
                label: label, classificationConfidence: semanticConfidence, prominence: regionProminence, isolation: features.isolation,
                detail: features.detail, textureDensity: features.texture, localizedProposal: localized, visibleRegion: visibleRegion)
            detections.append(Detection(observation: observation, candidate: candidate))
        }
        for person in people.results ?? [] { append(person, category: .person, label: "Person", semanticConfidence: Double(person.confidence)) }
        for face in faces.results ?? [] { append(face, category: .face, label: "Person", semanticConfidence: Double(face.confidence)) }
        for animal in petDetection ? animals.results ?? [] : [] {
            guard let recognized = animal.labels.first, recognized.confidence >= 0.55 else { continue }
            append(animal, category: .pet, label: recognized.identifier.capitalized, semanticConfidence: Double(recognized.confidence))
        }
        // People do not bypass the object path. Attention and objectness provide
        // complementary real boundaries for furniture, plants and products.
        var proposals: [VNDetectedObjectObservation] = []
        proposals += (objectness.results?.first?.salientObjects ?? []).map { $0 as VNDetectedObjectObservation }
        proposals += (attention.results?.first?.salientObjects ?? []).map { $0 as VNDetectedObjectObservation }
        proposals += (rectangles.results ?? []).map { $0 as VNDetectedObjectObservation }
        let ranked = proposals.filter {
            valid($0.boundingBox) && visibleRegion.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY))
        }.sorted { left, right in
            func rank(_ box: CGRect) -> Double {
                let features = evidence.features(for: box, saliencyProminence: prominence(box))
                let center = max(0, 1 - hypot(Double(box.midX - visibleRegion.midX), Double(box.midY - visibleRegion.midY)))
                return features.prominence + features.isolation * 0.3 + center * 0.3
            }
            return rank(left.boundingBox) > rank(right.boundingBox)
        }
        var objects = [VNDetectedObjectObservation]()
        for proposal in ranked {
            let duplicate = objects.contains { existing in
                let overlap = existing.boundingBox.intersection(proposal.boundingBox)
                let union = existing.boundingBox.width * existing.boundingBox.height + proposal.boundingBox.width * proposal.boundingBox.height - overlap.width * overlap.height
                return !overlap.isNull && union > 0 && overlap.width * overlap.height / union > 0.7
            }
            if !duplicate { objects.append(proposal) }
        }
        let full = CIImage(cvPixelBuffer: detailBuffer)
        let eligible = objects.filter { object in
            !detections.contains {
                let candidate = $0.candidate, overlap = candidate.bounds.intersection(object.boundingBox)
                let area = object.boundingBox.width * object.boundingBox.height
                return candidate.category.semantic && !overlap.isNull && area > 0 && overlap.width * overlap.height / area > 0.6
            }
        }
        // The crop budget begins after proposal detection, so a slower device
        // always gets a chance to classify its first actual object boundary.
        let deadline = ProcessInfo.processInfo.systemUptime + 1.3
        for object in eligible.prefix(2) {
            guard canContinue() else { return [] }
            if ProcessInfo.processInfo.systemUptime > deadline { break }
            let native = object.boundingBox.insetBy(dx: -0.025, dy: -0.025).intersection(visibleRegion)
            let rect = CGRect(x: native.minX * full.extent.width, y: native.minY * full.extent.height,
                              width: native.width * full.extent.width, height: native.height * full.extent.height).integral.intersection(full.extent)
            guard rect.width > 8, rect.height > 8 else { continue }
            let crop = full.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            let request = VNClassifyImageRequest()
            guard (try? performRequests([request], canContinue: canContinue) {
                try VNImageRequestHandler(ciImage: crop, orientation: .up).perform([request])
            }) != nil,
                let identity = SubjectIdentity.recognized((request.results ?? []).prefix(12).map { ($0.identifier, Double($0.confidence)) }, localized: true) else { continue }
            let category = SubjectCategory.classified(identity.name)
            guard !category.semantic else { continue }
            append(object, category: category, label: identity.name, semanticConfidence: identity.confidence, localized: true)
        }
        let hasObject = detections.contains { !$0.candidate.category.semantic && $0.candidate.score(configuration: selector.configuration) != nil }
        let printedInterval: TimeInterval = tracking == nil ? 1.5 : 4
        if canContinue(), !hasObject, timestamp - lastPrinted >= printedInterval {
            lastPrinted = timestamp
            detections += printedDetections(in: detailBuffer, proposals: eligible, evidence: evidence, visibleRegion: visibleRegion, canContinue: canContinue)
        }
        if canContinue(), timestamp - lastScene >= (retainedSceneNeeded(detections) ? 3 : 6), ProcessInfo.processInfo.systemUptime <= deadline {
            lastScene = timestamp
            let request = VNClassifyImageRequest()
            if (try? performRequests([request], canContinue: canContinue) { try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request]) }) != nil,
               let result = request.results?.first, result.confidence >= 0.65 {
                scene = SubjectScene(label: result.identifier, confidence: result.confidence, timestamp: timestamp)
            } else { scene = nil }
        }
        // Composition merit is category-neutral. Real named objects can win
        // through isolation/detail/usable framing, even when a person exists.
        for index in detections.indices {
            let c = detections[index].candidate
            let size = min(1,c.visibleArea/0.08)*max(0,min(1,(0.85-c.visibleArea)/0.25))
            detections[index].candidate.compositionPotential = c.isolation*0.4+min(1,c.detail/0.08)*0.2+size*0.25+c.centerPreference*0.15
        }
        return canContinue() ? detections : []
    }
    private func printedDetections(in buffer: CVPixelBuffer, proposals: [VNDetectedObjectObservation], evidence: SubjectImageEvidence,
                                   visibleRegion: CGRect, canContinue: () -> Bool) -> [Detection] {
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 4; rectangles.minimumConfidence = 0.6
        rectangles.minimumSize = 0.08; rectangles.minimumAspectRatio = 0.15; rectangles.quadratureTolerance = 30
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast; text.usesLanguageCorrection = false
        text.automaticallyDetectsLanguage = true; text.minimumTextHeight = 0.015
        do {
            try performRequests([rectangles, text], canContinue: canContinue) {
                try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([rectangles, text])
            }
            guard canContinue() else { return [] }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.7
            let lines: [PrintedTextLine] = (text.results ?? []).compactMap { observation in
                guard let top = observation.topCandidates(1).first else { return nil }
                return PrintedTextLine(text: top.string, confidence: Double(top.confidence), bounds: observation.boundingBox)
            }
            let full = CIImage(cvPixelBuffer: buffer)
            var detections = [Detection]()
            var shapes: [VNDetectedObjectObservation] = (rectangles.results ?? []).prefix(2).map { $0 }
            for proposal in proposals.prefix(3) {
                if !shapes.contains(where: { shape in
                    let overlap = shape.boundingBox.intersection(proposal.boundingBox)
                    return !overlap.isNull && overlap.width * overlap.height > proposal.boundingBox.width * proposal.boundingBox.height * 0.7
                }) { shapes.append(proposal) }
            }
            for rectangle in shapes.prefix(2) {
                let box = rectangle.boundingBox
                guard valid(box), visibleRegion.contains(CGPoint(x: box.midX, y: box.midY)), canContinue() else { continue }
                let printed = PrintedSubjectEvidence.identify(lines, inside: box)
                if !(rectangle is VNRectangleObservation) && printed == nil { continue }
                var name = printed?.name, confidence = printed?.confidence ?? 0
                // A useful geometric candidate need not have drawn saliency.
                // Read its real high-resolution crop before giving up on it.
                if (printed == nil || (printed?.confidence ?? 0) < 0.65) && ProcessInfo.processInfo.systemUptime <= deadline {
                    let roi = box.intersection(visibleRegion)
                    let rect = CGRect(x: roi.minX * full.extent.width, y: roi.minY * full.extent.height,
                                      width: roi.width * full.extent.width, height: roi.height * full.extent.height).integral.intersection(full.extent)
                    if rect.width > 12, rect.height > 12 {
                        let crop = full.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                        let request = VNClassifyImageRequest()
                        if (try? performRequests([request], canContinue: canContinue) { try VNImageRequestHandler(ciImage: crop, orientation: .up).perform([request]) }) != nil,
                           let identity = SubjectIdentity.recognized((request.results ?? []).prefix(12).map { ($0.identifier, Double($0.confidence)) }, localized: true),
                           !SubjectCategory.classified(identity.name).semantic {
                            name = identity.name; confidence = identity.confidence
                        }
                    }
                }
                guard canContinue(), let name else { continue }
                let features = evidence.features(for: box, saliencyProminence: nil)
                // Detector confidence is contour/saliency evidence, not an
                // assertion that the product is isolated from its background.
                let prominence = max(features.prominence, Double(rectangle.confidence) * 0.7)
                let candidate = SubjectCandidate(bounds: box, confidence: Double(rectangle.confidence), category: SubjectCategory.classified(name),
                    label: name, classificationConfidence: confidence, textConfidence: printed?.confidence ?? 0,
                    prominence: prominence, isolation: features.isolation, detail: features.detail,
                    textureDensity: features.texture, localizedProposal: true, visibleRegion: visibleRegion)
                detections.append(Detection(observation: rectangle, candidate: candidate))
            }
            return detections
        } catch { return [] }
    }
    private func retainedSceneNeeded(_ detections: [Detection]) -> Bool {
        !detections.contains { $0.candidate.score(configuration: selector.configuration) != nil }
    }
    private func start(_ detection: Detection) {
        sequence = VNSequenceRequestHandler(); health.reset()
        let seed = VNDetectedObjectObservation(boundingBox: detection.observation.boundingBox)
        let request = VNTrackObjectRequest(detectedObjectObservation: seed)
        request.trackingLevel = .accurate; tracking = trackingEnabled ? request : nil
        trackedCandidate = detection.candidate; label = detection.candidate.label
    }
    func reseed(bounds: CGRect, label: String, manual: Bool) {
        candidates = []; enclosingRectangles = []; lastDetection = -.infinity
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
