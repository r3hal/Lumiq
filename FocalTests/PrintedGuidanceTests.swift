import XCTest
@testable import Focal

final class PrintedGuidanceTests: XCTestCase {
    func testCardTitleIsGroundedInsideItsDetectedRegion() throws {
        let box = CGRect(x: 0.1, y: 0.3, width: 0.7, height: 0.4)
        let title = PrintedTextLine(text: "BELOT", confidence: 0.95, bounds: CGRect(x: 0.2, y: 0.4, width: 0.4, height: 0.1))
        XCTAssertEqual(try XCTUnwrap(PrintedSubjectEvidence.identify([title], inside: box)).name, "Belot cards")
        XCTAssertNil(PrintedSubjectEvidence.identify([title], inside: CGRect(x: 0.8, y: 0, width: 0.2, height: 0.2)))
    }
    func testUnreadableRepeatingAndGenericTextCannotCreateIdentity() {
        for text in ["JJJ", "123", "object", "", "A"] {
            let line = PrintedTextLine(text: text, confidence: 0.99, bounds: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.1))
            XCTAssertNil(PrintedSubjectEvidence.identify([line], inside: CGRect(x: 0, y: 0, width: 1, height: 1)))
        }
        let weak = PrintedTextLine(text: "BELOT", confidence: 0.2, bounds: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.1))
        XCTAssertNil(PrintedSubjectEvidence.identify([weak], inside: CGRect(x: 0, y: 0, width: 1, height: 1)))
    }
    func testUnknownPrintedTitleDoesNotInventProductType() throws {
        let line = PrintedTextLine(text: "SOLSTICE", confidence: 0.9, bounds: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.1))
        let identity = try XCTUnwrap(PrintedSubjectEvidence.identify([line], inside: CGRect(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertEqual(identity.name, "“SOLSTICE” print"); XCTAssertFalse(identity.namesCards)
    }
    func testSynonymsAndBroadLabelsDoNotHideSpecificCropRecognition() {
        XCTAssertEqual(SubjectIdentity.recognized([("Furniture", 0.9), ("Book", 0.65), ("Keyboard", 0.1)])?.name, "Book")
        XCTAssertEqual(SubjectIdentity.recognized([("Keyboard", 0.55), ("Keypad", 0.52), ("Book", 0.1)])?.name, "Computer keyboard")
        XCTAssertNil(SubjectIdentity.recognized([("Keyboard", 0.55), ("Book", 0.5)]))
    }
    func testLegiblePrintedDetailIsNotRejectedAsAnonymousTexture() throws {
        let box = SubjectCandidate(bounds: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3), confidence: 0.9, category: .object,
            label: "Belot cards", classificationConfidence: 0.9, textConfidence: 0.9, prominence: 0.7, isolation: 0.05, detail: 0.05, textureDensity: 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(box.score(configuration: .init())), 0.68)
        var selector = SubjectSelector()
        XCTAssertNil(selector.select([box], timestamp: 0)); XCTAssertNil(selector.select([box], timestamp: 0.75))
        XCTAssertEqual(selector.select([box], timestamp: 1.5), 0)
    }
    func testSubjectExposureDoesNotConfuseDarkBackgroundWithDarkSubject() throws {
        var luma = [Double](repeating: 0, count: 16 * 16)
        for y in 4..<12 { for x in 4..<12 { luma[y * 16 + x] = 0.8 } }
        let whole = try XCTUnwrap(PhotoMeasurements.from(luma: luma, width: 16, height: 16))
        let subject = try XCTUnwrap(PhotoMeasurements.subjectOnly(luma: luma, width: 16, height: 16, region: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
        XCTAssertNotNil(whole.lightingAdvice); XCTAssertNil(subject.lightingAdvice)
        XCTAssertEqual(subject.brightness, 0.8, accuracy: 0.001)
    }
    func testAlignedCompositionRetainsMeasuredLightWarningWithoutBlockingPlacement() {
        var guide = AutomaticGuidance()
        let reading = CompositionReading(state: .ready, subject: .init(x: 0.5, y: 0.5), subjectBounds: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), subjectConfidence: 0.9, target: .init(x: 0.5, y: 0.5))
        let dark = PhotoMeasurements(brightness: 0.1, shadowFraction: 0.8, highlightFraction: 0, detail: 0.05, backgroundEdges: nil)
        func step(_ time: Double) -> GuidanceMessage {
            guide.update(reading: reading, phase: .off, stable: true, rollReliable: false, autoEnabled: false, zoomAvailable: false, timestamp: time,
                subjectLabel: "Belot cards", subjectMeasurements: dark)
        }
        _ = step(0); _ = step(0.5)
        XCTAssertEqual(step(1.2).kind, .ready); XCTAssertTrue(step(1.3).text.contains("soft light"))
    }
    func testPanInstructionTakesPriorityOverLightingWhenSubjectIsOffTarget() {
        var guide = AutomaticGuidance()
        let reading = CompositionReading(state: .adjusting, subjectBounds: CGRect(x: 0.65, y: 0.4, width: 0.2, height: 0.2), subjectConfidence: 0.9, target: .init(x: 0.5, y: 0.5))
        let dark = PhotoMeasurements(brightness: 0.1, shadowFraction: 0.8, highlightFraction: 0, detail: 0.05, backgroundEdges: nil)
        for time in [0.0, 0.5, 1.2] {
            _ = guide.update(reading: reading, phase: .off, stable: true, rollReliable: false, autoEnabled: false, zoomAvailable: false, timestamp: time, subjectLabel: "Belot cards", subjectMeasurements: dark)
        }
        XCTAssertTrue(guide.update(reading: reading, phase: .off, stable: true, rollReliable: false, autoEnabled: false, zoomAvailable: false, timestamp: 1.3, subjectLabel: "Belot cards", subjectMeasurements: dark).text.contains("Pan right"))
    }
}
