import CatalogKit
import Core
import DownloadKit
import HouseholdKit
import SwiftUI

/// One My List row as the screen draws it (FAV-3).
struct MyListEntry: Identifiable, Equatable {
    enum Status: Equatable {
        /// In the catalog and visible to this profile.
        case available(GridEntry)
        /// Its source hasn't finished its first import on this device (a
        /// new device, or a source just added): not gone, just not here yet.
        case pending
        /// No longer offered by its provider: drawn greyed as "Unavailable"
        /// with a way to take it off the list.
        case unavailable
    }

    var favorite: FavoriteRecord
    var status: Status
    var id: UUID { favorite.id }

    /// How a favorite resolves against the catalog.
    ///
    /// - An item the catalog still holds but this profile's rules hide is
    ///   left off the list (nil) rather than shown as gone: it isn't, and a
    ///   Kids profile shouldn't learn its name.
    /// - An item whose source this device hasn't imported yet is pending:
    ///   My List syncs through iCloud long before a new device has
    ///   downloaded a 40 000-title catalog, and calling everything
    ///   "Unavailable" then would invite removing it.
    /// - Otherwise an item the catalog doesn't hold is unavailable.
    ///
    /// Favorites of a removed source never reach here: the store hides them
    /// (SRC-9).
    static func status(found: GridEntry?, catalogContains: Bool, sourceImported: Bool) -> Status? {
        if let found { return .available(found) }
        if catalogContains { return nil }
        return sourceImported ? .unavailable : .pending
    }
}

/// The profile's My List: its movies and shows as poster grids (FAV-3),
/// synced through the household so it follows the profile to every device.
struct MyListScreen: View {
    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(DownloadCenter.self) private var downloads
    @Environment(ProfileSession.self) private var session
    @Environment(\.hearthLayout) private var layout

    @State private var pendingRemoval: FavoriteRecord?
    private var metrics = PosterGridMetrics()

    private var isTV: Bool { layout == .tv }

    var body: some View {
        let _ = (catalog.revision, store.revision)
        Group {
            if isTV {
                // The TV: a shelf of movies and one of shows; the tab bar
                // already says "My List".
                ScrollView {
                    VStack(alignment: .leading, spacing: HearthTVMetrics.shelfSpacing) {
                        content
                    }
                    .padding(.bottom, 60)
                }
                .scrollClipDisabled()
                .hearthScreenBackground()
                .toolbar(.hidden, for: .automatic)
            } else {
                touchBody
            }
        }
        .confirmationDialog(
            String(localized: "Remove from My List?", bundle: .module),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { favorite in
            Button(String(localized: "Remove", bundle: .module), role: .destructive) {
                remove(favorite)
            }
        } message: { _ in
            Text("Its provider no longer offers it.", bundle: .module)
        }
    }

    /// The phone has no Downloads tab (five tabs, mockup 02): its downloads
    /// are a page from here. The Mac and the iPad's sidebar have their own.
    @ViewBuilder
    private var downloadsLink: some View {
        if layout == .compact, DownloadCenter.isSupported {
            NavigationLink(value: HearthRoute.downloads) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(HearthColor.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(HearthColor.surface))
                    .overlay(alignment: .topTrailing) {
                        if !downloads.running.isEmpty {
                            Circle().fill(HearthColor.accent).frame(width: 10, height: 10)
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Downloads", bundle: .module))
        }
    }

    private var touchBody: some View {
        let gutter = libraryGutter(layout)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LibraryTitleRow(title: String(localized: "My List", bundle: .module)) { downloadsLink }
                    .padding(.top, 4)
                content
            }
            .padding(.horizontal, gutter)
            .padding(.bottom, 32)
            .frame(maxWidth: libraryMaxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollRevealedTitle(String(localized: "My List", bundle: .module))
        .hearthScreenBackground()
    }

    /// An empty state in the layout's size.
    @ViewBuilder
    private func emptyState(systemName: String, title: String, message: String? = nil) -> some View {
        if isTV {
            TVNoticeCard(systemName: systemName, title: title, message: message ?? "")
                .frame(maxWidth: 1200, alignment: .leading)
        } else {
            EmptyStateView(systemName: systemName, title: title, message: message)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let profile = session.currentProfile {
            if profile.isGuest {
                emptyState(
                    systemName: "heart",
                    title: String(localized: "My List isn't kept for guests", bundle: .module),
                    message: String(localized: "Pick your own profile to keep movies and shows in My List.", bundle: .module)
                )
            } else {
                list(profileID: profile.id)
            }
        } else {
            emptyState(systemName: "person.crop.circle", title: String(localized: "Choose a profile to see its list", bundle: .module))
        }
    }

    @ViewBuilder
    private func list(profileID: UUID) -> some View {
        let movies = entries(profileID: profileID, kind: .movie)
        let shows = entries(profileID: profileID, kind: .series)
        let visibleMovies = movies.filter { $0.status != .pending }
        let visibleShows = shows.filter { $0.status != .pending }
        let pendingCount = (movies.count - visibleMovies.count) + (shows.count - visibleShows.count)

        if visibleMovies.isEmpty && visibleShows.isEmpty {
            if pendingCount > 0 {
                LibraryLoadingView(message: String(localized: "Loading My List from your sources…", bundle: .module))
                    .padding(.top, 60)
            } else {
                emptyState(
                    systemName: "heart",
                    title: String(localized: "Nothing in My List yet", bundle: .module),
                    message: isTV
                        ? String(localized: "Choose My List on a movie or show to keep it here. My List follows your profile to every device in the household.", bundle: .module)
                        : String(localized: "Tap the heart on a movie or show to keep it here. My List follows your profile to every device in the household.", bundle: .module)
                )
            }
        } else {
            if !visibleMovies.isEmpty {
                section(String(localized: "Movies", bundle: .module), entries: visibleMovies)
            }
            if !visibleShows.isEmpty {
                section(String(localized: "Shows", bundle: .module), entries: visibleShows)
            }
            if pendingCount > 0 {
                pendingNote(count: pendingCount)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, entries: [MyListEntry]) -> some View {
        if isTV {
            TVShelf(title) {
                ForEach(entries) { entry in
                    tile(entry)
                }
            }
        } else {
            touchSection(title, entries: entries)
        }
    }

    private func touchSection(_ title: String, entries: [MyListEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title)
            LazyVGrid(columns: metrics.columns(for: layout), alignment: .leading, spacing: 20) {
                ForEach(entries) { entry in
                    tile(entry)
                }
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func tile(_ entry: MyListEntry) -> some View {
        switch entry.status {
        case .available(let item):
            if isTV {
                TVLibraryPosterLink(entry: item)
            } else {
                LibraryPosterLink(entry: item)
            }
        case .unavailable where isTV:
            TVCard(width: HearthTVMetrics.posterWidth, title: String(localized: "Unavailable", bundle: .module), caption: String(localized: "No longer offered", bundle: .module)) {
                pendingRemoval = entry.favorite
            } artwork: {
                TVPosterArtwork(title: String(localized: "Unavailable", bundle: .module), url: nil)
                    .opacity(0.5)
            }
            .accessibilityHint(Text("Removes it from My List", bundle: .module))
        case .unavailable:
            Button {
                pendingRemoval = entry.favorite
            } label: {
                PosterCell(
                    title: String(localized: "Unavailable", bundle: .module),
                    url: nil,
                    caption: String(localized: "No longer offered", bundle: .module),
                    decoration: PosterDecoration(badge: nil, progress: nil),
                    isUnavailable: true
                )
            }
            .buttonStyle(.hearthTile)
            .accessibilityHint(Text("Removes it from My List", bundle: .module))
            .contextMenu {
                Button(role: .destructive) {
                    remove(entry.favorite)
                } label: {
                    Label(String(localized: "Remove from My List", bundle: .module), systemImage: "heart.slash")
                }
            }
        case .pending:
            EmptyView()
        }
    }

    /// Titles whose source is still importing on this device.
    private func pendingNote(count: Int) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(HearthColor.accent)
            Text("\(count) more from sources still loading on this device", bundle: .module)
                .font(.hearthFootnote)
                .foregroundStyle(HearthColor.textSecondary)
        }
        .frame(minHeight: HearthMetrics.minimumHitTarget)
        .accessibilityElement(children: .combine)
    }

    private func remove(_ favorite: FavoriteRecord) {
        store.toggleFavorite(profileID: favorite.profileID, itemKey: favorite.itemKey, kind: favorite.kind)
        pendingRemoval = nil
    }

    /// The profile's favorites of one kind, in the list's own order,
    /// resolved against the catalog.
    private func entries(profileID: UUID, kind: FavoriteKind) -> [MyListEntry] {
        let favorites = store.favorites(profileID: profileID, kind: kind)
        guard !favorites.isEmpty else { return [] }
        // Shows: the profile's latest episode of each, in one read.
        let latest: [String: ProgressRecord] = kind == .series
            ? Dictionary(store.seriesInProgress(profileID: profileID, limit: 1_000).compactMap { row in row.seriesKey.map { ($0, row) } },
                         uniquingKeysWith: { first, _ in first })
            : [:]
        return favorites.enumerated().compactMap { index, favorite in
            let key = ItemKey(rawValue: favorite.itemKey)
            let found: GridEntry?
            switch kind {
            case .movie:
                found = catalog.movie(key).map { GridEntry(movie: $0, index: index) }
            case .series:
                found = catalog.seriesItem(key).map { GridEntry(series: $0, index: index, latest: latest[$0.key.rawValue]) }
            case .channel:
                found = nil
            }
            let contains = found != nil || catalog.contains(key)
            return MyListEntry.status(found: found, catalogContains: contains, sourceImported: isImported(sourceOf: key))
                .map { MyListEntry(favorite: favorite, status: $0) }
        }
    }

    /// Whether this device has finished a first import of the key's source.
    /// A source the catalog doesn't know at all (deleted from the household
    /// outright) counts as imported, so its leftovers read as unavailable and
    /// can be removed.
    private func isImported(sourceOf key: ItemKey) -> Bool {
        guard let sourceID = key.sourceID, catalog.sources.contains(where: { $0.id == sourceID }) else { return true }
        return catalog.refreshStates[sourceID]?.catalogRefreshedAt != nil
    }
}
