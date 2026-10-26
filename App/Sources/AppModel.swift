import CatalogKit
import CloudKit
import Core
import Foundation
import HouseholdKit
import Observation
import os
import SourceKit

/// The services every screen reads, created once for the app.
@MainActor
struct AppServices {
    let store: HouseholdStore
    let catalog: CatalogService
    let session: ProfileSession
    let playback: PlaybackCoordinator
}

/// The composition root's state: opens the household store and the catalog,
/// makes sure a household exists, and keeps the services in step with each
/// other for the life of the app —
///
/// - the household's sources → `catalog.setSources` (SRC-6 imports new ones);
/// - the current profile and household → `catalog.filter` (PRF-4, PRF-6, PAR-1);
/// - store changes → `session.refresh()` (an edited or deleted profile);
/// - each finished catalog refresh → FAV-2's key rewrite;
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
    static let containerIdentifier = "iCloud.com.bhavikjain.hearth"

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
    /// iCloud account state for the "this device only" note.
    private(set) var iCloudSignedIn: Bool?

    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshedAt: [UUID: Date] = [:]
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
        let playback = PlaybackCoordinator(catalog: catalog, store: store, session: session)
        services = AppServices(store: store, catalog: catalog, session: session, playback: playback)
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
        checkICloudAccount()
        let names = HouseholdNaming.names(fullName: DeviceOwner.fullName)
        await services.store.prepareHousehold(defaultName: names.household, firstProfileName: names.profile)
        services.session.restore()
        startObserving(services)
        phase = .ready
        readyWaiters.forEach { $0.resume() }
        readyWaiters.removeAll()
        ShareInbox.attach { [weak self] metadata in self?.acceptShare(metadata) }
        #if DEBUG
        await DebugLaunch.run(model: self, services: services)
        #endif
        refreshIfStale()
        GuideRefreshScheduler.schedule()
    }

    /// Returns once the services are ready (the background refresh task can
    /// arrive before the launch it woke has finished).
    func waitUntilReady() async {
        if phase == .ready { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    private func checkICloudAccount() {
        guard !launch.inMemoryStores else { iCloudSignedIn = false; return }
        Task { [weak self] in
            let status = try? await CKContainer(identifier: Self.containerIdentifier).accountStatus()
            self?.iCloudSignedIn = status == .available
        }
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
            observeChanges(of: { SourceMapping.configurations(from: store.sources) }) { configurations in
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
    }

    /// The app went to the background: progress now, not at the next
    /// 5-minute checkpoint (technical spec, Sync and sharing rules), and the
    /// next guide refresh asked for.
    func enteredBackground() {
        services?.playback.saveProgressNow()
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
