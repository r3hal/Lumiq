import SwiftUI

@main
struct FocalApp: App {
    @StateObject private var library = PhotoLibrary()
    @StateObject private var settings = CameraSettings()

    var body: some Scene {
        WindowGroup {
            CameraView()
                .environmentObject(library)
                .environmentObject(settings)
                .tint(Palette.yellow)
                .preferredColorScheme(.dark)
        }
    }
}
