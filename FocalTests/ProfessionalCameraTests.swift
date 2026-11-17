import AVFoundation
import XCTest
@testable import Focal

final class ProfessionalCameraTests:XCTestCase {
    func testOnlyActionableCameraInterruptionsShowAnAlert() {
        XCTAssertNotNil(CameraInterruptionPolicy.message(for: .videoDeviceInUseByAnotherClient))
        XCTAssertNotNil(CameraInterruptionPolicy.message(for: .videoDeviceNotAvailableDueToSystemPressure))
        XCTAssertNil(CameraInterruptionPolicy.message(for: .videoDeviceNotAvailableInBackground))
        XCTAssertNil(CameraInterruptionPolicy.message(for: .audioDeviceInUseByAnotherClient))
        XCTAssertNil(CameraInterruptionPolicy.message(for: nil))
    }
    func testAutoResetClearsAllManualLocks() {
        var state = ManualCameraState(mode:.pro,iso:400,seconds:1/125.0,temperature:4300,tint:12,focus:0.6)
        state.reset()
        XCTAssertEqual(state.mode,.auto)
        XCTAssertFalse(state.hasManualExposure)
        XCTAssertNil(state.temperature); XCTAssertNil(state.focus)
    }
    func testExposureAutoResetsPairButRetainsManualFocusAndWB() {
        var state = ManualCameraState(mode:.pro,iso:400,seconds:0.01,temperature:4300,focus:0.6)
        state.automaticExposure()
        XCTAssertNil(state.iso); XCTAssertNil(state.seconds)
        XCTAssertEqual(state.temperature,4300); XCTAssertEqual(state.focus,0.6)
        XCTAssertEqual(state.mode,.pro)
    }
    func testTapAndAIFocusCannotOverrideManualFocus() {
        let manual = ManualCameraState(mode:.pro,focus:0.5)
        XCTAssertFalse(manual.permitsFocus(automatic:true))
        XCTAssertFalse(manual.permitsFocus(automatic:false))
        XCTAssertTrue(ManualCameraState().permitsFocus(automatic:true))
    }
    func testMeteringDoesNotResetManualExposure() {
        XCTAssertFalse(ManualCameraState(mode:.pro,iso:100).permitsAutoMetering)
        XCTAssertFalse(ManualCameraState(mode:.pro,seconds:0.01).permitsAutoMetering)
        XCTAssertTrue(ManualCameraState(mode:.pro,focus:0.5).permitsAutoMetering)
    }
    func testHardwareRangeClampAndNonfiniteRejection() {
        XCTAssertEqual(ManualCameraState.clamp(12,to:50...1600),50)
        XCTAssertEqual(ManualCameraState.clamp(8000,to:50...1600),1600)
        XCTAssertNil(ManualCameraState.clamp(.nan,to:50...1600))
        XCTAssertNil(ManualCameraState.clamp(.infinity,to:50...1600))
    }
    func testUnsupportedManualParametersAreAbsent() {
        let controls = CameraControlSnapshot()
        for parameter in CameraParameter.allCases { XCTAssertFalse(controls.supports(parameter)) }
        var supported = controls; supported.isoRange = 50...1600; supported.canFocus = true
        XCTAssertTrue(supported.supports(.iso)); XCTAssertTrue(supported.supports(.focus))
        XCTAssertFalse(supported.supports(.whiteBalance))
    }
    private func chair() -> SubjectCandidate {
        .init(bounds:CGRect(x:0.3,y:0.3,width:0.4,height:0.4),confidence:0.9,category:.object,label:"Chair",classificationConfidence:0.9,prominence:0.9,isolation:0.85,detail:0.08)
    }
    func testProductIntentPrefersObjectPoolOverPeople() {
        let config = SubjectSelectionConfiguration(intent:.product)
        var person = chair(); person.category = .person; person.label = "Person"
        XCTAssertNil(person.score(configuration:config))
        XCTAssertNotNil(chair().score(configuration:config))
    }
    func testPortraitAndPetIntentsUseActualSupportedCategories() {
        var subject = chair(); subject.category = .person; subject.label = "Person"
        XCTAssertNotNil(subject.score(configuration:.init(intent:.portrait)))
        XCTAssertNil(subject.score(configuration:.init(intent:.pet)))
        subject.category = .pet; subject.label = "Dog"
        XCTAssertNotNil(subject.score(configuration:.init(intent:.pet)))
        XCTAssertNil(subject.score(configuration:.init(intent:.portrait)))
    }
    func testArchitectureDoesNotPromoteGenericBackgroundStructure() {
        var wall = chair(); wall.category = .background; wall.label = "Wall"
        XCTAssertNil(wall.score(configuration:.init(intent:.architecture)))
        wall.category = .architecture; wall.label = "Castle"
        XCTAssertNotNil(wall.score(configuration:.init(intent:.architecture)))
    }
    func testLandscapeDoesNotAcquireForcedSubjectOrZoom() {
        for category in [SubjectCategory.person,.face,.pet,.object,.architecture,.nature,.landscape,.background] {
            XCTAssertFalse(PhotographyIntent.landscape.accepts(category))
        }
        XCTAssertNil(chair().score(configuration:.init(intent:.landscape)))
        XCTAssertFalse(PhotographyIntent.landscape.permitsZoom)
        XCTAssertFalse(PhotographyIntent.architecture.permitsZoom)
    }
    func testPortraitCropConstraintAndProductLayoutWeight() {
        XCTAssertLessThan(PhotographyIntent.portrait.maximumCropScale,PhotographyIntent.product.maximumCropScale)
        XCTAssertGreaterThan(PhotographyIntent.product.bonus(for:.fillFrame),PhotographyIntent.product.bonus(for:.leadingLines))
        XCTAssertGreaterThan(PhotographyIntent.architecture.bonus(for:.symmetry),PhotographyIntent.architecture.bonus(for:.fillFrame))
    }
    func testManualSubjectIntentStillBypassesAutomaticPoolFiltering() {
        var selector = SubjectSelector(); selector.configuration.intent = .portrait
        XCTAssertEqual(selector.select([chair()],timestamp:0,manualPoint:CGPoint(x:0.5,y:0.5)),0)
    }
    func testHistogramCountsEverySampleIncludingWhite() {
        let bins = PrecisionAnalyzer.histogram([0,0.25,0.5,0.75,1],bins:4)
        XCTAssertEqual(bins,[1,1,1,2]); XCTAssertEqual(bins?.reduce(0,+),5)
    }
    func testHistogramRejectsInvalidSamplesAndBinCount() {
        XCTAssertNil(PrecisionAnalyzer.histogram([]))
        XCTAssertNil(PrecisionAnalyzer.histogram([.nan]))
        XCTAssertNil(PrecisionAnalyzer.histogram([-0.1,0.5]))
        XCTAssertNil(PrecisionAnalyzer.histogram([0.5],bins:1))
    }
    func testUniformMidtoneHasNoZebraOrPeaking() {
        let mask = PrecisionAnalyzer.masks([Double](repeating:0.5,count:25),width:5,height:5,highlights:true,peaking:true)
        XCTAssertEqual(mask.zebra?.filter { $0 != 0 }.count,0)
        XCTAssertEqual(mask.edges?.filter { $0 != 0 }.count,0)
    }
    func testNearWhitePixelsProduceRealZebraMask() {
        let mask = PrecisionAnalyzer.masks([Double](repeating:0.99,count:25),width:5,height:5,highlights:true,peaking:false)
        XCTAssertGreaterThan(mask.zebra?.filter { $0 != 0 }.count ?? 0,0)
        XCTAssertNil(mask.edges)
    }
    func testEdgeMaskNeedsLocalContrastAndIndependentSwitch() {
        let luma = (0..<5).flatMap { _ in (0..<5).map { $0 < 2 ? 0.2 : 0.8 } }
        let mask = PrecisionAnalyzer.masks(luma,width:5,height:5,highlights:false,peaking:true)
        XCTAssertGreaterThan(mask.edges?.filter { $0 != 0 }.count ?? 0,0)
        XCTAssertNil(mask.zebra)
        XCTAssertNil(PrecisionAnalyzer.masks(luma,width:5,height:5,highlights:false,peaking:false).edges)
    }
    func testPrecisionDisabledHasNoProcessingDemand() {
        XCTAssertFalse(PrecisionOptions().enabled)
        XCTAssertTrue(PrecisionOptions(histogram:true).enabled)
        XCTAssertTrue(PrecisionOptions(highlights:true).enabled)
        XCTAssertTrue(PrecisionOptions(peaking:true).enabled)
        XCTAssertTrue(PrecisionOptions(autoTune:true).enabled)
    }
    private var clipped:PhotoMeasurements { .init(brightness:0.65,shadowFraction:0.01,highlightFraction:0.3,detail:0.08,backgroundEdges:nil) }
    private var controls:CameraControlSnapshot { .init(mode:.auto,iso:500,seconds:0.03,isoRange:50...1600,evAdjustable:true) }
    func testAutoTuneHighlightsOfferBoundedExplicitAutoAdjustment() throws {
        let results = AutoTune.recommendations(measured:clipped,controls:controls,ev:0,evRange:-2...2,motion:0,zoom:1,minimumZoom:0.5,timestamp:0)
        let result = try XCTUnwrap(results.first { $0.kind == .highlights })
        XCTAssertEqual(try XCTUnwrap(result.exposureBias),-1.0/3,accuracy:0.0001)
        XCTAssertFalse(result.reason.isEmpty)
    }
    func testAutoTuneNeverOffersApplyForProEvenWhenExposureIsAutomatic() throws {
        var pro = controls; pro.mode = .pro
        let result = try XCTUnwrap(AutoTune.recommendations(measured:clipped,controls:pro,ev:0,evRange:-2...2,motion:0,zoom:1,minimumZoom:0.5,timestamp:0).first)
        XCTAssertNil(result.exposureBias)
    }
    func testAutoTuneManualExposureAndLimitHaveNoApplyAction() {
        var manual = controls; manual.manualExposure = true
        XCTAssertNil(AutoTune.recommendations(measured:clipped,controls:manual,ev:0,evRange:-2...2,motion:0,zoom:1,minimumZoom:1,timestamp:0).first?.exposureBias)
        XCTAssertNil(AutoTune.recommendations(measured:clipped,controls:controls,ev:-2,evRange:-2...2,motion:0,zoom:1,minimumZoom:1,timestamp:0).first?.exposureBias)
    }
    func testAutoTuneMotionNeedsActualMotionAndSlowShutter() {
        let fast = AutoTune.recommendations(measured:clipped,controls:controls,ev:nil,evRange:nil,motion:nil,zoom:1,minimumZoom:1,timestamp:0)
        XCTAssertFalse(fast.contains { $0.kind == .motion })
        let moving = AutoTune.recommendations(measured:clipped,controls:controls,ev:nil,evRange:nil,motion:0.8,zoom:1,minimumZoom:1,timestamp:0)
        XCTAssertTrue(moving.contains { $0.kind == .motion })
    }
    func testAutoTuneSubjectMotionUsesObservedRelativeMovement() {
        let moving = AutoTune.recommendations(measured:clipped,controls:controls,ev:nil,evRange:nil,motion:0,zoom:1,minimumZoom:1,timestamp:0,subjectMotion:0.2)
        XCTAssertTrue(moving.contains { $0.kind == .motion && $0.reason.contains("tracked subject") })
        var fast = controls; fast.seconds = 1/500.0
        XCTAssertFalse(AutoTune.recommendations(measured:clipped,controls:fast,ev:nil,evRange:nil,motion:0,zoom:1,minimumZoom:1,timestamp:0,subjectMotion:0.2).contains { $0.kind == .motion })
    }
    func testAutoTuneApplyRejectsStaleFutureSonyProAndBusyStates() {
        let recommendation = AutoTuneRecommendation(kind:.highlights,title:"Measured",reason:"Pixels",exposureBias:-0.3,timestamp:10)
        XCTAssertTrue(AutoTune.permitsApplication(recommendation,source:.iPhone,mode:.auto,manualExposure:false,paused:false,busy:false,now:11))
        XCTAssertFalse(AutoTune.permitsApplication(recommendation,source:.iPhone,mode:.auto,manualExposure:false,paused:false,busy:false,now:13))
        XCTAssertFalse(AutoTune.permitsApplication(recommendation,source:.iPhone,mode:.auto,manualExposure:false,paused:false,busy:false,now:9))
        XCTAssertFalse(AutoTune.permitsApplication(recommendation,source:.sony,mode:.auto,manualExposure:false,paused:false,busy:false,now:11))
        XCTAssertFalse(AutoTune.permitsApplication(recommendation,source:.iPhone,mode:.pro,manualExposure:false,paused:false,busy:false,now:11))
        XCTAssertFalse(AutoTune.permitsApplication(recommendation,source:.iPhone,mode:.auto,manualExposure:true,paused:false,busy:false,now:11))
        XCTAssertFalse(AutoTune.permitsApplication(recommendation,source:.iPhone,mode:.auto,manualExposure:false,paused:false,busy:true,now:11))
    }
    func testAutoTuneBlankValidMidtoneDoesNotInventRecommendation() {
        let mid = PhotoMeasurements(brightness:0.5,shadowFraction:0,highlightFraction:0,detail:0.05,backgroundEdges:nil)
        XCTAssertTrue(AutoTune.recommendations(measured:mid,controls:controls,ev:0,evRange:-2...2,motion:0,zoom:1,minimumZoom:1,timestamp:0).isEmpty)
    }
    func testSubnetDiscoveryUsesActualNetworkAndExcludesSelfAndBroadcast() throws {
        let ip = try XCTUnwrap(SonyDiscovery.number("192.168.42.17"))
        let hosts = SonyDiscovery.candidates(address:ip,mask:0xffffff00)
        XCTAssertTrue(hosts.contains("192.168.42.1"))
        XCTAssertFalse(hosts.contains("192.168.42.17")); XCTAssertFalse(hosts.contains("192.168.42.255"))
        XCTAssertFalse(hosts.contains("192.168.122.1"))
        XCTAssertEqual(Set(hosts).count,hosts.count)
        XCTAssertLessThanOrEqual(hosts.count,64)
    }
    func testDiscoveryPreviousHostOnlyPrioritizedWithinCurrentSubnet() throws {
        let ip = try XCTUnwrap(SonyDiscovery.number("10.0.4.24"))
        XCTAssertEqual(SonyDiscovery.candidates(address:ip,mask:0xffffff00,previous:"10.0.4.77").first,"10.0.4.77")
        XCTAssertFalse(SonyDiscovery.candidates(address:ip,mask:0xffffff00,previous:"192.168.122.1").contains("192.168.122.1"))
    }
    func testDiscoveryRejectsPublicAddressAndMalformedMasks() {
        XCTAssertNil(SonyDiscovery.number("8.8.8.8"))
        XCTAssertTrue(SonyDiscovery.candidates(address:0x08080808,mask:0xffffff00).isEmpty)
        XCTAssertTrue(SonyDiscovery.candidates(address:0xc0a82a11,mask:0).isEmpty)
        XCTAssertTrue(SonyDiscovery.candidates(address:0xc0a82a11,mask:0xff00ff00).isEmpty)
    }
    func testComparisonReportsDifferencesWithoutWinner() {
        let a = PhotoInsight(measurements:.init(brightness:0.4,shadowFraction:0.2,highlightFraction:0.1,detail:0.05,backgroundEdges:nil),metadata:nil,subject:nil,proposedComposition:nil,suggestions:[],aspectRatio:0.75)
        let b = PhotoInsight(measurements:.init(brightness:0.6,shadowFraction:0.1,highlightFraction:0.2,detail:0.07,backgroundEdges:nil),metadata:nil,subject:nil,proposedComposition:nil,suggestions:[],aspectRatio:1)
        let comparison = PhotoComparison(first:a,second:b)
        XCTAssertEqual(comparison.brightnessDifference,0.2,accuracy:0.0001)
        XCTAssertEqual(comparison.highlightsDifference,0.1,accuracy:0.0001)
        XCTAssertEqual(comparison.shadowsDifference,-0.1,accuracy:0.0001)
        XCTAssertEqual(comparison.detailDifference,0.02,accuracy:0.0001)
        XCTAssertTrue(comparison.notes.contains { $0.contains("aspect ratios differ") })
        XCTAssertEqual(a.previewHeadroomIndex,70,accuracy:0.0001)
    }
    func testSceneGuidancePresentationDoesNotRequireInventedBox() {
        XCTAssertEqual(CameraGuideState.resolve(enabled:true,reading:.init(),phase:.off,message:.init(kind:.scene,text:"Measured horizon")),.scene)
        XCTAssertEqual(CameraGuideState.resolve(enabled:false,reading:.init(),phase:.off,message:.init(kind:.scene,text:"Measured horizon")),.off)
    }
}

@MainActor
final class ProfessionalPersistenceTests:XCTestCase {
    func testIntentCodecAndIndependentPrecisionPreferencesPersist() throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        let settings = CameraSettings(defaults:defaults)
        XCTAssertFalse(settings.guide); XCTAssertFalse(settings.histogram); XCTAssertFalse(settings.focusPeaking); XCTAssertFalse(settings.autoTune)
        settings.intent = .product; settings.encoding = .heif; settings.histogram = true; settings.highlightWarnings = true; settings.focusPeaking = true; settings.autoTune = true
        let restored = CameraSettings(defaults:defaults)
        XCTAssertEqual(restored.intent,.product); XCTAssertEqual(restored.encoding,.heif)
        XCTAssertTrue(restored.histogram); XCTAssertTrue(restored.highlightWarnings); XCTAssertTrue(restored.focusPeaking); XCTAssertTrue(restored.autoTune)
        XCTAssertFalse(restored.guide)
    }
    func testOldPhotoManifestDecodesWithoutNewIntent() throws {
        let photo = SavedPhoto(id:UUID(),filename:"original.jpg",createdAt:Date(),mode:"Free shoot",isDemo:false,isFavorite:false)
        let data = try JSONEncoder().encode(photo)
        let restored = try JSONDecoder().decode(SavedPhoto.self,from:data)
        XCTAssertNil(restored.photographyIntent)
        XCTAssertEqual(restored.filename,photo.filename)
    }
    func testAnalysisMissingFileFailsWithoutCreatingDemo() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".jpg")
        do { _ = try await PhotoInsightService.shared.analyze(url); XCTFail("Missing file must fail") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath:url.path)) }
    }
    func testCorruptImageAnalysisPreservesOriginalBytes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".jpg")
        let bytes = Data("not a decoded photograph".utf8)
        try bytes.write(to:url); defer { try? FileManager.default.removeItem(at:url) }
        do { _ = try await PhotoInsightService.shared.analyze(url); XCTFail("Corrupt data must not produce image analysis") }
        catch { XCTAssertEqual(try Data(contentsOf:url),bytes) }
    }
}
