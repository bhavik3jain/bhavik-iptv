import Foundation
import Observation
import SourceKit

/// The catalog as screens see it: every source's channels, guide, movies and
/// shows from the local store, refreshed from the providers in the
/// background. One instance for the app, injected with `.environment(_:)`.
///
/// Reads are synchronous and come from the store's main-queue context (fetch
/// limits keep them fast); imports run on background contexts and bump
/// `revision` when they land, so views that read `revision` re-query.
///
/// PUBLIC API IS A CONTRACT: features and the app compile against these
/// signatures. Add to it; don't change or remove.
@MainActor
@Observable
public final class CatalogService {
    public typealias ClientFactory = @Sendable (SourceConfiguration) -> any SourceClient

    /// Where the store lives; nil keeps it in memory (tests, `-InMemoryStores`).
    public init(storeURL: URL?, clientFactory: @escaping ClientFactory = { SourceClientFactory.make($0) }) {
        self.storeURL = storeURL
        self.clientFactory = clientFactory
    }

    /// The default on-disk location: Application Support/Catalog/Catalog.sqlite.
    public static var defaultStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "Catalog/Catalog.sqlite")
    }

    let storeURL: URL?
    let clientFactory: ClientFactory

    // MARK: Sources and refresh

    /// The household's sources (not removed), as last set by the app.
    public private(set) var sources: [SourceConfiguration] = []

    /// Bumped after every import or guide load; read it in a view to re-query.
    public private(set) var revision: Int = 0

    public private(set) var refreshStates: [UUID: SourceRefreshState] = [:]

    /// What the current profile may see. Every query below applies it unless
    /// it takes `applyingFilter: false`.
    public var filter = CatalogFilter() {
        didSet { if filter != oldValue { revision += 1 } }
    }

    /// Called by the app whenever the household's sources change. New sources
    /// are refreshed; a removed source's content stops appearing (its rows may
    /// stay on disk until the next cleanup, SRC-9).
    public func setSources(_ configurations: [SourceConfiguration]) {
        sources = configurations
        revision += 1
    }

    /// Refreshes one source's account, categories, channels, movies and shows
    /// (and its guide where it has a full one). Skips a catalog younger than a
    /// day unless `force` (SRC-6). Cancellable.
    public func refresh(sourceID: UUID, force: Bool = false) async {}

    /// Refreshes every source whose catalog is over 24 h old or guide over
    /// 6 h, one at a time. Called at launch and from background refresh.
    public func refreshAllIfStale() async {}

    /// Reloads one source's guide.
    public func refreshGuide(sourceID: UUID) async {}

    /// Signs in with an unsaved configuration and counts what it offers,
    /// without writing anything (SRC-4).
    public func testSource(_ configuration: SourceConfiguration) async -> SourceTestResult {
        SourceTestResult(succeeded: false, message: "Not implemented yet")
    }

    /// The account as last read (expiry, Xtream stream counts).
    public func account(sourceID: UUID) -> AccountInfo? { refreshStates[sourceID]?.account }

    /// Reads the account now (Xtream: before each play, HH-6).
    public func refreshAccount(sourceID: UUID) async -> AccountInfo? { nil }

    // MARK: Live TV

    public func categories(kind: ContentKind, sourceID: UUID? = nil, applyingFilter: Bool = true) -> [CatalogCategory] { [] }

    /// Channels in a category, or all visible channels when `categoryID` is
    /// nil, ordered by number then name, across sources.
    public func channels(categoryID: String? = nil, applyingFilter: Bool = true) -> [CatalogChannel] { [] }

    /// The channels for these keys, in the order given; missing keys skipped.
    public func channels(keys: [ItemKey]) -> [CatalogChannel] { [] }

    public func channel(_ key: ItemKey) -> CatalogChannel? { nil }

    /// Channels whose name or number matches (LIV-6).
    public func findChannels(_ query: String) -> [CatalogChannel] { [] }

    /// A channel's programmes overlapping `from..<to`, by start.
    public func programmes(for channel: CatalogChannel, from: Date, to: Date) -> [CatalogProgramme] { [] }

    /// What's on now and next.
    public func nowAndNext(for channel: CatalogChannel, at date: Date = .now) -> (now: CatalogProgramme?, next: CatalogProgramme?) { (nil, nil) }

    /// Loads the short guide for channels on screen, for sources with no full
    /// guide (Stalker). Throttled per channel; bumps `revision` when done.
    public func loadShortGuide(for channels: [CatalogChannel]) async {}

    /// The earliest and latest guide times held, for how far the timeline scrolls.
    public func guideRange() -> ClosedRange<Date>? { nil }

    // MARK: Movies and shows

    public func movies(categoryID: String? = nil, sort: CatalogSort = .dateAdded, limit: Int? = nil) -> [CatalogMovie] { [] }

    public func movie(_ key: ItemKey) -> CatalogMovie? { nil }

    public func series(categoryID: String? = nil, sort: CatalogSort = .dateAdded, limit: Int? = nil) -> [CatalogSeries] { [] }

    public func seriesItem(_ key: ItemKey) -> CatalogSeries? { nil }

    /// Seasons and episodes from the provider, cached in the store; returns
    /// the cache at once if fetched in the last day.
    public func episodes(for series: CatalogSeries) async throws -> [CatalogEpisode] { [] }

    /// Episodes already cached, without a fetch.
    public func cachedEpisodes(seriesKey: ItemKey) -> [CatalogEpisode] { [] }

    public func episode(_ key: ItemKey) -> CatalogEpisode? { nil }

    // MARK: Search

    /// Channels, the next 24 h of the guide, movies and shows (SRCH-1).
    /// Matches a normalised search key (lowercased, accents and punctuation
    /// stripped). Nothing leaves the device (SRCH-2).
    public func search(_ query: String, now: Date = .now, limitPerGroup: Int = 30) -> SearchResults { SearchResults() }

    // MARK: Playing

    /// A fresh stream link for a channel, movie or episode, asked of the
    /// provider now. For catch-up pass the programme start and duration.
    public func streamLink(for key: ItemKey, catchupStart: Date? = nil, catchupDuration: TimeInterval? = nil) async throws -> StreamLink {
        throw SourceError(.noLink)
    }

    /// Keeps a Stalker session alive while something plays from it.
    public func keepAlive(sourceID: UUID) async {}

    // MARK: Stable keys

    /// After a refresh: for each key no longer in the catalog, the one item of
    /// the same source, kind and normalised name that replaces it (FAV-2).
    /// Keys with none or several matches are left out.
    public func replacementKeys(for keys: [ItemKey]) -> [ItemKey: ItemKey] { [:] }

    /// True when the key's item is in the catalog now.
    public func contains(_ key: ItemKey) -> Bool { false }
}
