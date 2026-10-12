import Foundation

/// Matches resizeAspectFill: Vision's full image can be wider than the visible preview.
struct PreviewProjection {
    let imageAspect: Double
    let previewAspect: Double
    var mirrored = false

    private var scaleX: Double { max(1, imageAspect / previewAspect) }
    private var scaleY: Double { max(1, previewAspect / imageAspect) }

    func visiblePoint(_ imagePoint: UnitPoint2D) -> UnitPoint2D {
        let x = (imagePoint.x - 0.5) * scaleX + 0.5
        return UnitPoint2D(x: mirrored ? 1-x : x,y: (imagePoint.y-0.5)*scaleY+0.5)
    }

    func imagePoint(_ visiblePoint: UnitPoint2D) -> UnitPoint2D {
        let x = mirrored ? 1-visiblePoint.x : visiblePoint.x
        return UnitPoint2D(x: (x-0.5)/scaleX+0.5,y: (visiblePoint.y-0.5)/scaleY+0.5)
    }

    func visibleRect(_ rect: CGRect) -> CGRect {
        let origin = visiblePoint(.init(x: mirrored ? rect.maxX : rect.minX, y: rect.minY))
        return CGRect(x: origin.x, y: origin.y, width: rect.width * scaleX, height: rect.height * scaleY)
    }
}
