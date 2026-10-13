import CoreImage
import CoreText
import ImageIO
import Foundation

enum PhotoFrameRenderer {
    static func apply(_ image: CIImage, recipe: EditRecipe, properties: [String: Any]) -> CIImage {
        let style = recipe.frame, original = image.extent
        guard style != .none || recipe.dateStamp else { return image }
        let short = min(original.width, original.height)
        let border = style == .none ? 0 : max(1, (short * style.borderRatio).rounded())
        let bottom = style == .none ? 0 : max(border, (short * style.bottomRatio).rounded())
        let canvas = CGRect(x: 0, y: 0, width: original.width + border * 2, height: original.height + border + bottom)
        let background: CIColor = style == .black || style == .plain ? .black : style == .paper || style == .negative || style == .instant ? CIColor(red: 0.95, green: 0.94, blue: 0.9) : .white
        let positioned = image.transformed(by: CGAffineTransform(translationX: border, y: bottom))
        var result = positioned.composited(over: CIImage(color: background).cropped(to: canvas))
        if style == .negative || style == .plain {
            let color: CIColor = style == .plain ? .white : .black
            let thickness = max(1, short * 0.004)
            let opening = CGRect(x: border - thickness, y: bottom - thickness, width: original.width + thickness * 2, height: original.height + thickness * 2)
            result = positioned.composited(over: CIImage(color: color).cropped(to: opening).composited(over: result))
        }
        if style == .specs {
            let info = metadata(properties)
            if let stripe = text(info, width: Int(canvas.width - border * 2), height: max(24, Int(bottom * 0.65)), size: max(10, short * 0.02), dark: true) {
                result = stripe.transformed(by: CGAffineTransform(translationX: border, y: bottom * 0.15)).composited(over: result)
            }
        }
        if recipe.dateStamp, let date = recipe.stampDate {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy.MM.dd"
            let stripeWidth = Int(min(original.width * 0.42, 2400)), stripeHeight = max(24, Int(short * 0.04))
            if let stamp = text(formatter.string(from: date), width: stripeWidth, height: stripeHeight, size: max(10, short * 0.024), dark: style != .none && style != .black && style != .plain) {
                let x = canvas.width - border - CGFloat(stripeWidth)
                let y = style == .none ? short * 0.025 : max(1, bottom * 0.25)
                result = stamp.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: result)
            }
        }
        return result.cropped(to: canvas)
    }
    private static func metadata(_ properties: [String: Any]) -> String {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        var parts = [String]()
        if let aperture = exif[kCGImagePropertyExifFNumber as String] as? NSNumber { parts.append(String(format: "ƒ/%.1f", aperture.doubleValue)) }
        if let shutter = exif[kCGImagePropertyExifExposureTime as String] as? NSNumber, let label = CameraTelemetry.shutterLabel(seconds: shutter.doubleValue) { parts.append(label + " s") }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first { parts.append("ISO " + iso.stringValue) }
        if let focal = exif[kCGImagePropertyExifFocalLength as String] as? NSNumber { parts.append(String(format: "%.0f mm", focal.doubleValue)) }
        return parts.isEmpty ? "FOCAL" : parts.joined(separator: "   ·   ")
    }
    private static func text(_ value: String, width: Int, height: Int, size: CGFloat, dark: Bool) -> CIImage? {
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, min(size, CGFloat(height) * 0.65), nil)
        let foreground = dark ? CGColor(gray: 0.1, alpha: 1) : CGColor(red: 1, green: 0.7, blue: 0.2, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes) as CFAttributedString)
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: max(0, (CGFloat(width) - textWidth) / 2), y: CGFloat(height) * 0.22)
        CTLineDraw(line, context)
        return context.makeImage().map { CIImage(cgImage: $0) }
    }
}
