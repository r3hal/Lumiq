import XCTest
@testable import Focal

final class BroadSubjectGuidanceTests: XCTestCase {
    private func candidate(label: String = "Desk", confidence: Double = 0.3) -> SubjectCandidate {
        SubjectCandidate(bounds: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3), confidence: 0.9,
            category: SubjectCategory.classified(label), label: label, classificationConfidence: confidence,
            prominence: 0.7, isolation: 0.01, detail: 0.007, localizedProposal: true)
    }
    func testNormalHandMovementAllowsAcquisitionWithoutAllowingAutomaticZoomHold() {
        let rotation = (0.25, 0.1, 0.05), acceleration = (0.06, 0.02, 0.01)
        XCTAssertTrue(CameraStability.permitsDetection(rotation: rotation, acceleration: acceleration))
        XCTAssertFalse(CameraStability.isStable(rotation: rotation, acceleration: acceleration))
    }
    func testFastWhipPanOrInvalidMotionBlocksNewAcquisition() {
        XCTAssertFalse(CameraStability.permitsDetection(rotation: (2, 0, 0), acceleration: (0, 0, 0)))
        XCTAssertFalse(CameraStability.permitsDetection(rotation: (0, 0, 0), acceleration: (0.8, 0, 0)))
        XCTAssertFalse(CameraStability.permitsDetection(rotation: (.nan, 0, 0), acceleration: (0, 0, 0)))
    }
    func testModerateLocalizedDeskPredictionCanBeUsedButWholeFramePredictionCannot() {
        let predictions = [(identifier: "Desk", confidence: 0.32), (identifier: "Keyboard", confidence: 0.1)]
        XCTAssertEqual(SubjectIdentity.recognized(predictions, localized: true)?.name, "Desk")
        XCTAssertNil(SubjectIdentity.recognized(predictions))
    }
    func testLocalizedClassificationStillRejectsAmbiguityWeakAndGenericLabels() {
        XCTAssertNil(SubjectIdentity.recognized([("Desk", 0.32), ("Book", 0.3)], localized: true))
        XCTAssertNil(SubjectIdentity.recognized([("Tree", 0.2)], localized: true))
        XCTAssertNil(SubjectIdentity.recognized([("Furniture", 0.99), ("Room", 0.8)], localized: true))
        XCTAssertNil(SubjectIdentity.recognized([("Imaginary thing", 0.3)], localized: true))
    }
    func testFurnitureAndPlantAliasesRemainStableWithoutGuessingSpecies() {
        XCTAssertEqual(SubjectIdentity.recognized([("Writing desk", 0.4), ("Desk", 0.35)], localized: true)?.name, "Desk")
        XCTAssertEqual(SubjectIdentity.recognized([("Dining table", 0.4), ("Table", 0.35)], localized: true)?.name, "Table")
        XCTAssertEqual(SubjectIdentity.recognized([("Oak tree", 0.38), ("Pine tree", 0.35)], localized: true)?.name, "Tree")
        XCTAssertEqual(SubjectIdentity.recognized([("Houseplant", 0.4), ("Potted plant", 0.35)], localized: true)?.name, "Plant")
        XCTAssertEqual(SubjectCategory.classified("Tree"), .nature)
    }
    func testLowContrastDeskAndTableCanAcquireFromRepeatedRealProposals() throws {
        for label in ["Desk", "Table"] {
            let proposal = candidate(label: label)
            XCTAssertGreaterThan(try XCTUnwrap(proposal.score(configuration: .init())), 0.68)
            var selector = SubjectSelector()
            XCTAssertNil(selector.select([proposal], timestamp: 0))
            XCTAssertNil(selector.select([proposal], timestamp: 0.65))
            XCTAssertEqual(selector.select([proposal], timestamp: 1.3), 0)
        }
    }
    func testWeakLowContrastIdentityRequiresActualProposalEvidence() {
        var proposal = candidate(); proposal.localizedProposal = false
        XCTAssertNil(proposal.score(configuration: .init()))
    }
    func testNaturalTreeTextureIsNotTreatedAsAnonymousClutter() throws {
        var tree = candidate(label: "Tree"); tree.textureDensity = 0.95; tree.detail = 0.06
        XCTAssertGreaterThan(try XCTUnwrap(tree.score(configuration: .init())), 0.68)
        var selector = SubjectSelector()
        XCTAssertNil(selector.select([tree], timestamp: 0)); XCTAssertNil(selector.select([tree], timestamp: 0.65))
        XCTAssertEqual(selector.select([tree], timestamp: 1.3), 0)
    }
    func testForestSceneAndPlainWallDoNotBecomeFakeObjectBoxes() {
        for label in ["Forest", "Wall"] {
            var region = candidate(label: label, confidence: 0.95)
            region.prominence = 1; region.isolation = 1
            XCTAssertNil(region.score(configuration: .init()))
        }
    }
    func testNearbyBoundaryJitterCanAccumulateEvidenceButChangedIdentityCannot() {
        var first = candidate(confidence: 0.85); first.bounds = CGRect(x: 0.35, y: 0.35, width: 0.14, height: 0.14)
        first.isolation = 0.6; first.prominence = 0.9; first.detail = 0.03
        var next = first; next.bounds = first.bounds.offsetBy(dx: 0.038, dy: 0.038)
        XCTAssertFalse(first.matches(next)); XCTAssertTrue(first.continuesIdentity(next))
        var selector = SubjectSelector()
        XCTAssertNil(selector.select([first], timestamp: 0))
        XCTAssertNil(selector.select([next], timestamp: 0.65))
        XCTAssertEqual(selector.select([first], timestamp: 1.3), 0)
        next.label = "Chair"; XCTAssertFalse(first.continuesIdentity(next))
        next.label = first.label; next.bounds = first.bounds.offsetBy(dx: 0.5, dy: 0)
        XCTAssertFalse(first.continuesIdentity(next))
    }
    func testForegroundDeskCanReplacePeripheralPersonOnlyAfterDwell() throws {
        var desk = candidate(confidence: 0.65); desk.confidence = 0.98; desk.prominence = 0.9; desk.isolation = 0.5
        let person = SubjectCandidate(bounds: CGRect(x: 0.05, y: 0.25, width: 0.15, height: 0.3), confidence: 0.9,
            category: .person, label: "Person", classificationConfidence: 0.9, prominence: 0.65, isolation: 0.25, detail: 0.03)
        var selector = SubjectSelector()
        XCTAssertNil(selector.select([desk], timestamp: 0, current: person))
        XCTAssertNil(selector.select([desk], timestamp: 1.1, current: person))
        XCTAssertEqual(selector.select([desk], timestamp: 2.2, current: person), 0)
    }
    func testRelevantObjectTipsUseTheActualNoun() {
        XCTAssertTrue(SubjectIdentity.tip(for: "Desk").contains("surface"))
        XCTAssertTrue(SubjectIdentity.tip(for: "Tree").contains("trunk"))
        XCTAssertTrue(SubjectIdentity.tip(for: "Chair").contains("chair"))
    }
    func testBriefTrackerMissDoesNotRestartDetectionOrClaimReady() {
        var guide = AutomaticGuidance()
        let reading = CompositionReading(state: .ready, subjectBounds: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), subjectConfidence: 0.9, target: .init(x: 0.5, y: 0.5))
        _ = guide.update(reading: reading, phase: .off, stable: true, rollReliable: true, autoEnabled: false, zoomAvailable: false, timestamp: 0, subjectLabel: "Desk")
        let uncertain = guide.update(reading: .init(), phase: .off, stable: true, rollReliable: true, autoEnabled: false, zoomAvailable: false, timestamp: 0.2, subjectLabel: "Desk", recovering: true)
        XCTAssertEqual(uncertain.kind, .steady); XCTAssertEqual(uncertain.text, "Keep the subject in view")
        let reacquired = guide.update(reading: reading, phase: .off, stable: false, rollReliable: true, autoEnabled: false, zoomAvailable: false, timestamp: 0.6, subjectLabel: "Desk")
        XCTAssertNotEqual(reacquired.kind, .detected)
        let lost = guide.update(reading: .init(), phase: .off, stable: true, rollReliable: true, autoEnabled: false, zoomAvailable: false, timestamp: 1, subjectLabel: "Desk", recovering: false)
        XCTAssertEqual(lost.kind, .searching)
    }
}
