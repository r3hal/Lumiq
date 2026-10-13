import XCTest
@testable import Focal

final class SubjectSelectionTests: XCTestCase {
    private func candidate(_ category: SubjectCategory = .object, confidence: Double = 0.9,
                           bounds: CGRect = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)) -> SubjectCandidate {
        SubjectCandidate(bounds: bounds, confidence: confidence, category: category, label: "Test subject",
                         classificationConfidence: 0.75, prominence: 0.9, isolation: 0.9, detail: 0.08, textureDensity: 0)
    }
    func testWallAndEmptySceneDoNotForceSelection() {
        var selector = SubjectSelector()
        var wall = candidate(.background, bounds: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9))
        wall.isolation = 0.02; wall.detail = 0.002; wall.prominence = 0.15
        for time in [0.0, 0.75, 1.5, 2.25] {
            XCTAssertNil(selector.select([wall], timestamp: time))
            XCTAssertNil(selector.select([], timestamp: time))
        }
    }
    func testPersonAndPetGenerallyOutrankBackgroundFurniture() throws {
        var furniture = candidate(.background); furniture.isolation = 0.3; furniture.classificationConfidence = 0.9
        let person = candidate(.person, bounds: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3))
        let pet = candidate(.pet, bounds: CGRect(x: 0.2, y: 0.4, width: 0.2, height: 0.2))
        XCTAssertNil(furniture.score(configuration: SubjectSelectionConfiguration()))
        var selector = SubjectSelector()
        XCTAssertNil(selector.select([furniture, person], timestamp: 0))
        XCTAssertEqual(selector.select([furniture, person], timestamp: 0.75), 1)
        selector.reset()
        XCTAssertNil(selector.select([furniture, pet], timestamp: 1))
        XCTAssertEqual(selector.select([furniture, pet], timestamp: 1.75), 1)
    }
    func testIsolatedProductRequiresSustainedEvidence() {
        var selector = SubjectSelector()
        let product = candidate()
        XCTAssertNil(selector.select([product], timestamp: 0))
        XCTAssertNil(selector.select([product], timestamp: 0.75))
        XCTAssertEqual(selector.select([product], timestamp: 1.5), 0)
    }
    func testSingleObservationAndLongGapCannotCreateTemporalConfidence() {
        var selector = SubjectSelector()
        XCTAssertNil(selector.select([candidate()], timestamp: 0))
        XCTAssertNil(selector.select([candidate()], timestamp: 10))
        XCTAssertNil(selector.select([candidate()], timestamp: 10.75))
    }
    func testTinyUncertainAndInvalidRegionsAreRejected() {
        let low = candidate(.person, confidence: 0.2)
        let tiny = candidate(.pet, bounds: CGRect(x: 0.4, y: 0.4, width: 0.02, height: 0.02))
        let invalid = candidate(bounds: CGRect(x: -0.1, y: 0.4, width: 0.2, height: 0.2))
        var selector = SubjectSelector()
        for time in [0.0, 1.0, 2.0] { XCTAssertNil(selector.select([low, tiny, invalid], timestamp: time)) }
    }
    func testArchitectureCanBeAnIntentionalSubject() {
        var selector = SubjectSelector()
        var architecture = candidate(.architecture, bounds: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        architecture.isolation = 0.3; architecture.classificationConfidence = 0.9
        XCTAssertNil(selector.select([architecture], timestamp: 0))
        XCTAssertNil(selector.select([architecture], timestamp: 0.75))
        XCTAssertEqual(selector.select([architecture], timestamp: 1.5), 0)
    }
    func testLandscapeIsSceneContextWithoutInventedObjectBox() {
        var selector = SubjectSelector()
        let landscape = candidate(.landscape)
        XCTAssertNil(selector.select([landscape], timestamp: 0))
        XCTAssertNil(selector.select([landscape], timestamp: 0.75))
        XCTAssertNil(selector.select([landscape], timestamp: 1.5))
        XCTAssertTrue(SubjectScene(label: "Mountain landscape", confidence: 0.9, timestamp: 0).isLandscape)
    }
    func testManualTapRespectsRealBackgroundBoundaryAndCannotInventOne() {
        var selector = SubjectSelector()
        var background = candidate(.background); background.isolation = 0.2; background.prominence = 0.4
        let point = CGPoint(x: 0.5, y: 0.5)
        XCTAssertNil(background.score(configuration: selector.configuration))
        XCTAssertEqual(selector.select([background], timestamp: 0, manualPoint: point), 0)
        XCTAssertNil(selector.select([background], timestamp: 1, manualPoint: CGPoint(x: 0.05, y: 0.05)))
        XCTAssertNil(selector.select([], timestamp: 2, manualPoint: point))
    }
    func testManualIntentTakesPriorityOverStrongerAutomaticCandidate() {
        var selector = SubjectSelector()
        let person = candidate(.person, bounds: CGRect(x: 0.05, y: 0.35, width: 0.2, height: 0.3))
        var background = candidate(.background); background.isolation = 0.2
        XCTAssertEqual(selector.select([person, background], timestamp: 0, current: person, manualPoint: CGPoint(x: 0.5, y: 0.5)), 1)
    }
    func testMinorScoreChangesDoNotSwitchHealthyTracking() {
        var selector = SubjectSelector()
        let current = candidate(.person)
        let challenger = candidate(.person, bounds: CGRect(x: 0.65, y: 0.35, width: 0.3, height: 0.3))
        for time in [0.0, 0.75, 1.5, 2.25] { XCTAssertNil(selector.select([challenger], timestamp: time, current: current)) }
    }
    func testSubstantiallyStrongerChallengerMustPersist() {
        var selector = SubjectSelector()
        var current = candidate(confidence: 0.75); current.prominence = 0.8; current.classificationConfidence = 0.65
        var challenger = candidate(.person, confidence: 1, bounds: CGRect(x: 0.05, y: 0.35, width: 0.2, height: 0.3))
        challenger.isolation = 1; challenger.prominence = 1; challenger.classificationConfidence = 1
        XCTAssertNil(selector.select([challenger], timestamp: 0, current: current))
        XCTAssertNil(selector.select([challenger], timestamp: 0.75, current: current))
        XCTAssertEqual(selector.select([challenger], timestamp: 1.6, current: current), 0)
    }
    func testSelectivityThresholdIsConfigurable() throws {
        var selector = SubjectSelector()
        let product = candidate()
        let score = try XCTUnwrap(product.score(configuration: selector.configuration))
        selector.configuration.threshold = min(1, score + 0.01)
        for time in [0.0, 0.75, 1.5] { XCTAssertNil(selector.select([product], timestamp: time)) }
        selector.configuration.threshold = score - 0.01
        XCTAssertNil(selector.select([product], timestamp: 2.25))
        XCTAssertNil(selector.select([product], timestamp: 3))
        XCTAssertEqual(selector.select([product], timestamp: 3.75), 0)
    }
    func testDenseTextureDoesNotBecomeAutomaticPhotographicIntent() {
        var texture = candidate(); texture.textureDensity = 1
        var selector = SubjectSelector()
        for time in [0.0, 0.75, 1.5] { XCTAssertNil(selector.select([texture], timestamp: time)) }
    }
    func testImageEvidenceDistinguishesPlainWallFromIsolatedProduct() {
        let flat = SubjectImageEvidence.Pixel(red: 0.7, green: 0.7, blue: 0.7)
        let rect = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        var pixels = [SubjectImageEvidence.Pixel](repeating: flat, count: 64 * 64)
        let wall = SubjectImageEvidence(pixels: pixels, width: 64, height: 64).features(for: rect, saliencyProminence: nil)
        XCTAssertEqual(wall.isolation, 0, accuracy: 0.001); XCTAssertEqual(wall.detail, 0, accuracy: 0.001)
        for y in 23...41 { for x in 23...41 { pixels[y * 64 + x] = .init(red: 1, green: 0.05, blue: 0.05) } }
        let product = SubjectImageEvidence(pixels: pixels, width: 64, height: 64).features(for: rect, saliencyProminence: 0.9)
        XCTAssertGreaterThan(product.isolation, 0.45); XCTAssertGreaterThan(product.prominence, 0.45)
        XCTAssertGreaterThan(product.detail, wall.detail)
    }
    func testOneWeakTrackingFrameDoesNotDiscardSelectionButLossDoes() {
        var health = SubjectTrackingHealth()
        XCTAssertFalse(health.lost(reliable: false, timestamp: 0))
        XCTAssertFalse(health.lost(reliable: true, timestamp: 0.2))
        XCTAssertFalse(health.lost(reliable: false, timestamp: 1))
        XCTAssertFalse(health.lost(reliable: false, timestamp: 1.2))
        XCTAssertTrue(health.lost(reliable: false, timestamp: 1.4))
    }
    func testOffOnAndSourceChangesRejectStaleInferenceResults() {
        var activation = GuidanceActivation()
        XCTAssertFalse(activation.accepts(activation.snapshot))
        let first = activation.set(true)
        XCTAssertTrue(activation.accepts(first))
        _ = activation.set(false); XCTAssertFalse(activation.accepts(first))
        let second = activation.set(true); XCTAssertFalse(activation.accepts(first)); XCTAssertTrue(activation.accepts(second))
        let sony = activation.set(true, source: .sony)
        XCTAssertFalse(activation.accepts(second)); XCTAssertTrue(activation.accepts(sony)); XCTAssertEqual(sony.source, .sony)
    }
}
