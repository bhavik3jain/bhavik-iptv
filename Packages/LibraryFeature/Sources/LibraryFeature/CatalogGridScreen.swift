import CatalogKit
import Core
import HouseholdKit
import SourceKit
import SwiftUI

/// Which half of the library a grid lists.
enum LibraryShelf: String, Sendable {
    case movies
    case shows

    var title: String {
        switch self {
        case .movies: String(localized: "Movies", bundle: .module, comment: "Screen title")
        case .shows: String(localized: "Shows", bundle: .module, comment: "Screen title")
        }
    }

    var contentKind: ContentKind {
        switch self {
        case .movies: .vod
        case .shows: .series
        }
    }

    var favoriteKind: FavoriteKind {
        switch self {
        case .movies: .movie
        case .shows: .series
        }
    }
}

/// One poster in a grid: what the catalog says about a title, resolved once
/// per query so scrolling never touches the catalog. The profile's own state
/// (progress, My List) is read by the cell itself, see `LibraryPosterLink`.
struct GridEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case movie
        /// A show, with the profile's latest episode row from one bulk read
        /// (`seriesInProgress`) rather than one read per poster.
        case series(latest: ProgressRecord?)
    }

    var id: ItemKey
    /// Position in the loaded list, for "load the next page" checks.
    var index: Int
    var title: String
    var posterURL: URL?
    var caption: String?
    var addedAt: Date?
    var kind: Kind

    init(movie: CatalogMovie, index: Int) {
        id = movie.key
        self.index = index
        title = movie.name
        posterURL = movie.posterURL
        caption = movie.year.map(String.init)
        addedAt = movie.addedAt
        kind = .movie
    }

    init(series: CatalogSeries, index: Int, latest: ProgressRecord?) {
        id = series.key
        self.index = index
        title = series.name
        posterURL = series.posterURL
        caption = series.year.map(String.init)
        addedAt = series.addedAt
        kind = .series(latest: latest)
    }

    var route: HearthRoute {
        switch kind {
        case .movie: .movie(itemKey: id.rawValue)
        case .series: .series(itemKey: id.rawValue)
        }
    }

    var favoriteKind: FavoriteKind {
        switch kind {
        case .movie: .movie
        case .series: .series
        }
    }
}

/// Movies or shows by category as a poster grid (VOD-1, SER-1): a large
/// title with the sort menu, category chips, and posters that grow a page at a
/// time. Its empty states come from the sources' refresh states, so a
/// first-run import reads as "Loading…" rather than "No movies".
struct CatalogGridScreen: View {
    let shelf: LibraryShelf

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.hearthLayout) private var layout
    @Environment(\.openRoute) private var openRoute

    /// Remembered per window, so returning to the tab keeps the view.
    @SceneStorage private var sortRaw: String
    @SceneStorage private var storedCategoryID: String?

    @State private var paging = GridPaging()
    @State private var entries: [GridEntry] = []
    @State private var chips = CategoryChips(categories: [], sourceNames: [:])
    @State private var hasLoaded = false
    private var metrics = PosterGridMetrics()

    init(shelf: LibraryShelf) {
        self.shelf = shelf
        _sortRaw = SceneStorage(wrappedValue: CatalogSort.dateAdded.rawValue, "Library.\(shelf.rawValue).sort")
        _storedCategoryID = SceneStorage("Library.\(shelf.rawValue).category")
    }

    private var sort: CatalogSort { CatalogSort(rawValue: sortRaw) ?? .dateAdded }

    private var sortBinding: Binding<CatalogSort> {
        Binding(get: { sort }, set: { sortRaw = $0.rawValue })
    }

    private var categoryID: String? { chips.validSelection(storedCategoryID) }

    /// Everything a query depends on; a change re-runs it.
    private struct QueryKey: Hashable {
        var catalogRevision: Int
        var storeRevision: Int
        var profileID: UUID?
        var categoryID: String?
        var sort: CatalogSort
        var limit: Int
    }

    private var queryKey: QueryKey {
        // A movie cell reads its own progress; only the shows' bulk read of
        // latest episodes depends on the household store.
        QueryKey(catalogRevision: catalog.revision, storeRevision: shelf == .shows ? store.revision : 0,
                 profileID: session.currentProfile?.id,
                 categoryID: storedCategoryID, sort: sort, limit: paging.limit)
    }

    var body: some View {
        let gutter = libraryGutter(layout)
        ScrollView {
            // The chips pin under the bar once the title scrolls away, so a
            // different category is one tap from deep in a long grid.
            LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                LibraryTitleRow(title: shelf.title) { sortMenu }
                    .padding(.horizontal, gutter)
                    .padding(.top, 4)
                Section {
                    content(gutter: gutter)
                } header: {
                    if chips.chips.count > 1 {
                        chipRow(gutter: gutter)
                            .padding(.vertical, 6)
                            .background(HearthColor.background)
                    }
                }
            }
            .padding(.bottom, 32)
            .frame(maxWidth: libraryMaxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollRevealedTitle(shelf.title)
        .hearthScreenBackground()
        .onChange(of: queryKey, initial: true) { _, _ in reload() }
        .onChange(of: storedCategoryID) { _, _ in paging.reset() }
        .onChange(of: sortRaw) { _, _ in paging.reset() }
    }

    // MARK: Header

    private var sortMenu: some View {
        Menu {
            Picker(selection: sortBinding) {
                ForEach(CatalogSort.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            } label: {
                Text("Sort by", bundle: .module)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(HearthColor.textPrimary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(HearthColor.surface))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Sort", bundle: .module))
        .accessibilityValue(Text(sort.title))
    }

    private func chipRow(gutter: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips.chips) { chip in
                        PillChip(chip.title, isSelected: chip.categoryID == categoryID) {
                            storedCategoryID = chip.categoryID
                        }
                        .id(chip.id)
                    }
                }
            }
            .contentMargins(.horizontal, gutter, for: .scrollContent)
            // A category remembered from last time may sit far along the
            // row: bring it into view rather than leave "All" looking chosen.
            .onAppear {
                if let categoryID { proxy.scrollTo(categoryID, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Categories", bundle: .module))
    }

    // MARK: Content

    @ViewBuilder
    private func content(gutter: CGFloat) -> some View {
        switch shelfState {
        case .content:
            grid
                .padding(.horizontal, gutter)
                .padding(.top, 4)
        case .noSources:
            EmptyStateView(
                systemName: "tray",
                title: String(localized: "No sources yet", bundle: .module),
                message: shelf == .movies
                    ? String(localized: "Add a Stalker portal, Xtream login or M3U playlist and its movies appear here.", bundle: .module)
                    : String(localized: "Add a Stalker portal, Xtream login or M3U playlist and its shows appear here.", bundle: .module),
                actionTitle: session.canManageHousehold ? String(localized: "Add a source", bundle: .module) : nil,
                action: session.canManageHousehold ? { openRoute(.sourceEditor(sourceID: nil)) } : nil
            )
            .padding(.top, 40)
        case .importing(let message, let progress):
            LibraryLoadingView(message: message.isEmpty ? String(localized: "Loading your sources…", bundle: .module) : message, progress: progress)
                .padding(.top, 60)
        case .failed(let message, let sourceID):
            EmptyStateView(
                systemName: "exclamationmark.triangle",
                title: shelf == .movies ? String(localized: "Couldn't load movies", bundle: .module) : String(localized: "Couldn't load shows", bundle: .module),
                message: message,
                actionTitle: String(localized: "Try again", bundle: .module),
                action: { Task { await catalog.refresh(sourceID: sourceID, force: true) } }
            )
            .padding(.top, 40)
        case .noneOffered:
            EmptyStateView(
                systemName: shelf == .movies ? "film" : "tv",
                title: shelf == .movies ? String(localized: "No movies here", bundle: .module) : String(localized: "No shows here", bundle: .module),
                message: shelf == .movies
                    ? String(localized: "Your sources don't offer movies, or haven't sent any yet.", bundle: .module)
                    : String(localized: "Your sources don't offer shows, or haven't sent any yet.", bundle: .module)
            )
            .padding(.top, 40)
        case .hiddenByProfile:
            EmptyStateView(
                systemName: "eye.slash",
                title: String(localized: "Nothing to show on this profile", bundle: .module),
                message: shelf == .movies
                    ? String(localized: "This profile's rules hide every movie category. Someone who manages the household can change them.", bundle: .module)
                    : String(localized: "This profile's rules hide every show category. Someone who manages the household can change them.", bundle: .module)
            )
            .padding(.top, 40)
        case .categoryEmpty:
            EmptyStateView(
                systemName: "square.grid.2x2",
                title: String(localized: "Nothing in this category", bundle: .module),
                message: String(localized: "The provider sent this category empty.", bundle: .module),
                actionTitle: String(localized: "Show all", bundle: .module),
                action: { storedCategoryID = nil }
            )
            .padding(.top, 40)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: metrics.columns(for: layout), alignment: .leading, spacing: 20) {
            ForEach(entries) { entry in
                LibraryPosterLink(entry: entry)
                    .onAppear {
                        if paging.shouldGrow(appearingIndex: entry.index, loaded: entries.count) {
                            paging.grow()
                        }
                    }
            }
        }
        .overlay(alignment: .bottom) {
            if paging.hasMore(loaded: entries.count) {
                ProgressView()
                    .tint(HearthColor.accent)
                    .offset(y: 28)
                    .accessibilityLabel(Text("Loading more", bundle: .module))
            }
        }
    }

    // MARK: State

    private var sourceStates: [SourceRefreshState] {
        catalog.sources.compactMap { catalog.refreshStates[$0.id] }
    }

    private var shelfState: ShelfState {
        guard hasLoaded else {
            return .importing(message: String(localized: "Loading…", bundle: .module), progress: nil)
        }
        let offered = sourceStates.reduce(0) { $0 + (shelf == .movies ? $1.movieCount : $1.seriesCount) }
        return ShelfState.resolve(hasItems: !entries.isEmpty, categorySelected: categoryID != nil,
                                  sourceCount: catalog.sources.count, states: sourceStates, offeredCount: offered)
    }

    /// Re-queries the catalog (and, for shows, the profile's latest episode
    /// of each). Synchronous: the catalog reads from its main-queue context
    /// with a fetch limit. A movie's progress is read by its cell instead.
    private func reload() {
        let sourceNames = Dictionary(catalog.sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        chips = CategoryChips(categories: catalog.categories(kind: shelf.contentKind), sourceNames: sourceNames)
        let category = chips.validSelection(storedCategoryID)

        switch shelf {
        case .movies:
            entries = catalog.movies(categoryID: category, sort: sort, limit: paging.limit)
                .enumerated()
                .map { GridEntry(movie: $1, index: $0) }
        case .shows:
            let latest = latestEpisodeBySeries()
            entries = catalog.series(categoryID: category, sort: sort, limit: paging.limit)
                .enumerated()
                .map { GridEntry(series: $1, index: $0, latest: latest[$1.key.rawValue]) }
        }
        hasLoaded = true
    }

    /// The profile's latest episode row of every show it has touched, in one
    /// read rather than one per poster. Empty for a Guest.
    private func latestEpisodeBySeries() -> [String: ProgressRecord] {
        guard let profile = session.currentProfile, !profile.isGuest else { return [:] }
        let rows = store.seriesInProgress(profileID: profile.id, limit: 1_000)
        return Dictionary(rows.compactMap { row in row.seriesKey.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
    }
}
