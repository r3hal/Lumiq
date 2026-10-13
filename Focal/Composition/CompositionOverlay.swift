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
    var guidanceReady = true
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
                FramingDirectionOverlay(reading: reading, phase: framingPhase, guidanceReady: guidanceReady)
                let rect = actual.intersection(CGRect(x:0,y:0,width:1,height:1))
                if !rect.isNull && rect.width > 0 && rect.height > 0 {
                    RoundedRectangle(cornerRadius:6).stroke(Palette.yellow,lineWidth:1.3)
                        .frame(width:rect.width*geometry.size.width,height:rect.height*geometry.size.height)
                        .position(x:rect.midX*geometry.size.width,y:rect.midY*geometry.size.height)
                        .transition(.opacity)
                    if let name = SubjectIdentity.name(subjectLabel) {
                        Text(name.lowercased()).font(.system(size:11,weight:.medium)).lineLimit(2)
                        .foregroundStyle(Palette.yellow).padding(.horizontal,7).padding(.vertical,4)
                        .background(.black.opacity(0.55),in:RoundedRectangle(cornerRadius:5))
                        .position(x:min(geometry.size.width-65,max(65,rect.midX*geometry.size.width)),
                                  y:min(geometry.size.height-18,max(18,rect.maxY*geometry.size.height+14)))
                    }
                }
            }
        }.animation(.linear(duration:0.16),value:reading.subjectBounds)
            .animation(.easeOut(duration:0.18),value:reading.subjectBounds != nil)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct FramingDirectionOverlay: View {
    let reading: CompositionReading
    let phase: FramingPhase
    let guidanceReady: Bool
    var body: some View {
        GeometryReader { geometry in
            let aspect = Double(geometry.size.width / max(1, geometry.size.height))
            if let cue = CompositionCue(reading: reading, previewAspect: aspect) {
                let ready = guidanceReady && cue.aligned && reading.state == .ready && !phase.isPreparing
                let color = ready ? Palette.mint : Palette.yellow
                if !cue.aligned && phase != .zooming {
                    CameraPanLine(subject: cue.subject, target: cue.target)
                        .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                    CameraPanArrow(subject: cue.subject, target: cue.target)
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                ZStack {
                    Circle().stroke(color, lineWidth: 1.6).frame(width: 25, height: 25)
                    if ready { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(color) }
                    else { Circle().fill(color).frame(width: 4, height: 4) }
                }.position(x: cue.target.x * geometry.size.width, y: cue.target.y * geometry.size.height)
            }
        }
    }
}

private struct CameraPanLine: Shape {
    let subject: UnitPoint2D
    let target: UnitPoint2D
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: target.x * rect.width, y: target.y * rect.height))
            path.addLine(to: CGPoint(x: subject.x * rect.width, y: subject.y * rect.height))
        }
    }
}

private struct CameraPanArrow: Shape {
    let subject: UnitPoint2D
    let target: UnitPoint2D
    func path(in rect: CGRect) -> Path {
        let start = CGPoint(x: target.x * rect.width, y: target.y * rect.height)
        let end = CGPoint(x: subject.x * rect.width, y: subject.y * rect.height)
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(1, hypot(dx, dy)), ux = dx / length, uy = dy / length
        // Arrow points in the camera pan direction, not the opposite direction
        // in which the subject moves across the screen.
        let tip = CGPoint(x: start.x + dx * 0.6, y: start.y + dy * 0.6)
        return Path { path in
            path.move(to: CGPoint(x: tip.x - ux * 8 - uy * 5, y: tip.y - uy * 8 + ux * 5))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: tip.x - ux * 8 + uy * 5, y: tip.y - uy * 8 - ux * 5))
        }
    }
}
