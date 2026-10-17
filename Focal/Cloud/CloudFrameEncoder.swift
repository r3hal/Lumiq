import Foundation
import UIKit
import CoreImage

/// Upright video buffers already use the capture connection's 90-degree
/// rotation. Crop to the visible preview, mirror the front preview once, render
/// new pixels and encode a fresh JPEG with no source metadata attached.
enum CloudFrameEncoder {
    static func encode(_ image:CIImage,projection:PreviewProjection,context:CIContext) -> Data? {
        let visible = projection.imageRect(CGRect(x:0,y:0,width:1,height:1))
        let extent = image.extent
        let crop = CGRect(x:extent.minX+visible.minX*extent.width,y:extent.minY+(1-visible.maxY)*extent.height,width:visible.width*extent.width,height:visible.height*extent.height).intersection(extent)
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { return nil }
        var pixels = image.cropped(to:crop).transformed(by:CGAffineTransform(translationX:-crop.minX,y:-crop.minY))
        if projection.mirrored { pixels = pixels.transformed(by:CGAffineTransform(a:-1,b:0,c:0,d:1,tx:crop.width,ty:0)) }
        for edge in [768.0,512.0,384.0] {
            let scale = min(1,edge/max(Double(pixels.extent.width),Double(pixels.extent.height)))
            let resized = pixels.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            guard let cg = context.createCGImage(resized,from:resized.extent) else { return nil }
            if let jpeg = UIImage(cgImage:cg,scale:1,orientation:.up).jpegData(compressionQuality:0.65), jpeg.count <= 163_840 { return jpeg }
        }
        return nil
    }
}
