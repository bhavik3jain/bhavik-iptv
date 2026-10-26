import CatalogKit
import Core
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
    @Environment(ProfileSession.self) private var session
    @Environment(\.hearthLayout) private var layout

    @State private var pendingRemoval: FavoriteRecord?
    private var metrics = PosterGridMetrics()

    var body: some View {
        let _ = (catalog.revision, store.revision)
        let gutter = libraryGutter(layout)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LibraryTitleRow(title: String(localized: "My List", bundle: .module)) { EmptyView() }
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

    @ViewBuilder
    private var content: some View {
        if let profile = session.currentProfile {
            if profile.isGuest {
                EmptyStateView(
                    systemName: "heart",
                    title: String(localized: "My List isn't kept for guests", bundle: .module),
                    message: String(localized: "Pick your own profile to keep movies and shows in My List.", bundle: .module)
                )
                .padding(.top, 40)
            } else {
                list(profileID: profile.id)
            }
        } else {
            EmptyStateView(systemName: "person.crop.circle", title: String(localized: "Choose a profile to see its list", bundle: .module))
                .padding(.top, 40)
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
                EmptyStateView(
                    systemName: "heart",
                    title: String(localized: "Nothing in My List yet", bundle: .module),
                    message: String(localized: "Tap the heart on a movie or show to keep it here. My List follows your profile to every device in the household.", bundle: .module)
                )
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
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

    private func section(_ title: String, entries: [MyListEntry]) -> some View {
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
            LibraryPosterLink(entry: item)
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
