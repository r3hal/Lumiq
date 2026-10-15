import Foundation
import ImageIO
import SwiftUI
import UIKit

/// One worker and one replaceable waiting value. A slow decoder/UI never
/// creates a FIFO of old camera frames. Closing rejects later callbacks.
final class LatestFrameMailbox<Value> {
    private let lock = NSLock()
    private var pending: Value?
    private var scheduled = false
    private var closed = false
    func offer(_ value: Value) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        pending = value
        guard !scheduled else { return false }
        scheduled = true; return true
    }
    func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, let value = pending else { scheduled = false; return nil }
        pending = nil; return value
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true; pending = nil
    }
}

struct SonyDecodedFrame {
    let image: CGImage
    let receivedAt: TimeInterval
    var aspect: Double { Double(image.width) / Double(image.height) }
    static func decode(_ data: Data, receivedAt: TimeInterval) -> Self? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Int64(width) * Int64(height) <= 16_000_000 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let image: CGImage?
        if orientation == 1 {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else {
            // Transform EXIF orientation at the source resolution, never upscale.
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }
        guard let image, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return Self(image: image, receivedAt: receivedAt)
    }
}

/// Pixel delivery is deliberately not @Published: refreshing the entire
/// SwiftUI camera hierarchy for every remote JPEG makes the stream stutter.
@MainActor
final class SonyPreviewFeed {
    private let surfaces = NSHashTable<UIView>.weakObjects()
    private(set) var image: CGImage?
    func bind(_ surface: UIView) { surfaces.add(surface); display(image) }
    func display(_ image: CGImage?) {
        self.image = image
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for surface in surfaces.allObjects { surface.layer.contents = image }
        CATransaction.commit()
    }
}

struct SonyPreviewSurface: UIViewRepresentable {
    let feed: SonyPreviewFeed
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black; view.isUserInteractionEnabled = false
        view.layer.contentsGravity = .resizeAspectFill; view.layer.masksToBounds = true
        feed.bind(view); return view
    }
    func updateUIView(_ view: UIView, context: Context) { feed.bind(view) }
}

enum SonyLiveViewSize {
    /// Sony's version-1 response is [current, [available...]]. Keep the
    /// actual advertised spelling and never send an invented quality value.
    static func largest(in result: [Any]) -> String? {
        let available: [String]
        if result.count >= 2, let values = result[1] as? [String] { available = values }
        else if result.count == 1, let values = result[0] as? [String] { available = values }
        else { return nil }
        return ["L", "M", "S"].compactMap { preferred in
            available.first { $0.uppercased() == preferred }
        }.first
    }
}
