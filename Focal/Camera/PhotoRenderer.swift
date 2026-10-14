import UIKit
import CoreImage

enum PhotoRenderer {
    static func widePreview(_ image:CIImage,aspect:Double,mirrored:Bool,observedAt:Date,context:CIContext) -> WideScenePreview? {
        guard aspect.isFinite, aspect > 0, image.extent.width > 0, image.extent.height > 0 else { return nil }
        let size = image.extent.size
        let width = floor(min(size.width,size.height*aspect))
        let height = floor(min(size.height,size.width/aspect))
        guard width > 0, height > 0 else { return nil }
        let crop = CGRect(x:floor(image.extent.midX-width/2),y:floor(image.extent.midY-height/2),width:width,height:height).intersection(image.extent)
        var frame = image.cropped(to:crop)
        if mirrored { frame = frame.transformed(by:CGAffineTransform(scaleX:-1,y:1)) }
        frame = frame.transformed(by:CGAffineTransform(translationX:-frame.extent.minX,y:-frame.extent.minY))
        // Match the existing analysis preview budget, never upscale.
        let scale = min(1,1600/max(frame.extent.width,frame.extent.height))
        frame = frame.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        guard let pixels = context.createCGImage(frame,from:CGRect(x:0,y:0,width:floor(frame.extent.width),height:floor(frame.extent.height))),
              let data = UIImage(cgImage:pixels).jpegData(compressionQuality:0.93) else { return nil }
        return .init(data:data,pixelWidth:pixels.width,pixelHeight:pixels.height,observedAt:observedAt)
    }
    /// Only the selected-aspect derivative is cropped; the original camera JPEG is retained.
    static func crop(_ data: Data, to aspect: PhotoAspect) throws -> Data {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw RenderError.invalidImage }
        if abs(Double(image.extent.width / image.extent.height) - aspect.ratio) < 0.005 { return data }
        return try ImageEditor.export(data: data, recipe: EditRecipe(crop: aspect))
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
            ("Focal · field note" as NSString).draw(in: CGRect(x: padding, y: image.size.height + bandHeight * 0.2,
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
