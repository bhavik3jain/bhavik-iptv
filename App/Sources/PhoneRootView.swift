#if os(iOS)
import CatalogKit
import Core
import HomeFeature
import HouseholdFeature
import HouseholdKit
import LibraryFeature
import LiveTVFeature
import ProfilesFeature
import SearchFeature
import SettingsFeature
import SwiftUI

/// The iPhone, iPad and iPhone Duo root (mockup 02). "Who's watching?" until
/// a profile is chosen (PRF-2); then five tabs — Home, Live TV, Movies,
/// Shows, My List — each with its own navigation stack. `.sidebarAdaptable`
/// turns the tab bar into a sidebar wherever the width is regular: iPad and
/// iPhone Duo's inner display (MAC-6), where Search, Household and Settings
/// join it. One per window: each window keeps its own tabs and stacks.
struct PhoneRootView: View {
    let model: AppModel
    let services: AppServices

    @State private var navigation = AppNavigation()
    @State private var sceneID = UUID()
    @Environment(ProfileSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.needsProfileSelection {
                WhoIsWatchingView(onManageHousehold: {
                    navigation.open(.household, gateShowing: true)
                })
                .transition(.opacity)
            } else {
                tabs
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.needsProfileSelection)
        .windowPresentations(model: model, services: services, navigation: navigation, sceneID: sceneID)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { services.playback.lastSceneID = sceneID }
        }
        // A tab this window doesn't have (Downloads is Mac-only; Household
        // and Settings leave with a Kids or Guest profile) falls back to Home.
        .onChange(of: navigation.selection, initial: true) { _, tab in
            if !availableTabs.contains(tab) { navigation.selection = .home }
        }
    }

    /// Search, Household and Settings are sidebar rows only. `.sidebarOnly`
    /// alone doesn't keep them out of a compact tab bar: with eight tabs the
    /// iPhone folds the extras into "More" and My List disappears behind it.
    /// So they exist only while there is a sidebar (regular width: iPad,
    /// iPhone Duo opened); on the phone they're reached from Home's search
    /// button and the profile menu.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var hasSidebar: Bool { horizontalSizeClass == .regular }

    private var availableTabs: Set<AppTab> {
        guard hasSidebar else { return Set(AppTab.primary) }
        return Set(AppTab.primary + [.downloads, .search] + [AppTab.household, .settings].filter { RouteAccess.allows($0, session: session) })
    }

    private var tabs: some View {
        @Bindable var navigation = navigation
        return TabView(selection: navigation.tabSelection) {
            ForEach(AppTab.primary, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    TabStack(tab: tab, navigation: navigation)
                }
            }
            // The sidebar's own rows: never in the phone's tab bar.
            if hasSidebar {
                TabSection(String(localized: "More")) {
                    Tab(AppTab.downloads.title, systemImage: AppTab.downloads.systemImage, value: AppTab.downloads) {
                        TabStack(tab: .downloads, navigation: navigation)
                    }
                    .tabPlacement(.sidebarOnly)

                    Tab(AppTab.search.title, systemImage: AppTab.search.systemImage, value: AppTab.search) {
                        TabStack(tab: .search, navigation: navigation)
                    }
                    .tabPlacement(.sidebarOnly)

                    if RouteAccess.allows(AppTab.household, session: session) {
                        Tab(AppTab.household.title, systemImage: AppTab.household.systemImage, value: AppTab.household) {
                            TabStack(tab: .household, navigation: navigation)
                        }
                        .tabPlacement(.sidebarOnly)
                    }
                    if RouteAccess.allows(AppTab.settings, session: session) {
                        Tab(AppTab.settings.title, systemImage: AppTab.settings.systemImage, value: AppTab.settings) {
                            TabStack(tab: .settings, navigation: navigation)
                        }
                        .tabPlacement(.sidebarOnly)
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarHeader {
            ProfileSwitcherMenu(style: .sidebar)
                .padding(.vertical, 4)
        }
        .tabViewSidebarBottomBar {
            VStack(alignment: .leading, spacing: 8) {
                StreamUsageSummaryView()
                ICloudStatusNote()
            }
            .padding(.vertical, 8)
        }
    }
}

/// One tab's navigation stack, with every route mapped.
private struct TabStack: View {
    let tab: AppTab
    let navigation: AppNavigation

    var body: some View {
        NavigationStack(path: navigation.path(for: tab)) {
            TabRoot(tab: tab, navigation: navigation)
                .hearthRouteDestinations()
        }
    }
}
#endif

import Core
import HomeFeature
import HouseholdFeature
import LibraryFeature
import LiveTVFeature
import ProfilesFeature
import SearchFeature
import SettingsFeature
import SwiftUI

/// The screen at the root of a tab (iOS) or sidebar section (Mac).
struct TabRoot: View {
    let tab: AppTab
    let navigation: AppNavigation

    var body: some View {
        switch tab {
        case .home:
            HomeView {
                ProfileSwitcherMenu(style: .header)
            }
        case .live:
            LiveTVView()
        case .movies:
            MoviesView()
        case .shows:
            ShowsView()
        case .myList:
            MyListView()
        case .downloads:
            DownloadsView()
        case .search:
            // A new submitted query from the Mac sidebar starts a new search.
            SearchView(initialQuery: navigation.submittedSearch)
                .id(navigation.submittedSearch)
        case .household:
            RouteDestination(route: .household)
        case .settings:
            RouteDestination(route: .settings)
        }
    }
}
