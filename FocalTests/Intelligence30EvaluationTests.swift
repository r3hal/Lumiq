import XCTest
@testable import Focal

final class Intelligence30EvaluationTests: XCTestCase {
    func testStaticZoomMetricRequiresHumanLabelsAndDoesNotPretendToMeasureRamps() {
        let id = UUID()
        var sample = EvaluationSample(id:id,imageFile:"test.jpg",imageSHA256:"test",provenance:"unit fixture")
        sample.annotation.reviewed = true
        let proposal = EvaluationOutcome(sampleID:id,algorithm:"Focal Intelligence 3.0",selected:nil,detections:[],action:.none,text:"Ready to shoot",inferenceMilliseconds:nil,aestheticScore:nil,fitness:nil,proposedZoomScale:2)
        XCTAssertNil(EvaluationMetrics.calculate(samples:[sample],outcomes:[proposal]).autoZoomMistakes)
        sample.annotation.automaticZoomAppropriate = false
        let metrics = EvaluationMetrics.calculate(samples:[sample],outcomes:[proposal])
        XCTAssertEqual(metrics.autoZoomMistakes?.numerator,1)
        XCTAssertEqual(metrics.autoZoomMistakes?.denominator,1)
        XCTAssertNil(metrics.meanInferenceMilliseconds)
    }
    func testOldEvaluationJSONCanStillBeDecoded() throws {
        let old = """
        {"detectionAgreement":{"numerator":0,"denominator":0},"selectionAgreement":{"numerator":0,"denominator":0},"recommendationAgreement":{"numerator":0,"denominator":0},"unnecessaryRecommendations":{"numerator":0,"denominator":0},"contradictions":{"numerator":0,"denominator":0},"stability":{"numerator":0,"denominator":0}}
        """
        let decoded = try JSONDecoder().decode(EvaluationMetrics.self,from:Data(old.utf8))
        XCTAssertNil(decoded.autoZoomMistakes)
        XCTAssertNil(decoded.meanSelectionOverlap)
    }
    func testFrozen22ReproducesOriginalWeakObservationInstruction() {
        var old = BaselineGuidance22(), new = AutomaticGuidance()
        let reading = CompositionReading(state:.ready,subjectBounds:CGRect(x:0.2,y:0.2,width:0.4,height:0.5),subjectConfidence:0.5)
        let previous = old.update(reading:reading,phase:.off,stable:true,rollReliable:false,autoEnabled:false,zoomAvailable:false,timestamp:0,subjectLabel:"Cat")
        let current = new.update(reading:reading,phase:.off,stable:true,rollReliable:false,autoEnabled:false,zoomAvailable:false,timestamp:0,subjectLabel:"Cat")
        XCTAssertEqual(previous.text,"Keep the selected subject visible")
        XCTAssertTrue(current.text.isEmpty)
    }
    func testArchitectureCanBeAssessedWithoutAnInventedObject() {
        var guide = AutomaticGuidance()
        let result = guide.update(reading:.init(),phase:.off,stable:true,rollReliable:false,autoEnabled:false,zoomAvailable:false,timestamp:0,intent:.architecture)
        XCTAssertEqual(result.kind,.scene)
        XCTAssertFalse(result.showsDirection)
        XCTAssertEqual(result.text,"Ready to shoot")
    }
}
