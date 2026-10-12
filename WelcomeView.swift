import SwiftUI

struct WelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("focal").font(.system(size: 31, weight: .heavy, design: .rounded))
                        Circle().fill(Palette.ink).frame(width: 7, height: 7)
                        Spacer()
                        Eyebrow(text: "A little perspective")
                    }
                    .padding(.top, 12)

                    ZStack(alignment: .bottomLeading) {
                        Image("DemoScene")
                            .resizable()
                            .scaledToFill()
                            .frame(height: min(geometry.size.height * 0.40, 350))
                            .clipped()
                        LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                        ThirdsGrid().stroke(.white.opacity(0.35), lineWidth: 0.7)
                        VStack(alignment: .leading, spacing: 7) {
                            Label("A new way to see.", systemImage: "viewfinder")
                                .font(.system(.callout, design: .rounded, weight: .medium))
                            Eyebrow(text: "Find the balance in every frame")
                        }
                        .foregroundStyle(.white)
                        .padding(22)
                    }
                    .frame(height: min(geometry.size.height * 0.40, 350))
                    .clipShape(RoundedRectangle(cornerRadius: 26))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Good eye.\nGreat shot.")
                            .font(.system(size: 49, weight: .regular, design: .serif))
                            .tracking(-2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Find your subject. Follow the guide.\nMake a little more of what’s in front of you.")
                            .font(.subheadline)
                            .foregroundStyle(Palette.ink.opacity(0.65))
                            .lineSpacing(4)
                    }
                    Button(action: onContinue) {
                        HStack { Text("Let’s find your frame"); Spacer(); Image(systemName: "arrow.right") }
                            .padding(.horizontal, 20)
                    }
                    .buttonStyle(PrimaryButton())

                    Label("On-device guidance. Your photos stay yours.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(Palette.ink.opacity(0.65))
                        .frame(maxWidth: .infinity)
                }
                .padding(24)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
        .background(Palette.paper)
        .foregroundStyle(Palette.ink)
    }
}
