import Foundation

/// Frozen geometry for one real camera ramp. Coordinates are the visible preview,
/// so projection/mirroring is performed once by the existing camera pipeline.
struct AutomaticShotPlan {
    let id = UUID().uuidString
    let subjectLabel: String
    let initialBounds: CGRect
    let desiredBounds: CGRect
    let framingRectangle: CGRect
    let startingZoom: Double
    let targetZoom: Double
    let maximumZoom: Double
    let protectedRegions: [CGRect]
    let subjectRegions: [CGRect]
    let observedHead: CGRect?
    var desiredScale: Double { targetZoom / startingZoom }

    static func make(bounds: CGRect, label: String, composition: SceneCompositionPlan,
                     currentZoom: Double, maximumZoom: Double, detailLimit: Double, nativeStops: [Double],
                     regions: [CGRect], anatomy: SubjectAnatomy?, previewAspect: Double) -> Self? {
        let scale = composition.selected.zoomScale
        guard composition.permitsZoom, valid(bounds), [currentZoom,maximumZoom,detailLimit,scale,previewAspect].allSatisfy(\.isFinite),
              currentZoom > 0, scale > 1.12, previewAspect > 0 else { return nil }
        let targetZoom = currentZoom * scale
        let destination = FramingPlanner.zoomedRect(bounds,scale:scale)
        let positionError = hypot(Double(destination.midX)-composition.target.x,
                                  (Double(destination.midY)-composition.target.y)/previewAspect)
        let stops = FramingPlanner.availableScales(currentZoom:currentZoom,maximumZoom:maximumZoom,detailZoomLimit:detailLimit,nativeStops:nativeStops,maximumScale:scale,desiredScale:scale)
        guard positionError <= 0.065, stops.contains(where:{ abs($0-scale) < 0.001 }) else { return nil }
        var bodyRegions = anatomy?.face.map { [$0] } ?? []
        bodyRegions += (anatomy?.joints ?? []).map { CGRect(x:$0.x-0.004,y:$0.y-0.004,width:0.008,height:0.008) }
        guard regions.allSatisfy({ valid($0) }) else { return nil }
        let protected = regions
        guard safe(destination), (protected+bodyRegions).allSatisfy({ valid($0) && safe(FramingPlanner.zoomedRect($0,scale:scale)) }) else { return nil }
        let size = 1/scale
        return .init(subjectLabel:label,initialBounds:bounds,desiredBounds:destination,
                     framingRectangle:CGRect(x:(1-size)/2,y:(1-size)/2,width:size,height:size),
                     startingZoom:currentZoom,targetZoom:targetZoom,maximumZoom:maximumZoom,
                     protectedRegions:protected,subjectRegions:bodyRegions,observedHead:anatomy?.face)
    }
    func trackedAnatomy(bounds:CGRect,timestamp:TimeInterval) -> SubjectAnatomy? {
        guard let head = observedHead, Self.valid(bounds) else { return nil }
        let tracked = CGRect(x:bounds.minX+(head.minX-initialBounds.minX)*bounds.width/initialBounds.width,
            y:bounds.minY+(head.minY-initialBounds.minY)*bounds.height/initialBounds.height,
            width:head.width*bounds.width/initialBounds.width,height:head.height*bounds.height/initialBounds.height)
        // Tracked geometry from an observed region; no fresh pose recognition implied.
        return .init(face:tracked,timestamp:timestamp)
    }
    func safeRemainingCrop(bounds:CGRect,zoom:Double,observedRegions:[CGRect],projectToTarget:Bool = true) -> Bool {
        guard Self.valid(bounds), zoom.isFinite, zoom >= startingZoom*0.98, zoom <= maximumZoom+0.01 else { return false }
        let expected = FramingPlanner.zoomedRect(initialBounds,scale:zoom/startingZoom)
        guard hypot(Double(bounds.midX-expected.midX),Double(bounds.midY-expected.midY)) <= 0.12 else { return false }
        let remaining = projectToTarget ? max(1,targetZoom/zoom) : 1
        guard Self.safe(bounds), Self.safe(FramingPlanner.zoomedRect(bounds,scale:remaining)) else { return false }
        // Remember observed context through the ramp even when expensive detections pause.
        guard protectedRegions.allSatisfy({ Self.safe(FramingPlanner.zoomedRect($0,scale:desiredScale)) }),
              observedRegions.allSatisfy({ Self.valid($0) && Self.safe(FramingPlanner.zoomedRect($0,scale:remaining)) }) else { return false }
        // Head/joint envelopes follow the tracked body's affine change. This is
        // geometric protection, not new pose inference or proof of hidden anatomy.
        return subjectRegions.allSatisfy { region in
            let tracked = CGRect(x:bounds.minX+(region.minX-initialBounds.minX)*bounds.width/initialBounds.width,
                y:bounds.minY+(region.minY-initialBounds.minY)*bounds.height/initialBounds.height,
                width:region.width*bounds.width/initialBounds.width,height:region.height*bounds.height/initialBounds.height)
            return Self.safe(FramingPlanner.zoomedRect(tracked,scale:remaining))
        }
    }
    func achieved(bounds:CGRect,zoom:Double,previewAspect:Double) -> Bool {
        guard Self.valid(bounds), previewAspect > 0 else { return false }
        let sizeError = max(abs(Double(bounds.width/desiredBounds.width)-1),abs(Double(bounds.height/desiredBounds.height)-1))
        let positionError = hypot(Double(bounds.midX-desiredBounds.midX),Double(bounds.midY-desiredBounds.midY)/previewAspect)
        return zoom >= targetZoom*0.98 && zoom <= targetZoom*1.02 && sizeError <= 0.08 && positionError <= 0.05
    }
    static func valid(_ rect:CGRect) -> Bool {
        !rect.isNull && [rect.minX,rect.minY,rect.width,rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }
    static func safe(_ rect:CGRect) -> Bool { valid(rect) && CGRect(x:0.018,y:0.018,width:0.964,height:0.964).contains(rect) }
}

/// Bounded rate changes for the existing AVFoundation ramp, all to one target.
/// Device timing/easing remains hardware-dependent and must be verified on-device.
enum AutomaticZoomRampProfile {
    static func stage(progress:Double) -> Int { progress < 0.15 ? 0 : progress < 0.72 ? 1 : 2 }
    static func rate(stage:Int,hardwareDistance:Double) -> Float {
        let cruise = min(3,max(0.6,hardwareDistance/1.4))
        return Float(cruise * (stage == 0 ? 0.55 : stage == 1 ? 1 : 0.35))
    }
}
