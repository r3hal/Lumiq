import Foundation
import CoreGraphics
import CoreVideo

struct PrecisionOptions: Equatable {
    var histogram = false
    var highlights = false
    var peaking = false
    var autoTune = false
    var enabled: Bool { histogram || highlights || peaking || autoTune }
}
struct PrecisionContext {
    var generation = 0
    var source: CameraSource = .iPhone
    var options = PrecisionOptions()
    var previewAspect = 0.75
    var mirrored = false
    var paused = false
    var controls = CameraControlSnapshot()
    var ev: Double?
    var evRange: ClosedRange<Double>?
    var zoom = 1.0
    var minimumZoom = 1.0
    var relativeSubjectMotion: Double?
    var subjectMotionTimestamp: TimeInterval?
}
struct PrecisionReading {
    var histogram: [Int]
    var measurements: PhotoMeasurements
    var zebra: CGImage?
    var peaking: CGImage?
    var timestamp: TimeInterval
    var sampleWidth: Int
    var sampleHeight: Int
}

enum PrecisionAnalyzer {
    static func histogram(_ luma:[Double],bins:Int = 64) -> [Int]? {
        guard bins >= 2, bins <= 256, !luma.isEmpty, luma.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        var result = [Int](repeating:0,count:bins)
        for value in luma { result[min(bins-1,Int(value*Double(bins)))] += 1 }
        return result
    }
    static func masks(_ luma:[Double],width:Int,height:Int,highlights:Bool,peaking:Bool) -> (zebra:[UInt8]?,edges:[UInt8]?) {
        guard width > 2, height > 2, luma.count == width*height, luma.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return (nil,nil) }
        var zebra = highlights ? [UInt8](repeating:0,count:width*height*4) : nil
        var edges = peaking ? [UInt8](repeating:0,count:width*height*4) : nil
        for y in 1..<height-1 {
            for x in 1..<width-1 {
                let p = y*width+x, value = luma[p], i = p*4
                if highlights && value >= 0.98 && (x+y)%12 < 6 {
                    // Premultiplied amber RGBA, alpha 180.
                    zebra?[i] = 167; zebra?[i+1] = 143; zebra?[i+2] = 73; zebra?[i+3] = 180
                }
                let dx = abs(luma[p+1]-luma[p-1]), dy = abs(luma[p+width]-luma[p-width])
                if peaking && max(dx,dy) > 0.16 && value > 0.04 && value < 0.96 {
                    edges?[i] = 72; edges?[i+1] = 185; edges?[i+2] = 145; edges?[i+3] = 220
                }
            }
        }
        return (zebra,edges)
    }
    static func analyze(_ buffer:CVPixelBuffer,projection:PreviewProjection,options:PrecisionOptions,timestamp:TimeInterval) -> PrecisionReading? {
        guard options.enabled, projection.imageAspect.isFinite, projection.imageAspect > 0, projection.previewAspect.isFinite, (0.1...10).contains(projection.previewAspect), timestamp.isFinite,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to:UInt8.self) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(buffer), sourceHeight = CVPixelBufferGetHeight(buffer), rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let width = max(16,min(256,Int(320*projection.previewAspect))), height = max(16,min(320,Int(Double(width)/projection.previewAspect)))
        var luma = [Double](); luma.reserveCapacity(width*height)
        for y in 0..<height {
            for x in 0..<width {
                let imagePoint = projection.imagePoint(.init(x:(Double(x)+0.5)/Double(width),y:(Double(y)+0.5)/Double(height)))
                let sx = min(sourceWidth-1,max(0,Int(imagePoint.x*Double(sourceWidth))))
                let sy = min(sourceHeight-1,max(0,Int(imagePoint.y*Double(sourceHeight))))
                let i = sy*rowBytes+sx*4
                luma.append((0.2126*Double(base[i+2])+0.7152*Double(base[i+1])+0.0722*Double(base[i]))/255)
            }
        }
        guard let measured = PhotoMeasurements.from(luma:luma,width:width,height:height), let bins = histogram(luma) else { return nil }
        let mask = masks(luma,width:width,height:height,highlights:options.highlights,peaking:options.peaking)
        return .init(histogram:bins,measurements:measured,zebra:mask.zebra.flatMap { image($0,width:width,height:height) },peaking:mask.edges.flatMap { image($0,width:width,height:height) },timestamp:timestamp,sampleWidth:width,sampleHeight:height)
    }
    private static func image(_ bytes:[UInt8],width:Int,height:Int) -> CGImage? {
        guard let provider = CGDataProvider(data:Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big)
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:info,provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
    }
}
