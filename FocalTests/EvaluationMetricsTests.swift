import XCTest
@testable import Focal

final class EvaluationMetricsTests: XCTestCase {
    private func sample(_ time:Double = 0) -> EvaluationSample {
        var sample = EvaluationSample(id:UUID(),imageFile:"unused.jpg",imageSHA256:String(repeating:"0",count:64),provenance:"Synthetic unit test")
        sample.annotation.mainSubject = "Cat"; sample.annotation.reviewed = true
        sample.annotation.acceptableComposition = true; sample.annotation.preferredAction = GuidanceAction.none
        sample.annotation.sequenceID = "sequence"; sample.annotation.sequenceTime = time
        return sample
    }
    private func outcome(_ sample:EvaluationSample,_ action:GuidanceAction) -> EvaluationOutcome {
        let cat = AnalyzedSubject(label:"Cat",confidence:0.9,classificationConfidence:0.9,x:0.2,y:0.2,width:0.5,height:0.5)
        return .init(sampleID:sample.id,algorithm:"Test",selected:cat,detections:[cat],action:action,text:"Test",inferenceMilliseconds:nil,aestheticScore:nil,fitness:1)
    }
    func testEmptyDatasetMetricsAreUnavailableNotPerfect() {
        let metrics = EvaluationMetrics.calculate(samples:[],outcomes:[])
        XCTAssertNil(metrics.selectionAgreement.value); XCTAssertNil(metrics.meanInferenceMilliseconds)
        XCTAssertNil(metrics.contradictions.value)
    }
    func testUnreviewedImagesDoNotCreateBenchmarkDenominators() {
        var example = sample(); example.annotation.reviewed = false
        let metrics = EvaluationMetrics.calculate(samples:[example],outcomes:[outcome(example,.none)])
        XCTAssertEqual(metrics.selectionAgreement.denominator,0)
    }
    func testMetricsCountMissesAndUnnecessaryRecommendations() {
        let example = sample()
        let metrics = EvaluationMetrics.calculate(samples:[example],outcomes:[outcome(example,.makeRoom)])
        XCTAssertEqual(metrics.detectionAgreement.value,1)
        XCTAssertEqual(metrics.recommendationAgreement.value,0)
        XCTAssertEqual(metrics.unnecessaryRecommendations.value,1)
        XCTAssertNil(metrics.meanInferenceMilliseconds)
    }
    func testGroundTruthBoxIsUsedOnlyForAccuracyChecking() {
        var example = sample(); example.annotation.expectedBounds = EvaluationRect(CGRect(x:0.8,y:0.8,width:0.1,height:0.1))
        XCTAssertNil(example.annotation.manualSelection)
        let metrics = EvaluationMetrics.calculate(samples:[example],outcomes:[outcome(example,.none)])
        XCTAssertEqual(metrics.selectionAgreement.value,0)
    }
    func testOppositeDirectionsRequireGenuineOrderedSequencePairs() {
        let a = sample(0), b = sample(0.5)
        let metrics = EvaluationMetrics.calculate(samples:[a,b],outcomes:[outcome(a,.panRight),outcome(b,.panLeft)])
        XCTAssertEqual(metrics.contradictions.value,1)
        XCTAssertEqual(metrics.stability.value,0)
    }
    func testUnrelatedStillImagesDoNotMeasureStability() {
        var a = sample(),b = sample(); a.annotation.sequenceID = nil; b.annotation.sequenceID = nil
        let metrics = EvaluationMetrics.calculate(samples:[a,b],outcomes:[outcome(a,.panRight),outcome(b,.panLeft)])
        XCTAssertNil(metrics.contradictions.value); XCTAssertNil(metrics.stability.value)
    }
    func testDatasetAnnotationAndResultsRoundTripJSON() throws {
        let example = sample()
        let dataset = EvaluationDataset(samples:[example],report:nil)
        let decoded = try JSONDecoder().decode(EvaluationDataset.self,from:JSONEncoder().encode(dataset))
        XCTAssertEqual(decoded.samples[0].annotation,example.annotation)
        XCTAssertNil(decoded.report)
    }
    func testInvalidAndOutsideAnnotationBoxesAreRejected() {
        XCTAssertFalse(EvaluationRect(CGRect(x:-0.1,y:0,width:0.3,height:0.3)).valid)
        XCTAssertFalse(EvaluationRect(.zero).valid)
        XCTAssertTrue(EvaluationRect(CGRect(x:0.2,y:0.2,width:0.5,height:0.5)).valid)
    }
    func testRealBundledLandscapeHasReviewedReferenceWithoutInventedBenchmarkResults() throws {
        let path = Bundle.main.url(forResource:"IntelligenceSeed",withExtension:"json")
        let url = try XCTUnwrap(path)
        let object = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]
        XCTAssertEqual(object?["source"] as? String,"Unsplash photo-1476514525535-07fb3b4ae5f1")
        XCTAssertEqual(object?["intent"] as? String,"Landscape")
        XCTAssertEqual(object?["noObjectBoxNeeded"] as? Bool,true)
        XCTAssertNil(object?["benchmarkAccuracy"])
    }
}
