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
    var showDirection = true
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
                if let target = reading.targetCompositionRect, reading.shotPlanID != nil, framingPhase.isPreparing {
                    PlannedFrameOverlay(rect:target)
                }
                if showDirection { FramingDirectionOverlay(reading: reading, phase: framingPhase, guidanceReady: guidanceReady) }
                let rect = actual.intersection(CGRect(x:0,y:0,width:1,height:1))
                if !rect.isNull && rect.width > 0 && rect.height > 0 {
                        SubjectCorners().stroke(Palette.yellow, style: StrokeStyle(lineWidth:1.4,lineCap:.round))
                            .frame(width: rect.width * geometry.size.width, height: rect.height * geometry.size.height)
                            .position(x: rect.midX * geometry.size.width, y: rect.midY * geometry.size.height)
                    if let name = SubjectIdentity.name(subjectLabel) {
                        HStack(spacing: 6) {
                            Image(systemName: name.lowercased().contains("dog") || name.lowercased().contains("cat") ? "pawprint.fill" : "viewfinder")
                                .foregroundStyle(Palette.yellow)
                            Text(name + " detected").font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }.foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.black.opacity(0.7), in: Capsule())
                            .position(x: geometry.size.width / 2, y: 25)
                    }
                }
            }
        }.animation(.linear(duration:0.16),value:reading.subjectBounds)
            .animation(.easeOut(duration:0.18),value:reading.subjectBounds != nil)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A distinct source rectangle for the planned photograph, not another detector box.
private struct PlannedFrameOverlay: View {
    let rect: CGRect
    var body: some View {
        GeometryReader { geometry in
            let clipped = rect.intersection(CGRect(x:0,y:0,width:1,height:1))
            if !clipped.isNull && clipped.width > 0 && clipped.height > 0 {
                RoundedRectangle(cornerRadius:8)
                    .stroke(Palette.yellow.opacity(0.6),style:StrokeStyle(lineWidth:1,dash:[7,5]))
                    .frame(width:clipped.width*geometry.size.width,height:clipped.height*geometry.size.height)
                    .position(x:clipped.midX*geometry.size.width,y:clipped.midY*geometry.size.height)
                Text("Planned frame").font(.system(size:10,weight:.medium))
                    .foregroundStyle(Palette.yellow).padding(.horizontal,7).padding(.vertical,4)
                    .background(.black.opacity(0.6),in:Capsule())
                    .position(x:clipped.midX*geometry.size.width,y:max(14,clipped.minY*geometry.size.height-12))
            }
        }
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
                if !cue.aligned && !phase.isAutoFraming {
                    CameraPanLine(subject: cue.subject, target: cue.target)
                        .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                    CameraPanArrow(subject: cue.subject, target: cue.target)
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

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

private struct SubjectCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(19, min(rect.width, rect.height) * 0.24)
        return Path { path in
            for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                let dx: CGFloat = corner.x == rect.minX ? 1 : -1
                let dy: CGFloat = corner.y == rect.minY ? 1 : -1
                path.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
                path.addLine(to: corner)
                path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            }
        }
    }
}
