import XCTest
@testable import Focal

/// The recordings supply the observed sequence, not sensor telemetry or exact boxes.
/// Geometry below is a controlled regression fixture, not measurements extracted from video.
final class FramingVideoRegressionTests: XCTestCase {
    private let subject = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
    private func scene() -> SceneCompositionPlan {
        .init(selected:.init(technique:.fillFrame,target:.init(x:0.5,y:0.5),crop:CGRect(x:0.25,y:0.25,width:0.5,height:0.5),
            score:0.9,explanation:"Measured tighter pet portrait",zoomScale:2,measuredImprovement:0.15),alternatives:[],subjectLabel:"Cat",timestamp:0)
    }
    private func shot() throws -> AutomaticShotPlan {
        try XCTUnwrap(AutomaticShotPlan.make(bounds:subject,label:"Cat",composition:scene(),currentZoom:1.8,
            maximumZoom:5,detailLimit:4,nativeStops:[1,5],regions:[],anatomy:nil,previewAspect:0.75))
    }
    private func ramp() throws -> (FramingPlanner,AutomaticShotPlan) {
        var planner = FramingPlanner(); let shot = try shot()
        for time in [0.0,1.0] {
            _ = planner.update(bounds:subject,confidence:0.95,roll:0,timestamp:time,currentZoom:1.8,maximumZoom:5,
                detailZoomLimit:4,holdDuration:0.75,plannedScale:2,zoomDestination:.init(x:0.5,y:0.5),requiresShotPlan:true)
        }
        planner.commitShot(shot)
        return (planner,shot)
    }
    func testCatAtOnePointEightStartsTighterZoomAfterAlignment() {
        var planner = FramingPlanner(); var requested:Double?
        for i in 0...5 {
            requested = planner.update(bounds:subject,confidence:0.95,roll:0,timestamp:Double(i)*0.25,currentZoom:1.8,maximumZoom:5,
                detailZoomLimit:4,plannedScale:2,zoomDestination:.init(x:0.5,y:0.5),requiresShotPlan:true) ?? requested
        }
        XCTAssertEqual(requested ?? 0,3.6,accuracy:0.0001)
        XCTAssertEqual(planner.phase,.zooming)
        XCTAssertFalse(planner.shotVerified)
    }
    func testSmallCatMovementInsideAlignmentDoesNotRestartHoldForever() {
        var planner = FramingPlanner(); var requested:Double?
        for i in 0...12 {
            let box = subject.offsetBy(dx:i.isMultiple(of:2) ? -0.02 : 0.02,dy:0)
            requested = planner.update(bounds:box,confidence:0.95,roll:0,timestamp:Double(i)*0.25,currentZoom:1.8,maximumZoom:5,
                detailZoomLimit:4,plannedScale:2,zoomDestination:.init(x:0.5,y:0.5),requiresShotPlan:true) ?? requested
        }
        XCTAssertNotNil(requested,"A moving cat inside the alignment envelope is not a shaking phone")
    }
    func testOneMissingTrackingFrameDoesNotDiscardSelectedShot() throws {
        var (planner,shot) = try ramp()
        let result = planner.verifyShot(bounds:nil,label:"Cat",confidence:0,zoom:2.1,stable:true,fresh:true,timestamp:1.2,previewAspect:0.75)
        XCTAssertNotEqual(result,.cancel)
        XCTAssertEqual(planner.shotPlan?.id,shot.id)
        XCTAssertFalse(planner.shotVerified)
    }
}
