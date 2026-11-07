import CatalogKit
import CloudKit
import Core
import DownloadKit
import Foundation
import HouseholdKit
import Observation
import os
import SourceKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The services every screen reads, created once for the app.
@MainActor
struct AppServices {
    let store: HouseholdStore
    let catalog: CatalogService
    let session: ProfileSession
    let playback: PlaybackCoordinator
    /// Movies and episodes saved on this device (DL-1).
    let downloads: DownloadCenter
}

/// The composition root's state: opens the household store and the catalog,
/// makes sure a household exists, and keeps the services in step with each
/// other for the life of the app —
///
/// - the household's sources → `catalog.setSources` (SRC-6 imports new ones);
/// - the current profile and household → `catalog.filter` (PRF-4, PRF-6, PAR-1);
/// - store changes → `session.refresh()` (an edited or deleted profile);
/// - each finished catalog refresh → FAV-2's key rewrite;
/// - held movies and shows → their names onto household rows, and a search
///   for each one the catalog lacks (`HeldItems`);
/// - launch, becoming active and background refresh → `refreshAllIfStale`.
///
/// One instance, made in `HearthApp.init` so the iOS background task can be
/// registered with it before launch finishes.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        /// Opening the stores and waiting (bounded) for iCloud's first import.
        case starting
        case ready
        /// The household store couldn't open: shown, never a crash.
        case failed(String)
        /// `-InitializeCloudKitSchema YES`: no stores, just the ritual.
        case schemaInitializer(String)
    }

    /// The one iCloud container, as in the entitlements.
    nonisolated static let containerIdentifier = "iCloud.com.bhavikjain.hearth"

    let launch: LaunchOptions
    private(set) var phase: Phase = .starting
    private(set) var services: AppServices?
    /// The Mac's single main window's navigation, here so the menu commands
    /// (⌘1–⌘6, Switch Profile) reach it. iOS keeps one per window instead.
    let macNavigation = AppNavigation()
    /// A launch argument's tab or route, for the first window that appears.
    var pendingLaunchTab: AppTab?
    var pendingLaunchRoute: HearthRoute?
    /// What accepting a household invitation said, when it failed (HH-3).
    var shareAcceptError: String?

    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshedAt: [UUID: Date] = [:]
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.bhavikjain.hearth", category: "app")

    init(launch: LaunchOptions = .current) {
        self.launch = launch
        pendingLaunchTab = launch.openTab
        start()
    }

    // MARK: Starting

    private func start() {
        #if DEBUG
        if launch.initializeCloudKitSchema {
            phase = .schemaInitializer(String(localized: "Sending the household schema to iCloud Development…"))
            DebugLaunch.runSchemaInitializer(model: self)
            return
        }
        #endif
        openStores()
    }

    /// The schema ritual ended; its screen says how.
    func schemaInitializerFinished(_ outcome: String) {
        phase = .schemaInitializer(outcome)
    }

    /// "Try again" on the failure screen.
    func retry() {
        guard case .failed = phase else { return }
        phase = .starting
        openStores()
    }

    private func openStores() {
        let store: HouseholdStore
        do {
            store = try HouseholdStore(mode: launch.inMemoryStores ? .inMemory : .cloud(containerIdentifier: Self.containerIdentifier))
        } catch {
            logger.error("Household store failed to open: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
            return
        }
        let catalog = CatalogService(storeURL: launch.inMemoryStores ? nil : CatalogService.defaultStoreURL)
        let session = ProfileSession(store: store)
        let downloads = DownloadCenter()
        let playback = PlaybackCoordinator(catalog: catalog, store: store, session: session, downloads: downloads)
        services = AppServices(store: store, catalog: catalog, session: session, playback: playback, downloads: downloads)
        Task { await prepare() }
    }

    /// Makes sure a household exists, then wires the services together.
    ///
    /// In cloud mode `prepareHousehold` waits (at most 15 s) for this
    /// launch's first iCloud import before making a household, so a second
    /// device joins rather than duplicates — but returns at once when the
    /// device has no iCloud account: a simulator that isn't signed in opens
    /// a local household straight away, and it persists across launches.
    private func prepare() async {
        guard let services else { return }
        let names = HouseholdNaming.names(fullName: DeviceOwner.fullName)
        await services.store.prepareHousehold(defaultName: names.household, firstProfileName: names.profile)
        services.session.restore()
        startObserving(services)
        Task { await services.playback.downloadsLaunched() }
        Task { await services.catalog.warmUp() }
        phase = .ready
        readyWaiters.forEach { $0.resume() }
        readyWaiters.removeAll()
        ShareInbox.attach { [weak self] metadata in self?.acceptShare(metadata) }
        #if DEBUG
        await DebugLaunch.run(model: self, services: services)
        #endif
        refreshIfStale()
        GuideRefreshScheduler.schedule()
        observeTermination()
    }

    /// Quitting stops the stream properly: its who's-watching row goes and
    /// its progress is saved (the Mac rarely passes through "background").
    private func observeTermination() {
        #if os(macOS)
        let name = NSApplication.willTerminateNotification
        #else
        let name = UIApplication.willTerminateNotification
        #endif
        terminationObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.services?.playback.closeCurrent() }
        }
    }

    /// Returns once the services are ready (the background refresh task can
    /// arrive before the launch it woke has finished).
    func waitUntilReady() async {
        if phase == .ready { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    // MARK: Keeping the services in step

    private func startObserving(_ services: AppServices) {
        let store = services.store
        let catalog = services.catalog
        let session = services.session
        observers.forEach { $0.cancel() }
        observers = [
            // The household's sources, as SourceKit configurations. An edited
            // login gets a fresh client; a new source is imported (SRC-6).
            observeChanges(of: { AppSourceMapping.configurations(from: store.sources) }) { configurations in
                catalog.setSources(configurations)
            },
            // An edit or a sync may rename, change or delete the profile in
            // use; the session re-reads it.
            observeChanges(of: { ProfileSnapshot(profiles: store.profiles, hasHousehold: store.hasHousehold) }) { _ in
                session.refresh()
            },
            // What the current profile may see.
            observeChanges(of: { CatalogFilterBuilder.filter(profile: session.currentProfile, household: store.household) }) { filter in
                catalog.filter = filter
            },
            // FAV-2: after a refresh, keys that point at renamed items.
            observeChanges(of: { catalog.refreshStates.compactMapValues(\.catalogRefreshedAt) }) { [weak self] dates in
                self?.catalogRefreshed(dates)
            },
            // Titles held through iCloud that this device's catalog never
            // stored (a show found by search on another device): names
            // written down here, and searched for by name there.
            HeldItems.observe(store: store, catalog: catalog),
        ]
    }

    /// Rewrites favorite and progress keys a refresh orphaned (FAV-2): for
    /// each key of a refreshed source the catalog no longer contains, the
    /// one item of the same source, kind and normalised name.
    private func catalogRefreshed(_ dates: [UUID: Date]) {
        let refreshed = KeyRewriteCandidates.refreshedSources(previous: refreshedAt, current: dates)
        refreshedAt = dates
        guard !refreshed.isEmpty, let services else { return }
        let keys = KeyRewriteCandidates.keys(householdItemKeys(services.store), refreshedSources: refreshed)
        guard !keys.isEmpty else { return }
        let replacements = services.catalog.replacementKeys(for: keys)
        guard !replacements.isEmpty else { return }
        logger.notice("FAV-2: rewriting \(replacements.count, privacy: .public) item keys after a refresh")
        services.store.rewriteItemKeys(Dictionary(uniqueKeysWithValues: replacements.map { ($0.key.rawValue, $0.value.rawValue) }))
    }

    /// Every favorite of every profile, and the progress rows the store's
    /// public API reaches: unfinished movies and episodes, and every episode
    /// row of a series in progress. A finished movie's row isn't reachable
    /// (no "all progress" call), so its key isn't rewritten — a gap noted
    /// for HouseholdKit.
    private func householdItemKeys(_ store: HouseholdStore) -> [String] {
        var keys: [String] = []
        for profile in store.profiles where !profile.isGuest {
            for kind in FavoriteKind.allCases {
                keys += store.favorites(profileID: profile.id, kind: kind).map(\.itemKey)
            }
            keys += store.continueWatching(profileID: profile.id, limit: 500).map(\.itemKey)
            for series in store.seriesInProgress(profileID: profile.id, limit: 500) {
                if let seriesKey = series.seriesKey {
                    keys.append(seriesKey)
                    keys += store.seriesProgress(profileID: profile.id, seriesKey: seriesKey).map(\.itemKey)
                }
            }
        }
        return keys
    }

    // MARK: Refresh (SRC-6)

    /// Catalogs over a day old and guides over 6 hours, one source at a
    /// time. At launch and whenever the app becomes active; a refresh already
    /// running is left to finish.
    func refreshIfStale() {
        guard refreshTask == nil, let catalog = services?.catalog else { return }
        refreshTask = Task { [weak self] in
            await catalog.refreshAllIfStale()
            self?.refreshTask = nil
        }
    }

    /// The app came to the front.
    func becameActive() {
        guard phase == .ready, let services else { return }
        services.store.purgeStalePlaybacks()
        refreshIfStale()
        #if os(tvOS)
        services.playback.multiViewBackground.resume(
            catalog: services.catalog,
            store: services.store,
            profileID: services.session.currentProfile?.id
        )
        #endif
    }

    /// The app went to the background: progress now, not at the next
    /// 5-minute checkpoint (technical spec, Sync and sharing rules), and the
    /// next guide refresh asked for.
    func enteredBackground() {
        services?.playback.saveProgressNow()
        #if os(tvOS)
        // Tiles kept running would hold every stream behind the Home screen.
        if let services { services.playback.multiViewBackground.suspend(store: services.store) }
        #endif
        GuideRefreshScheduler.schedule()
    }

    /// iOS background refresh: whatever is stale, then done. Returns false
    /// when it was cut short.
    func backgroundRefresh() async -> Bool {
        await waitUntilReady()
        guard let catalog = services?.catalog else { return false }
        await catalog.refreshAllIfStale()
        return !Task.isCancelled
    }

    // MARK: Household invitations (HH-3)

    func acceptShare(_ metadata: CKShare.Metadata) {
        Task { [weak self] in
            await self?.waitUntilReady()
            guard let self, let store = self.services?.store else { return }
            do {
                try await store.acceptShare(metadata)
                self.services?.session.refresh()
            } catch {
                self.shareAcceptError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// The household's movies and shows that this device's catalog may never
/// have stored. Each device keeps its own catalog, and a big Stalker portal
/// is kept a page per category plus what that device browsed or searched, so
/// a show found by search and favorited on the iPhone reaches the Apple TV
/// through iCloud as a key its catalog doesn't hold: "Unavailable" in My List
/// and "No longer available" on its page. A Stalker portal can't be asked for
/// a title by id (only its seasons and files, without a name or poster), so
/// each favorite and progress row carries the title's name: this device
/// writes it from its catalog (`HouseholdStore.fillInTitles`), and a device
/// that lacks the title searches its provider by it
/// (`CatalogService.resolveHeldItems`). HouseholdKit never talks to a
/// provider and CatalogKit never reads iCloud, so the app passes both across.
@MainActor
enum HeldItems {
    /// One household row holding a movie or show.
    struct Row: Equatable {
        /// The row's own key, which `fillInTitles` writes by (for a show in
        /// progress, its latest episode's).
        var itemKey: String
        /// The key the catalog has to hold.
        var heldKey: ItemKey
        var title: String
    }

    /// Every profile's favorite movies and shows, its unfinished movies and
    /// episodes, and the shows it has in progress. Channels are left out:
    /// their lists are always imported whole.
    static func rows(in store: HouseholdStore) -> [Row] {
        var rows: [Row] = []
        func add(_ itemKey: String, held: String, title: String) {
            // A catch-up key carries a programme start after the channel's.
            guard !held.contains("@") else { return }
            rows.append(Row(itemKey: itemKey, heldKey: ItemKey(rawValue: held), title: title))
        }
        for profile in store.profiles where !profile.isGuest {
            for kind in [FavoriteKind.series, .movie] {
                store.favorites(profileID: profile.id, kind: kind).forEach { add($0.itemKey, held: $0.itemKey, title: $0.title) }
            }
            store.continueWatching(profileID: profile.id, limit: 100).forEach { add($0.itemKey, held: $0.itemKey, title: $0.title) }
            for row in store.seriesInProgress(profileID: profile.id, limit: 100) {
                if let seriesKey = row.seriesKey { add(row.itemKey, held: seriesKey, title: row.title) }
            }
        }
        return rows
    }

    /// What the catalog looks for.
    static func items(_ rows: [Row]) -> [HeldItem] {
        rows.map { HeldItem(key: $0.heldKey, title: $0.title) }
    }

    /// Names for the rows that have none yet, from this device's catalog,
    /// by each row's own key (an episode's row gets its show's name).
    static func titlesToFillIn(_ rows: [Row], catalog: CatalogService) -> [String: String] {
        var titles: [String: String] = [:]
        for row in rows where row.title.isEmpty && titles[row.itemKey] == nil {
            if let title = catalog.heldTitle(for: ItemKey(rawValue: row.itemKey)) { titles[row.itemKey] = title }
        }
        return titles
    }

    /// What starts a pass: the household's rows changing (a favorite or a
    /// name arriving from another device, a favorite made here) or a catalog
    /// refresh finishing (a first import, or a new generation, which asks
    /// again for what wasn't found).
    struct Trigger: Equatable {
        var rows: [Row]
        var refreshed: [UUID: Date]
    }

    /// For the life of the task, now and at every trigger: writes the names
    /// this device's catalog knows onto rows without one, then has the
    /// catalog search for held titles it lacks. The catalog asks each query
    /// once a catalog and skips titles it holds, so a trigger with nothing
    /// new costs a few reads.
    static func observe(store: HouseholdStore, catalog: CatalogService) -> Task<Void, Never> {
        observeChanges(of: {
            _ = store.revision
            return Trigger(rows: rows(in: store), refreshed: catalog.refreshStates.compactMapValues(\.catalogRefreshedAt))
        }) { trigger in
            let titles = titlesToFillIn(trigger.rows, catalog: catalog)
            if !titles.isEmpty { store.fillInTitles(titles) }
            Task { await catalog.resolveHeldItems(items(trigger.rows)) }
        }
    }
}

/// What the session's refresh depends on, compared as a whole.
private struct ProfileSnapshot: Equatable {
    var profiles: [ProfileRecord]
    var hasHousehold: Bool
}

/// The device owner's name, where the platform gives one (the Mac does; iOS
/// returns "mobile" or nothing, which `HouseholdNaming` ignores).
enum DeviceOwner {
    static var fullName: String? {
        let name = NSFullUserName()
        return name.isEmpty ? nil : name
    }
}
