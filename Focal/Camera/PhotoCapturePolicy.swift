import Foundation

enum RAWPhotoKind: Equatable { case bayer, appleProRAW }

/// Pixel identifiers are supplied by AVCapturePhotoOutput, never inferred from
/// the iPhone model or the selected zoom stop.
struct RAWPhotoFormat: Equatable {
    let pixelFormat: UInt32
    let kind: RAWPhotoKind
}

struct PhotoCaptureCapabilities: Equatable {
    var rawFormats: [RAWPhotoFormat] = []
    var encodings: [PhotoEncoding] = [.jpeg]
    var preferredRAW: RAWPhotoFormat? {
        rawFormats.first { $0.kind == .appleProRAW } ?? rawFormats.first { $0.kind == .bayer }
    }
    var supportsRAW: Bool { preferredRAW != nil }
    var supportsProRAW: Bool { rawFormats.contains { $0.kind == .appleProRAW } }

    /// Preview optimization must not remove a still-photo capability that was
    /// actually advertised by the committed .photo configuration.
    func preservesRAW(of photoConfiguration: Self) -> Bool {
        (!photoConfiguration.supportsRAW || supportsRAW)
            && (!photoConfiguration.supportsProRAW || supportsProRAW)
    }
    func selection(rawRequested: Bool, encoding: PhotoEncoding) throws -> PhotoCaptureSelection {
        let raw = rawRequested ? preferredRAW : nil
        guard !rawRequested || raw != nil else { throw PhotoCaptureError.rawUnavailable }
        let processed = raw?.kind == .bayer || !encodings.contains(encoding) ? PhotoEncoding.jpeg : encoding
        return .init(raw:raw,encoding:processed)
    }
}

struct PhotoCaptureSelection: Equatable {
    let raw: RAWPhotoFormat?
    let encoding: PhotoEncoding
    var isBayerRAW: Bool { raw?.kind == .bayer }
    func validateDelivery(rawData: Data?) throws {
        if raw != nil && (rawData?.isEmpty ?? true) { throw PhotoCaptureError.missingRAW }
    }
}

enum PhotoCaptureError: LocalizedError, Equatable {
    case rawUnavailable, missingRAW
    var errorDescription: String? {
        switch self {
        case .rawUnavailable: return "RAW is unavailable on the current camera. Choose a supported rear lens or turn RAW off, then try again."
        case .missingRAW: return "The camera did not return the requested DNG. The RAW capture was not saved. Please try again."
        }
    }
}
