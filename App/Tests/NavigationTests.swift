import Core
import Foundation
import HouseholdKit
import Testing
@testable import Hearth

// Who may open what (RouteAccess), the tabs (AppTab) and one window's
// navigation (AppNavigation).

/// Every route, one of each case.
let allRoutes: [HearthRoute] = [
    .movie(itemKey: "m"), .series(itemKey: "s"), .channel(itemKey: "c"), .liveGuide, .search(query: "news"),
    .household, .profileEditor(profileID: nil), .sourceEditor(sourceID: nil), .settings,
]

@MainActor
@Suite struct RouteAccessTests {
    /// A session on a fresh in-memory household (this device is its owner),
    /// switched to a new profile of `kind`, or left at the gate for nil.
    func session(_ kind: ProfileKind?) throws -> ProfileSession {
        let store = try makeHouseholdStore()
        let session = ProfileSession(store: store, defaults: makeDefaults())
        switch kind {
        case nil:
            break
        case .standard?:
            session.select(store.profiles[0])
        case let kind?:
            let profile = try #require(store.addProfile(name: kind.rawValue, kind: kind, avatarColor: .teal))
            session.select(profile)
        }
        return session
    }

    @Test func anAdultOwnerReachesEverything() throws {
        let owner = try session(.standard)
        for route in allRoutes {
            #expect(RouteAccess.allows(route, session: owner), "\(route)")
        }
        for tab in AppTab.allCases {
            #expect(RouteAccess.allows(tab, session: owner), "\(tab)")
        }
    }

    /// PRF-4: no Household, no Settings, no editors; everything to watch.
    @Test func kidsCantReachHouseholdSettingsOrTheEditors() throws {
        let kids = try session(.kids)
        let blocked: [HearthRoute] = [.household, .settings, .profileEditor(profileID: UUID()), .sourceEditor(sourceID: nil)]
        for route in blocked {
            #expect(!RouteAccess.allows(route, session: kids), "\(route)")
        }
        let watchable: [HearthRoute] = [.movie(itemKey: "m"), .series(itemKey: "s"), .channel(itemKey: "c"), .liveGuide, .search(query: "")]
        for route in watchable {
            #expect(RouteAccess.allows(route, session: kids), "\(route)")
        }
        #expect(!RouteAccess.allows(AppTab.household, session: kids))
        #expect(!RouteAccess.allows(AppTab.settings, session: kids))
    }

    /// A guest has no Household and can't edit, but may open Settings.
    @Test func guestsHaveNoHouseholdButHaveSettings() throws {
        let guest = try session(.guest)
        #expect(!RouteAccess.allows(HearthRoute.household, session: guest))
        #expect(!RouteAccess.allows(.profileEditor(profileID: nil), session: guest))
        #expect(!RouteAccess.allows(.sourceEditor(sourceID: nil), session: guest))
        #expect(RouteAccess.allows(HearthRoute.settings, session: guest))
        #expect(!RouteAccess.allows(AppTab.household, session: guest))
        #expect(RouteAccess.allows(AppTab.settings, session: guest))
    }

    /// "Manage household" on the gate: no profile chosen yet, so nothing
    /// narrows what the owner's device may open.
    @Test func theGateStillReachesTheHousehold() throws {
        let gate = try session(nil)
        #expect(gate.currentProfile == nil)
        #expect(RouteAccess.allows(HearthRoute.household, session: gate))
        #expect(RouteAccess.allows(.profileEditor(profileID: nil), session: gate))
    }

    /// Kids keep every tab of the phone's bar and the Mac's sidebar.
    @Test func kidsKeepEveryPrimaryTab() throws {
        let kids = try session(.kids)
        for tab in AppTab.primary + AppTab.macSections + [.search, .downloads] {
            #expect(RouteAccess.allows(tab, session: kids), "\(tab)")
        }
    }
}

@Suite struct AppTabTests {
    @Test func thePhonesFiveTabsInOrder() {
        #expect(AppTab.primary == [.home, .live, .movies, .shows, .myList])
    }

    /// ⌘1–⌘6: the phone's five, then Downloads.
    @Test func theMacSectionsInShortcutOrder() {
        #expect(AppTab.macSections == AppTab.primary + [.downloads])
    }

    @Test func everyTabInSidebarOrder() {
        #expect(AppTab.allCases == [.home, .live, .movies, .shows, .myList, .downloads, .search, .household, .settings])
    }

    /// `-OpenTab` and saved selections read these.
    @Test func rawValuesAreStable() {
        #expect(AppTab.allCases.map(\.rawValue) == ["home", "live", "movies", "shows", "mylist", "downloads", "search", "household", "settings"])
    }

    @Test func everyTabHasATitleAndItsOwnSymbol() {
        #expect(AppTab.allCases.allSatisfy { !$0.title.isEmpty && !$0.systemImage.isEmpty })
        #expect(Set(AppTab.allCases.map(\.systemImage)).count == AppTab.allCases.count)
        #expect(Set(AppTab.allCases.map(\.title)).count == AppTab.allCases.count)
    }
}

@MainActor
@Suite struct AppNavigationTests {
    let movie = HearthRoute.movie(itemKey: "m1")
    let show = HearthRoute.series(itemKey: "s1")

    @Test func startsAtHomeWithNothingOpen() {
        let navigation = AppNavigation()
        #expect(navigation.selection == .home)
        #expect(navigation.paths.isEmpty)
        #expect(navigation.sheet == nil)
    }

    @Test func openPushesOntoTheSelectedTabsStack() {
        let navigation = AppNavigation()
        navigation.select(.movies)
        navigation.open(movie, gateShowing: false)
        navigation.open(show, gateShowing: false)
        #expect(navigation.paths[.movies] == [movie, show])
        #expect(navigation.paths[.home] == nil)
        #expect(navigation.sheet == nil)
    }

    /// With the gate up there is no stack: the route opens in a sheet, and
    /// what it opens next goes onto the sheet's stack.
    @Test func theGateOpensASheetAndTheSheetKeepsItsOwnStack() {
        let navigation = AppNavigation()
        navigation.open(.household, gateShowing: true)
        #expect(navigation.sheet?.root == .household)
        #expect(navigation.sheet?.path == [])
        navigation.open(.profileEditor(profileID: nil), gateShowing: false)
        #expect(navigation.sheet?.path == [.profileEditor(profileID: nil)])
        #expect(navigation.paths.isEmpty)
    }

    /// The guide is a tab, not a page: it closes any sheet and shows Live TV
    /// at its root.
    @Test func openingTheGuideSwitchesToLiveTV() {
        let navigation = AppNavigation()
        navigation.select(.live)
        navigation.open(.channel(itemKey: "c1"), gateShowing: false)
        navigation.select(.home)
        navigation.open(.household, gateShowing: true)
        navigation.open(.liveGuide, gateShowing: false)
        #expect(navigation.selection == .live)
        #expect(navigation.paths[.live] == [])
        #expect(navigation.sheet == nil)
    }

    @Test func settingsOpenInASheetWithoutAWindowOfTheirOwn() {
        let navigation = AppNavigation()
        navigation.open(.settings, gateShowing: false)
        #expect(navigation.sheet?.root == .settings)
        #expect(navigation.paths.isEmpty)
    }

    /// The Mac gives Settings their own window.
    @Test func settingsUseTheMacsWindowWhenThereIsOne() {
        let navigation = AppNavigation()
        var opened = 0
        navigation.showSettings = { opened += 1 }
        navigation.open(.settings, gateShowing: true)
        #expect(opened == 1)
        #expect(navigation.sheet == nil)
    }

    /// A NavigationLink to the guide or Settings lands on the path binding;
    /// neither stays there.
    @Test func linksToTheGuideOrSettingsComeOffThePath() {
        let navigation = AppNavigation()
        let home = navigation.path(for: .home)
        home.wrappedValue = [movie]
        #expect(navigation.paths[.home] == [movie])

        home.wrappedValue = [movie, .liveGuide]
        #expect(navigation.paths[.home] == [movie])
        #expect(navigation.selection == .live)

        home.wrappedValue = [movie, .settings]
        #expect(navigation.paths[.home] == [movie])
        #expect(navigation.sheet?.root == .settings)
    }

    @Test func goingBackShortensThePath() {
        let navigation = AppNavigation()
        let home = navigation.path(for: .home)
        home.wrappedValue = [movie, show]
        home.wrappedValue = [movie]
        #expect(navigation.paths[.home] == [movie])
        #expect(navigation.path(for: .shows).wrappedValue == [])
    }

    @Test func aGuideLinkInsideASheetClosesIt() {
        let navigation = AppNavigation()
        navigation.open(.household, gateShowing: true)
        navigation.sheetPath.wrappedValue = [show]
        #expect(navigation.sheet?.path == [show])
        navigation.sheetPath.wrappedValue = [show, .liveGuide]
        #expect(navigation.sheet == nil)
        #expect(navigation.selection == .live)
    }

    @Test func theSheetPathIsIgnoredWithNoSheet() {
        let navigation = AppNavigation()
        navigation.sheetPath.wrappedValue = [show]
        #expect(navigation.sheet == nil)
        #expect(navigation.sheetPath.wrappedValue == [])
    }

    /// Choosing Live TV again goes back to the guide; other tabs keep their place.
    @Test func reselectingLiveTVPopsToTheGuide() {
        let navigation = AppNavigation()
        navigation.paths[.live] = [.channel(itemKey: "c1")]
        navigation.paths[.movies] = [movie]
        navigation.select(.live)
        #expect(navigation.paths[.live] == [.channel(itemKey: "c1")])
        navigation.select(.live)
        #expect(navigation.paths[.live] == [])
        navigation.select(.movies)
        navigation.select(.movies)
        #expect(navigation.paths[.movies] == [movie])
    }

    /// After a profile switch nothing of the last profile's browsing shows.
    @Test func resetClearsEverything() {
        let navigation = AppNavigation()
        navigation.select(.shows)
        navigation.open(show, gateShowing: false)
        navigation.open(.household, gateShowing: true)
        navigation.submittedSearch = "news"
        navigation.reset()
        #expect(navigation.selection == .home)
        #expect(navigation.paths.isEmpty)
        #expect(navigation.sheet == nil)
        #expect(navigation.submittedSearch == "")
    }
}
