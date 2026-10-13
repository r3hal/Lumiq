import XCTest
@testable import Focal

final class IntelligenceBaselineTests: XCTestCase {
    func testBaselineDemandsStepBackForContainedCatWithSixPercentMargins() {
        var baseline = BaselineGuidance21()
        let box = CGRect(x:0.06,y:0.2,width:0.88,height:0.6)
        let reading = CompositionReading(state:.ready,subject:.init(x:0.5,y:0.5),subjectBounds:box,subjectConfidence:0.95,target:.init(x:0.5,y:0.5))
        for time in [0.0,0.5,1.2] {
            _ = baseline.update(reading:reading,phase:.off,stable:true,rollReliable:true,autoEnabled:false,zoomAvailable:false,timestamp:time,subjectLabel:"Cat")
        }
        let old = baseline.update(reading:reading,phase:.off,stable:true,rollReliable:true,autoEnabled:false,zoomAvailable:false,timestamp:1.3,subjectLabel:"Cat")
        XCTAssertEqual(old.kind,.adjustment)
        XCTAssertTrue(old.text.contains("Step back"))
        XCTAssertTrue(CGRect(x:0,y:0,width:1,height:1).contains(box))
    }
    func testBaselineOffersCatPoseTipWithoutAnyObservedPose() {
        var baseline = BaselineGuidance21()
        let reading = CompositionReading(state:.ready,subject:.init(x:0.5,y:0.5),subjectBounds:CGRect(x:0.25,y:0.25,width:0.5,height:0.5),subjectConfidence:0.95,target:.init(x:0.5,y:0.5))
        for time in [0.0,0.5,1.2] {
            _ = baseline.update(reading:reading,phase:.off,stable:true,rollReliable:true,autoEnabled:false,zoomAvailable:false,timestamp:time,subjectLabel:"Cat")
        }
        let old = baseline.update(reading:reading,phase:.off,stable:true,rollReliable:true,autoEnabled:false,zoomAvailable:false,timestamp:1.3,subjectLabel:"Cat")
        XCTAssertTrue(old.text.contains("eye level"))
    }
    func testConfidentCatOnTexturedBedNoLongerFailsSelectionBecauseOfTexture() throws {
        let cat = SubjectCandidate(bounds:CGRect(x:0.3,y:0.3,width:0.4,height:0.4),confidence:0.95,category:.pet,label:"Cat",
            classificationConfidence:0.95,prominence:0.05,isolation:0,detail:0.06,textureDensity:0.95)
        let threshold = SubjectSelectionConfiguration().threshold
        XCTAssertLessThan(try XCTUnwrap(cat.baselineScore21(configuration:.init())),threshold)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(cat.score(configuration:.init())),threshold)
    }
}
