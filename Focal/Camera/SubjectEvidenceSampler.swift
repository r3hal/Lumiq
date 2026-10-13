import Foundation
import CoreVideo

extension SubjectImageEvidence {
    static func sample(_ buffer: CVPixelBuffer) -> Self? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard w > 0, h > 0 else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer), width = 64
        let height = max(16, min(96, Int(Double(h) / Double(w) * Double(width))))
        var pixels = [Pixel](); pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = min(h - 1, y * h / height) * stride + min(w - 1, x * w / width) * 4
                pixels.append(Pixel(red: Double(base[offset + 2]) / 255, green: Double(base[offset + 1]) / 255, blue: Double(base[offset]) / 255))
            }
        }
        return Self(pixels: pixels, width: width, height: height)
    }
}

enum SubjectSaliencyEvidence {
    static func prominence(_ rect: CGRect, buffer: CVPixelBuffer?) -> Double? {
        guard let buffer, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: Float.self) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard w > 0, h > 0 else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.stride
        var total = 0.0, inside = 0.0, count = 0.0, selectedCount = 0.0
        for y in 0..<32 {
            for x in 0..<32 {
                let value = Double(base[min(h - 1, y * h / 32) * stride + min(w - 1, x * w / 32)])
                guard value.isFinite, value >= 0 else { continue }
                total += value; count += 1
                if rect.contains(CGPoint(x: Double(x) / 32, y: 1 - Double(y) / 32)) { inside += value; selectedCount += 1 }
            }
        }
        guard total > 0.0001, count > 0, selectedCount > 0 else { return nil }
        let relative = (inside / selectedCount) / (total / count)
        return max(0, min(1, (relative - 1) / 3))
    }
}
