import CatalogKit
import Core
import HouseholdKit
import SwiftUI

/// One My List row as the screen draws it (FAV-3).
struct MyListEntry: Identifiable, Equatable {
    enum Status: Equatable {
        /// In the catalog and visible to this profile.
        case available(GridEntry)
        /// No longer offered by its provider: drawn greyed as "Unavailable"
        /// with a way to take it off the list.
        case unavailable
    }

    var favorite: FavoriteRecord
    var status: Status
    var id: UUID { favorite.id }

    /// How a favorite resolves against the catalog. An item the catalog
    /// still holds but this profile's rules hide is left off the list rather
    /// than shown as gone (it isn't, and a Kids profile shouldn't learn its
    /// name); one the catalog no longer holds is unavailable. Favorites of a
    /// removed source never reach here: the store hides them (SRC-9).
    static func status(found: GridEntry?, catalogContains: Bool) -> Status? {
        if let found { return .available(found) }
        return catalogContains ? nil : .unavailable
    }
}

/// The profile's My List: its movies and shows as poster grids (FAV-3),
/// synced through the household so it follows the profile to every device.
struct MyListScreen: View {
    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.hearthLayout) private var layout
    @Environment(\.play) private var play

    @State private var pendingRemoval: FavoriteRecord?
    private let metrics = PosterGridMetrics()

    var body: some View {
        let _ = (catalog.revision, store.revision)
        let gutter = libraryGutter(layout)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LibraryTitleRow(title: String(localized: "My List")) { EmptyView() }
                    .padding(.top, 4)
                content
            }
            .padding(.horizontal, gutter)
            .padding(.bottom, 32)
            .frame(maxWidth: libraryMaxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollRevealedTitle(String(localized: "My List"))
        .hearthScreenBackground()
        .confirmationDialog(
            String(localized: "Remove from My List?"),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { favorite in
            Button(String(localized: "Remove"), role: .destructive) {
                remove(favorite)
            }
        } message: { _ in
            Text("Its provider no longer offers it.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let profile = session.currentProfile {
            if profile.isGuest {
                EmptyStateView(
                    systemName: "heart",
                    title: String(localized: "My List isn't kept for guests"),
                    message: String(localized: "Pick your own profile to keep movies and shows in My List.")
                )
                .padding(.top, 40)
            } else {
                let movies = entries(profileID: profile.id, kind: .movie)
                let shows = entries(profileID: profile.id, kind: .series)
                if movies.isEmpty && shows.isEmpty {
                    EmptyStateView(
                        systemName: "heart",
                        title: String(localized: "Nothing in My List yet"),
                        message: String(localized: "Tap the heart on a movie or show to keep it here. My List follows your profile to every device in the household.")
                    )
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    if !movies.isEmpty {
                        section(String(localized: "Movies"), entries: movies, profileID: profile.id)
                    }
                    if !shows.isEmpty {
                        section(String(localized: "Shows"), entries: shows, profileID: profile.id)
                    }
                }
            }
        } else {
            EmptyStateView(systemName: "person.crop.circle", title: String(localized: "Choose a profile to see its list"))
                .padding(.top, 40)
        }
    }

    private func section(_ title: String, entries: [MyListEntry], profileID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title)
            LazyVGrid(columns: metrics.columns(for: layout), alignment: .leading, spacing: 20) {
                ForEach(entries) { entry in
                    tile(entry, profileID: profileID)
                }
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func tile(_ entry: MyListEntry, profileID: UUID) -> some View {
        switch entry.status {
        case .available(let item):
            NavigationLink(value: item.route) {
                PosterCell(title: item.title, url: item.posterURL, caption: item.caption, decoration: item.decoration)
            }
            .buttonStyle(.hearthTile)
            .contextMenu {
                if let start = item.movieStart {
                    Button {
                        play(PlayIntent(itemKey: item.id.rawValue, kind: .movie, title: item.title,
                                        artworkURL: item.posterURL, startPosition: start.startPosition))
                    } label: {
                        Label(start.title, systemImage: "play.fill")
                    }
                }
                Button(role: .destructive) {
                    remove(entry.favorite)
                } label: {
                    Label("Remove from My List", systemImage: "heart.slash")
                }
            }
        case .unavailable:
            Button {
                pendingRemoval = entry.favorite
            } label: {
                PosterCell(
                    title: String(localized: "Unavailable"),
                    url: nil,
                    caption: String(localized: "No longer offered"),
                    decoration: PosterDecoration(badge: nil, progress: nil),
                    isUnavailable: true
                )
            }
            .buttonStyle(.hearthTile)
            .accessibilityHint(Text("Removes it from My List"))
            .contextMenu {
                Button(role: .destructive) {
                    remove(entry.favorite)
                } label: {
                    Label("Remove from My List", systemImage: "heart.slash")
                }
            }
        }
    }

    private func remove(_ favorite: FavoriteRecord) {
        store.toggleFavorite(profileID: favorite.profileID, itemKey: favorite.itemKey, kind: favorite.kind)
        pendingRemoval = nil
    }

    /// The profile's favorites of one kind, in the list's own order,
    /// resolved against the catalog.
    private func entries(profileID: UUID, kind: FavoriteKind) -> [MyListEntry] {
        let now = Date.now
        return store.favorites(profileID: profileID, kind: kind).enumerated().compactMap { index, favorite in
            let key = ItemKey(rawValue: favorite.itemKey)
            let found: GridEntry?
            switch kind {
            case .movie:
                found = catalog.movie(key).map { movie in
                    let progress = store.progress(profileID: profileID, itemKey: movie.key.rawValue)
                    return GridEntry(id: movie.key, index: index, title: movie.name, posterURL: movie.posterURL,
                                     caption: movie.year.map(String.init),
                                     decoration: .movie(addedAt: movie.addedAt, progress: progress, now: now),
                                     route: .movie(itemKey: movie.key.rawValue), movieStart: MoviePlayState(progress: progress))
                }
            case .series:
                found = catalog.seriesItem(key).map { show in
                    let latest = store.seriesProgress(profileID: profileID, seriesKey: show.key.rawValue)
                        .max { $0.updatedAt < $1.updatedAt }
                    return GridEntry(id: show.key, index: index, title: show.name, posterURL: show.posterURL,
                                     caption: show.year.map(String.init),
                                     decoration: .series(addedAt: show.addedAt, latest: latest, now: now),
                                     route: .series(itemKey: show.key.rawValue), movieStart: nil)
                }
            case .channel:
                found = nil
            }
            return MyListEntry.status(found: found, catalogContains: found != nil || catalog.contains(key))
                .map { MyListEntry(favorite: favorite, status: $0) }
        }
    }
}
