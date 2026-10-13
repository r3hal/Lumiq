import Foundation

struct AutoTuneRecommendation: Equatable, Identifiable {
    enum Kind: String { case highlights, light, motion, noise, zoom }
    var kind: Kind
    var title: String
    var reason: String
    var exposureBias: Double?
    var timestamp: TimeInterval
    var id: Kind { kind }
}

enum AutoTune {
    static func permitsApplication(_ recommendation:AutoTuneRecommendation,source:CameraSource,mode:CameraControlMode,manualExposure:Bool,paused:Bool,busy:Bool,now:TimeInterval) -> Bool {
        source == .iPhone && mode == .auto && !manualExposure && !paused && !busy
            && now.isFinite && recommendation.timestamp.isFinite && now >= recommendation.timestamp && now-recommendation.timestamp <= 2
            && recommendation.exposureBias?.isFinite == true
    }
    static func recommendations(measured: PhotoMeasurements, controls: CameraControlSnapshot, ev: Double?, evRange: ClosedRange<Double>?,
                                motion: Double?, zoom: Double, minimumZoom: Double, timestamp: TimeInterval, subjectMotion:Double? = nil) -> [AutoTuneRecommendation] {
        guard timestamp.isFinite, [measured.brightness,measured.highlightFraction,measured.shadowFraction,zoom,minimumZoom].allSatisfy(\.isFinite) else { return [] }
        var result = [AutoTuneRecommendation]()
        func add(_ kind:AutoTuneRecommendation.Kind,_ title:String,_ reason:String,_ bias:Double? = nil) {
            result.append(.init(kind:kind,title:title,reason:reason,exposureBias:bias,timestamp:timestamp))
        }
        if measured.highlightFraction > 0.12 {
            let target: Double?
            if controls.mode == .auto, controls.evAdjustable, !controls.manualExposure, let ev, let evRange, ev.isFinite {
                let proposed = max(evRange.lowerBound,min(evRange.upperBound,ev-1.0/3))
                target = proposed < ev-0.01 ? proposed : nil
            } else { target = nil }
            add(.highlights,"Protect bright areas",String(format:"%.0f%% of sampled preview pixels are near white. Try less exposure; RAW headroom may differ.",measured.highlightFraction*100),target)
        }
        if measured.brightness < 0.18 || measured.shadowFraction > 0.65 {
            add(.light,"Add light or stabilize", "The preview is dark. More light or camera support can help without forcing a high ISO.")
            if zoom.isFinite, minimumZoom > 0, zoom > minimumZoom*1.8 { add(.zoom,"Try a wider view","A wider available view reduces the need to enlarge a dark preview.") }
        }
        if let motion, motion.isFinite, motion > 0.25, let seconds = controls.seconds, seconds > 1/125.0 {
            add(.motion,"Use a shorter exposure","Device rotation was measured while the shutter duration is relatively long. Support the camera or shorten exposure.")
        } else if let subjectMotion, subjectMotion.isFinite, subjectMotion > 0.12, let seconds = controls.seconds, seconds > 1/125.0 {
            add(.motion,"Check motion blur","The tracked subject is shifting in a steady phone preview. Consider a shorter exposure if you want to freeze that movement.")
        }
        if let iso = controls.iso, let range = controls.isoRange, iso > range.upperBound*0.7, measured.brightness > 0.4,
           let seconds = controls.seconds, seconds < 1/200.0, (motion ?? .infinity) < 0.12 {
            add(.noise,"Consider a lower ISO","The camera is steady with high ISO and a short exposure. A longer exposure may permit lower ISO if the subject stays still.")
        }
        return result
    }
}
