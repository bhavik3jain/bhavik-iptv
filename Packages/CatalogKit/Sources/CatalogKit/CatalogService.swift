import CoreData
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
        #if os(tvOS)
        // An Apple TV keeps only purgeable files beyond a few hundred KB of
        // defaults, so the catalog goes in Caches; a purge only means
        // fetching it from the provider again.
        URL.cachesDirectory.appending(path: "Catalog/Catalog.sqlite")
        #else
        URL.applicationSupportDirectory.appending(path: "Catalog/Catalog.sqlite")
        #endif
    }

    let storeURL: URL?
    let clientFactory: ClientFactory

    // MARK: Internal state
    //
    // Not observed: views observe `revision`, `refreshStates` and `sources`,
    // which change whenever anything below does in a way they can see.

    /// The store, once opened (lazily, on first use, so creating the service
    /// at launch costs nothing).
    @ObservationIgnored var openedStore: CatalogStore?
    @ObservationIgnored var storeOpenFailure: String?
    @ObservationIgnored var storeOpenAttempted = false
    /// Each source's live generations and last-read status, mirrored from
    /// its `SourceState` row so queries never fetch it.
    @ObservationIgnored var persisted: [UUID: PersistedSourceState] = [:]
    /// One client per source, reused so a Stalker session (its token) lives
    /// across refreshes, guide loads and plays.
    @ObservationIgnored var clients: [UUID: any SourceClient] = [:]
    /// Sources whose cached client has signed in during this run.
    @ObservationIgnored var signedIn: Set<UUID> = []
    @ObservationIgnored var refreshTasks: [UUID: Task<Void, Never>] = [:]
    /// New sources waiting for their first import, walked one at a time.
    @ObservationIgnored var pendingRefreshes: [UUID] = []
    @ObservationIgnored var backgroundRunner: Task<Void, Never>?
    /// Categories with a page on its way from the provider (`loadMore`).
    @ObservationIgnored var loadingMoreCategories: Set<String> = []
    /// Queries already asked of the providers this launch
    /// (`searchProviders`), by normalised text.
    @ObservationIgnored var providerSearchedQueries: Set<String> = []
    /// Provider searches on their way; Search shows that it's still asking.
    public internal(set) var providerSearchesRunning = 0
    /// When each channel's short guide was last asked for (throttle).
    @ObservationIgnored var shortGuideRequestedAt: [ItemKey: Date] = [:]
    /// Category keys whose names match as adult, per `revision`.
    @ObservationIgnored var adultNameMatches: (revision: Int, ids: Set<String>)?

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
        let previous = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sources = configurations
        let current = Set(configurations.map(\.id))

        for id in previous.keys where !current.contains(id) {
            forgetSource(id)
        }
        for configuration in configurations {
            // An edited login gets a fresh client (and session) next time.
            if let old = previous[configuration.id], old != configuration {
                clients[configuration.id] = nil
                signedIn.remove(configuration.id)
            }
        }

        openStore()
        seedRefreshStates()

        // SRC-6: a source that has never been imported on this device is
        // imported now, in the background; the rest wait for
        // `refreshAllIfStale`, which the app calls at launch.
        let needingImport = configurations
            .filter { previous[$0.id] != $0 && !(persisted[$0.id]?.hasCatalog ?? false) }
            .map(\.id)
        enqueueBackgroundRefresh(needingImport)
        revision += 1
    }

    /// Refreshes one source's account, categories, channels, movies and shows
    /// (and its guide where it has a full one). Skips a catalog younger than a
    /// day unless `force` (SRC-6). Cancellable.
    public func refresh(sourceID: UUID, force: Bool = false) async {
        await runExclusive(sourceID) { service in
            await service.performRefresh(sourceID: sourceID, mode: .catalog(force: force))
        }
    }

    /// Refreshes every source whose catalog is over 24 h old or guide over
    /// 6 h, one at a time. Called at launch and from background refresh.
    public func refreshAllIfStale() async {
        openStore(retry: true)
        for configuration in sources {
            if Task.isCancelled { return }
            guard needsRefresh(configuration, now: .now) else { continue }
            await refresh(sourceID: configuration.id)
        }
    }

    /// Reloads one source's guide.
    public func refreshGuide(sourceID: UUID) async {
        await runExclusive(sourceID) { service in
            await service.performRefresh(sourceID: sourceID, mode: .guide)
        }
    }

    /// Signs in with an unsaved configuration and counts what it offers,
    /// without writing anything (SRC-4).
    public func testSource(_ configuration: SourceConfiguration) async -> SourceTestResult {
        await SourceTester(client: clientFactory(configuration)).run()
    }

    /// The account as last read (expiry, Xtream stream counts).
    public func account(sourceID: UUID) -> AccountInfo? { refreshStates[sourceID]?.account }

    /// Reads the account now (Xtream: before each play, HH-6). Nil when the
    /// source is gone or the provider can't be asked: callers then go by
    /// `account(sourceID:)` or let the play be tried.
    public func refreshAccount(sourceID: UUID) async -> AccountInfo? {
        await readAccount(sourceID: sourceID)
    }

    /// Stops a source's refresh, if one is running. Added beside the
    /// contract for the Household screen's "Cancel" and for tests.
    public func cancelRefresh(sourceID: UUID) {
        refreshTasks[sourceID]?.cancel()
        pendingRefreshes.removeAll { $0 == sourceID }
    }

    // MARK: Live TV

    public func categories(kind: ContentKind, sourceID: UUID? = nil, applyingFilter: Bool = true) -> [CatalogCategory] {
        queryCategories(kind: kind, sourceID: sourceID, applyingFilter: applyingFilter)
    }

    /// Channels in a category, or all visible channels when `categoryID` is
    /// nil, ordered by number then name, across sources.
    public func channels(categoryID: String? = nil, applyingFilter: Bool = true) -> [CatalogChannel] {
        queryChannels(categoryID: categoryID, applyingFilter: applyingFilter)
    }

    /// The channels for these keys, in the order given; missing keys skipped.
    public func channels(keys: [ItemKey]) -> [CatalogChannel] {
        queryChannels(keys: keys)
    }

    public func channel(_ key: ItemKey) -> CatalogChannel? {
        queryChannels(keys: [key]).first
    }

    /// Channels whose name or number matches (LIV-6).
    public func findChannels(_ query: String) -> [CatalogChannel] {
        queryFindChannels(query)
    }

    /// A channel's programmes overlapping `from..<to`, by start.
    public func programmes(for channel: CatalogChannel, from: Date, to: Date) -> [CatalogProgramme] {
        queryProgrammes(for: channel, from: from, to: to)
    }

    /// What's on now and next.
    public func nowAndNext(for channel: CatalogChannel, at date: Date = .now) -> (now: CatalogProgramme?, next: CatalogProgramme?) {
        queryNowAndNext(for: channel, at: date)
    }

    /// Loads the short guide for channels on screen, for sources with no full
    /// guide (Stalker). Throttled per channel; bumps `revision` when done.
    public func loadShortGuide(for channels: [CatalogChannel]) async {
        await performShortGuideLoad(for: channels)
    }

    /// The earliest and latest guide times held, for how far the timeline scrolls.
    public func guideRange() -> ClosedRange<Date>? {
        queryGuideRange()
    }

    // MARK: Movies and shows

    public func movies(categoryID: String? = nil, sort: CatalogSort = .dateAdded, limit: Int? = nil) -> [CatalogMovie] {
        queryMovies(categoryID: categoryID, sort: sort, limit: limit)
    }

    public func movie(_ key: ItemKey) -> CatalogMovie? {
        queryMovie(key)
    }

    public func series(categoryID: String? = nil, sort: CatalogSort = .dateAdded, limit: Int? = nil) -> [CatalogSeries] {
        querySeries(categoryID: categoryID, sort: sort, limit: limit)
    }

    public func seriesItem(_ key: ItemKey) -> CatalogSeries? {
        querySeriesItem(key)
    }

    /// Seasons and episodes from the provider, cached in the store; returns
    /// the cache at once if fetched in the last day.
    public func episodes(for series: CatalogSeries) async throws -> [CatalogEpisode] {
        try await loadEpisodes(for: series)
    }

    /// Episodes already cached, without a fetch.
    public func cachedEpisodes(seriesKey: ItemKey) -> [CatalogEpisode] {
        queryCachedEpisodes(seriesKey: seriesKey)
    }

    public func episode(_ key: ItemKey) -> CatalogEpisode? {
        queryEpisode(key)
    }

    // MARK: Search

    /// Channels, the next 24 h of the guide, movies and shows (SRCH-1).
    /// Matches a normalised search key (lowercased, accents and punctuation
    /// stripped). Nothing leaves the device (SRCH-2).
    public func search(_ query: String, now: Date = .now, limitPerGroup: Int = 30) -> SearchResults {
        querySearch(query, now: now, limitPerGroup: limitPerGroup)
    }

    // MARK: Playing

    /// A fresh stream link for a channel, movie or episode, asked of the
    /// provider now. For catch-up pass the programme start and duration.
    public func streamLink(for key: ItemKey, catchupStart: Date? = nil, catchupDuration: TimeInterval? = nil) async throws -> StreamLink {
        try await resolveStreamLink(for: key, catchupStart: catchupStart, catchupDuration: catchupDuration)
    }

    /// Keeps a Stalker session alive while something plays from it.
    public func keepAlive(sourceID: UUID) async {
        guard let client = clients[sourceID] else { return }
        await client.keepAlive()
    }

    // MARK: Stable keys

    /// After a refresh: for each key no longer in the catalog, the one item of
    /// the same source, kind and normalised name that replaces it (FAV-2).
    /// Keys with none or several matches are left out.
    public func replacementKeys(for keys: [ItemKey]) -> [ItemKey: ItemKey] {
        var replacements: [ItemKey: ItemKey] = [:]
        for key in Set(keys) where !contains(key) {
            if let replacement = replacement(for: key) {
                replacements[key] = replacement
            }
        }
        return replacements
    }

    /// True when the key's item is in the catalog now.
    public func contains(_ key: ItemKey) -> Bool {
        queryContains(key)
    }

    // MARK: - Internal mutation
    //
    // The published properties are `private(set)`; the extensions in the
    // other files change them through these.

    /// After rows land through batch requests, which bypass every context:
    /// drop what the view context holds and tell views to re-query.
    func catalogDidChange() {
        openedStore?.viewContext.reset()
        revision += 1
    }

    func updateRefreshState(_ sourceID: UUID, _ change: (inout SourceRefreshState) -> Void) {
        var state = refreshStates[sourceID] ?? SourceRefreshState(sourceID: sourceID)
        change(&state)
        if refreshStates[sourceID] != state {
            refreshStates[sourceID] = state
        }
    }

    func removeRefreshState(_ sourceID: UUID) {
        refreshStates[sourceID] = nil
    }
}
