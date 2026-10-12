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
    var showLevel = false
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
            if guideEnabled, reading.subjectConfidence >= 0.4, let actual = reading.subjectBounds {
                let rect = actual.intersection(CGRect(x:0,y:0,width:1,height:1))
                if !rect.isNull && rect.width > 0 && rect.height > 0 {
                    RoundedRectangle(cornerRadius:6).stroke(Palette.yellow,lineWidth:1.3)
                        .frame(width:rect.width*geometry.size.width,height:rect.height*geometry.size.height)
                        .position(x:rect.midX*geometry.size.width,y:rect.midY*geometry.size.height)
                        .transition(.opacity)
                    Text(subjectLabel.lowercased()).font(.system(size:11,weight:.medium)).lineLimit(2)
                        .foregroundStyle(Palette.yellow).padding(.horizontal,7).padding(.vertical,4)
                        .background(.black.opacity(0.55),in:RoundedRectangle(cornerRadius:5))
                        .position(x:min(geometry.size.width-65,max(65,rect.midX*geometry.size.width)),
                                  y:min(geometry.size.height-18,max(18,rect.maxY*geometry.size.height+14)))
                }
            }
        }.animation(.linear(duration:0.16),value:reading.subjectBounds)
            .animation(.easeOut(duration:0.18),value:reading.subjectBounds != nil)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
