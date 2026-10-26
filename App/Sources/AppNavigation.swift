import Core
import HouseholdFeature
import HouseholdKit
import LibraryFeature
import LiveTVFeature
import Observation
import ProfilesFeature
import SearchFeature
import SettingsFeature
import SwiftUI

/// Who may open which route: Kids can't reach Household or Settings (PRF-4),
/// guests have no Household either, and the editors need a member who
/// manages (SRC-8). Features hide the links; this stops a stale link.
@MainActor
enum RouteAccess {
    static func allows(_ route: HearthRoute, session: ProfileSession) -> Bool {
        switch route {
        case .household: canSeeHousehold(session)
        case .profileEditor, .sourceEditor: session.canManageHousehold
        case .settings: session.canOpenSettings
        case .movie, .series, .channel, .liveGuide, .search: true
        }
    }

    static func canSeeHousehold(_ session: ProfileSession) -> Bool {
        !session.isKids && !session.isGuest
    }

    /// The tabs a profile gets in the sidebar (iPad, iPhone Duo opened).
    static func allows(_ tab: AppTab, session: ProfileSession) -> Bool {
        switch tab {
        case .household: canSeeHousehold(session)
        case .settings: session.canOpenSettings
        default: true
        }
    }
}

/// One window's navigation: the selected tab (or Mac sidebar section), a
/// stack per tab, and a sheet for routes opened where no stack is showing
/// ("Manage household" on the gate) or that belong in one (Settings on
/// the phone).
@MainActor
@Observable
final class AppNavigation {
    struct Sheet: Identifiable {
        let id = UUID()
        var root: HearthRoute
        var path: [HearthRoute] = []
    }

    var selection: AppTab = .home
    var paths: [AppTab: [HearthRoute]] = [:]
    var sheet: Sheet?
    /// The Mac sidebar's search, once submitted.
    var submittedSearch = ""
    /// The Mac opens Settings in its own window (MAC-4) rather than a sheet;
    /// its root sets this to SwiftUI's `openSettings`.
    @ObservationIgnored var showSettings: (() -> Void)?

    func path(for tab: AppTab) -> Binding<[HearthRoute]> {
        Binding(
            get: { self.paths[tab] ?? [] },
            set: { self.setPath($0, for: tab) }
        )
    }

    var sheetPath: Binding<[HearthRoute]> {
        Binding(
            get: { self.sheet?.path ?? [] },
            set: { newPath in
                guard var sheet = self.sheet else { return }
                if let last = newPath.last, newPath.count > sheet.path.count, case .liveGuide = last {
                    // The guide is a tab, not a page: close the sheet and go there.
                    self.sheet = nil
                    self.select(.live)
                    return
                }
                sheet.path = newPath
                self.sheet = sheet
            }
        )
    }

    /// A `NavigationLink(value:)` lands here. Two routes aren't pages of a
    /// stack: the live guide switches to the Live TV tab, and Settings opens
    /// in a sheet — so they come off the path again.
    private func setPath(_ newPath: [HearthRoute], for tab: AppTab) {
        let old = paths[tab] ?? []
        var kept = newPath
        if newPath.count > old.count, let last = newPath.last {
            switch last {
            case .liveGuide:
                kept.removeLast()
                paths[tab] = kept
                select(.live)
                return
            case .settings:
                kept.removeLast()
                paths[tab] = kept
                openSettings()
                return
            default:
                break
            }
        }
        paths[tab] = kept
    }

    func select(_ tab: AppTab) {
        if tab == .live, selection == .live {
            paths[.live] = []
        }
        selection = tab
    }

    /// `@Environment(\.openRoute)` for this window. With the gate up there
    /// is no stack, so the route opens in a sheet.
    func open(_ route: HearthRoute, gateShowing: Bool) {
        switch route {
        case .liveGuide:
            sheet = nil
            paths[.live] = []
            selection = .live
        case .settings:
            openSettings()
        default:
            if gateShowing {
                sheet = Sheet(root: route)
            } else if sheet != nil {
                sheet?.path.append(route)
            } else {
                paths[selection, default: []].append(route)
            }
        }
    }

    private func openSettings() {
        if let showSettings {
            showSettings()
        } else {
            sheet = Sheet(root: .settings)
        }
    }

    /// After a profile switch: back to Home with empty stacks, so nothing of
    /// the previous profile's browsing shows (and a Kids profile doesn't land
    /// on a tab it can't have).
    func reset() {
        paths = [:]
        sheet = nil
        selection = .home
        submittedSearch = ""
    }
}

/// Every `HearthRoute` as a screen (the composition root's half of Core's
/// routes contract).
struct RouteDestination: View {
    let route: HearthRoute
    @Environment(ProfileSession.self) private var session

    var body: some View {
        if RouteAccess.allows(route, session: session) {
            destination
        } else {
            EmptyStateView(
                systemName: "lock",
                title: String(localized: "Not on this profile"),
                message: String(localized: "Ask whoever manages the household to open this for you.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .hearthScreenBackground()
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch route {
        case .movie(let itemKey):
            MovieDetailView(itemKey: itemKey)
        case .series(let itemKey):
            ShowDetailView(itemKey: itemKey)
        case .channel(let itemKey):
            ChannelDetailView(itemKey: itemKey)
        case .liveGuide:
            // Normally switches tabs instead (AppNavigation); reached only
            // inside a sheet's root.
            LiveTVView()
        case .search(let query):
            SearchView(initialQuery: query)
        case .household:
            HouseholdView()
        case .profileEditor(let profileID):
            ProfileEditorView(profileID: profileID)
        case .sourceEditor(let sourceID):
            SourceEditorView(sourceID: sourceID)
        case .settings:
            SettingsView()
        }
    }
}

extension View {
    /// The route mapping on a NavigationStack's root.
    func hearthRouteDestinations() -> some View {
        navigationDestination(for: HearthRoute.self) { route in
            RouteDestination(route: route)
        }
    }
}

/// A route opened in a sheet: its own stack and a Done button.
struct RouteSheet: View {
    let navigation: AppNavigation
    let root: HearthRoute
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: navigation.sheetPath) {
            RouteDestination(route: root)
                .hearthRouteDestinations()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { dismiss() }
                            .accessibilityHint(Text("Closes this sheet"))
                    }
                }
        }
        .environment(\.openRoute, OpenRouteAction { route in
            navigation.open(route, gateShowing: false)
        })
        .hearthScreenBackground()
        #if os(macOS)
        // A Mac sheet takes its content's size; give the page room.
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 680)
        #endif
    }
}
