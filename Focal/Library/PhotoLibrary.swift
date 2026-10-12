import Foundation
import Combine
import UIKit
import ImageIO
import Photos

struct SavedPhoto: Identifiable, Codable, Equatable {
    let id: UUID
    let filename: String
    let createdAt: Date
    let mode: String
    let isDemo: Bool
    var isFavorite: Bool
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil

    var resolutionLabel: String? {
        guard let width = pixelWidth, let height = pixelHeight else { return nil }
        return "\(width) × \(height) · \(String(format: "%.1f", Double(width) * Double(height) / 1_000_000)) MP"
    }
}

@MainActor
final class PhotoLibrary: ObservableObject {
    @Published private(set) var photos: [SavedPhoto] = []
    @Published var errorMessage: String?
    private let directory: URL
    private var manifest: URL { directory.appendingPathComponent("library.json") }
    private var canWrite = true

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Focal", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifest.path) {
                photos = try JSONDecoder().decode([SavedPhoto].self, from: Data(contentsOf: manifest))
            }
        } catch {
            canWrite = false
            errorMessage = "Your library could not be opened. Existing files are preserved. \(error.localizedDescription)"
        }
    }

    func url(for photo: SavedPhoto) -> URL { directory.appendingPathComponent(photo.filename) }

    @discardableResult
    func add(data: Data, mode: String, isDemo: Bool = false) async throws -> SavedPhoto {
        guard canWrite else { throw LibraryError.unavailable }
        var photo = SavedPhoto(id: UUID(), filename: UUID().uuidString + ".jpg", createdAt: Date(),
                               mode: mode, isDemo: isDemo, isFavorite: false)
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
        try await Task.detached(priority: .userInitiated) {
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        }.value
        do {
            let next = [photo] + photos
            try persist(next)
            photos = next
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return photo
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
        try FileManager.default.removeItem(at: url(for: photo))
    }

    func saveToPhotos(_ photo: SavedPhoto) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw LibraryError.photosDenied }
        let file = url(for: photo)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
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
