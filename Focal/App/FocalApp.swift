import SwiftUI

@main
struct FocalApp: App {
    @StateObject private var library = PhotoLibrary()
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasSeenWelcome { RootView() }
                else { WelcomeView { hasSeenWelcome = true } }
            }
                .environmentObject(library)
                .tint(Palette.mint)
                .preferredColorScheme(.dark)
        }
    }
}

private struct RootView: View {
    var body: some View {
        TabView {
            CameraView()
                .tabItem { Label("Camera", systemImage: "camera") }
            LibraryView()
                .tabItem { Label("Your shots", systemImage: "square.stack") }
            FieldGuideView()
                .tabItem { Label("Field notes", systemImage: "sparkles") }
        }
        .toolbarBackground(Palette.ink, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}
