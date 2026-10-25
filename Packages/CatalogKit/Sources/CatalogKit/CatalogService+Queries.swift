import CoreData
import Foundation
import SourceKit

// CatalogService's reads: every query runs on the store's main-queue
// context, scoped to the live generation of each source the household still
// has, and (unless told otherwise) to what the current profile may see.

extension CatalogService {
    // MARK: Scope

    /// The sources a query covers: those the household has (a removed
    /// source's rows stay on disk but never show, SRC-9), narrowed to the
    /// profile's visible ones when filtering (PRF-6).
    func scopedSourceIDs(_ sourceID: UUID? = nil, applyingFilter: Bool) -> [UUID] {
        var ids = sources.map(\.id)
        if let sourceID { ids = ids.filter { $0 == sourceID } }
        if applyingFilter, let visible = filter.visibleSourceIDs { ids = ids.filter(visible.contains) }
        return ids
    }

    /// `(sourceID == A AND generation == gA) OR …`: each source's live
    /// catalog (or guide) generation, so rows an import is still writing,
    /// or failed to finish, never show.
    func liveScope(_ sourceIDs: [UUID], guide: Bool = false) -> NSPredicate {
        let parts = sourceIDs.map { id -> NSPredicate in
            let state = persisted[id]
            let generation = (guide ? state?.guideGeneration : state?.generation) ?? 0
            return NSPredicate(format: "sourceID == %@ AND generation == %lld", id as NSUUID, generation)
        }
        switch parts.count {
        case 0: return NSPredicate(value: false)
        case 1: return parts[0]
        default: return NSCompoundPredicate(orPredicateWithSubpredicates: parts)
        }
    }

    /// Category keys this profile may not see: hidden ones (PRF-6, LIV-8)
    /// and, while adult content is hidden, those matched by name or marked
    /// by the household (PAR-1).
    func excludedCategoryIDs() -> Set<String> {
        var excluded = filter.hiddenCategoryIDs
        if filter.hidesAdult {
            excluded.formUnion(filter.adultCategoryIDs)
            excluded.formUnion(adultCategoryIDsByName())
        }
        return excluded
    }

    /// Categories whose names match as adult, read once per revision: a
    /// handful of rows, but asked by every query while a list scrolls.
    func adultCategoryIDsByName() -> Set<String> {
        if let cached = adultNameMatches, cached.revision == revision { return cached.ids }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            liveScope(scopedSourceIDs(applyingFilter: false)),
            NSPredicate(format: "isAdult == YES"),
        ])
        let ids = Set(fetch(CatalogModel.Entity.category, predicate).map { $0.string("categoryKey") })
        adultNameMatches = (revision, ids)
        return ids
    }

    /// The profile's category rules as a predicate on an item's
    /// `categoryID`. A Kids profile (allowed list) sees only items in an
    /// allowed category; everyone else sees uncategorised items too.
    func categoryRules(applyingFilter: Bool) -> [NSPredicate] {
        guard applyingFilter else { return [] }
        var rules: [NSPredicate] = []
        if let allowed = filter.allowedCategoryIDs {
            rules.append(NSPredicate(format: "categoryID IN %@", Array(allowed)))
        }
        let excluded = excludedCategoryIDs()
        if !excluded.isEmpty {
            // `NOT (NULL IN …)` is NULL in SQL, which would drop every
            // uncategorised item; say what's meant.
            rules.append(NSPredicate(format: "categoryID == nil OR NOT (categoryID IN %@)", Array(excluded)))
        }
        return rules
    }

    /// Live, in-scope, profile-filtered items of one entity, plus `extra`.
    func itemPredicate(_ sourceID: UUID? = nil, applyingFilter: Bool, _ extra: NSPredicate...) -> NSPredicate {
        let scope = liveScope(scopedSourceIDs(sourceID, applyingFilter: applyingFilter))
        return NSCompoundPredicate(andPredicateWithSubpredicates: [scope] + categoryRules(applyingFilter: applyingFilter) + extra)
    }

    // MARK: Fetching

    func fetch(_ entity: String, _ predicate: NSPredicate, sort: [NSSortDescriptor] = [], limit: Int? = nil) -> [NSManagedObject] {
        guard let store = openStore() else { return [] }
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = predicate
        request.sortDescriptors = sort
        if let limit, limit > 0 { request.fetchLimit = limit }
        request.returnsObjectsAsFaults = false
        return (try? store.viewContext.fetch(request)) ?? []
    }

    func count(_ entity: String, _ predicate: NSPredicate) -> Int {
        guard let store = openStore() else { return 0 }
        return Fetch.count(entity, where: predicate, in: store.viewContext)
    }

    /// An item by key in its source's live generation, whatever the filter:
    /// what stream links, episode fetches and key checks read.
    func liveRow(_ entity: String, key: ItemKey) -> NSManagedObject? {
        guard let sourceID = key.sourceID else { return nil }
        return liveRows(entity, sourceID: sourceID, NSPredicate(format: "stableKey == %@", key.rawValue), limit: 1).first
    }

    func liveRows(_ entity: String, sourceID: UUID, _ predicate: NSPredicate, limit: Int? = nil) -> [NSManagedObject] {
        guard source(sourceID) != nil else { return [] }
        return fetch(entity, NSCompoundPredicate(andPredicateWithSubpredicates: [liveScope([sourceID]), predicate]), limit: limit)
    }

    func sourceName(_ sourceID: UUID) -> String {
        source(sourceID)?.name ?? ""
    }

    // MARK: Sorting

    /// By number then name (LIV-1), unnumbered channels last (their
    /// `sortNumber` is Int64.max), then the provider's order.
    static let channelOrder = [
        NSSortDescriptor(key: "sortNumber", ascending: true),
        NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:))),
        NSSortDescriptor(key: "position", ascending: true),
    ]

    /// VOD-1: newest first, A to Z, or by year (newest first). SQLite puts
    /// NULLs first ascending and last descending, so undated titles trail.
    static func order(_ sort: CatalogSort) -> [NSSortDescriptor] {
        let byName = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
        switch sort {
        case .dateAdded:
            return [NSSortDescriptor(key: "addedAt", ascending: false), NSSortDescriptor(key: "position", ascending: true), byName]
        case .name:
            return [byName, NSSortDescriptor(key: "position", ascending: true)]
        case .year:
            return [NSSortDescriptor(key: "year", ascending: false), byName]
        }
    }

    // MARK: Categories

    func queryCategories(kind: ContentKind, sourceID: UUID?, applyingFilter: Bool) -> [CatalogCategory] {
        var predicates = [
            liveScope(scopedSourceIDs(sourceID, applyingFilter: applyingFilter)),
            NSPredicate(format: "kindRaw == %@", kind.rawValue),
        ]
        if applyingFilter {
            if let allowed = filter.allowedCategoryIDs {
                predicates.append(NSPredicate(format: "categoryKey IN %@", Array(allowed)))
            }
            let excluded = excludedCategoryIDs()
            if !excluded.isEmpty {
                predicates.append(NSPredicate(format: "NOT (categoryKey IN %@)", Array(excluded)))
            }
        }
        let rows = fetch(
            CatalogModel.Entity.category,
            NSCompoundPredicate(andPredicateWithSubpredicates: predicates),
            sort: [NSSortDescriptor(key: "sortOrder", ascending: true), NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))]
        )
        let sourceOrder = Dictionary(sources.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let categories = rows.compactMap { RowReader.category($0, householdAdultIDs: filter.adultCategoryIDs) }
        // Sources in the household's order, each in its provider's order.
        return categories.enumerated()
            .sorted { ($0.element.sourceID == $1.element.sourceID ? $0.offset < $1.offset : (sourceOrder[$0.element.sourceID] ?? .max) < (sourceOrder[$1.element.sourceID] ?? .max)) }
            .map(\.element)
    }

    // MARK: Channels

    func queryChannels(categoryID: String?, applyingFilter: Bool) -> [CatalogChannel] {
        var extra: [NSPredicate] = []
        if let categoryID { extra.append(NSPredicate(format: "categoryID == %@", categoryID)) }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [itemPredicate(applyingFilter: applyingFilter)] + extra)
        return fetch(CatalogModel.Entity.channel, predicate, sort: Self.channelOrder).compactMap(channelValue)
    }

    func queryChannels(keys: [ItemKey]) -> [CatalogChannel] {
        guard !keys.isEmpty else { return [] }
        let predicate = itemPredicate(applyingFilter: true, NSPredicate(format: "stableKey IN %@", keys.map(\.rawValue)))
        let byKey = Dictionary(fetch(CatalogModel.Entity.channel, predicate).compactMap(channelValue).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return keys.compactMap { byKey[$0] }
    }

    /// LIV-6: a number finds channels whose number starts with it ("1"
    /// finds 1, 10–19, 100…), anything finds names containing every word.
    func queryFindChannels(_ query: String, limit: Int = 100) -> [CatalogChannel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = SearchKey.tokens(trimmed)
        guard !tokens.isEmpty else { return [] }
        var match: NSPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: tokens.map { NSPredicate(format: "searchKey CONTAINS %@", $0) })
        if !trimmed.isEmpty, trimmed.allSatisfy(\.isASCIIDigitCharacter) {
            match = NSCompoundPredicate(orPredicateWithSubpredicates: [NSPredicate(format: "numberText BEGINSWITH %@", trimmed), match])
        }
        return fetch(CatalogModel.Entity.channel, itemPredicate(applyingFilter: true, match), sort: Self.channelOrder, limit: limit).compactMap(channelValue)
    }

    func channelValue(_ row: NSManagedObject) -> CatalogChannel? {
        guard let sourceID = row.uuid("sourceID") else { return nil }
        return RowReader.channel(row, sourceName: sourceName(sourceID))
    }

    // MARK: Guide

    /// The key a channel's programmes are stored under: its guide id, or its
    /// own id when the provider gives none (what the importer wrote).
    static func guideKey(_ channel: CatalogChannel) -> String {
        channel.guideChannelID ?? channel.remoteID
    }

    func programmePredicate(for channel: CatalogChannel, _ extra: NSPredicate) -> NSPredicate? {
        guard source(channel.sourceID) != nil else { return nil }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            liveScope([channel.sourceID], guide: true),
            NSPredicate(format: "guideChannelID == %@", Self.guideKey(channel)),
            extra,
        ])
    }

    func queryProgrammes(for channel: CatalogChannel, from: Date, to: Date) -> [CatalogProgramme] {
        guard from < to, let predicate = programmePredicate(for: channel, NSPredicate(format: "end > %@ AND start < %@", from as NSDate, to as NSDate)) else { return [] }
        let now = Date.now
        let archive = ArchiveWindow(channel)
        return fetch(CatalogModel.Entity.programme, predicate, sort: [NSSortDescriptor(key: "start", ascending: true)])
            .compactMap { RowReader.programme($0, archive: archive, now: now) }
    }

    func queryNowAndNext(for channel: CatalogChannel, at date: Date) -> (now: CatalogProgramme?, next: CatalogProgramme?) {
        guard let predicate = programmePredicate(for: channel, NSPredicate(format: "end > %@", date as NSDate)) else { return (nil, nil) }
        let archive = ArchiveWindow(channel)
        let upcoming = fetch(CatalogModel.Entity.programme, predicate, sort: [NSSortDescriptor(key: "start", ascending: true)], limit: 3)
            .compactMap { RowReader.programme($0, archive: archive, now: date) }
        let current = upcoming.first { $0.isOn(at: date) }
        let next = upcoming.first { $0.start >= (current?.end ?? date) && $0 != current }
        return (current, next)
    }

    func queryGuideRange() -> ClosedRange<Date>? {
        let scope = liveScope(scopedSourceIDs(applyingFilter: true), guide: true)
        guard let first = fetch(CatalogModel.Entity.programme, scope, sort: [NSSortDescriptor(key: "start", ascending: true)], limit: 1).first,
              let last = fetch(CatalogModel.Entity.programme, scope, sort: [NSSortDescriptor(key: "end", ascending: false)], limit: 1).first else { return nil }
        let start = first.date("start")
        let end = last.date("end")
        return start <= end ? start...end : nil
    }

    // MARK: Movies and shows

    func queryMovies(categoryID: String?, sort: CatalogSort, limit: Int?) -> [CatalogMovie] {
        var extra: [NSPredicate] = []
        if let categoryID { extra.append(NSPredicate(format: "categoryID == %@", categoryID)) }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [itemPredicate(applyingFilter: true)] + extra)
        return fetch(CatalogModel.Entity.movie, predicate, sort: Self.order(sort), limit: limit).compactMap(movieValue)
    }

    func queryMovie(_ key: ItemKey) -> CatalogMovie? {
        let predicate = itemPredicate(applyingFilter: true, NSPredicate(format: "stableKey == %@", key.rawValue))
        return fetch(CatalogModel.Entity.movie, predicate, limit: 1).first.flatMap(movieValue)
    }

    func movieValue(_ row: NSManagedObject) -> CatalogMovie? {
        guard let sourceID = row.uuid("sourceID") else { return nil }
        return RowReader.movie(row, sourceName: sourceName(sourceID))
    }

    func querySeries(categoryID: String?, sort: CatalogSort, limit: Int?) -> [CatalogSeries] {
        var extra: [NSPredicate] = []
        if let categoryID { extra.append(NSPredicate(format: "categoryID == %@", categoryID)) }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [itemPredicate(applyingFilter: true)] + extra)
        return fetch(CatalogModel.Entity.series, predicate, sort: Self.order(sort), limit: limit).compactMap(seriesValue)
    }

    func querySeriesItem(_ key: ItemKey) -> CatalogSeries? {
        let predicate = itemPredicate(applyingFilter: true, NSPredicate(format: "stableKey == %@", key.rawValue))
        return fetch(CatalogModel.Entity.series, predicate, limit: 1).first.flatMap(seriesValue)
    }

    func seriesValue(_ row: NSManagedObject) -> CatalogSeries? {
        guard let sourceID = row.uuid("sourceID") else { return nil }
        return RowReader.series(row, sourceName: sourceName(sourceID))
    }

    // MARK: Episodes

    /// Episodes are a per-show cache outside the generations (their keys,
    /// by season and number, survive refreshes), so they are scoped by
    /// source only.
    func episodePredicate(seriesKey: ItemKey) -> NSPredicate? {
        guard let sourceID = seriesKey.sourceID, let seriesID = seriesKey.remoteID, seriesKey.kind == .series,
              scopedSourceIDs(sourceID, applyingFilter: true).contains(sourceID) else { return nil }
        return NSPredicate(format: "sourceID == %@ AND seriesID == %@", sourceID as NSUUID, seriesID)
    }

    func queryCachedEpisodes(seriesKey: ItemKey) -> [CatalogEpisode] {
        guard let predicate = episodePredicate(seriesKey: seriesKey) else { return [] }
        return fetch(CatalogModel.Entity.episode, predicate, sort: [NSSortDescriptor(key: "season", ascending: true), NSSortDescriptor(key: "number", ascending: true)])
            .compactMap(RowReader.episode)
    }

    func episodesFetchedAt(seriesKey: ItemKey) -> Date? {
        guard let predicate = episodePredicate(seriesKey: seriesKey) else { return nil }
        return fetch(CatalogModel.Entity.episode, predicate, sort: [NSSortDescriptor(key: "fetchedAt", ascending: true)], limit: 1).first?.optionalDate("fetchedAt")
    }

    func episodeRow(_ key: ItemKey) -> NSManagedObject? {
        guard key.kind == .episode, let sourceID = key.sourceID, source(sourceID) != nil else { return nil }
        let predicate = NSPredicate(format: "sourceID == %@ AND stableKey == %@", sourceID as NSUUID, key.rawValue)
        return fetch(CatalogModel.Entity.episode, predicate, limit: 1).first
    }

    func queryEpisode(_ key: ItemKey) -> CatalogEpisode? {
        guard let sourceID = key.sourceID, scopedSourceIDs(sourceID, applyingFilter: true).contains(sourceID) else { return nil }
        return episodeRow(key).flatMap(RowReader.episode)
    }

    // MARK: Stable keys

    /// Whether the key's item is in its source's live catalog, whatever the
    /// profile filter. An episode counts while its show is there: episodes
    /// are fetched only when a show is opened, and their keys (season and
    /// number) outlive the cache.
    func queryContains(_ key: ItemKey) -> Bool {
        guard let sourceID = key.sourceID, let kind = key.kind, source(sourceID) != nil else { return false }
        if kind == .episode {
            guard let seriesKey = key.seriesKey, key.seasonAndEpisode != nil else { return false }
            return queryContains(seriesKey)
        }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            liveScope([sourceID]),
            NSPredicate(format: "stableKey == %@", key.rawValue),
        ])
        return count(CatalogModel.Entity.forKind(kind), predicate) > 0
    }

    func removedNameKey(for key: ItemKey) -> String? {
        guard let sourceID = key.sourceID else { return nil }
        let predicate = NSPredicate(format: "sourceID == %@ AND stableKey == %@", sourceID as NSUUID, key.rawValue)
        return fetch(CatalogModel.Entity.removedItem, predicate, sort: [NSSortDescriptor(key: "removedAt", ascending: false)], limit: 1).first?.string("nameKey")
    }

    // MARK: Search

    /// SRCH-1/2/3: every word of the query must appear in the normalised
    /// name; titles starting with the query come first. Programmes are the
    /// next 24 hours, shown with their channel, and only where that channel
    /// is one the profile may see.
    func querySearch(_ query: String, now: Date, limitPerGroup: Int) -> SearchResults {
        let normalized = SearchKey.normalize(query)
        let tokens = normalized.split(separator: " ").map(String.init)
        guard !tokens.isEmpty, limitPerGroup > 0 else { return SearchResults() }
        let match = NSCompoundPredicate(andPredicateWithSubpredicates: tokens.map { NSPredicate(format: "searchKey CONTAINS %@", $0) })

        func ranked<T>(_ rows: [NSManagedObject], _ value: (NSManagedObject) -> T?) -> [T] {
            let prefixed = rows.filter { $0.string("searchKey").hasPrefix(normalized) }
            let rest = rows.filter { !$0.string("searchKey").hasPrefix(normalized) }
            return (prefixed + rest).prefix(limitPerGroup).compactMap(value)
        }

        // Fetched past the limit so prefix matches further down the
        // alphabet can still rank first.
        let overfetch = limitPerGroup * 3
        let channels = fetch(CatalogModel.Entity.channel, itemPredicate(applyingFilter: true, match), sort: Self.channelOrder, limit: overfetch)
        let movies = fetch(CatalogModel.Entity.movie, itemPredicate(applyingFilter: true, match), sort: Self.order(.name), limit: overfetch)
        let series = fetch(CatalogModel.Entity.series, itemPredicate(applyingFilter: true, match), sort: Self.order(.name), limit: overfetch)

        return SearchResults(
            channels: ranked(channels, channelValue),
            programmes: searchProgrammes(match, now: now, limit: limitPerGroup),
            movies: ranked(movies, movieValue),
            series: ranked(series, seriesValue)
        )
    }

    private func searchProgrammes(_ match: NSPredicate, now: Date, limit: Int) -> [SearchResults.ProgrammeHit] {
        let sourceIDs = scopedSourceIDs(applyingFilter: true)
        let window = NSPredicate(format: "end > %@ AND start < %@", now as NSDate, now.addingTimeInterval(24 * 3_600) as NSDate)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [liveScope(sourceIDs, guide: true), window, match])
        // Some hits will belong to channels the profile can't see; fetch
        // extra so the list still fills.
        let rows = fetch(CatalogModel.Entity.programme, predicate, sort: [NSSortDescriptor(key: "start", ascending: true)], limit: limit * 5)
        guard !rows.isEmpty else { return [] }

        let guideKeys = Set(rows.map { $0.string("guideChannelID") })
        let channelRows = fetch(
            CatalogModel.Entity.channel,
            itemPredicate(applyingFilter: true, NSPredicate(format: "guideKey IN %@", Array(guideKeys))),
            sort: Self.channelOrder
        )
        // Several channels can share a guide id (HD and SD); the first by
        // number speaks for the programme.
        var channelByGuide: [String: CatalogChannel] = [:]
        for row in channelRows {
            guard let sourceID = row.uuid("sourceID") else { continue }
            let lookup = "\(sourceID.uuidString)/\(row.string("guideKey"))"
            if channelByGuide[lookup] == nil, let channel = channelValue(row) {
                channelByGuide[lookup] = channel
            }
        }

        var hits: [SearchResults.ProgrammeHit] = []
        for row in rows {
            guard let sourceID = row.uuid("sourceID"),
                  let channel = channelByGuide["\(sourceID.uuidString)/\(row.string("guideChannelID"))"],
                  let programme = RowReader.programme(row, archive: ArchiveWindow(channel), now: now) else { continue }
            hits.append(SearchResults.ProgrammeHit(programme: programme, channel: channel))
            if hits.count == limit { break }
        }
        return hits
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}
