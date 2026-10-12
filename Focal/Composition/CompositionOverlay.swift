import SwiftUI

struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            for fraction in [CGFloat(1.0 / 3), CGFloat(2.0 / 3)] {
                path.move(to: CGPoint(x: rect.width * fraction, y: 0))
                path.addLine(to: CGPoint(x: rect.width * fraction, y: rect.height))
                path.move(to: CGPoint(x: 0, y: rect.height * fraction))
                path.addLine(to: CGPoint(x: rect.width, y: rect.height * fraction))
            }
        }
    }
}

struct CompositionOverlay: View {
    let reading: CompositionReading
    let showGrid: Bool
    let guideEnabled: Bool
    var showLevel = true
    var subjectLabel = "Subject"
    var framingPhase: FramingPhase = .off
    var body: some View {
        GeometryReader { geometry in
            if showGrid { ThirdsGrid().stroke(.white.opacity(0.22), lineWidth: 0.6) }
            if showLevel {
                Rectangle().fill(Palette.yellow).frame(width: geometry.size.width * 0.36, height: 1.5)
                    .rotationEffect(.degrees(-reading.rollDegrees))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                Rectangle().fill(abs(reading.rollDegrees) < 4 ? Palette.mint : Palette.yellow)
                    .frame(width: 2, height: 16).position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            if guideEnabled, let point = reading.subject {
                if framingPhase.isPreparing, let rect = reading.subjectBounds {
                    RoundedRectangle(cornerRadius: 7).stroke(Palette.yellow, lineWidth: 1.5)
                        .frame(width: rect.width * geometry.size.width, height: rect.height * geometry.size.height)
                        .position(x: rect.midX * geometry.size.width, y: rect.midY * geometry.size.height)
                }
                if reading.state == .adjusting && !framingPhase.isPreparing {
                    Image(systemName: "plus").font(.system(size: 16, weight: .light)).foregroundStyle(Palette.yellow)
                        .position(x: reading.target.x * geometry.size.width, y: reading.target.y * geometry.size.height)
                }
                HStack(spacing: 5) {
                    Circle().fill(framingPhase.isPreparing ? Palette.yellow : Palette.mint).frame(width: 4, height: 4)
                    Text(subjectLabel.lowercased()).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                }
                .foregroundStyle(framingPhase.isPreparing ? Palette.yellow : Palette.mint).padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: 145, alignment: .leading)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                .position(x: min(geometry.size.width - 78, max(78, point.x * geometry.size.width)),
                          y: min(geometry.size.height - 26, max(26, (reading.subjectBounds?.maxY ?? point.y) * geometry.size.height + 18)))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
