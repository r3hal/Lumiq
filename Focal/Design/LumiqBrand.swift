import SwiftUI

/// Lumiq logo system: Ink #15151D, Porcelain #F6F5FA, Iris #6551D8, Soft Iris #AEA2FF.
enum Brand {
    static let ink = Color(red:0x15/255.0,green:0x15/255.0,blue:0x1D/255.0)
    static let porcelain = Color(red:0xF6/255.0,green:0xF5/255.0,blue:0xFA/255.0)
    static let iris = Color(red:0x65/255.0,green:0x51/255.0,blue:0xD8/255.0)
    static let softIris = Color(red:0xAE/255.0,green:0xA2/255.0,blue:0xFF/255.0)
}

/// Geometry is drawn in a 135×135 design box (same as the icon artwork).
private func designTransform(_ rect:CGRect) -> CGAffineTransform {
    let s = min(rect.width,rect.height)/135
    return CGAffineTransform(translationX:rect.midX-67.5*s,y:rect.midY-67.5*s).scaledBy(x:s,y:s)
}

/// The two viewfinder corners of the mark.
struct LumiqBrackets: Shape {
    var weight: CGFloat = 14
    func path(in rect:CGRect) -> Path {
        var p = Path()
        p.move(to:CGPoint(x:72,y:7)); p.addLine(to:CGPoint(x:24,y:7))
        p.addArc(center:CGPoint(x:24,y:24),radius:17,startAngle:.degrees(270),endAngle:.degrees(180),clockwise:true)
        p.addLine(to:CGPoint(x:7,y:70))
        p.move(to:CGPoint(x:128,y:65)); p.addLine(to:CGPoint(x:128,y:100))
        p.addArc(center:CGPoint(x:100,y:100),radius:28,startAngle:.degrees(0),endAngle:.degrees(90),clockwise:false)
        p.addLine(to:CGPoint(x:63,y:128))
        return p.strokedPath(StrokeStyle(lineWidth:weight,lineCap:.round,lineJoin:.round)).applying(designTransform(rect))
    }
}

/// The four-point spark of the mark.
struct LumiqSpark: Shape {
    func path(in rect:CGRect) -> Path {
        var p = Path()
        p.move(to:CGPoint(x:68,y:35))
        p.addQuadCurve(to:CGPoint(x:100,y:67),control:CGPoint(x:71,y:64))
        p.addQuadCurve(to:CGPoint(x:68,y:99),control:CGPoint(x:71,y:70))
        p.addQuadCurve(to:CGPoint(x:36,y:67),control:CGPoint(x:65,y:70))
        p.addQuadCurve(to:CGPoint(x:68,y:35),control:CGPoint(x:65,y:64))
        p.closeSubpath()
        return p.applying(designTransform(rect))
    }
}

struct LumiqMark: View {
    var starColor: Color = Brand.softIris
    var bracketColor: Color = Brand.porcelain
    var weight: CGFloat = 14
    var body: some View {
        ZStack {
            LumiqBrackets(weight:weight).fill(bracketColor)
            LumiqSpark().fill(starColor)
        }
        .aspectRatio(1,contentMode:.fit)
        .accessibilityHidden(true)
    }
}

/// Mark + "Lumiq" wordmark, as in the primary logo.
struct LumiqLogo: View {
    var height: CGFloat = 24
    var textColor: Color = Brand.porcelain
    var starColor: Color = Brand.softIris
    var body: some View {
        HStack(spacing:height*0.32) {
            LumiqMark(starColor:starColor,bracketColor:textColor).frame(width:height,height:height)
            Text("Lumiq").font(.system(size:height*1.05,weight:.medium)).tracking(-0.3).foregroundStyle(textColor)
        }
        .accessibilityElement(children:.ignore).accessibilityLabel("Lumiq")
    }
}

/// Shown when the app opens. Starts exactly like the static launch screen
/// (mark centered on Ink) so there is no visible jump, then reveals the name.
struct LumiqSplashView: View {
    @State private var revealed = false
    @State private var sparkle = false
    var body: some View {
        ZStack {
            Brand.ink.ignoresSafeArea()
            VStack(spacing:22) {
                ZStack {
                    LumiqBrackets().fill(Brand.porcelain)
                    LumiqSpark().fill(Brand.softIris)
                        .scaleEffect(sparkle ? 1 : 0.6).rotationEffect(.degrees(sparkle ? 0 : -45))
                }
                .frame(width:120,height:120)
                Text("Lumiq").font(.system(size:40,weight:.medium)).tracking(-0.5).foregroundStyle(Brand.porcelain)
                    .opacity(revealed ? 1 : 0).offset(y:revealed ? 0 : 8)
            }
            .offset(y:revealed ? 0 : 35) // Keeps the mark at the launch-screen center until the name appears.
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(response:0.55,dampingFraction:0.6)) { sparkle = true }
            withAnimation(.easeOut(duration:0.45).delay(0.15)) { revealed = true }
        }
    }
}
