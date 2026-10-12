import SwiftUI

@main
struct FocalApp: App {
    @StateObject private var library = PhotoLibrary()
    @StateObject private var settings = CameraSettings()
    @StateObject private var recipes = RecipeStore()

    var body: some Scene {
        WindowGroup {
            CameraView()
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(recipes)
                .tint(Palette.yellow)
                .preferredColorScheme(.dark)
        }
    }
}
