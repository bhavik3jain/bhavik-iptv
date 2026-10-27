#if os(tvOS)
import Core
import HouseholdKit
import ProfilesFeature
import SwiftUI

/// The Apple TV root. "Who's watching?" until a profile is chosen (PRF-2);
/// then tvOS's own top tab bar — Home, Live TV, Movies, Shows, My List,
/// Search and Settings — each tab with its own navigation stack, so Menu on
/// the remote walks back through it and, at a tab's root, back to the bar.
///
/// The features draw their TV variants from `\.hearthLayout == .tv`
/// (`hearthLayoutFromSizeClass()` sets it on tvOS): large cards that lift
/// with focus, rows the focus engine walks, 10-foot type. Household is
/// reached from Settings and is read-only here: sources and people are
/// added from an iPhone, iPad or Mac in the same iCloud household.
struct TVRootView: View {
    let model: AppModel
    let services: AppServices

    @State private var navigation = AppNavigation()
    @State private var sceneID = UUID()
    @Environment(ProfileSession.self) private var session

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
        // A tab the TV doesn't have (Downloads; Settings leaves with a Kids
        // profile) falls back to Home.
        .onChange(of: navigation.selection, initial: true) { _, tab in
            if !availableTabs.contains(tab) { navigation.selection = .home }
        }
        .onAppear {
            // Settings is a tab here, not a sheet.
            let navigation = navigation
            navigation.showSettings = { [weak navigation] in
                navigation?.sheet = nil
                navigation?.select(.settings)
            }
        }
    }

    private var availableTabs: [AppTab] {
        AppTab.tv.filter { RouteAccess.allows($0, session: session) }
    }

    private var tabs: some View {
        @Bindable var navigation = navigation
        return TabView(selection: $navigation.selection) {
            ForEach(availableTabs.filter { $0 != .search }, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    TVTabStack(tab: tab, navigation: navigation)
                }
            }
            // The search role puts the magnifier at the bar's leading end,
            // where tvOS apps keep it.
            Tab(value: AppTab.search, role: .search) {
                TVTabStack(tab: .search, navigation: navigation)
            }
        }
    }
}

/// One tab's navigation stack, with every route mapped.
private struct TVTabStack: View {
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
