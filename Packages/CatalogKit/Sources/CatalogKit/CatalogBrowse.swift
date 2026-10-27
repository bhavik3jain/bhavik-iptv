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
    /// ("10,332 shows"), or nil when the whole list is stored.
    public func remoteCount(kind: ContentKind, categoryID: String) -> Int? {
        browseCursor(categoryID)?.remoteTotal
    }

    /// Fetches the next page of a movie or show category from its provider
    /// into the live catalog and bumps `revision`. Returns false when nothing
    /// more can come (the end, a failure, or a page already on its way).
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

        do {
            let client = try await readyClient(for: configuration)
            let added: Int
            let pageHasMore: Bool
            switch kind {
            case .vod:
                let page = try await client.movies(categoryID: remoteID, page: cursor.nextPage)
                let movies = page.items.map { movie -> RemoteMovie in
                    var movie = movie
                    movie.categoryID = movie.categoryID ?? remoteID
                    return movie
                }
                added = try await CatalogWriter.appendMovies(movies, sourceID: sourceID, generation: generation, store: store)
                pageHasMore = page.hasMore && !page.items.isEmpty
            case .series:
                let page = try await client.series(categoryID: remoteID, page: cursor.nextPage)
                let shows = page.items.map { series -> RemoteSeries in
                    var series = series
                    series.categoryID = series.categoryID ?? remoteID
                    return series
                }
                added = try await CatalogWriter.appendSeries(shows, sourceID: sourceID, generation: generation, store: store)
                pageHasMore = page.hasMore && !page.items.isEmpty
            case .live:
                return false
            }
            cursor.nextPage += 1
            cursor.hasMore = pageHasMore
            persisted[sourceID, default: PersistedSourceState()].browseCursors[categoryID] = cursor
            let cursors = persisted[sourceID]?.browseCursors ?? [:]
            try? await CatalogWriter.saveBrowseCursors(cursors, sourceID: sourceID, store: store)
            if added > 0 { catalogDidChange() }
            return cursor.hasMore || added > 0
        } catch {
            return false
        }
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
    /// Returns how many were new.
    @concurrent
    static func appendMovies(_ movies: [RemoteMovie], sourceID: UUID, generation: Int64, store: CatalogStore) async throws -> Int {
        try await append(CatalogModel.Entity.movie, movies, id: \.id, sourceID: sourceID, generation: generation, store: store) { movie, position in
            RowWriter.movie(movie, position: position, sourceID: sourceID, generation: generation)
        }
    }

    @concurrent
    static func appendSeries(_ shows: [RemoteSeries], sourceID: UUID, generation: Int64, store: CatalogStore) async throws -> Int {
        try await append(CatalogModel.Entity.series, shows, id: \.id, sourceID: sourceID, generation: generation, store: store) { series, position in
            RowWriter.series(series, position: position, sourceID: sourceID, generation: generation)
        }
    }

    private static func append<Item: Sendable>(
        _ entity: String,
        _ items: [Item],
        id: @escaping @Sendable (Item) -> String,
        sourceID: UUID,
        generation: Int64,
        store: CatalogStore,
        row: @escaping @Sendable (Item, Int) -> [String: Any]
    ) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        return try await store.write { context in
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
            let rows = fresh.enumerated().map { row($1, base + $0) }
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
