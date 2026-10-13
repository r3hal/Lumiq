import XCTest
@testable import Focal

final class SubjectIdentityTests: XCTestCase {
    func testGenericRegionsNeverBecomeNamedSubjects() {
        for name in ["object", "Structure", "subject", "furniture", "wall", "room", "", "unknown"] {
            XCTAssertNil(SubjectIdentity.name(name))
            XCTAssertNil(SubjectIdentity.recognized([(name, 0.99)]))
        }
        XCTAssertEqual(SubjectIdentity.name("computer_keyboard, keypad"), "Computer keyboard")
        XCTAssertEqual(SubjectIdentity.name("coffee mug"), "Coffee mug")
    }
    func testAmbiguousCropDoesNotInventAnIdentity() {
        XCTAssertNil(SubjectIdentity.recognized([("Keyboard", 0.45), ("Desk", 0.4)]))
        XCTAssertNil(SubjectIdentity.recognized([("Keyboard", 0.65), ("Desk", 0.62)]))
        XCTAssertEqual(SubjectIdentity.recognized([("Keyboard", 0.8), ("Desk", 0.1)])?.name, "Computer keyboard")
    }
    func testIdentityMustPersistAlongWithTheBoundary() {
        var selector = SubjectSelector()
        var candidate = SubjectCandidate(bounds: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3), confidence: 0.9,
            category: .object, label: "Keyboard", classificationConfidence: 0.9, prominence: 0.8, isolation: 0.5, detail: 0.03)
        XCTAssertNil(selector.select([candidate], timestamp: 0))
        candidate.label = "Desk"
        XCTAssertNil(selector.select([candidate], timestamp: 0.7))
        XCTAssertNil(selector.select([candidate], timestamp: 1.4))
        XCTAssertEqual(selector.select([candidate], timestamp: 2.1), 0)
    }
    func testNamedLowContrastProductAndPersonCanBeSelected() throws {
        var candidate = SubjectCandidate(bounds: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3), confidence: 0.9,
            category: .object, label: "Coffee mug", classificationConfidence: 0.85, prominence: 0.6, isolation: 0.2, detail: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(candidate.score(configuration: .init())), 0.68)
        candidate.label = "Structure"
        XCTAssertNil(candidate.score(configuration: .init()))
        candidate.category = .person; candidate.label = "Person"; candidate.prominence = 0; candidate.isolation = 0
        XCTAssertGreaterThan(try XCTUnwrap(candidate.score(configuration: .init())), 0.68)
    }
    func testLineAndTextUseCorrectPanSignsAcrossBothAspectRatios() throws {
        for aspect in [0.75, 1.5] {
            for position in [(0.8, 0.5, "right"), (0.2, 0.5, "left"), (0.5, 0.8, "down"), (0.5, 0.2, "up")] {
                let reading = CompositionReading(subjectBounds: CGRect(x: position.0 - 0.1, y: position.1 - 0.1, width: 0.2, height: 0.2), subjectConfidence: 0.9, target: .init(x: 0.5, y: 0.5))
                let cue = try XCTUnwrap(CompositionCue(reading: reading, previewAspect: aspect))
                XCTAssertFalse(cue.aligned); XCTAssertEqual(cue.direction, position.2)
                XCTAssertTrue(cue.instruction(subjectName: "Keyboard").contains("keyboard"))
                XCTAssertEqual(cue.target, reading.target)
            }
        }
    }
    func testNoDirectionLineWithoutRealConfidentBounds() {
        XCTAssertNil(CompositionCue(reading: .init(), previewAspect: 1.5))
        let weak = CompositionReading(subjectBounds: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3), subjectConfidence: 0.2)
        XCTAssertNil(CompositionCue(reading: weak, previewAspect: 0.75))
    }
    func testGuidanceUsesRecognizedSubjectAndRetainsDwell() {
        var guide = AutomaticGuidance()
        let reading = CompositionReading(state: .adjusting, subject: .init(x: 0.75, y: 0.5), subjectBounds: CGRect(x: 0.65, y: 0.4, width: 0.2, height: 0.2), subjectConfidence: 0.9, target: .init(x: 0.5, y: 0.5))
        func step(_ time: Double) -> GuidanceMessage {
            guide.update(reading: reading, phase: .off, stable: true, rollReliable: false, autoEnabled: false, zoomAvailable: false, timestamp: time, previewAspect: 1.5, subjectLabel: "Keyboard")
        }
        XCTAssertEqual(step(0).text, "Keyboard detected")
        _ = step(0.5)
        XCTAssertEqual(step(1.2).text, "Pan right · place the keyboard on the mark")
    }
}
