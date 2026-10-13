#if DEBUG || FOCAL_EVALUATION
import Foundation
import Combine
import UIKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@MainActor final class EvaluationStore: ObservableObject {
    @Published private(set) var samples = [EvaluationSample]()
    @Published var report: EvaluationReport?
    @Published var message: String?
    @Published var running = false
    let directory: URL
    private var job: Task<Void,Never>?
    init() {
        directory = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("IntelligenceEvaluation",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let manifest = directory.appendingPathComponent("dataset.json")
            if FileManager.default.fileExists(atPath:manifest.path) {
                let dataset = try JSONDecoder().decode(EvaluationDataset.self,from:Data(contentsOf:manifest))
                guard dataset.schemaVersion == 1, dataset.samples.count <= 100, dataset.samples.allSatisfy(Self.validSample) else { throw EvaluationError.invalidDataset }
                samples = dataset.samples; report = dataset.report
            }
        } catch { message = error.localizedDescription }
    }
    nonisolated static func validSample(_ sample:EvaluationSample) -> Bool {
        sample.imageFile == sample.id.uuidString+".jpg" && sample.imageSHA256.count == 64
            && (sample.annotation.expectedBounds?.valid ?? true) && (sample.annotation.manualSelection?.valid ?? true)
            && (sample.annotation.sequenceTime.map { $0.isFinite && $0 >= 0 } ?? true)
    }
    func addImage(_ data:Data,provenance:String = "User photo import") async throws {
        guard samples.count < 100, data.count <= 32*1024*1024 else { throw EvaluationError.limit }
        let normalized = try await Task.detached(priority:.utility) { try Self.normalize(data) }.value
        try Task.checkCancellation()
        let id = UUID(), file = id.uuidString+".jpg"
        try normalized.write(to:directory.appendingPathComponent(file),options:.atomic)
        samples.append(.init(id:id,imageFile:file,imageSHA256:Self.digest(normalized),provenance:provenance))
        report = nil; try persist()
    }
    func save(_ annotation:EvaluationAnnotation,for id:UUID) throws {
        guard let index = samples.firstIndex(where:{ $0.id == id }) else { return }
        var sample = samples[index]; sample.annotation = annotation
        guard Self.validSample(sample) else { throw EvaluationError.invalidDataset }
        samples[index] = sample; report = nil; try persist()
    }
    func delete(_ id:UUID) throws {
        guard let sample = samples.first(where:{ $0.id == id }) else { return }
        try FileManager.default.removeItem(at:directory.appendingPathComponent(sample.imageFile))
        samples.removeAll { $0.id == id }; report = nil; try persist()
    }
    func seedLandscape() async throws {
        guard !samples.contains(where:{ $0.provenance.hasPrefix("Bundled Unsplash") }), let image = UIImage(named:"DemoScene"),let data = image.jpegData(compressionQuality:0.9) else { return }
        try await addImage(data,provenance:"Bundled Unsplash photograph photo-1476514525535-07fb3b4ae5f1; landscape label visually reviewed. One photo, not an independent benchmark corpus.")
        if let id = samples.last?.id {
            var annotation = EvaluationAnnotation()
            annotation.intent = .landscape; annotation.expectsNoObject = true; annotation.acceptableComposition = true; annotation.preferredAction = GuidanceAction.none
            annotation.framingIssue = "None"; annotation.reviewed = false
            annotation.notes = "Starter reference: whole-scene landscape with lake, mountains and foreground boat. Do not invent a mandatory object box or pan. Confirm these labels before evaluation."
            try save(annotation,for:id)
        }
    }
    func evaluate() {
        guard !running else { return }
        running = true; message = nil
        let input = samples, location = directory
        job = Task {
            defer { running = false; job = nil }
            do {
                let result = try await EvaluationRunner.shared.run(samples:input,directory:location)
                guard !Task.isCancelled else { return }
                report = result; try persist()
            } catch is CancellationError { message = "Evaluation cancelled; images and labels retained." }
            catch { message = error.localizedDescription }
        }
    }
    func cancel() { job?.cancel() }
    func export() async throws -> URL {
        let input = samples, results = report, location = directory
        return try await Task.detached(priority:.utility) {
            var copies = input, total = 0
            for index in copies.indices {
                let data = try Data(contentsOf:location.appendingPathComponent(copies[index].imageFile))
                total += data.count
                guard total <= 24*1024*1024 else { throw EvaluationError.limit }
                copies[index].imageData = data
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            let data = try encoder.encode(EvaluationDataset(samples:copies,report:results))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Focal-intelligence-evaluation.json")
            try data.write(to:url,options:.atomic)
            return url
        }.value
    }
    func importDataset(_ url:URL) async throws {
        let imported = try await Task.detached(priority:.utility) {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size <= 32*1024*1024 else { throw EvaluationError.limit }
            let dataset = try JSONDecoder().decode(EvaluationDataset.self,from:Data(contentsOf:url))
            guard dataset.schemaVersion == 1, dataset.samples.count <= 100,Set(dataset.samples.map(\.id)).count == dataset.samples.count,
                  dataset.samples.allSatisfy(Self.validSample) else { throw EvaluationError.invalidDataset }
            for sample in dataset.samples {
                guard let data = sample.imageData, data.count <= 2*1024*1024, Self.digest(data) == sample.imageSHA256,
                      CGImageSourceCreateWithData(data as CFData,nil) != nil else { throw EvaluationError.invalidDataset }
            }
            return dataset
        }.value
        guard !running else { throw EvaluationError.busy }
        for sample in imported.samples { try sample.imageData!.write(to:location.appendingPathComponent(sample.imageFile),options:.atomic) }
        samples = imported.samples.map { sample in var copy = sample; copy.imageData = nil; return copy }
        report = imported.report; try persist()
    }
    private func persist() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(EvaluationDataset(samples:samples,report:report)).write(to:directory.appendingPathComponent("dataset.json"),options:.atomic)
    }
    nonisolated private static func digest(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    nonisolated private static func normalize(_ data:Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil), let image = CGImageSourceCreateThumbnailAtIndex(source,0,
            [kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:1024] as CFDictionary) else { throw EvaluationError.invalidDataset }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output,UTType.jpeg.identifier as CFString,1,nil) else { throw EvaluationError.invalidDataset }
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 2*1024*1024 else { throw EvaluationError.invalidDataset }
        return output as Data
    }
}

enum EvaluationError: LocalizedError {
    case invalidDataset, limit, busy
        var errorDescription:String? {
            switch self {
            case .invalidDataset: return "The image or evaluation JSON is invalid. Check schema version, image hashes and normalized boxes."
            case .limit: return "Use up to 100 images. Imports/exports are bounded to keep local evaluation manageable."
            case .busy: return "Stop evaluation before replacing the dataset."
            }
        }
    }
#endif
