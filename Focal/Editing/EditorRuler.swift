import SwiftUI

struct EditorRuler: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let title: String
    let begin: () -> Void
    let commit: () -> Void
    @State private var dragging = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(0..<41, id: \.self) { tick in
                    Rectangle().fill(Color.white.opacity(tick % 5 == 0 ? 0.3 : 0.13))
                        .frame(width: 1, height: tick % 5 == 0 ? 16 : 9)
                        .position(x: CGFloat(tick) / 40 * geometry.size.width, y: 20)
                }
                Rectangle().fill(Palette.yellow).frame(width: 2, height: 27)
                    .position(x: CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * geometry.size.width, y: 20)
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    if !dragging { dragging = true; begin() }
                    let fraction = finiteClamp(Double(event.location.x / max(1, geometry.size.width)), 0...1)
                    value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                }.onEnded { _ in dragging = false; commit() })
        }.frame(height: 40)
            .accessibilityElement().accessibilityLabel(title).accessibilityValue(String(format: "%.2f", value))
            .accessibilityAdjustableAction { direction in
                begin()
                let step = (range.upperBound - range.lowerBound) / 100
                value = finiteClamp(value + (direction == .increment ? step : -step), range)
                commit()
            }
    }
}
