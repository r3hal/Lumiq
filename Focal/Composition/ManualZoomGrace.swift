import Foundation

/// Camera-queue policy. Manual framing suspends the motor, never the AI session.
struct ManualZoomGrace {
    static let duration:TimeInterval = 3
    private(set) var active = false
    private(set) var resumeAt:TimeInterval = 0
    private(set) var revision = 0
    mutating func begin(at time:TimeInterval) { active = true; changed(at:time) }
    mutating func changed(at time:TimeInterval) {
        guard time.isFinite else { return }
        revision += 1; resumeAt = max(resumeAt,time+Self.duration)
    }
    mutating func end(at time:TimeInterval) { active = false; changed(at:time) }
    mutating func reset() { self = Self(revision:revision+1) }
    func permitsAutomaticZoom(at time:TimeInterval) -> Bool { time.isFinite && !active && time >= resumeAt }
    static func trackedBounds(_ bounds:CGRect,from oldZoom:Double,to newZoom:Double) -> CGRect? {
        guard oldZoom.isFinite,newZoom.isFinite,oldZoom > 0,newZoom > 0,
              [bounds.minX,bounds.minY,bounds.width,bounds.height].allSatisfy(\.isFinite),
              bounds.width > 0,bounds.height > 0 else { return nil }
        let result = FramingPlanner.zoomedRect(bounds,scale:newZoom/oldZoom).intersection(CGRect(x:0,y:0,width:1,height:1))
        guard !result.isNull,result.width > 0.015,result.height > 0.015 else { return nil }
        return result
    }
}
