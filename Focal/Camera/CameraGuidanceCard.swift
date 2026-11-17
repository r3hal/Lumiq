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

/// Keeps the guidance card readable. The service measures at several frames
/// per second and its wording can legitimately change between phases faster
/// than a photographer can read it, which showed up on device as the card
/// flashing between "Finding", "Framing" and "Aim" lines. Ordinary wording
/// changes must persist briefly and the shown line stays up for a minimum
/// time. Honest state changes are never delayed: guidance off, active zoom,
/// entering READY and leaving READY are shown at once, so the card cannot
/// claim a ready frame the camera has stopped measuring. Showing a card from
/// hidden is immediate; hiding one needs the same short persistence.
struct GuidancePresentationStabilizer {
    struct Presentation: Equatable {
        var state: CameraGuideState
        var instruction: String
        var visible: Bool { state != .off && !instruction.isEmpty }
    }
    static let minimumDisplay: TimeInterval = 0.7
    static let candidateDwell: TimeInterval = 0.3
    private(set) var shown: Presentation?
    private var shownAt: TimeInterval = -.infinity
    private var candidate: Presentation?
    private var candidateSince: TimeInterval = -.infinity

    mutating func reset() { self = Self() }

    /// Returns what to display and, while a change is pending, when to ask again.
    mutating func update(_ next: Presentation, at time: TimeInterval) -> (presentation: Presentation, recheckAt: TimeInterval?) {
        guard time.isFinite else { reset(); return (next, nil) }
        guard let current = shown, time >= shownAt else { return commit(next, at: time) }
        if next == current { candidate = nil; return (current, nil) }
        if Self.isImmediate(from: current, to: next) { return commit(next, at: time) }
        if candidate != next { candidate = next; candidateSince = time }
        let due = max(shownAt + Self.minimumDisplay, candidateSince + Self.candidateDwell)
        if time >= due { return commit(next, at: time) }
        return (current, due)
    }

    static func isImmediate(from current: Presentation, to next: Presentation) -> Bool {
        let honest: [CameraGuideState] = [.off, .ready, .zooming]
        if honest.contains(next.state) || current.state == .off || current.state == .ready { return true }
        return !current.visible && next.visible
    }

    private mutating func commit(_ next: Presentation, at time: TimeInterval) -> (presentation: Presentation, recheckAt: TimeInterval?) {
        shown = next; shownAt = time; candidate = nil
        return (next, nil)
    }
}

/// Main-thread driver for `GuidancePresentationStabilizer`. It re-evaluates a
/// pending change once its dwell expires even if no newer reading arrives.
@MainActor
final class GuidanceCardPresenter: ObservableObject {
    @Published private(set) var presentation = GuidancePresentationStabilizer.Presentation(state: .off, instruction: "")
    private var stabilizer = GuidancePresentationStabilizer()
    private var latest: GuidancePresentationStabilizer.Presentation?
    private var recheck: Task<Void, Never>?

    func submit(_ next: GuidancePresentationStabilizer.Presentation) {
        latest = next
        evaluate()
    }

    private func evaluate() {
        guard let latest else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let result = stabilizer.update(latest, at: now)
        if presentation != result.presentation { presentation = result.presentation }
        recheck?.cancel(); recheck = nil
        guard let due = result.recheckAt else { return }
        let delay = UInt64(max(0.02, due - now) * 1_000_000_000)
        recheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.evaluate()
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
