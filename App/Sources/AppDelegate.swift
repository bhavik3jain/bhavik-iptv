import CloudKit
import Foundation

// Tapping a household invitation (Messages, Mail) has to land somewhere
// (HH-3). On a scene-based iOS app the entry point is a UIWindowSceneDelegate
// method, which exists only when something supplies the scene configuration —
// hence the UIApplicationDelegate as well; SwiftUI has no equivalent of
// either. The Mac's NSApplicationDelegate gets the callback directly.
// Multitrack's ShareAcceptDelegate, adapted. Both forward to `ShareInbox`,
// which holds an invitation until the household store is ready.
//
// Both delegates also register for remote notifications: CloudKit's silent
// pushes are what make a partner's favorite land in seconds rather than at
// the next launch (needs `aps-environment`, which both entitlements carry).

/// Invitations accepted before the store was ready wait here.
@MainActor
enum ShareInbox {
    private static var handler: ((CKShare.Metadata) -> Void)?
    private static var pending: [CKShare.Metadata] = []

    static func receive(_ metadata: CKShare.Metadata) {
        if let handler {
            handler(metadata)
        } else {
            pending.append(metadata)
        }
    }

    /// Called once the services are ready; delivers anything that waited.
    static func attach(_ newHandler: @escaping (CKShare.Metadata) -> Void) {
        handler = newHandler
        let waiting = pending
        pending.removeAll()
        waiting.forEach(newHandler)
    }
}

#if os(iOS) || os(tvOS)
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    /// The only way to name a custom UIWindowSceneDelegate; without it
    /// `windowScene(_:userDidAcceptCloudKitShareWith:)` is never called.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// A tap that launches the app brings the invitation here; the callback
    /// below is then never called (Multitrack missed this path at first).
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            MainActor.assumeIsolated { ShareInbox.receive(metadata) }
        }
    }

    /// The app was already running.
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        MainActor.assumeIsolated { ShareInbox.receive(cloudKitShareMetadata) }
    }
}
#endif

#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    /// No scene layer on the Mac: the app delegate hears every acceptance,
    /// whether or not the app was running.
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        MainActor.assumeIsolated { ShareInbox.receive(metadata) }
    }

    /// Closing the last window doesn't quit: the player and Settings are
    /// windows of their own, and a household app is usually reopened.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
#endif
