import Foundation

/// Frozen geometry for one real camera ramp. Coordinates are the visible preview,
/// so projection/mirroring is performed once by the existing camera pipeline.
struct AutomaticShotPlan {
    private(set) var id = UUID().uuidString
    let subjectLabel: String
    private(set) var initialBounds: CGRect
    let desiredBounds: CGRect
    private(set) var framingRectangle: CGRect
    private(set) var startingZoom: Double
    private(set) var targetZoom: Double
    let maximumZoom: Double
    private(set) var protectedRegions: [CGRect]
    private(set) var subjectRegions: [CGRect]
    private(set) var observedHead: CGRect?
    private(set) var trackingReference: String? = nil
    private(set) var selectedConfidence: Float = 0
    private(set) var compositionType: CompositionTechnique = .centered
    private(set) var kind: ShotCompositionKind = .environmental
    private(set) var qualityScore: Double = 0
    private(set) var selectionReason: String = ""
    private(set) var imageGeometry: ShotImageGeometry? = nil
    private(set) var sceneAnchor = false
    var desiredScale: Double { targetZoom / startingZoom }
    var requiresZoom: Bool { desiredScale > 1.12 }
    var desiredPosition: UnitPoint2D { .init(x:desiredBounds.midX,y:desiredBounds.midY) }
    func scaleForCurrentBounds(_ bounds:CGRect) -> Double {
        guard Self.valid(bounds) else { return desiredScale }
        return max(1,min(Double(desiredBounds.width/bounds.width),Double(desiredBounds.height/bounds.height)))
    }
    func aimingTarget(bounds:CGRect) -> UnitPoint2D {
        let scale = scaleForCurrentBounds(bounds)
        return .init(x:0.5+(desiredPosition.x-0.5)/scale,y:0.5+(desiredPosition.y-0.5)/scale)
    }
    func currentTargetRectangle(bounds:CGRect,zoom:Double) -> CGRect? {
        guard zoom.isFinite, zoom > 0 else { return nil }
        return TargetRectangleGeometry.crop(subject:bounds,position:desiredPosition,scale:scaleForCurrentBounds(bounds))
    }
    func error(bounds:CGRect,zoom:Double,aspect:Double) -> ShotFramingError {
        .init(position:hypot(Double(bounds.midX-desiredBounds.midX),Double(bounds.midY-desiredBounds.midY)/max(0.1,aspect)),
            width:abs(Double(bounds.width/desiredBounds.width)-1),height:abs(Double(bounds.height/desiredBounds.height)-1),
            zoom:abs(zoom/targetZoom-1))
    }
    /// Plan a specific photograph before aiming. No camera command or still capture.
    static func propose(bounds:CGRect,label:String,confidence:Float,trackingReference:String?,composition:SceneCompositionPlan,
                        currentZoom:Double,maximumZoom:Double,detailLimit:Double,nativeStops:[Double],
                        regions:[CGRect],anatomy:SubjectAnatomy?,projection:PreviewProjection) -> Self? {
        let scale = composition.selected.zoomScale
        guard confidence.isFinite, confidence >= 0.65, valid(bounds), currentZoom.isFinite, currentZoom > 0,
              composition.permitsZoom || composition.selected.isCurrentFrame,
              let crop = TargetRectangleGeometry.crop(subject:bounds,position:composition.target,scale:scale),
              TargetRectangleGeometry.contains(CGRect(x:0,y:0,width:1,height:1),crop),
              FramingPlanner.availableScales(currentZoom:currentZoom,maximumZoom:maximumZoom,detailZoomLimit:detailLimit,
                nativeStops:nativeStops,maximumScale:scale,desiredScale:scale).contains(where:{ abs($0-scale) < 0.001 }) else { return nil }
        let desired = TargetRectangleGeometry.relative(bounds,in:crop)
        var body = anatomy?.face.map { [$0] } ?? []
        body += (anatomy?.joints ?? []).map { CGRect(x:$0.x-0.004,y:$0.y-0.004,width:0.008,height:0.008) }
        guard safe(desired), (regions+body).allSatisfy({ valid($0) && safe(TargetRectangleGeometry.relative($0,in:crop)) }) else { return nil }
        var shot = Self(subjectLabel:label,initialBounds:bounds,desiredBounds:desired,framingRectangle:crop,
            startingZoom:currentZoom,targetZoom:currentZoom*scale,maximumZoom:maximumZoom,
            protectedRegions:regions,subjectRegions:body,observedHead:anatomy?.face)
        shot.id = composition.id; shot.trackingReference = trackingReference; shot.selectedConfidence = confidence
        shot.compositionType = composition.selected.technique; shot.kind = composition.selected.kind ?? (scale > 1 ? .subjectPortrait : .environmental)
        shot.qualityScore = composition.selected.score; shot.selectionReason = composition.selected.explanation
        shot.imageGeometry = .init(subject:projection.imageRect(bounds),composition:projection.imageRect(crop),
            imageAspect:projection.imageAspect,previewAspect:projection.previewAspect,mirrored:projection.mirrored)
        return shot
    }
    /// Rebase only the execution origin after the user aims. Identity, intended
    /// final bounds, score and rationale remain the same selected photograph.
    func prepared(bounds:CGRect,zoom:Double,detailLimit:Double,nativeStops:[Double],regions:[CGRect],anatomy:SubjectAnatomy?,aspect:Double) -> Self? {
        let scale = scaleForCurrentBounds(bounds)
        let final = FramingPlanner.zoomedRect(bounds,scale:scale)
        guard requiresZoom, scale > 1.12, Self.safe(final),
              FramingPlanner.availableScales(currentZoom:zoom,maximumZoom:maximumZoom,detailZoomLimit:detailLimit,nativeStops:nativeStops,
                maximumScale:scale,desiredScale:scale).contains(where:{ abs($0-scale) < 0.001 }),
              hypot(Double(final.midX-desiredBounds.midX),Double(final.midY-desiredBounds.midY)/max(0.1,aspect)) <= 0.05,
              abs(Double(final.width/desiredBounds.width)-1) <= 0.08, abs(Double(final.height/desiredBounds.height)-1) <= 0.08 else { return nil }
        var shot = self
        shot.initialBounds = bounds; shot.startingZoom = zoom; shot.targetZoom = zoom*scale
        shot.framingRectangle = CGRect(x:(1-1/scale)/2,y:(1-1/scale)/2,width:1/scale,height:1/scale)
        shot.protectedRegions = regions
        shot.subjectRegions = (anatomy?.face.map { [$0] } ?? []) + (anatomy?.joints ?? []).map { CGRect(x:$0.x-0.004,y:$0.y-0.004,width:0.008,height:0.008) }
        shot.observedHead = anatomy?.face
        guard (shot.protectedRegions+shot.subjectRegions).allSatisfy({ Self.valid($0) && Self.safe(FramingPlanner.zoomedRect($0,scale:scale)) }) else { return nil }
        return shot
    }

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
        guard Self.valid(bounds), observedHead != nil || !subjectRegions.isEmpty else { return nil }
        func tracked(_ region:CGRect) -> CGRect {
            CGRect(x:bounds.minX+(region.minX-initialBounds.minX)*bounds.width/initialBounds.width,
                y:bounds.minY+(region.minY-initialBounds.minY)*bounds.height/initialBounds.height,
                width:region.width*bounds.width/initialBounds.width,height:region.height*bounds.height/initialBounds.height)
        }
        let head = observedHead.map(tracked)
        let joints = subjectRegions.filter { $0 != observedHead }.map { tracked($0) }.map { CGPoint(x:$0.midX,y:$0.midY) }
        // Affine tracking of actually observed features, not new pose/eye inference.
        return .init(face:head,joints:joints,timestamp:timestamp)
    }
    static func scene(label:String,evidence:SceneCompositionEvidence,zoom:Double,projection:PreviewProjection) -> Self {
        let full = CGRect(x:0,y:0,width:1,height:1)
        var shot = Self(subjectLabel:label,initialBounds:full,desiredBounds:full,framingRectangle:full,
            startingZoom:zoom,targetZoom:zoom,maximumZoom:zoom,protectedRegions:[],subjectRegions:[],observedHead:nil)
        shot.sceneAnchor = true; shot.kind = .scenic; shot.qualityScore = 1-evidence.region(full).clipping
        shot.compositionType = evidence.lines.contains { $0.length > 0.45 } ? .leadingLines : .horizon
        shot.selectionReason = "Preserve the observed wide scene; no tighter tracked subject selected"
        shot.imageGeometry = .init(subject:projection.imageRect(full),composition:projection.imageRect(full),imageAspect:projection.imageAspect,
            previewAspect:projection.previewAspect,mirrored:projection.mirrored)
        return shot
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
        guard Self.valid(bounds), previewAspect.isFinite, previewAspect > 0, zoom.isFinite else { return false }
        return error(bounds:bounds,zoom:zoom,aspect:previewAspect).complete
    }
    static func valid(_ rect:CGRect) -> Bool {
        !rect.isNull && [rect.minX,rect.minY,rect.width,rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }
    static func safe(_ rect:CGRect) -> Bool { valid(rect) && TargetRectangleGeometry.contains(CGRect(x:0.018,y:0.018,width:0.964,height:0.964),rect) }
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
