import CoreImage
import CoreGraphics
import Foundation

struct FilmRandom {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var value = state; value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return Double(value ^ (value >> 31)) / Double(UInt64.max)
    }
}
enum FilmEffectRenderer {
    static func apply(_ input: CIImage, recipe: EditRecipe) -> CIImage {
        var image = input
        let f = recipe.effects, extent = image.extent, width = extent.width
        if f.motion > 0 { image = image.clampedToExtent().applyingFilter("CIMotionBlur", parameters: ["inputRadius": f.motion * Double(width) * 0.025, "inputAngle": f.motionAngle]).cropped(to: extent) }
        if f.fringe > 0 {
            let shift = CGFloat(f.fringe) * width * 0.004
            func channel(_ vector: CIVector, offset: CGFloat) -> CIImage {
                image.clampedToExtent().transformed(by: CGAffineTransform(translationX: offset, y: 0))
                    .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: vector.x, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: vector.y, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: vector.z, w: 0)])
            }
            let red = channel(CIVector(x: 1, y: 0, z: 0), offset: shift)
            let green = channel(CIVector(x: 0, y: 1, z: 0), offset: 0)
            let blue = channel(CIVector(x: 0, y: 0, z: 1), offset: -shift)
            image = red.applyingFilter("CIAdditionCompositing", parameters: ["inputBackgroundImage": green])
                .applyingFilter("CIAdditionCompositing", parameters: ["inputBackgroundImage": blue]).cropped(to: extent)
        }
        if f.halation > 0 {
            let mask = image.clampedToExtent().applyingFilter("CIColorControls", parameters: ["inputSaturation": 0, "inputBrightness": -0.65])
                .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 3, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.6, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0.15, w: 0)])
                .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": width * 0.007])
            image = opacity(mask, f.halation * 0.65).applyingFilter("CIScreenBlendMode", parameters: ["inputBackgroundImage": image]).cropped(to: extent)
        }
        if f.glow > 0 { image = image.clampedToExtent().applyingFilter("CIBloom", parameters: ["inputRadius": width * 0.012, "inputIntensity": f.glow * 0.75]).cropped(to: extent) }
        if recipe.grain > 0, let noise = noiseTile(seed: f.seed) {
            let scale = max(0.5, width / 1000) * CGFloat(0.5 + f.grainSize * 4)
            let tiled = noise.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).applyingFilter("CIAffineTile").cropped(to: extent)
            image = opacity(tiled, recipe.grain * 0.28).applyingFilter("CIOverlayBlendMode", parameters: ["inputBackgroundImage": image])
        }
        if f.lightLeak > 0 {
            let leak = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: -width * 0.1, y: extent.height * 0.85),
                "inputPoint1": CIVector(x: width * 0.65, y: extent.height * 0.25),
                "inputColor0": CIColor(red: 1, green: 0.2, blue: 0.025, alpha: f.lightLeak * 0.7), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)])?.outputImage
            if let leak { image = leak.cropped(to: extent).applyingFilter("CIScreenBlendMode", parameters: ["inputBackgroundImage": image]) }
        }
        if (f.dust > 0 || f.scratches > 0), let marks = marks(extent: extent, effects: f) { image = marks.composited(over: image) }
        if recipe.vignette > 0 { image = image.applyingFilter("CIVignette", parameters: ["inputIntensity": recipe.vignette, "inputRadius": min(width, extent.height) * 0.65]) }
        return image.cropped(to: extent)
    }
    private static func opacity(_ image: CIImage, _ amount: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: amount)])
    }
    private static func noiseTile(seed: UInt64) -> CIImage? {
        var rng = FilmRandom(state: seed), bytes = [UInt8](); bytes.reserveCapacity(256 * 256 * 4)
        for _ in 0..<(256 * 256) { let value = UInt8(rng.next() * 255); bytes += [value, value, value, 255] }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: 256 * 4, size: CGSize(width: 256, height: 256), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
    private static func marks(extent: CGRect, effects: FilmEffects) -> CIImage? {
        let scale = min(1, 1800 / max(extent.width, extent.height))
        let width = max(1, Int(extent.width * scale)), height = max(1, Int(extent.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var rng = FilmRandom(state: effects.seed &+ 42)
        for _ in 0..<Int(effects.dust * 140) {
            let radius = 0.4 + rng.next() * 2
            context.setFillColor(CGColor(gray: rng.next() > 0.4 ? 1 : 0, alpha: 0.15 + rng.next() * 0.35))
            context.fillEllipse(in: CGRect(x: rng.next() * Double(width), y: rng.next() * Double(height), width: radius * 2, height: radius * 2))
        }
        context.setStrokeColor(CGColor(gray: 1, alpha: effects.scratches * 0.35))
        for _ in 0..<Int(effects.scratches * 50) {
            let x = rng.next() * Double(width), y = rng.next() * Double(height)
            context.setLineWidth(0.3 + rng.next() * 0.8); context.move(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x + (rng.next() - 0.5) * 10, y: y + rng.next() * Double(height) * 0.25)); context.strokePath()
        }
        guard let cg = context.makeImage() else { return nil }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)).cropped(to: extent)
    }
}
