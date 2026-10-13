import Foundation
import ImageIO

struct PhotoMetadata: Sendable {
    let rows: [(String, String)]
    static func read(_ url: URL) -> Self? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var rows: [(String,String)] = []
        if let type = CGImageSourceGetType(source) { rows.append(("Encoding",(type as String).replacingOccurrences(of:"public.",with:"").uppercased())) }
        if let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int {
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            rows.append(("File dimensions",orientation >= 5 ? "\(h) × \(w)" : "\(w) × \(h)"))
        }
        if let model = tiff[kCGImagePropertyTIFFModel] as? String { rows.append(("Camera",model)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first { rows.append(("ISO",iso.stringValue)) }
        if let value = exif[kCGImagePropertyExifExposureTime] as? NSNumber {
            let t = value.doubleValue
            if t > 0 { rows.append(("Shutter", t < 1 ? String(format: "1/%.0f s", 1/t) : String(format: "%.2f s", t))) }
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? NSNumber { rows.append(("Aperture",String(format: "ƒ/%.1f",aperture.doubleValue))) }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? NSNumber { rows.append(("Focal length",String(format: "%.1f mm",focal.doubleValue))) }
        return Self(rows: rows)
    }
}
