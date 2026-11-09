import CoreData
import Foundation
import SourceKit

/// Where one category's provider list stands when the list is too big to
/// import whole. A Stalker portal can hold 160,000 titles at 14 a page and
/// 1.5 s a page — days of requests — so a refresh keeps each category's first
/// page and the rest arrives as someone browses it, as iSTB does.
struct BrowseCursor: Sendable, Hashable, Codable {
    /// The provider page (0-based) to ask for next.
    var nextPage: Int
    var hasMore: Bool
    /// The provider's own count for the category, when it gave one.
    var remoteTotal: Int?
}

extension CatalogService {
    /// True when a category's provider list holds more than the catalog has
    /// stored: the grid asks for the next page with `loadMore` as it nears
    /// the end of what's stored.
    public func canLoadMore(kind: ContentKind, categoryID: String) -> Bool {
        browseCursor(categoryID)?.hasMore ?? false
    }

    /// The provider's count for a category that loads as it is browsed
    /// ("10,332 shows"), or nil for a category imported whole.
    public func remoteCount(kind: ContentKind, categoryID: String) -> Int? {
        browseCursor(categoryID)?.remoteTotal
    }

    /// Pages one `loadMore` call goes through when each adds nothing new.
    static let loadMoreSkipLimit = 20

    /// Fetches the next page of a movie or show category from its provider
    /// into the live catalog and bumps `revision`. A page whose titles are
    /// all stored already (kept over a refresh, found by search) moves
    /// straight on to the next, up to `loadMoreSkipLimit` pages, so the grid
    /// isn't left waiting on a page that changed nothing. Returns false when
    /// nothing more can come (the end, a failure, or a page already on its way).
    @discardableResult
    public func loadMore(kind: ContentKind, categoryID: String) async -> Bool {
        guard kind != .live,
              let (sourceID, remoteID) = Self.parseCategoryID(categoryID),
              let configuration = source(sourceID),
              let store = openStore(),
              var cursor = browseCursor(categoryID), cursor.hasMore,
              loadingMoreCategories.insert(categoryID).inserted
        else { return false }
        defer { loadingMoreCategories.remove(categoryID) }
        let generation = persisted[sourceID]?.generation ?? 0

        var added = 0
        var pages = 0
        defer { if added > 0 { catalogDidChange() } }
        do {
            let client = try await readyClient(for: configuration)
            repeat {
                let pageHasMore: Bool
                switch kind {
                case .vod:
                    let page = try await client.movies(categoryID: remoteID, page: cursor.nextPage)
                    let movies = page.items.map { movie -> RemoteMovie in
                        var movie = movie
                        movie.categoryID = movie.categoryID ?? remoteID
                        return movie
                    }
                    added += try await CatalogWriter.appendMovies(movies, sourceID: sourceID, generation: generation, store: store)
                    pageHasMore = page.hasMore && !page.items.isEmpty
                case .series:
                    let page = try await client.series(categoryID: remoteID, page: cursor.nextPage)
                    let shows = page.items.map { series -> RemoteSeries in
                        var series = series
                        series.categoryID = series.categoryID ?? remoteID
                        return series
                    }
                    added += try await CatalogWriter.appendSeries(shows, sourceID: sourceID, generation: generation, store: store)
                    pageHasMore = page.hasMore && !page.items.isEmpty
                case .live:
                    return false
                }
                cursor.nextPage += 1
                cursor.hasMore = pageHasMore
                pages += 1
                persisted[sourceID, default: PersistedSourceState()].browseCursors[categoryID] = cursor
            } while added == 0 && cursor.hasMore && pages < Self.loadMoreSkipLimit && !Task.isCancelled
            let cursors = persisted[sourceID]?.browseCursors ?? [:]
            try? await CatalogWriter.saveBrowseCursors(cursors, sourceID: sourceID, store: store)
            return cursor.hasMore || added > 0
        } catch {
            if pages > 0 {
                let cursors = persisted[sourceID]?.browseCursors ?? [:]
                try? await CatalogWriter.saveBrowseCursors(cursors, sourceID: sourceID, store: store)
            }
            return added > 0
        }
    }

    /// How many pages of a provider's search are asked for (14 titles a page
    /// on Ministra, 2–4 s each, so the pages go out together).
    static let providerSearchPages = 2
    /// How many pages a held title's search goes through looking for its
    /// key (`resolveHeldItems`).
    static let heldSearchPageLimit = 6

    /// True when some source keeps only part of its movies and shows on this
    /// device and can search the rest: a search there also asks the provider.
    public var searchesProviders: Bool {
        sources.contains { persisted[$0.id]?.browseCursors.isEmpty == false }
    }

    /// Asks each source that keeps only part of its catalog here (a big
    /// Stalker portal, imported a page per category) for movies and shows
    /// matching `query`, and adds what comes back, so `search(_:)` finds
    /// titles nobody has browsed to yet and gives the same answer every time.
    /// The query goes to the provider: the owner chose that over search
    /// staying on the device for these sources (SRCH-2). Each query's pages
    /// are asked once per catalog: a refresh that swaps one in asks again.
    /// Returns how many titles were new; `revision` bumps when any were.
    @discardableResult
    public func searchProviders(_ query: String) async -> Int {
        await searchProviders(query, showingProgress: true)
    }

    /// `searchProviders(_:)`; `showingProgress` false keeps a search nobody
    /// typed (a held title's, `resolveHeldItems`) out of
    /// `providerSearchesRunning`, so Search doesn't spin for it.
    ///
    /// Pages go out `providerSearchPages` at a time, up to `pageLimit`, and
    /// stop early once `found` says so or the provider has no more. Pages a
    /// query was already asked for this catalog aren't asked again, so a held
    /// title's search (`heldSearchPageLimit`) carries on past the two pages
    /// a typed search of the same name asked, rather than being skipped.
    func searchProviders(_ query: String, showingProgress: Bool, pageLimit: Int = CatalogService.providerSearchPages, until found: () -> Bool = { false }) async -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = SearchKey.normalize(trimmed)
        guard normalized.count >= 2, let store = openStore() else { return 0 }
        let browsed = sources.filter { persisted[$0.id]?.browseCursors.isEmpty == false }
        guard !browsed.isEmpty else { return 0 }
        var showing = false
        defer { if showing { providerSearchesRunning -= 1 } }

        var added = 0
        while !found(), !Task.isCancelled {
            let asked = providerSearchedPages[normalized] ?? 0
            guard asked < pageLimit else { break }
            let batch = asked..<min(asked + Self.providerSearchPages, pageLimit)
            // Claimed before asking, so the same query sent again meanwhile
            // doesn't ask for these pages a second time.
            providerSearchedPages[normalized] = batch.upperBound
            if showingProgress, !showing {
                showing = true
                providerSearchesRunning += 1
            }
            var answered = false
            var more = false
            for configuration in browsed {
                guard let client = try? await readyClient(for: configuration), client.capabilities.searchesCatalog else { continue }
                let pages = await withTaskGroup(of: RemoteSearchPage?.self) { group in
                    for page in batch {
                        group.addTask { try? await client.search(trimmed, page: page) }
                    }
                    var pages: [RemoteSearchPage] = []
                    for await page in group { if let page { pages.append(page) } }
                    return pages.sorted { $0.page < $1.page }
                }
                if !pages.isEmpty { answered = true }
                if pages.last?.hasMore == true { more = true }
                let generation = persisted[configuration.id]?.generation ?? 0
                let movies = pages.flatMap(\.movies)
                let series = pages.flatMap(\.series)
                added += (try? await CatalogWriter.appendMovies(movies, sourceID: configuration.id, generation: generation, store: store)) ?? 0
                added += (try? await CatalogWriter.appendSeries(series, sourceID: configuration.id, generation: generation, store: store)) ?? 0
            }
            if !answered {
                // Nothing came back (offline, cancelled): these pages may be
                // asked for again.
                if providerSearchedPages[normalized] == batch.upperBound {
                    providerSearchedPages[normalized] = asked == 0 ? nil : asked
                }
                break
            }
            if !more {
                // The provider's last page: nothing further to ask, however
                // many pages a later caller would go to.
                providerSearchedPages[normalized] = .max
                break
            }
        }
        if added > 0 { catalogDidChange() }
        return added
    }

    func browseCursor(_ categoryID: String) -> BrowseCursor? {
        guard let (sourceID, _) = Self.parseCategoryID(categoryID) else { return nil }
        return persisted[sourceID]?.browseCursors[categoryID]
    }

    /// `CategoryKey.make` backwards: `<sourceUUID>/<kind>/<remoteID>`.
    nonisolated static func parseCategoryID(_ categoryID: String) -> (UUID, String)? {
        let parts = categoryID.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let sourceID = UUID(uuidString: String(parts[0])) else { return nil }
        return (sourceID, String(parts[2]))
    }
}

extension CatalogWriter {
    /// Adds a browsed page of movies to the live generation, skipping titles
    /// already stored (a page asked for twice, a title in two categories).
    /// `generation` is only a fallback: the store says which one is live.
    /// Returns how many were new.
    @concurrent
    static func appendMovies(_ movies: [RemoteMovie], sourceID: UUID, generation: Int64, store: CatalogStore) async throws -> Int {
        try await append(CatalogModel.Entity.movie, movies, id: \.id, sourceID: sourceID, generation: generation, store: store) { movie, position, live in
            RowWriter.movie(movie, position: position, sourceID: sourceID, generation: live)
        }
    }

    @concurrent
    static func appendSeries(_ shows: [RemoteSeries], sourceID: UUID, generation: Int64, store: CatalogStore) async throws -> Int {
        try await append(CatalogModel.Entity.series, shows, id: \.id, sourceID: sourceID, generation: generation, store: store) { series, position, live in
            RowWriter.series(series, position: position, sourceID: sourceID, generation: live)
        }
    }

    private static func append<Item: Sendable>(
        _ entity: String,
        _ items: [Item],
        id: @escaping @Sendable (Item) -> String,
        sourceID: UUID,
        generation: Int64,
        store: CatalogStore,
        row: @escaping @Sendable (Item, Int, Int64) -> [String: Any]
    ) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        return try await store.write { context in
            // The generation live now, asked of the store inside this write:
            // `generation` was read before the provider answered, and a
            // refresh may have swapped in a new catalog since. Rows written
            // to the old one then were thrown away with it.
            let generation = try SourceStateRow.fetch(sourceID, in: context).map { $0.int64("generation") } ?? generation
            // Which of these the catalog already holds, and where the
            // source's list ends now (new rows sort after it).
            let ids = items.map(id)
            let existing = NSFetchRequest<NSDictionary>(entityName: entity)
            existing.resultType = .dictionaryResultType
            existing.propertiesToFetch = ["remoteID"]
            existing.predicate = NSPredicate(format: "sourceID == %@ AND generation == %lld AND remoteID IN %@", sourceID as NSUUID, generation, ids)
            let stored = Set(try context.fetch(existing).compactMap { $0["remoteID"] as? String })

            let last = NSFetchRequest<NSDictionary>(entityName: entity)
            last.resultType = .dictionaryResultType
            last.propertiesToFetch = ["position"]
            last.predicate = NSPredicate(format: "sourceID == %@ AND generation == %lld", sourceID as NSUUID, generation)
            last.sortDescriptors = [NSSortDescriptor(key: "position", ascending: false)]
            last.fetchLimit = 1
            let base = Int((try context.fetch(last).first?["position"] as? Int64) ?? -1) + 1

            var seen = stored
            let fresh = items.filter { seen.insert(id($0)).inserted }
            let rows = fresh.enumerated().map { row($1, base + $0, generation) }
            try Batch.insert(entity, rows, into: context)
            return fresh.count
        }
    }

    /// Persists the browse cursors on the source's state row, so a relaunch
    /// carries on from the page it reached.
    @concurrent
    static func saveBrowseCursors(_ cursors: [String: BrowseCursor], sourceID: UUID, store: CatalogStore) async throws {
        let data = try JSONEncoder().encode(cursors)
        try await store.write { context in
            try SourceStateRow.update(sourceID, in: context) { row in
                row.setValue(data, forKey: "browseJSON")
            }
        }
    }
}
