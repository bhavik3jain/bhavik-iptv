#if os(tvOS)
import Core
import HouseholdKit
import ProfilesFeature
import SwiftUI

/// The Apple TV root. "Who's watching?" until a profile is chosen (PRF-2);
/// then tvOS's own top tab bar — Search, Home, Live TV, Movies, Shows, My
/// List and Settings, opening on Home — each tab with its own navigation
/// stack, so Menu on the remote walks back through it and, at a tab's root,
/// back to the bar.
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
            // Words, not icons, as tvOS's own apps label their tabs (seven
            // with icons overflow the bar); Search is the magnifier alone.
            ForEach(availableTabs, id: \.self) { tab in
                Tab(value: tab) {
                    TVTabStack(tab: tab, navigation: navigation)
                } label: {
                    if tab == .search {
                        Image(systemName: tab.systemImage)
                            .accessibilityLabel(Text(tab.title))
                    } else {
                        Text(tab.title)
                    }
                }
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

#if os(tvOS)
/// Where the TV sends a profile or source edit: to an iPhone, iPad or Mac in
/// the same household, whose change then syncs here.
struct TVEditElsewhereView: View {
    enum Subject { case profile, source }
    let subject: Subject

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            TVPageHeader(title)
            TVNoticeCard(systemName: "ipad.and.iphone", title: String(localized: "Use Hearth on your iPhone, iPad or Mac"), message: message)
                .frame(maxWidth: 1200, alignment: .leading)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hearthScreenBackground()
        .toolbar(.hidden, for: .automatic)
    }

    private var title: String {
        switch subject {
        case .profile: String(localized: "Profiles")
        case .source: String(localized: "Sources")
        }
    }

    private var message: String {
        switch subject {
        case .profile:
            String(localized: "Add and edit profiles — names, colours, PINs, Kids categories — in Hearth on another device signed in to the same iCloud household. They appear on this Apple TV on their own.")
        case .source:
            String(localized: "Add a Stalker portal, an Xtream login or an M3U playlist in Hearth on another device signed in to the same iCloud household: Household › Add a source. Its channels, movies and shows appear on this Apple TV on their own.")
        }
    }
}
#endif
