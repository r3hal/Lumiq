import SwiftUI
import Combine

enum PhotoAspect: String, CaseIterable, Identifiable, Codable, Hashable {
    case standard = "3:4", portrait = "4:5", square = "1:1", tall = "9:16", landscape = "4:3", wide = "16:9"
    var id: Self { self }
    var ratio: Double {
        switch self {
        case .standard: return 3.0 / 4
        case .portrait: return 4.0 / 5
        case .square: return 1
        case .tall: return 9.0 / 16
        case .landscape: return 4.0 / 3
        case .wide: return 16.0 / 9
        }
    }
    func cropRect(in size: CGSize) -> CGRect {
        let width = min(size.width, size.height * ratio)
        let height = min(size.height, size.width / ratio)
        let w = min(size.width, max(1, floor(width))), h = min(size.height, max(1, floor(height)))
        return CGRect(x: floor((size.width - w) / 2), y: floor((size.height - h) / 2), width: w, height: h)
    }
}

enum CaptionStyle: String, CaseIterable, Identifiable, Codable {
    case bold = "Bold", editorial = "Editorial", garamond = "Garamond", handwriting = "Handwritten"
    var id: Self { self }
    var font: Font {
        switch self {
        case .bold: return .system(size: 17, weight: .bold).italic()
        case .editorial: return .custom("Georgia-Italic", size: 17)
        case .garamond: return .custom("EBGaramond-Italic", size: 17)
        case .handwriting: return .custom("SnellRoundhand", size: 17)
        }
    }
}

enum CameraFlash: Int, CaseIterable, Identifiable {
    case off = 0, on = 1, auto = 2
    var id: Self { self }
    var label: String { self == .off ? "Off" : self == .on ? "On" : "Auto" }
    var symbol: String { self == .off ? "bolt.slash" : self == .on ? "bolt.fill" : "bolt.badge.a" }
}

struct CaptureOptions {
    var raw = false
    var flash: CameraFlash = .off
    var shutterSound = true
}

struct CameraCapture {
    let processed: Data
    let raw: Data?
}

@MainActor
final class CameraSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var grid = false { didSet { defaults.set(grid, forKey: "camera.grid") } }
    @Published var level = false { didSet { defaults.set(level, forKey: "camera.level") } }
    @Published var shutterSound = false { didSet { defaults.set(shutterSound, forKey: "camera.sound") } }
    @Published var saveScan = true { didSet { defaults.set(saveScan, forKey: "camera.scan") } }
    @Published var autoSaveToPhotos = false { didSet { defaults.set(autoSaveToPhotos, forKey: "camera.autoPhotos") } }
    @Published var keepRAW = true { didSet { defaults.set(keepRAW, forKey: "camera.keepRAW") } }
    @Published var raw = false { didSet { defaults.set(raw, forKey: "camera.raw") } }
    @Published var holdDuration: Double = 0.9 { didSet { defaults.set(holdDuration,forKey: "camera.holdDuration") } }
    @Published var autoFrame = true { didSet { defaults.set(autoFrame, forKey: "camera.autoFrame") } }
    @Published var smartShutter = false { didSet { defaults.set(smartShutter, forKey: "camera.smart") } }
    @Published var burstCount = 1 { didSet { defaults.set(burstCount, forKey: "camera.burst") } }
    @Published var coach = false { didSet { defaults.set(coach, forKey: "camera.coach") } }
    @Published var challenge = "" { didSet { defaults.set(challenge, forKey: "camera.challenge") } }
    @Published var guide = false { didSet { defaults.set(guide, forKey: "camera.guide") } }
    @Published var subjectThreshold: Double = 0.68 { didSet { defaults.set(subjectThreshold, forKey: "camera.subjectThreshold") } }
    @Published var aspect: PhotoAspect = .standard { didSet { defaults.set(aspect.rawValue, forKey: "camera.aspect") } }
    @Published var caption: CaptionStyle = .bold { didSet { defaults.set(caption.rawValue, forKey: "camera.caption") } }
    @Published var flash: CameraFlash = .off { didSet { defaults.set(flash.rawValue, forKey: "camera.flash") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.integer(forKey:"camera.cleanCompositionVersion") < 1 {
            defaults.set(false,forKey:"camera.grid"); defaults.set(false,forKey:"camera.level")
            defaults.set(1,forKey:"camera.cleanCompositionVersion")
        }
        if defaults.integer(forKey: "camera.intentionalGuidanceVersion") < 1 {
            defaults.set(false, forKey: "camera.guide")
            defaults.set(1, forKey: "camera.intentionalGuidanceVersion")
        }
        defaults.register(defaults: ["camera.grid": false, "camera.level": false, "camera.holdDuration":0.9, "camera.scan": true,
                                    "camera.keepRAW": true, "camera.guide": false, "camera.subjectThreshold": 0.68, "camera.autoFrame": true])
        smartShutter = defaults.bool(forKey: "camera.smart")
        burstCount = [1, 3, 5].contains(defaults.integer(forKey: "camera.burst")) ? defaults.integer(forKey: "camera.burst") : 1
        coach = defaults.bool(forKey: "camera.coach")
        challenge = defaults.string(forKey: "camera.challenge") ?? ""
        holdDuration = max(0.5,min(2,defaults.double(forKey:"camera.holdDuration")))
        grid = defaults.bool(forKey: "camera.grid")
        level = defaults.bool(forKey: "camera.level")
        shutterSound = defaults.bool(forKey: "camera.sound")
        saveScan = defaults.bool(forKey: "camera.scan")
        autoSaveToPhotos = defaults.bool(forKey: "camera.autoPhotos")
        keepRAW = defaults.bool(forKey: "camera.keepRAW")
        raw = defaults.bool(forKey: "camera.raw")
        autoFrame = defaults.bool(forKey: "camera.autoFrame")
        guide = defaults.bool(forKey: "camera.guide")
        subjectThreshold = max(0.55, min(0.85, defaults.double(forKey: "camera.subjectThreshold")))
        aspect = PhotoAspect(rawValue: defaults.string(forKey: "camera.aspect") ?? "") ?? .standard
        caption = CaptionStyle(rawValue: defaults.string(forKey: "camera.caption") ?? "") ?? .bold
        flash = CameraFlash(rawValue: defaults.integer(forKey: "camera.flash")) ?? .off
    }
}
