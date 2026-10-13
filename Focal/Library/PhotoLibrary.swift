import Foundation
import Combine
import UIKit
import ImageIO
import Photos

struct SavedPhoto: Identifiable, Codable, Equatable {
    let id: UUID
    var filename: String
    let createdAt: Date
    let mode: String
    let isDemo: Bool
    var isFavorite: Bool
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var rawFilename: String? = nil
    var originalFilename: String? = nil
    var scanFilename: String? = nil
    var aspect: String? = nil
    var subject: String? = nil
    var collection: String? = nil
    var challenge: String? = nil
    var burstID: UUID? = nil
    var measurements: PhotoMeasurements? = nil
    var cameraOrigin: String? = nil
    var photographyIntent: String? = nil
    var editingRecipe: EditRecipe? = nil
    var editingSourceFilename: String? = nil
    var developedFromRAW: Bool? = nil
    var canUsePhoneEditor: Bool { cameraOrigin == CameraSource.iPhone.rawValue || (isDemo && cameraOrigin != CameraSource.sony.rawValue) }

    var resolutionLabel: String? {
        guard let width = pixelWidth, let height = pixelHeight else { return nil }
        return "\(width) × \(height) · \(String(format: "%.1f", Double(width) * Double(height) / 1_000_000)) MP"
    }
}

@MainActor
final class PhotoLibrary: ObservableObject {
    @Published private(set) var photos: [SavedPhoto] = []
    @Published var errorMessage: String?
    @Published private(set) var collections: [String] = []
    private let directory: URL
    private var manifest: URL { directory.appendingPathComponent("library.json") }
    private var canWrite = true

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focal", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let collectionFile = self.directory.appendingPathComponent("collections.json")
            if let bytes = try? Data(contentsOf: collectionFile), let stored = try? JSONDecoder().decode([String].self,from: bytes) { collections = stored }
            if FileManager.default.fileExists(atPath: manifest.path) {
                photos = try JSONDecoder().decode([SavedPhoto].self, from: Data(contentsOf: manifest))
                for index in photos.indices where photos[index].cameraOrigin == nil {
                    let file = self.directory.appendingPathComponent(photos[index].filename)
                    guard let image = CGImageSourceCreateWithURL(file as CFURL, nil),
                          let values = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                          let tiff = values[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
                          let model = tiff[kCGImagePropertyTIFFModel] as? String else { continue }
                    if model.lowercased().contains("iphone") { photos[index].cameraOrigin = CameraSource.iPhone.rawValue }
                    else if (tiff[kCGImagePropertyTIFFMake] as? String)?.lowercased().contains("sony") == true { photos[index].cameraOrigin = CameraSource.sony.rawValue }
                }
                collections = Array(Set(collections + photos.compactMap(\.collection))).sorted()
            }
        } catch {
            canWrite = false
            errorMessage = "Your library could not be opened. Existing files are preserved. \(error.localizedDescription)"
        }
    }

    func url(for photo: SavedPhoto) -> URL { directory.appendingPathComponent(photo.filename) }
    func rawURL(for photo: SavedPhoto) -> URL? { photo.rawFilename.map { directory.appendingPathComponent($0) } }
    func originalURL(for photo: SavedPhoto) -> URL? { photo.originalFilename.map { directory.appendingPathComponent($0) } }
    func scanURL(for photo: SavedPhoto) -> URL? { photo.scanFilename.map { directory.appendingPathComponent($0) } }
    func editingSourceURL(for photo: SavedPhoto) -> URL? { photo.editingSourceFilename.map { directory.appendingPathComponent($0) } }

    var storageBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,includingPropertiesForKeys: nil)) ?? []
        return files.reduce(0) { total,file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    @discardableResult
    func add(data: Data, mode: String, isDemo: Bool = false, rawData: Data? = nil,
             originalData: Data? = nil, scanData: Data? = nil, aspect: String? = nil, subject: String? = nil,
             challenge: String? = nil, burstID: UUID? = nil, cameraOrigin: String? = nil, editingRecipe: EditRecipe? = nil, developedFromRAW: Bool? = nil, photographyIntent:String? = nil) async throws -> SavedPhoto {
        guard canWrite else { throw LibraryError.unavailable }
        var photo = SavedPhoto(id: UUID(), filename: UUID().uuidString + "." + Self.fileExtension(data), createdAt: Date(),
                               mode: mode, isDemo: isDemo, isFavorite: false)
        photo.aspect = aspect
        photo.subject = subject
        photo.challenge = challenge
        photo.burstID = burstID
        photo.cameraOrigin = cameraOrigin
        photo.photographyIntent = photographyIntent
        photo.editingRecipe = editingRecipe
        photo.developedFromRAW = developedFromRAW
        photo.measurements = await Task.detached { PhotoMeasurements.from(data: data) }.value
        if rawData != nil { photo.rawFilename = UUID().uuidString + ".dng" }
        if let originalData { photo.originalFilename = UUID().uuidString + "." + Self.fileExtension(originalData) }
        if scanData != nil { photo.scanFilename = UUID().uuidString + ".jpg" }
        // Read the file header only, without decoding/re-encoding the full-resolution capture.
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = properties[kCGImagePropertyPixelWidth] as? Int
            let height = properties[kCGImagePropertyPixelHeight] as? Int
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            photo.pixelWidth = orientation >= 5 ? height : width
            photo.pixelHeight = orientation >= 5 ? width : height
        }
        let destination = url(for: photo)
        var files: [URL: Data] = [destination: data]
        if let rawData, let file = rawURL(for: photo) { files[file] = rawData }
        if let originalData, let file = originalURL(for: photo) { files[file] = originalData }
        if let scanData, let file = scanURL(for: photo) { files[file] = scanData }
        let capturedFiles = files
        do {
            try await Task.detached(priority: .userInitiated) {
                for (file, bytes) in capturedFiles {
                    try bytes.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
                }
            }.value
            let next = [photo] + photos
            try persist(next)
            photos = next
        } catch {
            for file in capturedFiles.keys { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        return photo
    }

    static func fileExtension(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil), let type = CGImageSourceGetType(source) else { return "jpg" }
        return (type as String).lowercased().contains("hei") ? "heic" : "jpg"
    }

    /// Replace only the review derivative; keep camera JPEG, edit baseline and
    /// RAW under their existing names. Commit the manifest before removing files.
    func finishPhoneReview(_ photo: SavedPhoto, data: Data, recipe: EditRecipe, developedFromRAW: Bool) async throws -> SavedPhoto {
        guard canWrite, photo.canUsePhoneEditor, let index = photos.firstIndex(where: { $0.id == photo.id }) else { throw LibraryError.unavailable }
        guard photos[index].canUsePhoneEditor else { throw LibraryError.unavailable }
        if recipe.normalized == .original && !developedFromRAW && photos[index].editingRecipe == nil { return photos[index] }
        var nextPhoto = photos[index]
        let oldName = nextPhoto.filename
        if nextPhoto.editingSourceFilename == nil { nextPhoto.editingSourceFilename = oldName }
        if nextPhoto.originalFilename == nil { nextPhoto.originalFilename = oldName }
        nextPhoto.filename = UUID().uuidString + ".jpg"
        nextPhoto.editingRecipe = recipe.normalized; nextPhoto.developedFromRAW = developedFromRAW
        nextPhoto.aspect = recipe.crop?.rawValue ?? nextPhoto.aspect
        if let source = CGImageSourceCreateWithData(data as CFData, nil), let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            nextPhoto.pixelWidth = values[kCGImagePropertyPixelWidth] as? Int; nextPhoto.pixelHeight = values[kCGImagePropertyPixelHeight] as? Int
        }
        nextPhoto.measurements = await Task.detached { PhotoMeasurements.from(data: data) }.value
        let destination = url(for: nextPhoto)
        try await Task.detached { try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen]) }.value
        guard let currentIndex = photos.firstIndex(where: { $0.id == photo.id }), photos[currentIndex].filename == oldName else { try? FileManager.default.removeItem(at: destination); throw LibraryError.unavailable }
        var next = photos; next[currentIndex] = nextPhoto
        do { try persist(next); photos = next }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        let kept = [nextPhoto.filename, nextPhoto.originalFilename, nextPhoto.editingSourceFilename].compactMap { $0 }
        if !kept.contains(oldName) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(oldName)) }
        return nextPhoto
    }

    func createCollection(_ name: String) throws {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canWrite else { throw LibraryError.unavailable }
        guard !value.isEmpty, !collections.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        let next = (collections + [value]).sorted()
        try JSONEncoder().encode(next).write(to: directory.appendingPathComponent("collections.json"),options: [.atomic,.completeFileProtectionUnlessOpen])
        collections = next
    }
    func setCollection(_ name: String?, for photo: SavedPhoto) {
        guard name == nil || collections.contains(name!) else { return }
        var next = photos
        guard let index = next.firstIndex(where: { $0.id == photo.id }) else { return }
        next[index].collection = name
        do { try persist(next); photos = next } catch { errorMessage = error.localizedDescription }
    }
    func isBestInBurst(_ photo: SavedPhoto) -> Bool {
        guard let id = photo.burstID, photo.measurements != nil else { return false }
        let group = photos.filter { $0.burstID == id && $0.measurements != nil }
        return group.max { ($0.measurements?.technicalScore ?? 0) < ($1.measurements?.technicalScore ?? 0) }?.id == photo.id
    }

    func toggleFavorite(_ photo: SavedPhoto) {
        var next = photos
        guard let index = next.firstIndex(where: { $0.id == photo.id }) else { return }
        next[index].isFavorite.toggle()
        do { try persist(next); photos = next }
        catch { errorMessage = error.localizedDescription }
    }

    func delete(_ photo: SavedPhoto) throws {
        let next = photos.filter { $0.id != photo.id }
        try persist(next)
        photos = next
        // A failed file removal only leaves an unreferenced file, never a broken manifest.
        var failure: Error?
        for file in [url(for: photo), rawURL(for: photo), originalURL(for: photo), scanURL(for: photo), editingSourceURL(for: photo)].compactMap({ $0 }) {
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do { try FileManager.default.removeItem(at: file) } catch { failure = error }
        }
        if let failure { throw failure }
    }

    func saveToPhotos(_ photo: SavedPhoto, imageURL: URL? = nil) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw LibraryError.photosDenied }
        let file = imageURL ?? url(for: photo)
        let raw = file == scanURL(for: photo) ? nil : rawURL(for: photo)
        let separateRAW = file == url(for: photo) && photo.originalFilename != nil
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: file, options: nil)
            if let raw {
                if separateRAW {
                    // A cropped JPEG and full-sensor DNG have different framing. Export as
                    // separate assets rather than pretending they are an identical image pair.
                    let rawRequest = PHAssetCreationRequest.forAsset()
                    rawRequest.addResource(with: .photo, fileURL: raw, options: nil)
                } else { request.addResource(with: .alternatePhoto, fileURL: raw, options: nil) }
            }
        }
    }

    private func persist(_ items: [SavedPhoto]) throws {
        guard canWrite else { throw LibraryError.unavailable }
        try JSONEncoder().encode(items).write(to: manifest, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    enum LibraryError: LocalizedError {
        case unavailable, photosDenied
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The local library is unavailable. Restart Focal to try opening it again."
            case .photosDenied: return "Allow Focal to add photos in Settings → Privacy & Security → Photos, then try again."
            }
        }
    }
}

enum PhotoLoader {
    static func load(url: URL, maxPixels: Int) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        }.value
    }
}
