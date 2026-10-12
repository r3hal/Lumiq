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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if showGrid {
                ThirdsGrid().stroke(.white.opacity(0.27), lineWidth: 0.65)
            }
            if guideEnabled, let subject = reading.subject {
                if let bounds = reading.subjectBounds {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .frame(width: max(1, bounds.width * geometry.size.width),
                               height: max(1, bounds.height * geometry.size.height))
                        .position(x: bounds.midX * geometry.size.width, y: bounds.midY * geometry.size.height)
                }
                let target = position(reading.target, in: geometry.size)
                let current = position(subject, in: geometry.size)
                Path { path in
                    path.move(to: current)
                    path.addLine(to: target)
                }
                .stroke(.white.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))

                Circle()
                    .fill(Palette.mint.opacity(reading.state == .ready ? 0.3 : 0.08))
                    .frame(width: geometry.size.width * 0.13, height: geometry.size.width * 0.13)
                    .overlay(Circle().stroke(Palette.mint, lineWidth: 1.5))
                    .overlay {
                        if reading.state == .ready {
                            Image(systemName: "checkmark").font(.system(size: 19, weight: .medium)).foregroundStyle(Palette.mint)
                        } else {
                            Image(systemName: "plus").font(.system(size: 12, weight: .light)).foregroundStyle(Palette.mint)
                        }
                    }
                    .position(target)
                if reading.state != .ready {
                    Circle().fill(.white).frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.3), radius: 3)
                        .position(current)
                }
            }
            if guideEnabled {
                ZStack {
                    Rectangle().fill(.white.opacity(0.35)).frame(width: 70, height: 1)
                    HStack(spacing: 8) {
                        Capsule().frame(width: 26, height: 2)
                        Circle().frame(width: 4, height: 4)
                        Capsule().frame(width: 26, height: 2)
                    }
                    .foregroundStyle(abs(reading.rollDegrees) < 4 ? Palette.mint : .white)
                    .rotationEffect(.degrees(-reading.rollDegrees))
                }
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: reading.subject)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func position(_ point: UnitPoint2D, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
}
