import CatalogKit
import Core
import HouseholdKit
import SwiftUI

// CONTRACT — the app shell builds against these entry views. Their names and
// initialisers stay; what they draw is the feature implementation's to replace.
// Services come from the environment: CatalogService, HouseholdStore and
// ProfileSession (injected by the app), plus Core's \.play and \.openRoute.

/// Home for the current profile (mockup 02, HOME-1): Continue watching,
/// favorite channels with what's on, up next in shows, new movies. The header
/// holds the profile switcher, AirPlay and search; the app passes the
/// switcher in so Home never imports ProfilesFeature.
///
/// Pass `EmptyView` where the switcher lives elsewhere (the Mac sidebar,
/// PRF-8): the header then shows a "Home" title in its place.
public struct HomeView<ProfileSwitcher: View>: View {
    let profileSwitcher: ProfileSwitcher

    public init(@ViewBuilder profileSwitcher: () -> ProfileSwitcher) {
        self.profileSwitcher = profileSwitcher()
    }

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.hearthLayout) private var layout

    @State private var snapshot = HomeSnapshot.empty
    /// False until the first read: before it, an empty snapshot would flash
    /// "Pin your favorite channels" at a profile that has some.
    @State private var hasLoaded = false
    /// The width Home lays out in (after the readable-width cap), for the
    /// gutters, the sidebar hero and how many poster columns fit.
    @State private var contentWidth: CGFloat = 0
    /// Shows whose episodes Home has asked for this session. A show the
    /// provider sends no episodes for stays "needing" them; without this it
    /// would be asked again on every change.
    @State private var episodeFetchesTried: Set<ItemKey> = []

    public var body: some View {
        Group {
            if layout == .tv {
                HomeTVContent(snapshot: snapshot, status: status, hasLoaded: hasLoaded, profileSwitcher: profileSwitcher)
                    .toolbar(.hidden, for: .automatic)
            } else {
                touchBody
            }
        }
        .onChange(of: reloadKey, initial: true) { reload() }
        .task(id: snapshot.seriesNeedingEpisodes.map(\.key)) { await fetchMissingEpisodes() }
        .task(id: snapshot.favoriteChannels.map(\.key)) { await keepFavoriteGuidesFresh() }
    }

    /// The phone and sidebar layouts.
    private var touchBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HearthMetrics.sectionSpacing) {
                HomeHeader(profileSwitcher: profileSwitcher, greeting: greeting)
                    .padding(.horizontal, gutter)
                content
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: HomeLayoutMetrics.readableWidth)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            .frame(maxWidth: .infinity)
        }
        .hearthScreenBackground()
        .navigationTitle(Text("Home", bundle: .module))
        .inlineNavigationTitle()
        // The phone's header is the mockup's own row, not a navigation bar
        // (`.automatic` is the navigation bar on iOS). In the sidebar layout
        // the bar stays: on iPad and iPhone Duo it holds the sidebar button,
        // on the Mac it is the window's toolbar.
        .toolbar(layout == .compact ? .hidden : .automatic, for: .automatic)
    }

    private var gutter: CGFloat { HomeLayoutMetrics.gutter(layout: layout, width: contentWidth) }

    /// Nil while the app passes a real switcher; with `EmptyView`, the
    /// profile's greeting.
    private var greeting: String? {
        guard ProfileSwitcher.self == EmptyView.self else { return nil }
        return HomeGreeting.text(name: session.currentProfile?.name, at: .now)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch status {
        case .noSources:
            NoSourcesState(canManageHousehold: session.canManageHousehold)
                .padding(.horizontal, gutter)
                .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length * 0.7 }
        case .firstRefresh(let sourceName, let progress, let message):
            FirstRefreshState(sourceName: sourceName, progress: progress, message: message)
                .padding(.horizontal, gutter)
                .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length * 0.7 }
        case .failed(let sourceID, let sourceName, let message):
            RefreshFailedState(sourceID: sourceID, sourceName: sourceName, message: message, canManageHousehold: session.canManageHousehold)
                .padding(.horizontal, gutter)
                .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length * 0.7 }
        case .ready:
            if hasLoaded { sections }
        }
    }

    @ViewBuilder
    private var sections: some View {
        let profileID = session.currentProfile?.id
        let canKeepLists = !session.isGuest && profileID != nil

        if let item = snapshot.continueWatching {
            ContinueWatchingHero(
                item: item,
                showsSidePoster: HomeLayoutMetrics.heroShowsSidePoster(layout: layout, contentWidth: contentWidth),
                profileID: canKeepLists ? profileID : nil
            )
            .padding(.horizontal, gutter)
        }

        FavoriteChannelsSection(
            channels: snapshot.favoriteChannels,
            catalogRevision: catalog.revision,
            layout: layout,
            gutter: gutter,
            contentWidth: contentWidth,
            profileID: canKeepLists ? profileID : nil,
            isGuest: session.isGuest,
            syncStatus: store.syncStatus
        )

        if !snapshot.upNext.isEmpty {
            PosterShelf(
                title: String(localized: "Up next in your shows", bundle: .module),
                items: snapshot.upNext,
                layout: layout,
                gutter: gutter,
                contentWidth: contentWidth,
                maxRows: nil
            ) { item in
                UpNextTile(item: item, profileID: canKeepLists ? profileID : nil)
            }
        }
    }

    // MARK: State

    /// The household's live sources: the catalog's (what the app handed it)
    /// plus any the store has that the app hasn't passed on yet, so a launch
    /// never flashes "Add a source" at a household that has one.
    private var status: HomeStatus {
        let records = store.sources.filter { !$0.isRemoved }
        var ids = catalog.sources.map(\.id)
        for record in records where !ids.contains(record.id) {
            ids.append(record.id)
        }
        let names = Dictionary(records.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return HomeStatus.make(sourceIDs: ids, names: names, refreshStates: catalog.refreshStates)
    }

    /// Read in `body`, so a catalog import, a guide load, a synced favorite or
    /// a profile switch re-reads Home.
    private var reloadKey: ReloadKey {
        ReloadKey(catalogRevision: catalog.revision, storeRevision: store.revision, profileID: session.currentProfile?.id)
    }

    private func reload() {
        let next = HomeLoader(catalog: catalog, store: store).load(profileID: session.currentProfile?.id)
        if next != snapshot { snapshot = next }
        hasLoaded = true
    }

    /// SER-2 needs each show's episodes; a show this device never opened has
    /// none cached. One at a time, so a Stalker portal sees a trickle rather
    /// than a burst. Each landing bumps the catalog's revision, Home re-reads,
    /// and this task restarts with whatever is still missing.
    private func fetchMissingEpisodes() async {
        for series in snapshot.seriesNeedingEpisodes where !episodeFetchesTried.contains(series.key) {
            do {
                _ = try await catalog.episodes(for: series)
            } catch is CancellationError {
                return
            } catch {
                // Offline or a provider hiccup: the show just stays out of
                // Up next until the next launch tries again.
            }
            if Task.isCancelled { return }
            episodeFetchesTried.insert(series.key)
        }
    }

    /// Stalker portals have no full guide, so the favorites' now-playing
    /// comes from the short guide (CatalogKit throttles it per channel, and
    /// skips sources with a full guide). Asked again every quarter hour while
    /// Home is on screen, so the cards don't run out of programmes. Only the
    /// favorites the row can show: a portal isn't asked about the rest.
    private func keepFavoriteGuidesFresh() async {
        let channels = Array(snapshot.favoriteChannels.prefix(FavoriteChannelsSection.rowLimit))
        guard !channels.isEmpty else { return }
        while !Task.isCancelled {
            await catalog.loadShortGuide(for: channels)
            try? await Task.sleep(for: .seconds(15 * 60))
        }
    }
}

private struct ReloadKey: Hashable {
    var catalogRevision: Int
    var storeRevision: Int
    var profileID: UUID?
}
