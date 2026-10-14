import XCTest
import UIKit
import CoreImage
@testable import Focal

@MainActor
final class ShotCaptureSessionTests: XCTestCase {
    private let subject = CGRect(x:0.4,y:0.4,width:0.2,height:0.2)
    private func plan() throws -> AutomaticShotPlan {
        let composition = SceneCompositionPlan(selected:.init(technique:.fillFrame,target:.init(x:0.5,y:0.5),
            crop:CGRect(x:0.25,y:0.25,width:0.5,height:0.5),score:0.9,explanation:"Measured pet portrait",zoomScale:2,measuredImprovement:0.15),
            alternatives:[],subjectLabel:"Cat",timestamp:0)
        return try XCTUnwrap(AutomaticShotPlan.make(bounds:subject,label:"Cat",composition:composition,currentZoom:1,
            maximumZoom:4,detailLimit:4,nativeStops:[1],regions:[],anatomy:nil,previewAspect:0.75))
    }
    private func jpeg(_ color:UIColor = .red) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size:CGSize(width:120,height:160),format:format).image { _ in
            color.setFill(); UIRectFill(CGRect(x:0,y:0,width:120,height:160))
        }.jpegData(compressionQuality:0.95)!
    }
    private func preview() -> WideScenePreview {
        .init(data:jpeg(),pixelWidth:120,pixelHeight:160,observedAt:Date(timeIntervalSince1970:100))
    }
    private func readySession(wide:Bool = true) throws -> (ShotCaptureSession,AutomaticShotPlan) {
        let shot = try plan(); var session = ShotCaptureSession()
        session.select(shot,preview:wide ? preview() : nil)
        session.observe(plan:shot,verified:true,bounds:shot.desiredBounds,label:"Cat",confidence:0.95,zoom:2,stable:true,timestamp:1,aspect:0.75)
        return (session,shot)
    }
    private func payload(wide:Bool = true) throws -> FramedCapture {
        let (session,_) = try readySession(wide:wide)
        return try XCTUnwrap(session.userCapture(at:1.1,date:Date(timeIntervalSince1970:102),guidanceEnabled:true))
    }
    func testDiscoveryAndUnverifiedShotDoNotProduceSavePayload() throws {
        var session = ShotCaptureSession(); let shot = try plan()
        XCTAssertNil(session.userCapture(at:0,guidanceEnabled:true))
        session.select(shot,preview:preview())
        session.observe(plan:shot,verified:false,bounds:subject,label:"Cat",confidence:1,zoom:1,stable:true,timestamp:1,aspect:0.75)
        XCTAssertNil(session.userCapture(at:1.1,guidanceEnabled:true))
    }
    func testOneUserRequestAssociatesEarlierPreviewWithVerifiedShot() throws {
        let capture = try payload()
        XCTAssertTrue(capture.metadata.hasWidePreview)
        XCTAssertEqual(capture.metadata.startingZoom,1); XCTAssertEqual(capture.metadata.capturedZoom,2)
        XCTAssertLessThan(try XCTUnwrap(capture.metadata.widePreviewObservedAt),capture.metadata.shutterRequestedAt)
        XCTAssertEqual(capture.metadata.widePreviewWidth,120)
        XCTAssertTrue(capture.matchesCamera(zoom:2,enabled:true,ramping:false))
    }
    func testManualOverrideAndCameraSwitchCancelPendingPair() throws {
        var (session,_) = try readySession()
        session.cancel()
        XCTAssertNil(session.userCapture(at:1.1,guidanceEnabled:true))
    }
    func testAIOffAndRampingCameraCannotUsePair() throws {
        let (session,_) = try readySession()
        XCTAssertNil(session.userCapture(at:1.1,guidanceEnabled:false))
        let capture = try payload()
        XCTAssertFalse(capture.matchesCamera(zoom:2,enabled:false,ramping:false))
        XCTAssertFalse(capture.matchesCamera(zoom:2,enabled:true,ramping:true))
        XCTAssertFalse(capture.matchesCamera(zoom:1,enabled:true,ramping:false))
    }
    func testMovedOrUncertainSubjectCannotPairOldScene() throws {
        for confidence in [Float(0.3),Float(0.95)] {
            var (session,shot) = try readySession()
            session.observe(plan:shot,verified:true,bounds:CGRect(x:0.1,y:0.1,width:0.2,height:0.2),label:"Cat",confidence:confidence,
                zoom:2,stable:true,timestamp:1.1,aspect:0.75)
            XCTAssertNil(session.userCapture(at:1.2,guidanceEnabled:true))
            session.observe(plan:shot,verified:true,bounds:shot.desiredBounds,label:"Cat",confidence:0.95,zoom:2,stable:true,timestamp:1.3,aspect:0.75)
            XCTAssertNil(session.userCapture(at:1.4,guidanceEnabled:true)?.widePreview)
        }
    }
    func testBriefCameraMotionWaitsWithoutDiscardingSameScene() throws {
        var (session,shot) = try readySession()
        session.observe(plan:shot,verified:true,bounds:shot.desiredBounds,label:"Cat",confidence:1,zoom:2,stable:false,timestamp:1.1,aspect:0.75)
        XCTAssertNil(session.userCapture(at:1.2,guidanceEnabled:true))
        session.observe(plan:shot,verified:true,bounds:shot.desiredBounds,label:"Cat",confidence:1,zoom:2,stable:true,timestamp:1.3,aspect:0.75)
        XCTAssertNotNil(session.userCapture(at:1.4,guidanceEnabled:true)?.widePreview)
    }
    func testStaleVerificationAndDifferentShotCannotPair() throws {
        var (session,shot) = try readySession()
        XCTAssertNil(session.userCapture(at:2.1,guidanceEnabled:true))
        let other = try plan()
        session.observe(plan:other,verified:true,bounds:shot.desiredBounds,label:"Cat",confidence:1,zoom:2,stable:true,timestamp:2.2,aspect:0.75)
        XCTAssertNil(session.userCapture(at:2.3,guidanceEnabled:true))
    }
    func testUnavailableWidePreviewStillAllowsFramedCapture() throws {
        let capture = try payload(wide:false)
        XCTAssertNil(capture.widePreview); XCTAssertFalse(capture.metadata.hasWidePreview)
        XCTAssertTrue(capture.matchesCamera(zoom:2,enabled:true,ramping:false))
    }
    func testAlreadyCorrectUnzoomedShotDoesNotInventWiderPixels() {
        var session = ShotCaptureSession()
        session.observe(plan:nil,verified:false,bounds:subject,label:"Cat",confidence:1,zoom:1,stable:true,timestamp:1,aspect:0.75)
        XCTAssertNil(session.userCapture(at:1.1,guidanceEnabled:true))
    }
    func testGuidedShutterAlwaysRequestsOnlyOneStill() {
        XCTAssertEqual(UserShutterPolicy.count(guidanceEnabled:true,requestedSeries:5),1)
        XCTAssertEqual(UserShutterPolicy.count(guidanceEnabled:false,requestedSeries:3),3)
    }
    func testCompletedFramingIsInvalidatedWhenSubjectLeaves() throws {
        var planner = FramingPlanner(); let shot = try plan()
        for time in [0.0,1.0] {
            _ = planner.update(bounds:subject,confidence:1,roll:0,timestamp:time,currentZoom:1,maximumZoom:4,
                plannedScale:2,zoomDestination:.init(x:0.5,y:0.5),requiresShotPlan:true)
        }
        planner.commitShot(shot)
        _ = planner.verifyShot(bounds:shot.desiredBounds,label:"Cat",confidence:1,zoom:2,stable:true,fresh:true,timestamp:2,previewAspect:0.75)
        _ = planner.verifyShot(bounds:shot.desiredBounds,label:"Cat",confidence:1,zoom:2,stable:true,fresh:true,timestamp:2.3,previewAspect:0.75)
        XCTAssertTrue(planner.shotVerified)
        planner.revalidateCompletedShot(bounds:nil,label:"Cat",confidence:0,zoom:2,aspect:0.75)
        XCTAssertFalse(planner.shotVerified); XCTAssertEqual(planner.phase,.off)
    }
    func testWidePreviewRendererPreservesAspectAndNeverUpscales() throws {
        let image = try XCTUnwrap(CIImage(data:jpeg()))
        let context = CIContext()
        for mirrored in [false,true] {
            let preview = try XCTUnwrap(PhotoRenderer.widePreview(image,aspect:0.75,mirrored:mirrored,observedAt:Date(),context:context))
            XCTAssertEqual(preview.pixelWidth,120); XCTAssertEqual(preview.pixelHeight,160)
            XCTAssertEqual(try XCTUnwrap(UIImage(data:preview.data)).size,CGSize(width:120,height:160))
        }
        XCTAssertNil(PhotoRenderer.widePreview(image,aspect:.nan,mirrored:false,observedAt:Date(),context:context))
    }
    func testPairedLibraryEntryReloadsAndDeletesBothResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let library = PhotoLibrary(directory:directory), capture = try payload(), final = jpeg(.blue)
        let photo = try await library.add(data:final,mode:"Pet",cameraOrigin:CameraSource.iPhone.rawValue,framedCapture:capture)
        XCTAssertEqual(library.photos.count,1)
        XCTAssertEqual(photo.framingSession?.sessionID,capture.metadata.sessionID)
        let wideURL = try XCTUnwrap(library.widePreviewURL(for:photo))
        XCTAssertEqual(try Data(contentsOf:wideURL),try XCTUnwrap(capture.widePreview).data)
        XCTAssertEqual(try Data(contentsOf:library.url(for:photo)),final)
        let reopened = PhotoLibrary(directory:directory)
        XCTAssertEqual(reopened.photos.first,photo)
        try reopened.delete(photo)
        XCTAssertFalse(FileManager.default.fileExists(atPath:wideURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:library.url(for:photo).path))
    }
    func testEditingKeepsWidePreviewAndSessionAssociation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let library = PhotoLibrary(directory:directory)
        let photo = try await library.add(data:jpeg(.blue),mode:"Pet",cameraOrigin:CameraSource.iPhone.rawValue,framedCapture:try payload())
        let edited = try await library.finishPhoneReview(photo,data:jpeg(.green),recipe:EditRecipe(exposure:0.5),developedFromRAW:false)
        XCTAssertEqual(edited.framingSession,photo.framingSession)
        XCTAssertEqual(edited.widePreviewFilename,photo.widePreviewFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath:try XCTUnwrap(library.widePreviewURL(for:edited)).path))
        XCTAssertNotEqual(library.originalURL(for:edited),library.widePreviewURL(for:edited))
    }
    func testManifestFailureRollsBackBothImageFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let library = PhotoLibrary(directory:directory)
        try FileManager.default.createDirectory(at:directory.appendingPathComponent("library.json"),withIntermediateDirectories:true)
        do {
            _ = try await library.add(data:jpeg(),mode:"Pet",cameraOrigin:CameraSource.iPhone.rawValue,framedCapture:try payload())
            XCTFail("Manifest failure must not leave a partial session")
        } catch {
            XCTAssertTrue(library.photos.isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path),["library.json"])
        }
    }
    func testMissingPreviewMetadataPersistsAndSonyDoesNotReceivePair() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let library = PhotoLibrary(directory:directory)
        let phone = try await library.add(data:jpeg(),mode:"Pet",cameraOrigin:CameraSource.iPhone.rawValue,framedCapture:try payload(wide:false))
        XCTAssertNotNil(phone.framingSession); XCTAssertNil(phone.widePreviewFilename)
        let sony = try await library.add(data:jpeg(),mode:"Sony",cameraOrigin:CameraSource.sony.rawValue,framedCapture:try payload())
        XCTAssertNil(sony.framingSession); XCTAssertNil(sony.widePreviewFilename)
    }
}
