import SwiftUI

enum Palette {
    static let ink = Color.black
    static let panel = Color(white: 0.12)
    static let paper = Color(red: 0.95, green: 0.94, blue: 0.90)
    static let mint = Color(red: 76.0 / 255, green: 217.0 / 255, blue: 100.0 / 255)
    static let yellow = Color(red: 1, green: 211.0 / 255, blue: 42.0 / 255)
}

struct CameraPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(.caption2, design: .monospaced, weight: .medium))
            .tracking(2)
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 19)
            .foregroundStyle(Palette.ink)
            .background(Palette.mint.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct RoundToolButton: View {
    let symbol: String
    let label: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(selected ? Palette.ink : .white)
                .frame(width: 46, height: 46)
                .background(selected ? Palette.mint : Color.white.opacity(0.10), in: Circle())
        }
        .accessibilityLabel(label)
        .accessibilityValue(selected ? "On" : "Off")
    }
}
