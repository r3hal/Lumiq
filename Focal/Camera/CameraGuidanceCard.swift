import SwiftUI

enum CameraViewportLayout {
    static func aspect(source: CameraSource, capture: PhotoAspect, sonyFullFrame: Bool, sonyAspect: Double, width: Double, height: Double) -> Double {
        if source == .sony && sonyFullFrame { return sonyAspect }
        // Keep the visible frame identical to the selected capture crop.
        return capture.ratio
    }
}

/// Presentation is derived from measured service state, never a timed demo.
enum CameraGuideState: Equatable {
    case off, searching, scene, recovering, detected, guiding, holding, zooming, ready
    static func resolve(enabled: Bool, reading: CompositionReading, phase: FramingPhase, message: GuidanceMessage) -> Self {
        guard enabled else { return .off }
        if phase.isRecovering { return .recovering }
        let validBounds = reading.subjectBounds.map { !$0.isNull && $0.width > 0 && $0.height > 0 && [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) } ?? false
        let confirmed = validBounds && reading.subjectConfidence >= 0.4
        if !confirmed,reading.sceneFrameVerified,message.kind == .ready,reading.state == .ready,phase == .framed { return .ready }
        guard confirmed else { return message.kind == .steady ? .recovering : message.kind == .scene ? .scene : .searching }
        if phase.isAutoFraming { return .zooming }
        if message.kind == .ready && reading.state == .ready && !phase.isPreparing { return .ready }
        if message.kind == .detected { return .detected }
        if phase == .settling || message.kind == .steady { return .holding }
        return .guiding
    }
    var symbol: String {
        switch self {
        case .off: return "sparkles"
        case .searching, .recovering: return "viewfinder"
        case .scene: return "mountain.2"
        case .detected: return "viewfinder.circle"
        case .guiding: return "arrow.up.and.down.and.arrow.left.and.right"
        case .holding: return "hand.raised.circle"
        case .zooming: return "arrow.up.left.and.arrow.down.right"
        case .ready: return "checkmark.circle.fill"
        }
    }
}

struct CameraGuidanceCard: View {
    let state: CameraGuideState
    let instruction: String
    let holdProgress: Double
    var showHoldProgress = true
    var composition: String? = nil
    var body: some View {
        if state != .off && !instruction.isEmpty {
            VStack(spacing: 7) {
                HStack(spacing: 10) {
                    if state == .zooming { ProgressView().tint(Palette.yellow).scaleEffect(0.8) }
                    else { Image(systemName: state.symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(state == .detected ? Palette.yellow : Palette.mint) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(state == .detected || state == .zooming ? Color.white : Palette.mint)
                        if instruction != title { Text(instruction).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true).lineLimit(2) }
                        if let composition, state != .searching && state != .recovering {
                            Text(composition).font(.system(size:10,weight:.medium)).foregroundStyle(Palette.yellow)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if state == .holding && showHoldProgress {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                            Capsule().fill(Palette.mint).frame(width: geometry.size.width * min(1, max(0, holdProgress)))
                        }
                    }.frame(height: 3)
                    .animation(.linear(duration: 0.18), value: holdProgress)
                }
            }.padding(.horizontal, 13).padding(.vertical, 10)
                .background(.black.opacity(0.73), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.07), lineWidth: 0.5))
                .frame(maxWidth: 300).accessibilityElement(children: .combine)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }
    private var title: String {
        switch state {
        case .off: return ""
        case .searching: return "Finding your shot"
        case .scene: return "Scene assessment"
        case .recovering: return "Finding your shot"
        case .detected: return "Subject acquired"
        case .guiding: return instruction
        case .holding: return "Capture guidance"
        case .zooming: return "Framing your shot"
        case .ready: return instruction == "Shot ready" ? "Shot ready" : "Ready to shoot"
        }
    }
}
