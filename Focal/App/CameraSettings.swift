import SwiftUI
import Combine

enum PhotoAspect: String, CaseIterable, Identifiable, Codable {
    case standard = "3:4", portrait = "4:5", square = "1:1", tall = "9:16"
    var id: Self { self }
    var ratio: Double {
        switch self {
        case .standard: return 3.0 / 4
        case .portrait: return 4.0 / 5
        case .square: return 1
        case .tall: return 9.0 / 16
        }
    }
    func cropRect(in size: CGSize) -> CGRect {
        let width = min(size.width, size.height * ratio)
        let height = min(size.height, size.width / ratio)
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height).integral
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
    @Published var grid = true { didSet { defaults.set(grid, forKey: "camera.grid") } }
    @Published var level = true { didSet { defaults.set(level, forKey: "camera.level") } }
    @Published var shutterSound = false { didSet { defaults.set(shutterSound, forKey: "camera.sound") } }
    @Published var saveScan = true { didSet { defaults.set(saveScan, forKey: "camera.scan") } }
    @Published var autoSaveToPhotos = false { didSet { defaults.set(autoSaveToPhotos, forKey: "camera.autoPhotos") } }
    @Published var keepRAW = true { didSet { defaults.set(keepRAW, forKey: "camera.keepRAW") } }
    @Published var raw = false { didSet { defaults.set(raw, forKey: "camera.raw") } }
    @Published var autoFrame = true { didSet { defaults.set(autoFrame, forKey: "camera.autoFrame") } }
    @Published var guide = true { didSet { defaults.set(guide, forKey: "camera.guide") } }
    @Published var aspect: PhotoAspect = .standard { didSet { defaults.set(aspect.rawValue, forKey: "camera.aspect") } }
    @Published var caption: CaptionStyle = .bold { didSet { defaults.set(caption.rawValue, forKey: "camera.caption") } }
    @Published var flash: CameraFlash = .off { didSet { defaults.set(flash.rawValue, forKey: "camera.flash") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["camera.grid": true, "camera.level": true, "camera.scan": true,
                                    "camera.keepRAW": true, "camera.guide": true, "camera.autoFrame": true])
        grid = defaults.bool(forKey: "camera.grid")
        level = defaults.bool(forKey: "camera.level")
        shutterSound = defaults.bool(forKey: "camera.sound")
        saveScan = defaults.bool(forKey: "camera.scan")
        autoSaveToPhotos = defaults.bool(forKey: "camera.autoPhotos")
        keepRAW = defaults.bool(forKey: "camera.keepRAW")
        raw = defaults.bool(forKey: "camera.raw")
        autoFrame = defaults.bool(forKey: "camera.autoFrame")
        guide = defaults.bool(forKey: "camera.guide")
        aspect = PhotoAspect(rawValue: defaults.string(forKey: "camera.aspect") ?? "") ?? .standard
        caption = CaptionStyle(rawValue: defaults.string(forKey: "camera.caption") ?? "") ?? .bold
        flash = CameraFlash(rawValue: defaults.integer(forKey: "camera.flash")) ?? .off
    }
}
