import SwiftUI

enum Palette {
    static let ink = Color(red:16.0/255,green:17.0/255,blue:18.0/255)
    static let panel = Color(red:35.0/255,green:37.0/255,blue:39.0/255)
    static let text = Color(white:247.0/255)
    static let muted = Color(red:158.0/255,green:163.0/255,blue:168.0/255)
    static let paper = Color(red: 0.95, green: 0.94, blue: 0.90)
    static let mint = Color(red:0.45,green:0.74,blue:0.58)
    static let yellow = Color(red:237.0/255,green:202.0/255,blue:103.0/255)
}

struct FocalIntelligenceMark: Shape {
    func path(in rect:CGRect) -> Path {
        let c = CGPoint(x:rect.midX,y:rect.midY), half = min(rect.width,rect.height)*0.35, arm = half*0.4
        return Path { path in
            for sx in [-1.0,1.0] {
                for sy in [-1.0,1.0] {
                    let p = CGPoint(x:c.x+sx*half,y:c.y+sy*half)
                    path.move(to:CGPoint(x:p.x-sx*arm,y:p.y)); path.addLine(to:p)
                    path.addLine(to:CGPoint(x:p.x,y:p.y-sy*arm))
                }
            }
            path.move(to:CGPoint(x:c.x,y:c.y-half*0.4))
            path.addLine(to:CGPoint(x:c.x+half*0.35,y:c.y))
            path.addLine(to:CGPoint(x:c.x,y:c.y+half*0.4))
            path.addLine(to:CGPoint(x:c.x-half*0.35,y:c.y)); path.closeSubpath()
        }
    }
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
