import Foundation

/// Coordinates are normalized in the already oriented, visible camera image.
/// The portrait capture connection supplies the orientation; Vision's y flip
/// and preview mirroring are handled by PreviewProjection at the boundary.
enum ShotCompositionKind: String {
    case environmental, subjectPortrait, observedFacePortrait, objectPortrait, scenic
}

struct ShotFramingError {
    let position: Double
    let width: Double
    let height: Double
    let zoom: Double
    var complete: Bool { position <= 0.05 && width <= 0.08 && height <= 0.08 && zoom <= 0.020000000001 }
}

struct ShotImageGeometry {
    let subject: CGRect // Oriented camera image, top-left origin, unmirrored.
    let composition: CGRect
    let imageAspect: Double
    let previewAspect: Double
    let mirrored: Bool
}

enum TargetRectangleGeometry {
    static let margin = 0.035
    /// Direct normalized bounds comparisons avoid CGRect union/equality ULP
    /// artifacts at fractional zoom. Epsilon is far below any crop margin.
    static func contains(_ outer:CGRect,_ inner:CGRect) -> Bool {
        guard AutomaticShotPlan.valid(outer), AutomaticShotPlan.valid(inner) else { return false }
        let epsilon = 1e-9
        return inner.minX >= outer.minX-epsilon && inner.minY >= outer.minY-epsilon
            && inner.maxX <= outer.maxX+epsilon && inner.maxY <= outer.maxY+epsilon
    }
    static func crop(subject:CGRect,position:UnitPoint2D,scale:Double) -> CGRect? {
        guard AutomaticShotPlan.valid(subject), scale.isFinite, scale >= 1,
              position.x.isFinite, position.y.isFinite else { return nil }
        return CGRect(x:subject.midX-position.x/scale,y:subject.midY-position.y/scale,width:1/scale,height:1/scale)
    }
    static func relative(_ subject:CGRect,in crop:CGRect) -> CGRect {
        CGRect(x:(subject.minX-crop.minX)/crop.width,y:(subject.minY-crop.minY)/crop.height,
               width:subject.width/crop.width,height:subject.height/crop.height)
    }
    static func desiredArea(label:String,intent:PhotographyIntent) -> Double {
        let category = SubjectCategory.classified(label)
        if intent == .landscape || intent == .architecture { return 0 }
        if category == .face { return 0.38 }
        if intent == .pet || category == .pet { return 0.44 }
        if intent == .portrait || category == .person { return 0.34 }
        return intent == .product ? 0.46 : 0.40
    }
    static func preferredScale(subject:CGRect,label:String,intent:PhotographyIntent) -> Double {
        guard AutomaticShotPlan.valid(subject), intent.permitsZoom else { return 1 }
        let area = Double(subject.width*subject.height)
        // Both dimensions constrain the target; area alone could crop ears/feet.
        let fit = min(0.86/Double(subject.width),0.86/Double(subject.height))
        return max(1,min(fit,sqrt(desiredArea(label:label,intent:intent)/max(0.0001,area))))
    }
}

/// Estimates a conservative crop budget from configured output pixels. Optical
/// stops remain separate. This does not certify optical quality or sensor detail.
enum AutomaticZoomQualityBudget {
    static func detailLimit(existing:Double,previewShortSide:Double,photoPixels:Double) -> Double {
        guard [existing,previewShortSide,photoPixels].allSatisfy(\.isFinite), existing > 0 else { return 1 }
        let stillBudget = sqrt(max(1,photoPixels/8_000_000))
        let previewBudget = max(1,previewShortSide/960)
        return max(existing,min(3,min(stillBudget,previewBudget)))
    }
}
