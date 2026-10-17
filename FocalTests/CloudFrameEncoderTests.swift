import XCTest
import UIKit
import CoreImage
import ImageIO
@testable import Focal

final class CloudFrameEncoderTests: XCTestCase {
    private let context = CIContext(options:[.useSoftwareRenderer:true])
    func testEncodedPreviewIsSmallUprightAndHasNoLocationMetadata() throws {
        let image = CIImage(color:CIColor(red:0.3,green:0.6,blue:0.2)).cropped(to:CGRect(x:0,y:0,width:2000,height:3000))
        let data = try XCTUnwrap(CloudFrameEncoder.encode(image,projection:.init(imageAspect:2.0/3,previewAspect:0.75),context:context))
        XCTAssertLessThanOrEqual(data.count,163_840)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData,nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary]); XCTAssertNil(properties[kCGImagePropertyExifDictionary])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int), height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertLessThanOrEqual(max(width,height),768); XCTAssertEqual(Double(width)/Double(height),0.75,accuracy:0.005)
        XCTAssertEqual(UIImage(data:data)?.imageOrientation,.up)
    }
    func testFrontPreviewMirrorsExactlyOnce() throws {
        let left = CIImage(color:CIColor(red:1,green:0,blue:0)).cropped(to:CGRect(x:0,y:0,width:100,height:100))
        let right = CIImage(color:CIColor(red:0,green:0,blue:1)).cropped(to:CGRect(x:100,y:0,width:100,height:100))
        let image = left.composited(over:right)
        for mirrored in [false,true] {
            let jpeg = try XCTUnwrap(CloudFrameEncoder.encode(image,projection:.init(imageAspect:2,previewAspect:2,mirrored:mirrored),context:context))
            let decoded = try XCTUnwrap(CIImage(data:jpeg))
            var pixel = [UInt8](repeating:0,count:4)
            context.render(decoded,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:20,y:50,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
            XCTAssertTrue(mirrored ? pixel[2] > pixel[0] : pixel[0] > pixel[2])
        }
    }
    func testEncoderDoesNotUpscaleSmallPreview() throws {
        let image = CIImage(color:CIColor(red:0.4,green:0.5,blue:0.6)).cropped(to:CGRect(x:0,y:0,width:120,height:160))
        let data = try XCTUnwrap(CloudFrameEncoder.encode(image,projection:.init(imageAspect:0.75,previewAspect:0.75),context:context))
        let decoded = try XCTUnwrap(UIImage(data:data)); XCTAssertEqual(decoded.size.width,120); XCTAssertEqual(decoded.size.height,160)
    }
}
