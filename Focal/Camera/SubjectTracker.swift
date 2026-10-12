import Vision
import CoreVideo
import Foundation

/// Select once, then track that region instead of choosing a different bright object each frame.
final class SubjectTracker {
    private var sequence = VNSequenceRequestHandler()
    private var tracking: VNTrackObjectRequest?
    private var candidates: [VNDetectedObjectObservation] = []
    private var lastDetection: TimeInterval = -.infinity
    private var lastClassification: TimeInterval = -.infinity
    private(set) var manual = false
    private(set) var label = "Auto subject"

    func reset() {
        sequence = VNSequenceRequestHandler()
        tracking = nil
        candidates = []
        lastDetection = -.infinity
        lastClassification = -.infinity
        manual = false
        label = "Auto subject"
    }

    func select(at imagePoint: UnitPoint2D) {
        let point = CGPoint(x: imagePoint.x, y: 1 - imagePoint.y)
        let nearby = candidates.filter { $0.boundingBox.insetBy(dx: -0.04, dy: -0.04).contains(point) }
        let selected = nearby.min {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }
        let rect = CGRect(x: max(0, min(0.82, point.x - 0.09)),
                          y: max(0, min(0.82, point.y - 0.09)), width: 0.18, height: 0.18)
        start(selected ?? VNDetectedObjectObservation(boundingBox: rect))
        manual = true
        label = "Your subject"
    }

    func observation(in buffer: CVPixelBuffer, timestamp: TimeInterval) -> VNDetectedObjectObservation? {
        if let tracking {
            do {
                try sequence.perform([tracking], on: buffer, orientation: .up)
                if let result = tracking.results?.first as? VNDetectedObjectObservation,
                   result.confidence >= 0.4, valid(result.boundingBox) {
                    tracking.inputObservation = result
                    candidates = [result]
                    classify(result, in: buffer, timestamp: timestamp)
                    return result
                }
            } catch { /* Lost tracking: reacquire rather than presenting a guessed position. */ }
            self.tracking = nil
            sequence = VNSequenceRequestHandler()
            manual = false
            label = "Auto subject"
        }
        guard timestamp - lastDetection >= 0.65 else { return nil }
        lastDetection = timestamp
        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let animals = VNRecognizeAnimalsRequest()
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([faces, animals, saliency])
            let faceCandidates: [VNDetectedObjectObservation] = (faces.results ?? []).filter {
                $0.confidence >= 0.5 && valid($0.boundingBox)
            }
            let objects: [VNDetectedObjectObservation] = (saliency.results?.first?.salientObjects ?? []).filter {
                valid($0.boundingBox)
            }
            let animalCandidates = (animals.results ?? []).filter {
                $0.confidence >= 0.5 && ($0.labels.first?.confidence ?? 0) >= 0.5 && valid($0.boundingBox)
            }
            candidates = faceCandidates + animalCandidates + objects
            // Semantic pet boxes avoid zooming into the surrounding bed or background.
            let choices: [VNDetectedObjectObservation] = !faceCandidates.isEmpty ? faceCandidates
                : !animalCandidates.isEmpty ? animalCandidates : objects
            guard let selected = choices.max(by: { score($0.boundingBox) < score($1.boundingBox) }) else { return nil }
            if !faceCandidates.isEmpty { label = "Person" }
            else if let animal = selected as? VNRecognizedObjectObservation, let name = animal.labels.first?.identifier {
                label = name.capitalized
            } else { label = "Auto subject" }
            start(selected)
            classify(selected, in: buffer, timestamp: timestamp)
            return selected
        } catch { return nil }
    }

    private func classify(_ observation: VNDetectedObjectObservation, in buffer: CVPixelBuffer, timestamp: TimeInterval) {
        guard !["Person", "Cat", "Dog"].contains(label), timestamp - lastClassification > 2 else { return }
        lastClassification = timestamp
        let request = VNClassifyImageRequest()
        request.regionOfInterest = observation.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
            if let result = request.results?.first, result.confidence >= 0.45 {
                let name = result.identifier.components(separatedBy: ",").first ?? result.identifier
                label = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces).capitalized
            }
        } catch { /* Keep the honest generic label when the classifier is uncertain. */ }
    }

    func reseed(bounds: CGRect, label: String, manual: Bool) {
        let clipped = bounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, clipped.width > 0.01, clipped.height > 0.01 else { reset(); return }
        start(VNDetectedObjectObservation(boundingBox: clipped))
        self.label = label
        self.manual = manual
        lastClassification = -.infinity
    }

    private func start(_ observation: VNDetectedObjectObservation) {
        sequence = VNSequenceRequestHandler()
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate
        tracking = request
    }

    private func valid(_ rect: CGRect) -> Bool {
        let area = rect.width * rect.height
        return area > 0.002 && area < 0.72 && rect.midX >= 0 && rect.midX <= 1 && rect.midY >= 0 && rect.midY <= 1
    }

    private func score(_ rect: CGRect) -> Double {
        let area = Double(rect.width * rect.height)
        let centerDistance = hypot(Double(rect.midX) - 0.5, Double(rect.midY) - 0.5)
        return sqrt(area) * (1 - area) * (1 - centerDistance * 0.35)
    }
}
