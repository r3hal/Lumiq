import Foundation
import CoreImage

struct EditRGB: Equatable {
    var r: Double, g: Double, b: Double
    var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var clamped: Self { Self(r: finiteClamp(r, 0...1), g: finiteClamp(g, 0...1), b: finiteClamp(b, 0...1)) }
    var hsl: (h: Double, s: Double, l: Double) {
        let hi = max(r, max(g, b)), lo = min(r, min(g, b)), delta = hi - lo
        let l = (hi + lo) / 2
        guard delta > 0.000001 else { return (0, 0, l) }
        var h = hi == r ? (g - b) / delta : hi == g ? (b - r) / delta + 2 : (r - g) / delta + 4
        h /= 6; if h < 0 { h += 1 }
        return (h, delta / max(0.000001, 1 - abs(2 * l - 1)), l)
    }
    static func fromHSL(hue: Double, saturation: Double, lightness: Double) -> Self {
        let h = hue - floor(hue), s = finiteClamp(saturation, 0...1), l = finiteClamp(lightness, 0...1)
        let c = (1 - abs(2 * l - 1)) * s, x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
        let base: Self
        switch Int(h * 6) {
        case 0: base = Self(r: c, g: x, b: 0)
        case 1: base = Self(r: x, g: c, b: 0)
        case 2: base = Self(r: 0, g: c, b: x)
        case 3: base = Self(r: 0, g: x, b: c)
        case 4: base = Self(r: x, g: 0, b: c)
        default: base = Self(r: c, g: 0, b: x)
        }
        return Self(r: base.r + m, g: base.g + m, b: base.b + m)
    }
}

enum ColorProcessing {
    private static let cache = NSCache<NSString, NSData>()
    private struct Key: Codable { let color: AdvancedColor; let whites: Double; let blacks: Double; let fade: Double }
    static func transform(_ pixel: EditRGB, color: AdvancedColor, whites: Double, blacks: Double, fade: Double) -> EditRGB {
        var rgb = pixel
        let hsl = rgb.hsl
        let centers = [0.0, 1.0 / 12, 1.0 / 6, 1.0 / 3, 0.5, 2.0 / 3, 0.75, 5.0 / 6]
        var dh = 0.0, ds = 0.0, dl = 0.0
        for i in 0..<min(8, color.hsl.count) {
            let distance = abs(hsl.h - centers[i]), wrapped = min(distance, 1 - distance)
            let weight = max(0, 1 - wrapped / 0.12) * min(1, hsl.s * 3)
            dh += color.hsl[i].hue * weight * 0.1; ds += color.hsl[i].saturation * weight; dl += color.hsl[i].lightness * weight * 0.25
        }
        if dh != 0 || ds != 0 || dl != 0 { rgb = .fromHSL(hue: hsl.h + dh, saturation: hsl.s * max(0, 1 + ds), lightness: hsl.l + dl) }
        let l = finiteClamp(rgb.luma + color.balance * 0.2, 0...1)
        let weights = [pow(1 - l, 2), max(0, 1 - abs(2 * l - 1)), pow(l, 2)]
        for (grade, weight) in zip([color.shadows, color.midtones, color.highlights], weights) where grade.amount > 0 {
            let tint = EditRGB.fromHSL(hue: grade.hue, saturation: 0.8, lightness: 0.5)
            let strength = grade.amount * weight * 0.3
            rgb.r += (tint.r - tint.luma) * strength; rgb.g += (tint.g - tint.luma) * strength; rgb.b += (tint.b - tint.luma) * strength
        }
        let r = rgb.r, g = rgb.g, b = rgb.b, luminance = rgb.luma
        rgb.r = r + (r - luminance) * color.redSaturation * 0.3 - g * color.greenHue * 0.12 + b * color.blueHue * 0.12
        rgb.g = g + (g - luminance) * color.greenSaturation * 0.3 + r * color.redHue * 0.12 - b * color.blueHue * 0.12
        rgb.b = b + (b - luminance) * color.blueSaturation * 0.3 - r * color.redHue * 0.12 + g * color.greenHue * 0.12
        let tonal = whites * pow(pixel.luma, 3) * 0.25 + blacks * pow(1 - pixel.luma, 3) * 0.25
        rgb.r = (rgb.r + tonal) * (1 - fade * 0.25) + fade * 0.08
        rgb.g = (rgb.g + tonal) * (1 - fade * 0.25) + fade * 0.08
        rgb.b = (rgb.b + tonal) * (1 - fade * 0.25) + fade * 0.08
        return rgb.clamped
    }
    static func apply(_ image: CIImage, recipe: EditRecipe) -> CIImage {
        guard recipe.color != AdvancedColor() || recipe.whites != 0 || recipe.blacks != 0 || recipe.fade != 0 else { return image }
        let key = Key(color: recipe.color, whites: recipe.whites, blacks: recipe.blacks, fade: recipe.fade)
        let name = ((try? JSONEncoder().encode(key).base64EncodedString()) ?? "") as NSString
        let data: Data
        if let saved = cache.object(forKey: name) { data = saved as Data }
        else {
            let size = 32
            var values = [Float](); values.reserveCapacity(size * size * size * 4)
            for b in 0..<size { for g in 0..<size { for r in 0..<size {
                let pixel = EditRGB(r: Double(r) / 31, g: Double(g) / 31, b: Double(b) / 31)
                let output = transform(pixel, color: key.color, whites: key.whites, blacks: key.blacks, fade: key.fade)
                values += [Float(output.r), Float(output.g), Float(output.b), 1]
            } } }
            data = values.withUnsafeBytes { Data($0) }
            cache.totalCostLimit = 8 * 1024 * 1024; cache.setObject(data as NSData, forKey: name, cost: data.count)
        }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": 32, "inputCubeData": data, "inputColorSpace": CGColorSpaceCreateDeviceRGB()])
    }
}
