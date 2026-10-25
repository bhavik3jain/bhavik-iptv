import CoreData
import Foundation
import SourceKit

/// Where an import stands, as the importer reports it to the service.
struct ImportProgress: Sendable, Hashable {
    var fraction: Double?
    var message: String
}

/// One source's import from its provider into the store, run off the main
/// actor (SRC-6). The service drives the steps and publishes what they
/// return; nothing here touches the view context.
///
/// The generation scheme (see `CatalogModel`): `importCatalog` writes every
/// row under `generation + 1` beside the live catalog and flips
/// `SourceState.generation` only once all of it is in, so a provider that
/// fails half way leaves yesterday's catalog showing. `retireCatalog` then
/// deletes the old rows, after the service has moved its queries over.
struct CatalogImporter: Sendable {
    let store: CatalogStore
    let sourceID: UUID
    let client: any SourceClient
    let report: @Sendable (ImportProgress) async -> Void

    /// Stalker pages hold about 14 items, so 10,000 pages is 140,000 titles:
    /// past any real catalog, short of looping forever on a portal that
    /// keeps answering `hasMore`.
    static let pageCap = 10_000
    /// The guide is kept from 7 days back to 7 days ahead (Technical spec,
    /// Catalog store): far enough for catch-up, small enough to stay fast.
    static let guideKeptBack: TimeInterval = 7 * 86_400
    static let guideKeptAhead: TimeInterval = 7 * 86_400
    /// How long the name of a vanished item is remembered for FAV-2.
    static let removalsKept: TimeInterval = 180 * 86_400

    // MARK: Catalog

    /// Signs in, then imports categories, channels, movies and shows into a
    /// new generation and swaps it in. Returns the new state; throws (with
    /// the live catalog untouched) on any failure or cancellation.
    @concurrent
    func importCatalog(from previous: PersistedSourceState, now: Date) async throws -> PersistedSourceState {
        let progress = ProgressThrottle(report)
        let capabilities = client.capabilities
        let client = self.client
        let sourceID = self.sourceID
        let live = previous.generation
        let generation = live + 1

        await progress.update(0, String(localized: "Signing in"), force: true)
        let account = try await client.signIn()
        try Task.checkCancellation()

        // Rows a crashed or failed import left behind share no generation
        // with the live catalog; clear them so the new one starts clean.
        try await store.write { context in
            for entity in CatalogModel.Entity.generational {
                try Batch.delete(entity, where: Where.notGeneration(live, of: sourceID), in: context)
            }
        }

        await progress.update(0.05, String(localized: "Categories"), force: true)
        var kinds: [ContentKind] = [.live]
        if capabilities.hasMovies { kinds.append(.vod) }
        if capabilities.hasSeries { kinds.append(.series) }
        var categoriesByKind: [ContentKind: [RemoteCategory]] = [:]
        for kind in kinds {
            let fetched = try await unlessUnsupported([]) { try await client.categories(kind) }
            var seen = Set<String>()
            categoriesByKind[kind] = fetched.compactMap { category in
                guard seen.insert(category.id).inserted else { return nil }
                // Filed under the kind it was asked for, whatever the
                // provider wrote, so its key matches its items' categoryID.
                var category = category
                category.kind = kind
                return category
            }
            try Task.checkCancellation()
        }
        try await insert(CatalogModel.Entity.category, kinds.flatMap { categoriesByKind[$0] ?? [] }) { category, _ in
            RowWriter.category(category, sourceID: sourceID, generation: generation)
        }

        await progress.update(0.1, String(localized: "Channels"), force: true)
        var seenChannels = Set<String>()
        let channels = try await client.channels().filter { seenChannels.insert($0.id).inserted }
        try Task.checkCancellation()
        try await insert(CatalogModel.Entity.channel, channels) { channel, position in
            RowWriter.channel(channel, position: position, sourceID: sourceID, generation: generation)
        }

        var movieCount = 0
        if capabilities.hasMovies {
            movieCount = try await importPaged(
                entity: CatalogModel.Entity.movie,
                label: String(localized: "Movies"),
                slice: 0.15...0.6,
                categories: categoriesByKind[.vod] ?? [],
                progress: progress,
                fetch: { try await client.movies(categoryID: $0, page: $1) },
                id: { $0.id },
                row: { movie, position in RowWriter.movie(movie, position: position, sourceID: sourceID, generation: generation) }
            )
        }

        var seriesCount = 0
        if capabilities.hasSeries {
            seriesCount = try await importPaged(
                entity: CatalogModel.Entity.series,
                label: String(localized: "Shows"),
                slice: 0.6...0.95,
                categories: categoriesByKind[.series] ?? [],
                progress: progress,
                fetch: { try await client.series(categoryID: $0, page: $1) },
                id: { $0.id },
                row: { series, position in RowWriter.series(series, position: position, sourceID: sourceID, generation: generation) }
            )
        }

        try Task.checkCancellation()
        await progress.update(0.97, String(localized: "Finishing"), force: true)

        // The swap: from here on the new generation is the catalog.
        var state = previous
        state.generation = generation
        state.catalogRefreshedAt = now
        state.account = account
        state.channelCount = channels.count
        state.movieCount = movieCount
        state.seriesCount = seriesCount
        let swapped = state
        try await store.write { context in
            try SourceStateRow.update(sourceID, in: context) { row in
                row.setValue(swapped.generation, forKey: "generation")
                row.setValue(now, forKey: "catalogRefreshedAt")
                row.setValue(Int64(swapped.channelCount), forKey: "channelCount")
                row.setValue(Int64(swapped.movieCount), forKey: "movieCount")
                row.setValue(Int64(swapped.seriesCount), forKey: "seriesCount")
                SourceStateRow.setAccount(account, on: row, readAt: now)
            }
        }
        return state
    }

    /// After the swap: remembers the keys that vanished (with their names,
    /// for `replacementKeys`, FAV-2), deletes the previous generation, the
    /// cached episodes of shows that are gone and guide rows past the window.
    @concurrent
    func retireCatalog(keeping generation: Int64, now: Date) async throws {
        let sourceID = self.sourceID
        try await store.write { context in
            let current = Where.generation(generation, of: sourceID)
            let old = Where.notGeneration(generation, of: sourceID)

            var currentKeys = Set<String>()
            var vanished: [(key: String, kind: ItemKind, nameKey: String)] = []
            for (entity, kind) in CatalogModel.Entity.keyed {
                let keys = Set(try Fetch.strings("stableKey", from: entity, where: current, in: context))
                currentKeys.formUnion(keys)
                for row in try Fetch.values(["stableKey", "searchKey"], from: entity, where: old, in: context) {
                    guard let key = row["stableKey"] as? String, !keys.contains(key) else { continue }
                    vanished.append((key, kind, row["searchKey"] as? String ?? ""))
                }
            }

            let removedEntity = CatalogModel.Entity.removedItem
            let remembered = Set(try Fetch.strings("stableKey", from: removedEntity, where: Where.source(sourceID), in: context))
            // A key that came back is no longer missing.
            let returned = remembered.intersection(currentKeys)
            if !returned.isEmpty {
                try Batch.delete(removedEntity, where: NSPredicate(format: "sourceID == %@ AND stableKey IN %@", sourceID as NSUUID, Array(returned)), in: context)
            }
            try Batch.delete(removedEntity, where: NSPredicate(format: "removedAt < %@", now.addingTimeInterval(-Self.removalsKept) as NSDate), in: context)
            let rows = vanished
                .filter { !remembered.contains($0.key) }
                .map { RowWriter.removedItem(stableKey: $0.key, kind: $0.kind, nameKey: $0.nameKey, sourceID: sourceID, removedAt: now) }
            try Batch.insert(removedEntity, rows, into: context)

            for entity in CatalogModel.Entity.generational {
                try Batch.delete(entity, where: old, in: context)
            }

            // Episodes are cached per show outside the generations; drop
            // those whose show left the catalog.
            let seriesIDs = Set(try Fetch.strings("remoteID", from: CatalogModel.Entity.series, where: current, in: context))
            let cachedSeriesIDs = Set(try Fetch.strings("seriesID", from: CatalogModel.Entity.episode, where: Where.source(sourceID), in: context, distinct: true))
            let goneSeries = cachedSeriesIDs.subtracting(seriesIDs)
            if !goneSeries.isEmpty {
                try Batch.delete(CatalogModel.Entity.episode, where: NSPredicate(format: "sourceID == %@ AND seriesID IN %@", sourceID as NSUUID, Array(goneSeries)), in: context)
            }

            // Short guides (Stalker) never swap generations; age them out here.
            try Batch.delete(CatalogModel.Entity.programme, where: NSPredicate(format: "sourceID == %@ AND end < %@", sourceID as NSUUID, now.addingTimeInterval(-Self.guideKeptBack) as NSDate), in: context)
        }
    }

    // MARK: Guide

    /// Streams the full guide (XMLTV) into a new guide generation, keeping 7
    /// days back to 7 ahead, and swaps it in. Nil when the source has no
    /// full guide. A guide that comes back empty keeps the last one.
    @concurrent
    func importGuide(from previous: PersistedSourceState, now: Date) async throws -> PersistedSourceState? {
        guard let stream = client.fullGuide() else { return nil }
        let progress = ProgressThrottle(report)
        let sourceID = self.sourceID
        let live = previous.guideGeneration
        let generation = live + 1

        try await store.write { context in
            try Batch.delete(CatalogModel.Entity.programme, where: Where.notGeneration(live, of: sourceID), in: context)
        }

        await progress.update(nil, String(localized: "Guide"), force: true)
        let earliest = now.addingTimeInterval(-Self.guideKeptBack)
        let latest = now.addingTimeInterval(Self.guideKeptAhead)
        var buffer: [RemoteProgramme] = []
        buffer.reserveCapacity(Batch.chunkSize)
        var count = 0
        for try await programme in stream {
            guard programme.end > programme.start, programme.end > earliest, programme.start < latest else { continue }
            buffer.append(programme)
            if buffer.count >= Batch.chunkSize {
                try Task.checkCancellation()
                try await insertProgrammes(buffer, generation: generation)
                count += buffer.count
                buffer.removeAll(keepingCapacity: true)
                await progress.update(nil, String(localized: "Guide: \(count.formatted()) programmes"))
            }
        }
        try Task.checkCancellation()
        try await insertProgrammes(buffer, generation: generation)
        count += buffer.count

        var state = previous
        state.guideRefreshedAt = now
        if count > 0 { state.guideGeneration = generation }
        let swapped = state
        try await store.write { context in
            try SourceStateRow.update(sourceID, in: context) { row in
                row.setValue(swapped.guideGeneration, forKey: "guideGeneration")
                row.setValue(now, forKey: "guideRefreshedAt")
            }
        }
        return state
    }

    /// After a guide swap: deletes the previous guide generation.
    @concurrent
    func retireGuide(keeping generation: Int64) async throws {
        let sourceID = self.sourceID
        try await store.write { context in
            try Batch.delete(CatalogModel.Entity.programme, where: Where.notGeneration(generation, of: sourceID), in: context)
        }
    }

    // MARK: Steps

    /// A whole paged list (movies or shows): asks for everything at once and,
    /// when the provider won't (`notSupported`), category by category.
    /// Stops when the provider says there's no more, a page comes back
    /// empty, or a page repeats the last one (a portal ignoring `p`).
    /// Titles listed twice (in two categories) are written once.
    private func importPaged<Item: Sendable & Hashable>(
        entity: String,
        label: String,
        slice: ClosedRange<Double>,
        categories: [RemoteCategory],
        progress: ProgressThrottle,
        fetch: @Sendable (String?, Int) async throws -> Page<Item>,
        id: @escaping @Sendable (Item) -> String,
        row: @escaping @Sendable (Item, Int) -> [String: Any]
    ) async throws -> Int {
        var seen = Set<String>()
        var written = 0
        let width = slice.upperBound - slice.lowerBound

        func list(_ categoryID: String?, share: ClosedRange<Double>) async throws {
            var page = 0
            var previousIDs: [String] = []
            var listed = 0
            while page < Self.pageCap {
                try Task.checkCancellation()
                let result = try await fetch(categoryID, page)
                let ids = result.items.map(id)
                if ids.isEmpty || ids == previousIDs { break }
                previousIDs = ids
                listed += ids.count
                let fresh = result.items.filter { seen.insert(id($0)).inserted }
                try await insert(entity, fresh, positionBase: written, row: row)
                written += fresh.count

                var fraction = share.lowerBound
                if let total = result.totalItems, total > 0 {
                    fraction += (share.upperBound - share.lowerBound) * min(Double(listed) / Double(total), 1)
                }
                await progress.update(fraction, "\(label): \(written.formatted())")
                guard result.hasMore else { break }
                page += 1
            }
        }

        do {
            try await list(nil, share: slice)
        } catch let error as SourceError where error.code == .notSupported {
            for (index, category) in categories.enumerated() {
                let lower = slice.lowerBound + width * Double(index) / Double(categories.count)
                let upper = slice.lowerBound + width * Double(index + 1) / Double(categories.count)
                try await list(category.id, share: lower...upper)
            }
        }
        await progress.update(slice.upperBound, "\(label): \(written.formatted())", force: true)
        return written
    }

    private func insert<Item: Sendable>(_ entity: String, _ items: [Item], positionBase: Int = 0, row: @escaping @Sendable (Item, Int) -> [String: Any]) async throws {
        guard !items.isEmpty else { return }
        try await store.write { context in
            var start = 0
            while start < items.count {
                let end = min(start + Batch.chunkSize, items.count)
                try autoreleasepool {
                    let rows = (start..<end).map { row(items[$0], positionBase + $0) }
                    try Batch.insert(entity, rows, into: context)
                }
                start = end
            }
        }
    }

    private func insertProgrammes(_ programmes: [RemoteProgramme], generation: Int64) async throws {
        let sourceID = self.sourceID
        try await insert(CatalogModel.Entity.programme, programmes) { programme, _ in
            RowWriter.programme(programme, sourceID: sourceID, generation: generation)
        }
    }

    /// Movies and shows are optional for a provider; a client that says it
    /// can't list them yields an empty list rather than a failed refresh.
    private func unlessUnsupported<T: Sendable>(_ fallback: T, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as SourceError where error.code == .notSupported {
            return fallback
        }
    }
}

/// Writes that don't come from a full import: episodes when a show opens,
/// short guides for the channels on screen, an account read before a play.
enum CatalogWriter {
    /// One channel's short guide, under the key its programmes join on.
    struct ShortGuide: Sendable {
        var guideKey: String
        var programmes: [RemoteProgramme]
    }

    /// Replaces a show's cached episodes. Keys are by season and number
    /// (Stable ids, 5), so an episode listed twice keeps its first entry.
    @concurrent
    static func saveEpisodes(_ detail: SeriesDetail, seriesID: String, sourceID: UUID, fetchedAt: Date, store: CatalogStore) async throws {
        try await store.write { context in
            try Batch.delete(CatalogModel.Entity.episode, where: NSPredicate(format: "sourceID == %@ AND seriesID == %@", sourceID as NSUUID, seriesID), in: context)
            let seasons = Dictionary(detail.seasons.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<[Int]>()
            let rows = detail.episodes.compactMap { episode -> [String: Any]? in
                guard seen.insert([episode.season, episode.number]).inserted else { return nil }
                return RowWriter.episode(episode, season: seasons[episode.season], seriesID: seriesID, sourceID: sourceID, fetchedAt: fetchedAt)
            }
            try Batch.insert(CatalogModel.Entity.episode, rows, into: context)
        }
    }

    /// Writes short guides into the source's live guide generation,
    /// replacing whatever overlapped them.
    @concurrent
    static func saveShortGuides(_ guides: [ShortGuide], sourceID: UUID, generation: Int64, store: CatalogStore) async throws {
        try await store.write { context in
            for guide in guides {
                let programmes = guide.programmes.filter { $0.end > $0.start }
                guard let start = programmes.map(\.start).min(), let end = programmes.map(\.end).max() else { continue }
                try Batch.delete(
                    CatalogModel.Entity.programme,
                    where: NSPredicate(format: "sourceID == %@ AND guideChannelID == %@ AND start < %@ AND end > %@", sourceID as NSUUID, guide.guideKey, end as NSDate, start as NSDate),
                    in: context
                )
                let rows = programmes.map { RowWriter.programme($0, guideKey: guide.guideKey, sourceID: sourceID, generation: generation) }
                try Batch.insert(CatalogModel.Entity.programme, rows, into: context)
            }
        }
    }

    @concurrent
    static func saveAccount(_ account: AccountInfo, sourceID: UUID, readAt: Date, store: CatalogStore) async throws {
        try await store.write { context in
            try SourceStateRow.update(sourceID, in: context) { row in
                SourceStateRow.setAccount(account, on: row, readAt: readAt)
            }
        }
    }
}

/// Reports progress without flooding the main actor: Stalker lists arrive
/// 14 items a page, thousands of pages, and every report redraws the
/// Household screen. Passes a report on when forced (a new step) or a
/// quarter second after the last. Used by one import task only.
final class ProgressThrottle {
    private let report: @Sendable (ImportProgress) async -> Void
    private var lastReport: ContinuousClock.Instant?
    private static let interval: Duration = .milliseconds(250)

    init(_ report: @escaping @Sendable (ImportProgress) async -> Void) {
        self.report = report
    }

    func update(_ fraction: Double?, _ message: String, force: Bool = false) async {
        let now = ContinuousClock.now
        if !force, let lastReport, now - lastReport < Self.interval { return }
        lastReport = now
        await report(ImportProgress(fraction: fraction, message: message))
    }
}
