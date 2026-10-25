import CoreData
import Foundation
import SourceKit

// Everything in CatalogService that talks to a provider or writes the store:
// opening the store, refreshes, the short guide, episodes, stream links and
// account reads. Queries are in CatalogService+Queries.swift.

/// When a source's catalog and guide are due (SRC-6). A value type so the
/// rule is tested without a provider.
enum RefreshPolicy {
    /// Catalogs refresh daily.
    static let catalogMaxAge: TimeInterval = 24 * 3_600
    /// Guides every 6 hours.
    static let guideMaxAge: TimeInterval = 6 * 3_600

    struct Plan: Sendable, Hashable {
        var catalog: Bool
        var guide: Bool

        var isEmpty: Bool { !catalog && !guide }
    }

    /// A catalog import always brings the guide along (where the source has
    /// a full one): new channels need their programmes.
    static func plan(for state: PersistedSourceState, hasFullGuide: Bool, now: Date, force: Bool) -> Plan {
        let catalog = force || !state.hasCatalog || isStale(state.catalogRefreshedAt, maxAge: catalogMaxAge, now: now)
        let guide = hasFullGuide && (catalog || isStale(state.guideRefreshedAt, maxAge: guideMaxAge, now: now))
        return Plan(catalog: catalog, guide: guide)
    }

    /// Never refreshed, older than `maxAge`, or stamped in the future (the
    /// clock was changed): all stale.
    static func isStale(_ refreshedAt: Date?, maxAge: TimeInterval, now: Date) -> Bool {
        guard let refreshedAt else { return true }
        return refreshedAt > now || now.timeIntervalSince(refreshedAt) >= maxAge
    }
}

extension CatalogService {
    enum RefreshMode: Sendable {
        case catalog(force: Bool)
        case guide
    }

    /// The short guide is asked for at most this often per channel: Stalker
    /// portals rate-limit, and a programme list doesn't change in half an hour.
    static let shortGuideInterval: TimeInterval = 30 * 60
    /// Episodes fetched within a day are shown from the cache without asking.
    static let episodeCacheAge: TimeInterval = 24 * 3_600
    /// Catch-up asked for without a duration (a programme the guide doesn't
    /// end): two hours covers nearly every broadcast.
    static let defaultCatchupDuration: TimeInterval = 2 * 3_600

    // MARK: Store

    /// The store, opened on first use. A store that fails to open even after
    /// being deleted and created again leaves every source showing the
    /// failure in `refreshStates`; queries then return nothing rather than
    /// crash. `retry` tries again after an earlier failure (refreshes do;
    /// queries don't, so a broken disk isn't hit on every redraw).
    @discardableResult
    func openStore(retry: Bool = false) -> CatalogStore? {
        if let openedStore { return openedStore }
        guard !storeOpenAttempted || retry else { return nil }
        storeOpenAttempted = true
        do {
            let store = try CatalogStore.open(at: storeURL)
            openedStore = store
            storeOpenFailure = nil
            persisted = (try? SourceStateRow.loadAll(in: store.viewContext)) ?? [:]
            store.viewContext.reset()
            seedRefreshStates()
            return store
        } catch {
            storeOpenFailure = String(localized: "The catalog couldn't be opened: \(error.localizedDescription)")
            seedRefreshStates()
            return nil
        }
    }

    /// Gives every source a refresh state from what the store remembers, so
    /// the Household screen shows counts, last refresh and expiry at launch
    /// (SRC-5) before any provider is asked.
    func seedRefreshStates() {
        for configuration in sources {
            let saved = persisted[configuration.id]
            updateRefreshState(configuration.id) { state in
                if let saved {
                    state.account = state.account ?? saved.account
                    state.catalogRefreshedAt = saved.catalogRefreshedAt
                    state.guideRefreshedAt = saved.guideRefreshedAt
                    state.channelCount = saved.channelCount
                    state.movieCount = saved.movieCount
                    state.seriesCount = saved.seriesCount
                }
                if let storeOpenFailure {
                    state.phase = .failed(message: storeOpenFailure)
                } else if case .failed(let message) = state.phase, message.hasPrefix(String(localized: "The catalog couldn't be opened")) {
                    state.phase = .idle
                }
            }
        }
    }

    func source(_ sourceID: UUID) -> SourceConfiguration? {
        sources.first { $0.id == sourceID }
    }

    /// A removed source: stop its work and drop its session. Its rows stay
    /// until a later cleanup (SRC-9: adding it back restores everything).
    func forgetSource(_ sourceID: UUID) {
        refreshTasks[sourceID]?.cancel()
        pendingRefreshes.removeAll { $0 == sourceID }
        clients[sourceID] = nil
        signedIn.remove(sourceID)
        shortGuideRequestedAt = shortGuideRequestedAt.filter { $0.key.sourceID != sourceID }
        removeRefreshState(sourceID)
    }

    // MARK: Clients

    /// The source's client, created once and kept (setSources drops it when
    /// the login changes).
    func client(for configuration: SourceConfiguration) -> any SourceClient {
        if let cached = clients[configuration.id] { return cached }
        let client = clientFactory(configuration)
        clients[configuration.id] = client
        signedIn.remove(configuration.id)
        return client
    }

    /// The client, signed in once per run before its first non-refresh call
    /// (a stream link or episode list right after launch, when the catalog
    /// was fresh and no import signed in).
    func readyClient(for configuration: SourceConfiguration) async throws -> any SourceClient {
        let client = client(for: configuration)
        if !signedIn.contains(configuration.id) {
            let account = try await client.signIn()
            signedIn.insert(configuration.id)
            noteAccount(account, sourceID: configuration.id)
        }
        return client
    }

    func noteAccount(_ account: AccountInfo, sourceID: UUID) {
        persisted[sourceID, default: PersistedSourceState()].account = account
        updateRefreshState(sourceID) { $0.account = account }
    }

    func readAccount(sourceID: UUID) async -> AccountInfo? {
        guard let configuration = source(sourceID) else { return nil }
        let client = client(for: configuration)
        do {
            let account: AccountInfo
            if signedIn.contains(sourceID) {
                account = try await client.accountInfo()
            } else {
                // Signing in reports the account too, and leaves a session
                // the play that usually follows can use.
                account = try await client.signIn()
                signedIn.insert(sourceID)
            }
            noteAccount(account, sourceID: sourceID)
            if let store = openStore() {
                try? await CatalogWriter.saveAccount(account, sourceID: sourceID, readAt: .now, store: store)
            }
            return account
        } catch {
            return nil
        }
    }

    // MARK: Refresh

    /// Runs a refresh for a source unless one is already running, in which
    /// case it waits for that one: one import per source at a time. The work
    /// is an unstructured task (so a background refresh outlives the view
    /// that started it) whose cancellation follows the caller's.
    func runExclusive(_ sourceID: UUID, _ work: @escaping @MainActor (CatalogService) async -> Void) async {
        let task: Task<Void, Never>
        if let running = refreshTasks[sourceID] {
            task = running
        } else {
            task = Task { [weak self] in
                guard let self else { return }
                await work(self)
                self.refreshTasks[sourceID] = nil
            }
            refreshTasks[sourceID] = task
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// New sources' first imports, one at a time, in the background.
    func enqueueBackgroundRefresh(_ sourceIDs: [UUID]) {
        for id in sourceIDs where !pendingRefreshes.contains(id) {
            pendingRefreshes.append(id)
        }
        guard backgroundRunner == nil, !pendingRefreshes.isEmpty else { return }
        backgroundRunner = Task { [weak self] in
            while let self, !self.pendingRefreshes.isEmpty, !Task.isCancelled {
                let next = self.pendingRefreshes.removeFirst()
                await self.refresh(sourceID: next)
            }
            self?.backgroundRunner = nil
        }
    }

    /// Waits for the background imports `setSources` started. For tests and
    /// for a caller that wants the catalog before going on.
    public func waitForBackgroundRefreshes() async {
        while let runner = backgroundRunner {
            await runner.value
        }
    }

    func needsRefresh(_ configuration: SourceConfiguration, now: Date) -> Bool {
        let state = persisted[configuration.id] ?? PersistedSourceState()
        let hasFullGuide = client(for: configuration).capabilities.hasFullGuide
        return !RefreshPolicy.plan(for: state, hasFullGuide: hasFullGuide, now: now, force: false).isEmpty
    }

    /// One source's refresh (SRC-6): the catalog into a new generation,
    /// swapped in when complete, then the guide the same way. Progress and
    /// the outcome go to `refreshStates`; a failure keeps the last good
    /// catalog and says why.
    func performRefresh(sourceID: UUID, mode: RefreshMode) async {
        guard let configuration = source(sourceID) else { return }
        guard let store = openStore(retry: true) else { return }
        let client = client(for: configuration)
        let now = Date.now
        var state = persisted[sourceID] ?? PersistedSourceState()
        let hasFullGuide = client.capabilities.hasFullGuide

        let plan: RefreshPolicy.Plan
        switch mode {
        case .catalog(let force):
            plan = RefreshPolicy.plan(for: state, hasFullGuide: hasFullGuide, now: now, force: force)
        case .guide:
            plan = RefreshPolicy.Plan(catalog: false, guide: hasFullGuide)
        }
        guard !plan.isEmpty else { return }

        updateRefreshState(sourceID) {
            $0.phase = .refreshing(progress: 0, message: String(localized: "Starting"))
        }
        let importer = CatalogImporter(store: store, sourceID: sourceID, client: client) { [weak self] progress in
            await self?.importDidProgress(progress, sourceID: sourceID)
        }

        var failedStep: String?
        do {
            if plan.catalog {
                state = try await importer.importCatalog(from: state, now: now)
                signedIn.insert(sourceID)
                adopt(state, sourceID: sourceID)
                catalogDidChange()
                // The old rows are already out of every query; a cleanup
                // that fails is finished by the next import's first step.
                try? await importer.retireCatalog(keeping: state.generation, now: now)
                openedStore?.viewContext.reset()
            }
            if plan.guide {
                failedStep = String(localized: "The guide couldn't be loaded")
                if let guideState = try await importer.importGuide(from: state, now: now) {
                    state = guideState
                    adopt(state, sourceID: sourceID)
                    catalogDidChange()
                    try? await importer.retireGuide(keeping: state.guideGeneration)
                    openedStore?.viewContext.reset()
                }
            }
            updateRefreshState(sourceID) { $0.phase = .idle }
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? SourceError)?.code == .cancelled
            updateRefreshState(sourceID) {
                if cancelled {
                    $0.phase = .idle
                } else {
                    let reason = Self.describe(error)
                    $0.phase = .failed(message: failedStep.map { "\($0): \(reason)" } ?? reason)
                }
            }
        }
    }

    /// Mirrors a swapped-in state: the generations queries use, and what the
    /// Household screen shows.
    func adopt(_ state: PersistedSourceState, sourceID: UUID) {
        persisted[sourceID] = state
        updateRefreshState(sourceID) {
            $0.account = state.account ?? $0.account
            $0.catalogRefreshedAt = state.catalogRefreshedAt
            $0.guideRefreshedAt = state.guideRefreshedAt
            $0.channelCount = state.channelCount
            $0.movieCount = state.movieCount
            $0.seriesCount = state.seriesCount
        }
    }

    func importDidProgress(_ progress: ImportProgress, sourceID: UUID) {
        guard refreshTasks[sourceID] != nil else { return }
        updateRefreshState(sourceID) {
            $0.phase = .refreshing(progress: progress.fraction, message: progress.message)
        }
    }

    /// The provider's own words when it sent any (SRC-4), else ours.
    nonisolated static func describe(_ error: any Error) -> String {
        if let sourceError = error as? SourceError, let text = sourceError.errorDescription { return text }
        return error.localizedDescription
    }

    // MARK: Short guide

    func performShortGuideLoad(for channels: [CatalogChannel]) async {
        let now = Date.now
        var bySource: [UUID: [RemoteChannel]] = [:]
        for channel in channels {
            if let last = shortGuideRequestedAt[channel.key], now.timeIntervalSince(last) < Self.shortGuideInterval, last <= now { continue }
            guard let configuration = source(channel.sourceID),
                  !client(for: configuration).capabilities.hasFullGuide,
                  let row = liveRow(CatalogModel.Entity.channel, key: channel.key) else { continue }
            // Marked when asked, not when answered: a portal that fails is
            // left alone for the same half hour instead of hit on every scroll.
            shortGuideRequestedAt[channel.key] = now
            bySource[channel.sourceID, default: []].append(RowReader.remoteChannel(row))
        }
        guard !bySource.isEmpty, let store = openStore() else { return }

        var landed = false
        for (sourceID, remoteChannels) in bySource {
            guard let configuration = source(sourceID),
                  let client = try? await readyClient(for: configuration) else { continue }
            let guides = await ShortGuideLoader.load(remoteChannels, client: client)
            guard !guides.isEmpty else { continue }
            let generation = persisted[sourceID]?.guideGeneration ?? 0
            if (try? await CatalogWriter.saveShortGuides(guides, sourceID: sourceID, generation: generation, store: store)) != nil {
                landed = true
            }
        }
        if landed { catalogDidChange() }
    }

    // MARK: Episodes

    func loadEpisodes(for series: CatalogSeries) async throws -> [CatalogEpisode] {
        let cached = queryCachedEpisodes(seriesKey: series.key)
        if let fetchedAt = episodesFetchedAt(seriesKey: series.key), !cached.isEmpty,
           fetchedAt <= .now, Date.now.timeIntervalSince(fetchedAt) < Self.episodeCacheAge {
            return cached
        }
        guard let configuration = source(series.sourceID), let store = openStore() else {
            if !cached.isEmpty { return cached }
            throw SourceError(.invalidConfiguration, detail: "The show's source is not in the household")
        }
        let remote = liveRow(CatalogModel.Entity.series, key: series.key).map(RowReader.remoteSeries)
            ?? RemoteSeries(id: series.remoteID, name: series.name, posterURL: series.posterURL, plot: series.plot, year: series.year, rating: series.rating, addedAt: series.addedAt, genre: series.genre)
        do {
            let client = try await readyClient(for: configuration)
            let detail = try await client.seriesDetail(remote)
            try await CatalogWriter.saveEpisodes(detail, seriesID: series.remoteID, sourceID: series.sourceID, fetchedAt: .now, store: store)
            catalogDidChange()
            return queryCachedEpisodes(seriesKey: series.key)
        } catch {
            // Offline or a provider hiccup: what was cached still plays.
            if !cached.isEmpty, !(error is CancellationError) { return cached }
            throw error
        }
    }

    // MARK: Stream links

    /// Rebuilds the SourceKit request from the stored row (links themselves
    /// are never stored: they expire) and asks the provider now.
    func resolveStreamLink(for key: ItemKey, catchupStart: Date?, catchupDuration: TimeInterval?) async throws -> StreamLink {
        guard let sourceID = key.sourceID, let kind = key.kind, let configuration = source(sourceID) else {
            throw SourceError(.noLink, detail: "No source in the household for this item")
        }
        let request: StreamRequest
        switch kind {
        case .channel:
            guard let row = liveRow(CatalogModel.Entity.channel, key: key) else {
                throw SourceError(.noLink, detail: "The channel is not in the catalog")
            }
            let channel = RowReader.remoteChannel(row)
            if let catchupStart {
                request = .catchup(channel, start: catchupStart, duration: catchupDuration ?? Self.defaultCatchupDuration)
            } else {
                request = .live(channel)
            }
        case .movie:
            guard let row = liveRow(CatalogModel.Entity.movie, key: key) else {
                throw SourceError(.noLink, detail: "The movie is not in the catalog")
            }
            request = .movie(RowReader.remoteMovie(row))
        case .episode:
            guard let row = episodeRow(key) else {
                throw SourceError(.noLink, detail: "The episode is not cached; open the show first")
            }
            let series = key.seriesKey.flatMap { liveRow(CatalogModel.Entity.series, key: $0) }.map(RowReader.remoteSeries)
            request = .episode(RowReader.remoteEpisode(row), series: series)
        case .series:
            throw SourceError(.noLink, detail: "A show plays by episode")
        }
        let client = try await readyClient(for: configuration)
        return try await client.streamLink(for: request)
    }

    // MARK: Stable keys

    /// FAV-2: the one item of the same source, kind and normalised name as
    /// the vanished one. The name comes from `RemovedItem`, written when the
    /// refresh that dropped the key retired the old generation. An episode
    /// follows its show: same season and number under the show's new key.
    func replacement(for key: ItemKey) -> ItemKey? {
        guard let sourceID = key.sourceID, let kind = key.kind, source(sourceID) != nil else { return nil }
        if kind == .episode {
            guard let seriesKey = key.seriesKey, let position = key.seasonAndEpisode,
                  !queryContains(seriesKey),
                  let newSeries = replacement(for: seriesKey), let newSeriesID = newSeries.remoteID else { return nil }
            return .episode(source: sourceID, seriesID: newSeriesID, season: position.season, number: position.number)
        }
        guard let nameKey = removedNameKey(for: key), !nameKey.isEmpty else { return nil }
        let matches = liveRows(CatalogModel.Entity.forKind(kind), sourceID: sourceID, NSPredicate(format: "searchKey == %@", nameKey), limit: 2)
        guard matches.count == 1 else { return nil }
        let replacement = ItemKey(rawValue: matches[0].string("stableKey"))
        return replacement == key ? nil : replacement
    }
}

// MARK: - Short guide loader

/// Fetches short guides a few channels at a time: enough to fill a screen
/// quickly, few enough that a portal doesn't throttle the device.
enum ShortGuideLoader {
    static let programmesPerChannel = 10
    static let concurrency = 4

    @concurrent
    static func load(_ channels: [RemoteChannel], client: any SourceClient) async -> [CatalogWriter.ShortGuide] {
        await withTaskGroup(of: CatalogWriter.ShortGuide?.self) { group in
            var remaining = channels[...]
            var guides: [CatalogWriter.ShortGuide] = []
            for _ in 0..<concurrency {
                guard let channel = remaining.popFirst() else { break }
                group.addTask { await fetch(channel, client: client) }
            }
            while let result = await group.next() {
                if let result { guides.append(result) }
                if let channel = remaining.popFirst(), !Task.isCancelled {
                    group.addTask { await fetch(channel, client: client) }
                }
            }
            return guides
        }
    }

    private static func fetch(_ channel: RemoteChannel, client: any SourceClient) async -> CatalogWriter.ShortGuide? {
        guard let programmes = try? await client.shortGuide(for: channel, limit: programmesPerChannel), !programmes.isEmpty else { return nil }
        return CatalogWriter.ShortGuide(guideKey: channel.guideChannelID ?? channel.id, programmes: programmes)
    }
}

// MARK: - Source test

/// "Test" in the source editor (SRC-4): signs in with an unsaved
/// configuration and counts what the provider offers, writing nothing. Each
/// step is reported with its time; nothing in a step names the login.
struct SourceTester: Sendable {
    let client: any SourceClient

    func run() async -> SourceTestResult {
        var result = SourceTestResult(succeeded: false)
        var step = String(localized: "Signing in")
        let clock = ContinuousClock()
        var started = clock.now

        func finish(_ line: String) {
            result.steps.append("\(line) (\(Self.format(clock.now - started)))")
            started = clock.now
        }

        do {
            result.account = try await client.signIn()
            finish(String(localized: "Signed in"))

            step = String(localized: "Live categories")
            let live = try await client.categories(.live)
            finish(String(localized: "Live categories: \(live.count)"))

            step = String(localized: "Channels")
            let channels = try await client.channels()
            result.channelCount = channels.count
            finish(String(localized: "Channels: \(channels.count)"))

            if client.capabilities.hasMovies {
                step = String(localized: "Movies")
                let (count, line) = try await count(String(localized: "Movies")) { try await client.movies(categoryID: nil, page: 0) }
                result.movieCount = count
                finish(line)
            }
            if client.capabilities.hasSeries {
                step = String(localized: "Shows")
                let (count, line) = try await count(String(localized: "Shows")) { try await client.series(categoryID: nil, page: 0) }
                result.seriesCount = count
                finish(line)
            }
            result.succeeded = true
        } catch {
            let message = CatalogService.describe(error)
            result.message = message
            finish(String(localized: "\(step) failed: \(message)"))
        }
        return result
    }

    /// The first page's total when the provider gives one; else what the
    /// page holds when it is the only one. A provider that lists only by
    /// category gets no count rather than a failed test.
    private func count<Item: Sendable & Hashable>(_ label: String, _ fetch: () async throws -> Page<Item>) async throws -> (Int?, String) {
        do {
            let page = try await fetch()
            if let total = page.totalItems { return (total, "\(label): \(total.formatted())") }
            if !page.hasMore { return (page.items.count, "\(label): \(page.items.count.formatted())") }
            return (nil, String(localized: "\(label): more than \(page.items.count.formatted())"))
        } catch let error as SourceError where error.code == .notSupported {
            return (nil, String(localized: "\(label): listed by category"))
        }
    }

    static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2f s", seconds)
    }
}
