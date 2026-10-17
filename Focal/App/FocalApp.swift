import SwiftUI

@main
@MainActor
struct FocalApp: App {
    @UIApplicationDelegateAdaptor(FocalBackupAppDelegate.self) private var backupDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library: PhotoLibrary
    @StateObject private var settings = CameraSettings()
    @StateObject private var recipes = RecipeStore()

    init() {
        let library = PhotoLibrary()
        _library = StateObject(wrappedValue:library)
        PhotoBackupCoordinator.shared.attach(library)
    }
    var body: some Scene {
        WindowGroup {
            CameraView()
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(recipes)
                .tint(Palette.yellow)
                .preferredColorScheme(.dark)
                .onChange(of:scenePhase) { _,phase in
                    if phase == .active { PhotoBackupCoordinator.shared.foreground() }
                    else if phase == .background { PhotoBackupCoordinator.shared.backgrounded() }
                }
                .task { PhotoBackupCoordinator.shared.foreground() }
        }
    }
}
