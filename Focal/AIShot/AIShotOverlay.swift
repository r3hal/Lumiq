import SwiftUI

/// Viewfinder overlay for AI Shot: target box, center crosshair, label pill.
struct AIShotOverlay: View {
    @ObservedObject var model: AIShotModel

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let center = CGPoint(x:size.width/2,y:size.height/2)
            ZStack {
                if model.phase == .finding { FindingBrackets().frame(width:size.width*0.42,height:size.width*0.42).position(center) }
                if model.phase.isLocked, let f = model.frame {
                    let rect = CGRect(x:f.minX*size.width,y:f.minY*size.height,width:f.width*size.width,height:f.height*size.height)
                    let target = CGPoint(x:rect.midX,y:rect.midY)
                    let ready = model.phase == .ready
                    if f.width < 0.85 {
                        RoundedRectangle(cornerRadius:12)
                            .stroke(Palette.yellow,style:StrokeStyle(lineWidth:ready ? 3 : 2.5))
                            .frame(width:rect.width,height:rect.height).position(target)
                            .shadow(color:.black.opacity(0.35),radius:3)
                    }
                    if model.phase == .aiming && hypot(target.x-center.x,target.y-center.y) > 18 {
                        Path { path in path.move(to:center); path.addLine(to:target) }
                            .stroke(Palette.yellow.opacity(0.8),style:StrokeStyle(lineWidth:1.5,dash:[4,5]))
                    }
                    PlusMark().stroke(ready ? Palette.yellow : Palette.mint,style:StrokeStyle(lineWidth:2,lineCap:.round))
                        .frame(width:16,height:16).position(target)
                }
                if model.phase.isActive && model.phase != .finding {
                    PlusMark().stroke(Color.white.opacity(0.9),style:StrokeStyle(lineWidth:1.2,lineCap:.round))
                        .frame(width:24,height:24).position(center)
                }
            }
            .overlay(alignment:.top) { pill.padding(.top,12) }
            .animation(.easeOut(duration:0.12),value:model.frame)
            .animation(.easeInOut(duration:0.2),value:model.phase)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var pill: some View {
        switch model.phase {
        case .finding:
            HStack(spacing:7) { ProgressView().controlSize(.mini).tint(Palette.yellow); Text("Finding your shot…") }
                .modifier(PillStyle())
        case .aiming, .zooming, .ready:
            HStack(spacing:8) {
                Text(model.suggestion?.subject ?? "your shot").lineLimit(1)
                if model.phase == .ready {
                    Rectangle().fill(.white.opacity(0.35)).frame(width:1,height:12)
                    Text("Ready").foregroundStyle(Palette.yellow).fontWeight(.semibold)
                }
            }.modifier(PillStyle())
        default: EmptyView()
        }
    }
}

/// Instruction line under the viewfinder (replaces the classic guidance card).
struct AIShotInstruction: View {
    @ObservedObject var model: AIShotModel
    var body: some View {
        HStack(spacing:8) {
            if let direction = model.direction, model.phase == .aiming {
                Image(systemName:"arrow.up").rotationEffect(.radians(atan2(direction.dx,-direction.dy)))
                    .foregroundStyle(Palette.yellow)
            } else if model.phase == .ready {
                Image(systemName:"checkmark.circle.fill").foregroundStyle(Palette.yellow)
            } else if case .failed = model.phase {
                Image(systemName:"exclamationmark.circle").foregroundStyle(.orange)
            }
            Text(model.instruction).lineLimit(2).multilineTextAlignment(.center)
        }
        .font(.system(size:14,weight:.medium))
        .foregroundStyle(.white)
        .padding(.horizontal,14).padding(.vertical,8)
        .background(.black.opacity(0.6),in:Capsule())
        .animation(.easeInOut(duration:0.2),value:model.instruction)
        .accessibilityElement(children:.combine)
    }
}

private struct PillStyle: ViewModifier {
    func body(content:Content) -> some View {
        content.font(.system(size:12,weight:.medium)).foregroundStyle(.white)
            .padding(.horizontal,12).padding(.vertical,6)
            .background(.black.opacity(0.62),in:Capsule())
    }
}

struct PlusMark: Shape {
    func path(in rect:CGRect) -> Path {
        Path { p in
            p.move(to:CGPoint(x:rect.midX,y:rect.minY)); p.addLine(to:CGPoint(x:rect.midX,y:rect.maxY))
            p.move(to:CGPoint(x:rect.minX,y:rect.midY)); p.addLine(to:CGPoint(x:rect.maxX,y:rect.midY))
        }
    }
}

/// Four soft corner brackets that breathe while the AI looks at the scene.
private struct FindingBrackets: View {
    @State private var pulse = false
    var body: some View {
        CornerBrackets()
            .stroke(Palette.yellow,style:StrokeStyle(lineWidth:2.5,lineCap:.round,lineJoin:.round))
            .scaleEffect(pulse ? 1.06 : 0.94).opacity(pulse ? 1 : 0.55)
            .onAppear { withAnimation(.easeInOut(duration:0.8).repeatForever(autoreverses:true)) { pulse = true } }
    }
}

struct CornerBrackets: Shape {
    func path(in rect:CGRect) -> Path {
        let arm = min(rect.width,rect.height)*0.22
        return Path { p in
            let corners: [(CGPoint,CGFloat,CGFloat)] = [(CGPoint(x:rect.minX,y:rect.minY),1,1),(CGPoint(x:rect.maxX,y:rect.minY),-1,1),
                                                        (CGPoint(x:rect.minX,y:rect.maxY),1,-1),(CGPoint(x:rect.maxX,y:rect.maxY),-1,-1)]
            for (corner,sx,sy) in corners {
                p.move(to:CGPoint(x:corner.x+sx*arm,y:corner.y)); p.addLine(to:corner); p.addLine(to:CGPoint(x:corner.x,y:corner.y+sy*arm))
            }
        }
    }
}
