import CatalogKit
import Core
import HouseholdKit
import LiveTVFeature
import PlayerKit
import SwiftUI

/// Every window's root: the launch screen while the stores open, a plain
/// failure screen if the household store can't (never a crash), the schema
/// ritual's screen, and once ready the platform's root with the services in
/// the environment. Sets the layout from the size class once, here
/// (`.compact` / `.sidebar`), and the dark scheme and amber tint.
struct AppRootView: View {
    let model: AppModel

    var body: some View {
        content
            .hearthLayoutFromSizeClass()
            .preferredColorScheme(.dark)
            .tint(HearthColor.accent)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .starting:
            LaunchScreen()
        case .failed(let message):
            StoreFailureView(message: message) { model.retry() }
        case .schemaInitializer(let status):
            SchemaInitializerView(status: status)
        case .ready:
            if let services = model.services {
                ReadyRoot(model: model, services: services)
                    .environment(services.catalog)
                    .environment(services.store)
                    .environment(services.session)
            } else {
                LaunchScreen()
            }
        }
    }
}

/// The platform root, once the household exists.
private struct ReadyRoot: View {
    let model: AppModel
    let services: AppServices

    var body: some View {
        #if os(macOS)
        MacRootView(model: model, services: services)
        #elseif os(tvOS)
        TVRootView(model: model, services: services)
        #else
        PhoneRootView(model: model, services: services)
        #endif
    }
}

// MARK: - One window's presentations

/// What every main window presents on top of its content: a route opened in
/// a sheet, the stream-limit warning (HH-6), a play that couldn't start, the
/// player itself on iOS (full screen; the Mac opens a window), multi-view
/// from the player, and a failed household invitation. Also gives the window
/// its `\.play` and `\.openRoute`, outermost so the sheets inherit them.
struct WindowPresentations: ViewModifier {
    let model: AppModel
    let services: AppServices
    let navigation: AppNavigation
    let sceneID: UUID

    @Environment(\.hearthLayout) private var layout

    private var playback: PlaybackCoordinator { services.playback }
    private var session: ProfileSession { services.session }

    func body(content: Content) -> some View {
        @Bindable var navigation = navigation
        content
            .sheet(item: $navigation.sheet) { sheet in
                RouteSheet(navigation: navigation, root: sheet.root)
                    .environment(\.play, playAction)
            }
            .sheet(item: limitPrompt) { prompt in
                StreamLimitSheet(prompt: prompt) { decision in
                    playback.resolveLimitPrompt(decision)
                }
            }
            .alert(
                playback.notice?.title ?? "",
                isPresented: noticeShowing,
                presenting: playback.notice
            ) { _ in
                Button(String(localized: "OK"), role: .cancel) { playback.notice = nil }
            } message: { notice in
                Text(notice.message)
            }
            .alert(
                String(localized: "Couldn't join the household"),
                isPresented: shareErrorShowing
            ) {
                Button(String(localized: "OK"), role: .cancel) { model.shareAcceptError = nil }
            } message: {
                Text(model.shareAcceptError ?? "")
            }
            .hearthFullScreenCover(item: presentedPlayer) { playerSession in
                PlayerView(model: playerSession.model)
                    .hearthStatusBarHidden()
                    .preferredColorScheme(.dark)
            }
            .hearthFullScreenCover(isPresented: multiViewShowing) {
                MultiViewSheet { playback.multiViewSceneID = nil }
                    .environment(services.catalog)
                    .environment(services.store)
                    .environment(services.session)
                    .environment(\.play, playAction)
                    .environment(\.hearthLayout, layout)
            }
            .onAppear { playback.lastSceneID = sceneID }
            .onChange(of: session.currentProfile?.id) { _, _ in
                // A profile switch: nothing of the last profile's browsing stays.
                navigation.reset()
            }
            .task(id: model.pendingLaunchTab) {
                if let tab = model.pendingLaunchTab {
                    navigation.select(tab)
                    model.pendingLaunchTab = nil
                }
            }
            .task(id: model.pendingLaunchRoute) {
                if let route = model.pendingLaunchRoute {
                    navigation.open(route, gateShowing: session.needsProfileSelection)
                    model.pendingLaunchRoute = nil
                }
            }
            .environment(\.play, playAction)
            .environment(\.openRoute, OpenRouteAction { [navigation, session] route in
                navigation.open(route, gateShowing: session.needsProfileSelection)
            })
    }

    private var playAction: PlayAction {
        let playback = playback
        let sceneID = sceneID
        let layout = layout
        return PlayAction { intent in
            playback.play(intent, sceneID: sceneID, layout: layout)
        }
    }

    // MARK: Bindings scoped to this window

    private var limitPrompt: Binding<StreamLimitPrompt?> {
        Binding(
            get: { playback.limitPrompt.flatMap { playback.targets($0.sceneID, scene: sceneID) ? $0 : nil } },
            set: { newValue in
                // Swiped away: the same as Cancel.
                if newValue == nil, playback.limitPrompt != nil { playback.resolveLimitPrompt(.cancel) }
            }
        )
    }

    private var noticeShowing: Binding<Bool> {
        Binding(
            get: { playback.notice.map { playback.targets($0.sceneID, scene: sceneID) } ?? false },
            set: { if !$0 { playback.notice = nil } }
        )
    }

    private var shareErrorShowing: Binding<Bool> {
        Binding(
            get: { model.shareAcceptError != nil && playback.lastSceneID == sceneID },
            set: { if !$0 { model.shareAcceptError = nil } }
        )
    }

    private var presentedPlayer: Binding<PlayerSession?> {
        Binding(
            get: { playback.presentedSession(forScene: sceneID) },
            set: { newValue in
                if newValue == nil, playback.presentedSession(forScene: sceneID) != nil { playback.closeCurrent() }
            }
        )
    }

    private var multiViewShowing: Binding<Bool> {
        Binding(
            get: { playback.multiViewSceneID.map { playback.targets($0, scene: sceneID) } ?? false },
            set: { if !$0 { playback.multiViewSceneID = nil } }
        )
    }
}

extension View {
    func windowPresentations(model: AppModel, services: AppServices, navigation: AppNavigation, sceneID: UUID) -> some View {
        modifier(WindowPresentations(model: model, services: services, navigation: navigation, sceneID: sceneID))
    }
}

/// Multi-view opened from the player's top bar (PLY-9): Live TV's screen
/// with a way back.
private struct MultiViewSheet: View {
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            MultiViewScreen()
                .navigationTitle(Text("Multi-view"))
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Done"), action: onDone)
                            .hearthCancelShortcut()
                            .accessibilityHint(Text("Closes multi-view and stops its channels"))
                    }
                }
        }
        .hearthScreenBackground()
    }
}

// MARK: - Before the household is ready

/// The launch screen while the stores open. A first launch on a device
/// signed in to iCloud waits up to 15 s for the household to arrive, so
/// after a moment it says what it is waiting for.
struct LaunchScreen: View {
    @State private var showsWaitingNote = false

    var body: some View {
        VStack(spacing: 18) {
            HearthLogo()
            if showsWaitingNote {
                VStack(spacing: 10) {
                    ProgressView().tint(HearthColor.textSecondary)
                    Text("Looking for your household in iCloud…")
                        .font(.hearthFootnote)
                        .foregroundStyle(HearthColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .transition(.opacity)
            }
        }
        .padding(HearthMetrics.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hearthScreenBackground()
        .task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { showsWaitingNote = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Hearth is starting"))
    }
}

/// The household store couldn't open (a damaged file, a full disk). Shown
/// instead of crashing, with the reason and a way to try again.
struct StoreFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        EmptyStateView(
            systemName: "exclamationmark.icloud",
            title: String(localized: "Hearth couldn't open your household"),
            message: String(localized: "\(message)\n\nYour favorites and progress are safe in iCloud. Try again, or restart the device if it keeps happening."),
            actionTitle: String(localized: "Try again"),
            action: retry
        )
        .frame(maxWidth: 520)
        .padding(HearthMetrics.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hearthScreenBackground()
    }
}

/// `-InitializeCloudKitSchema YES`: a plain screen while the schema goes to
/// iCloud Development; the script reads the result from stdout.
struct SchemaInitializerView: View {
    let status: String

    var body: some View {
        VStack(spacing: 16) {
            HearthLogoMark(size: 44)
            Text("CloudKit schema")
                .font(.hearthTitle)
                .foregroundStyle(HearthColor.textPrimary)
            Text(status)
                .font(.hearthBody)
                .foregroundStyle(HearthColor.textSecondary)
                .multilineTextAlignment(.center)
                .hearthTextSelectable()
        }
        .padding(HearthMetrics.screenPadding)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hearthScreenBackground()
    }
}

/// iCloud as the shell words it: a device with no account keeps the
/// household on this device only — a fact, not an error (4b).
struct ICloudStatusNote: View {
    @Environment(HouseholdStore.self) private var store

    var body: some View {
        if let text = ICloudStatusText.text(store.syncStatus) {
            Label {
                Text(text)
            } icon: {
                Image(systemName: "icloud.slash")
            }
            .font(.hearthCaption)
            .foregroundStyle(HearthColor.textTertiary)
            .accessibilityElement(children: .combine)
        }
    }
}

enum ICloudStatusText {
    /// Only the no-account case is worth a line in the shell; Household
    /// shows the full sync state.
    static func text(_ status: HouseholdSyncStatus) -> String? {
        switch status {
        case .noAccount: String(localized: "iCloud: Not signed in — this device only")
        case .local, .syncing, .upToDate, .failed: nil
        }
    }
}
