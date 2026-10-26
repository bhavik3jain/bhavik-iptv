#if os(macOS)
import CatalogKit
import Core
import HouseholdFeature
import HouseholdKit
import PlayerKit
import ProfilesFeature
import SettingsFeature
import SwiftUI

/// The Mac's main window (MAC-1, mockup 07): a sidebar with the profile
/// switcher, a search field, the sections, the profile's favorite channels
/// (click to play) and each source's streams at the foot; the detail is one
/// navigation stack per section with every route mapped. "Who's watching?"
/// covers the whole window until a profile is chosen (PRF-2).
struct MacRootView: View {
    let model: AppModel
    let services: AppServices

    @State private var sceneID = UUID()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(ProfileSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var navigation: AppNavigation { model.macNavigation }

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                MacSidebar(navigation: navigation)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
            } detail: {
                NavigationStack(path: navigation.path(for: navigation.selection)) {
                    TabRoot(tab: navigation.selection, navigation: navigation)
                        .hearthRouteDestinations()
                }
                // Each section keeps its own stack; switching shows its last page.
                .id(navigation.selection)
            }
            .navigationSplitViewStyle(.balanced)
            .disabled(session.needsProfileSelection)
            .accessibilityHidden(session.needsProfileSelection)

            if session.needsProfileSelection {
                WhoIsWatchingView(onManageHousehold: {
                    navigation.open(.household, gateShowing: true)
                })
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.needsProfileSelection)
        .frame(minWidth: 1000, minHeight: 640)
        .windowPresentations(model: model, services: services, navigation: navigation, sceneID: sceneID)
        .onAppear {
            // The Mac plays in a window of its own (see HearthApp).
            services.playback.openPlayerWindow = { id in openWindow(id: HearthApp.playerWindowID, value: id) }
            navigation.showSettings = { openSettings() }
        }
    }
}

/// The sidebar's rows (mockup 07).
private struct MacSidebar: View {
    let navigation: AppNavigation

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.play) private var play
    @State private var searchText = ""

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(AppTab.macSections, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .font(.hearthBody)
                        .tag(tab)
                        .accessibilityHint(Text("Shows \(tab.title)"))
                }
            }

            let favorites = favoriteChannels
            if !favorites.isEmpty {
                Section {
                    ForEach(favorites) { channel in
                        FavoriteChannelRow(channel: channel, isLive: catalog.nowAndNext(for: channel).now != nil) {
                            play(PlaybackCoordinator.liveIntent(for: channel, queue: favorites.map(\.key.rawValue)))
                        }
                    }
                } header: {
                    SectionLabel(String(localized: "Favorite channels"))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(HearthColor.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 12) {
                ProfileSwitcherMenu(style: .sidebar)
                SearchField(String(localized: "Search everything"), text: $searchText) {
                    submitSearch()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(HearthColor.sidebar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                StreamUsageSummaryView()
                ICloudStatusNote()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HearthColor.sidebar)
        }
    }

    private var selection: Binding<AppTab?> {
        Binding(
            get: { navigation.selection },
            set: { if let tab = $0 { navigation.select(tab) } }
        )
    }

    /// The current profile's favorite channels the catalog can show, in the
    /// profile's order (FAV-1). Reads both revisions so the list follows
    /// edits, syncs and refreshes.
    private var favoriteChannels: [CatalogChannel] {
        _ = catalog.revision
        _ = store.revision
        guard let profile = session.currentProfile, !profile.isGuest else { return [] }
        let keys = store.favorites(profileID: profile.id, kind: .channel).map { ItemKey(rawValue: $0.itemKey) }
        return catalog.channels(keys: keys)
    }

    private func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        navigation.submittedSearch = query
        navigation.paths[.search] = []
        navigation.select(.search)
    }
}

/// A favorite channel in the sidebar: its logo or monogram, its name, and an
/// amber dot while something is on (the guide has a programme now).
private struct FavoriteChannelRow: View {
    let channel: CatalogChannel
    let isLive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ChannelLogo(name: channel.name, url: channel.logoURL, size: 26)
                Text(channel.name)
                    .font(.hearthBody)
                    .foregroundStyle(HearthColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isLive {
                    Circle()
                        .fill(HearthColor.accent)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(channel.name))
        .accessibilityValue(isLive ? Text("On now") : Text(""))
        .accessibilityHint(Text("Plays this channel"))
    }
}

// MARK: - Other windows

/// The player in a window of its own (MAC-1): resizable, and full screen
/// with F (PlayerView) or ⌃⌘F (View menu). Closing the window stops the
/// stream; the player closing itself (Esc, its close button, a new play)
/// closes the window.
struct PlayerWindowContent: View {
    let model: AppModel
    let sessionID: UUID?

    @Environment(\.dismiss) private var dismiss

    private var playerSession: PlayerSession? {
        guard let current = model.services?.playback.current, current.id == sessionID else { return nil }
        return current
    }

    var body: some View {
        Group {
            if let playerSession {
                PlayerView(model: playerSession.model)
                    .navigationTitle(playerSession.model.item.title)
            } else {
                // A window restored or left over with no player behind it.
                Color.black
                    .onAppear { dismiss() }
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onChange(of: model.services?.playback.current?.id) { _, newID in
            if newID != sessionID { dismiss() }
        }
        .onDisappear {
            if let playback = model.services?.playback, playback.current?.id == sessionID {
                playback.closeCurrent()
            }
        }
    }
}

/// The Settings window (⌘,, MAC-4). Kids profiles can't open it (PRF-4).
struct SettingsWindowContent: View {
    let model: AppModel

    var body: some View {
        Group {
            if let services = model.services, model.phase == .ready {
                SettingsHost(model: model, services: services)
                    .environment(services.catalog)
                    .environment(services.store)
                    .environment(services.session)
            } else {
                LaunchScreen()
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 680)
        .hearthLayoutFromSizeClass()
        .preferredColorScheme(.dark)
        .tint(HearthColor.accent)
    }
}

private struct SettingsHost: View {
    let model: AppModel
    let services: AppServices

    @Environment(ProfileSession.self) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationStack {
            if session.canOpenSettings {
                SettingsView()
                    .hearthRouteDestinations()
            } else {
                EmptyStateView(
                    systemName: "lock",
                    title: String(localized: "Settings aren't available on a Kids profile"),
                    message: String(localized: "Switch to another profile to change settings.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .hearthScreenBackground()
            }
        }
        // Links that leave Settings (Household, a source) open in the main window.
        .environment(\.openRoute, OpenRouteAction { [navigation = model.macNavigation, session] route in
            openWindow(id: HearthApp.mainWindowID)
            navigation.open(route, gateShowing: session.needsProfileSelection)
        })
        .environment(\.play, PlayAction { [playback = services.playback] intent in
            playback.play(intent, sceneID: nil, layout: .sidebar)
        })
    }
}

// MARK: - Menus (MAC-2)

/// View ▸ Home … Downloads on ⌘1–⌘6, and a Profile menu. Playback keys
/// (space, arrows, F, Esc) live in the player.
struct HearthCommands: Commands {
    let model: AppModel

    private var isReady: Bool {
        model.phase == .ready && model.services?.session.needsProfileSelection == false
    }

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            ForEach(Array(AppTab.macSections.enumerated()), id: \.element) { index, tab in
                Button(tab.title) {
                    model.macNavigation.select(tab)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .disabled(!isReady)
            }
            Divider()
        }
        CommandGroup(after: .textEditing) {
            Button(String(localized: "Search Everything")) {
                model.macNavigation.select(.search)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(!isReady)
        }
        CommandMenu(String(localized: "Profile")) {
            Button(String(localized: "Switch Profile…")) {
                model.services?.playback.closeCurrent()
                model.services?.session.signOut()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!isReady)

            if let session = model.services?.session, RouteAccess.canSeeHousehold(session) {
                Button(String(localized: "Household")) {
                    model.macNavigation.open(.household, gateShowing: false)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!isReady)
            }
        }
    }
}
#endif
