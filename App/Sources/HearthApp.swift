import Core
import SwiftUI

/// The composition root. One `AppModel` for the app's life, made here so the
/// iOS background refresh can be registered with it before launch finishes
/// (SRC-6), and the platform's delegate for CloudKit invitations and pushes.
///
/// iOS: a window group, each window with its own tabs; the player opens full
/// screen in the window that asked.
///
/// tvOS: one window, the same as iOS underneath, with a root of its own for
/// the focus engine (`TVRootView`).
///
/// macOS: one main window (a `Window`, so the menu commands have one
/// navigation to drive), the player in windows of its own that can go full
/// screen, and Settings (⌘,). The player got real windows rather than a large
/// sheet because a sheet can't go full screen on its own, can't be moved
/// beside the guide, and blocks the main window while it plays.
@main
struct HearthApp: App {
    #if os(iOS) || os(tvOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    static let mainWindowID = "main"
    static let playerWindowID = "player"

    init() {
        HearthFonts.register()
        let model = AppModel()
        _model = State(initialValue: model)
        GuideRefreshScheduler.register(model: model)
    }

    var body: some Scene {
        #if os(macOS)
        Window(Text("Hearth"), id: Self.mainWindowID) {
            AppRootView(model: model)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands { HearthCommands(model: model) }
        .onChange(of: scenePhase) { _, phase in sceneChanged(phase) }

        WindowGroup(Text("Player"), id: Self.playerWindowID, for: UUID.self) { $sessionID in
            PlayerWindowContent(model: model, sessionID: sessionID)
        }
        .defaultSize(width: 1280, height: 720)
        .windowResizability(.contentMinSize)
        // A player window means nothing after a relaunch.
        .restorationBehavior(.disabled)

        Settings {
            SettingsWindowContent(model: model)
        }
        #else
        WindowGroup {
            AppRootView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in sceneChanged(phase) }
        #endif
    }

    /// The app as a whole came forward or went back (the app-level phase is
    /// the most active of its windows).
    private func sceneChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: model.becameActive()
        case .background: model.enteredBackground()
        default: break
        }
    }
}
