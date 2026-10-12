import Foundation
import CoreVideo
import CoreImage
import ImageIO

struct PhotoMeasurements: Codable, Equatable {
    let brightness: Double
    let shadowFraction: Double
    let highlightFraction: Double
    let detail: Double
    let backgroundEdges: Double?
    /// Technical ranking only: exposure clipping and local contrast, not aesthetics or true optical sharpness.
    var technicalScore: Double { 100 * (0.6 * max(0, 1 - shadowFraction - highlightFraction) + 0.4 * min(1, detail / 0.12)) }
    var lightingAdvice: String? {
        if brightness < 0.18 || shadowFraction > 0.65 { return "Low light: add light and hold steady. Avoid heavy zoom." }
        if highlightFraction > 0.12 { return "Bright areas are clipping. Lower exposure to protect highlights." }
        if shadowFraction > 0.4 { return "Deep shadows: try softer light or raise exposure slightly." }
        return nil
    }
    var clutterAdvice: String? {
        if let backgroundEdges, backgroundEdges > 0.23 { return "Busy background: change your angle or move closer to separate the subject." }
        return nil
    }

    static func from(luma: [Double], width: Int, height: Int, subject: CGRect? = nil) -> Self? {
        guard width > 1, height > 1, luma.count == width * height, luma.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        var detail = 0.0, pairs = 0, edges = 0, background = 0
        for y in 0..<height {
            for x in 0..<width {
                let value = luma[y * width + x]
                if x > 0 { detail += abs(value - luma[y * width + x - 1]); pairs += 1 }
                if y > 0 { detail += abs(value - luma[(y - 1) * width + x]); pairs += 1 }
                let point = CGPoint(x: Double(x) / Double(width), y: Double(y) / Double(height))
                if let subject, !subject.contains(point), x > 0, y > 0 {
                    background += 1
                    if max(abs(value - luma[y * width + x - 1]), abs(value - luma[(y - 1) * width + x])) > 0.15 { edges += 1 }
                }
            }
        }
        return Self(brightness: luma.reduce(0,+) / Double(luma.count),
                    shadowFraction: Double(luma.filter { $0 < 0.04 }.count) / Double(luma.count),
                    highlightFraction: Double(luma.filter { $0 > 0.96 }.count) / Double(luma.count),
                    detail: detail / Double(max(1,pairs)), backgroundEdges: background > 0 ? Double(edges) / Double(background) : nil)
    }

    static func from(buffer: CVPixelBuffer, subject: CGRect? = nil) -> Self? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        let sampledWidth = 64, sampledHeight = max(2, Int(Double(h) / Double(w) * 64))
        var values = [Double](); values.reserveCapacity(sampledWidth * sampledHeight)
        for y in 0..<sampledHeight {
            for x in 0..<sampledWidth {
                let i = min(h - 1, y * h / sampledHeight) * stride + min(w - 1, x * w / sampledWidth) * 4
                let brightness = (0.2126 * Double(base[i+2]) + 0.7152 * Double(base[i+1]) + 0.0722 * Double(base[i])) / 255
                values.append(max(0,min(1,brightness)))
            }
        }
        return from(luma: values, width: sampledWidth, height: sampledHeight, subject: subject)
    }

    static func from(data: Data) -> Self? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 128] as CFDictionary) else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, cg.width, cg.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CIContext(options: [.cacheIntermediates: false]).render(CIImage(cgImage: cg), to: buffer)
        return from(buffer: buffer)
    }
}

struct SmartShutterGate {
    private(set) var armed = true
    private var notBefore: TimeInterval = 0
    mutating func reset(timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) { armed = true; notBefore = timestamp+0.8 }
    mutating func consume() { armed = false }
    mutating func shouldCapture(enabled: Bool, ready: Bool, active: Bool, busy: Bool, zooming: Bool, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard timestamp >= notBefore, enabled, armed, ready, active, !busy, !zooming else { return false }
        armed = false
        return true
    }
}
