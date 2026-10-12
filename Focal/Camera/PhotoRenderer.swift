import UIKit
import CoreImage

enum PhotoRenderer {
    /// Only the selected-aspect derivative is cropped; the original camera JPEG is retained.
    static func crop(_ data: Data, to aspect: PhotoAspect) throws -> Data {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw RenderError.invalidImage }
        if abs(Double(image.extent.width / image.extent.height) - aspect.ratio) < 0.005 { return data }
        let rect = aspect.cropRect(in: image.extent.size).offsetBy(dx: image.extent.minX, dy: image.extent.minY)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cropped = context.createCGImage(image, from: rect),
              let encoded = UIImage(cgImage: cropped).jpegData(compressionQuality: 0.98) else { throw RenderError.invalidImage }
        return encoded
    }

    static func captionedScan(_ data: Data, style: CaptionStyle) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let padding = image.size.width * 0.035
        let bandHeight = image.size.width * 0.13
        let size = CGSize(width: image.size.width, height: image.size.height + bandHeight)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: image.size))
            let fontSize = image.size.width * 0.06
            let font: UIFont
            switch style {
            case .bold:
                let descriptor = UIFont.boldSystemFont(ofSize: fontSize).fontDescriptor
                    .withSymbolicTraits([.traitBold, .traitItalic])
                font = descriptor.map { UIFont(descriptor: $0, size: fontSize) } ?? .boldSystemFont(ofSize: fontSize)
            case .editorial: font = UIFont(name: "Georgia-Italic", size: fontSize) ?? .italicSystemFont(ofSize: fontSize)
            case .garamond: font = UIFont(name: "EBGaramond-Italic", size: fontSize) ?? .italicSystemFont(ofSize: fontSize)
            case .handwriting: font = UIFont(name: "SnellRoundhand", size: fontSize) ?? .italicSystemFont(ofSize: fontSize)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            ("What I see" as NSString).draw(in: CGRect(x: padding, y: image.size.height + bandHeight * 0.2,
                                                       width: image.size.width - padding * 2, height: bandHeight * 0.75),
                                            withAttributes: [.font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph])
        }
        return rendered.jpegData(compressionQuality: 0.95)
    }

    enum RenderError: LocalizedError {
        case invalidImage
        var errorDescription: String? { "The captured photo could not be rendered. Please try again." }
    }
}
