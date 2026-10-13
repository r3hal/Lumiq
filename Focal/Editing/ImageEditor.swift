import CoreImage
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Render preview derivatives separately; never replace a captured file.
enum ImageEditor {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    static func render(_ source: CIImage, recipe: EditRecipe, maxPixels: CGFloat? = nil) -> CIImage {
        let edit = recipe.normalized
        var image = source
        switch edit.quarterTurns {
        case 1: image = image.oriented(.right)
        case 2: image = image.oriented(.down)
        case 3: image = image.oriented(.left)
        default: break
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let crop = edit.crop { image = image.cropped(to: crop.cropRect(in: image.extent.size)) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let maxPixels {
            let scale = min(1, maxPixels / max(image.extent.width, image.extent.height))
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = image.extent
        if edit.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": edit.exposure]) }
        image = image.applyingFilter("CIColorControls", parameters: ["inputContrast": edit.contrast, "inputSaturation": edit.saturation])
        if edit.warmth != 0 || edit.tint != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - edit.warmth * 2000, y: edit.tint * 80)])
        }
        if edit.highlights != 1 || edit.shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": edit.highlights, "inputShadowAmount": edit.shadows])
        }
        if edit.vibrance != 0 { image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": edit.vibrance]) }
        if edit.curve != 0 {
            image = image.applyingFilter("CIToneCurve", parameters: ["inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 - edit.curve * 0.08), "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + edit.curve * 0.08), "inputPoint4": CIVector(x: 1, y: 1)])
        }
        image = ColorProcessing.apply(image, recipe: edit)
        if edit.sharpness > 0 { image = image.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": edit.sharpness]) }
        image = FilmEffectRenderer.apply(image, recipe: edit).cropped(to: extent)
        return PhotoFrameRenderer.apply(image, recipe: edit, properties: source.properties)
    }

    static func preview(source: CIImage, recipe: EditRecipe, maxPixels: CGFloat = 1400) -> UIImage? {
        let image = render(source, recipe: recipe, maxPixels: maxPixels)
        return context.createCGImage(image, from: image.extent).map { UIImage(cgImage: $0) }
    }

    static func export(data: Data, recipe: EditRecipe) throws -> Data {
        guard recipe.normalized != .original else { return data }
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw PhotoRenderer.RenderError.invalidImage }
        return try export(source: image, recipe: recipe)
    }

    static func export(source: CIImage, recipe: EditRecipe) throws -> Data {
        let rendered = render(source, recipe: recipe)
        guard let cgImage = context.createCGImage(rendered, from: rendered.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw PhotoRenderer.RenderError.invalidImage }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { throw PhotoRenderer.RenderError.invalidImage }
        var properties: [CFString: Any] = [:]
        for (key, value) in source.properties { properties[key as CFString] = value }
        properties.removeValue(forKey: kCGImagePropertyProfileName)
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString:Any] {
            exif[kCGImagePropertyExifPixelXDimension] = cgImage.width
            exif[kCGImagePropertyExifPixelYDimension] = cgImage.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString:Any] { tiff[kCGImagePropertyTIFFOrientation] = 1; properties[kCGImagePropertyTIFFDictionary] = tiff }
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = cgImage.width
        properties[kCGImagePropertyPixelHeight] = cgImage.height
        properties[kCGImageDestinationLossyCompressionQuality] = 0.98
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoRenderer.RenderError.invalidImage }
        return bytes as Data
    }
}
