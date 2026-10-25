import CloudKit
import CoreData
import Foundation
import os
import Synchronization

/// Why the household store couldn't open. The app shows `errorDescription`
/// rather than crashing: a model that breaks a CloudKit rule fails here, at
/// load, never at compile time.
public enum HouseholdStoreError: LocalizedError, Equatable {
    case storeLoadFailed(store: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .storeLoadFailed(let store, let reason):
            "The household's \(store) storage couldn't be opened: \(reason)"
        }
    }
}

/// Builds the household's `NSPersistentCloudKitContainer`: a private store
/// (this person's own household) and a shared-scope store (a household
/// someone else shared with them), the pair CKShare needs — Multitrack's
/// CloudSharedStore, adapted.
enum HouseholdContainer {
    static let name = "Household"
    /// Written into persistent history for this device's own saves, so a
    /// history reader can tell them from a partner's.
    static let appAuthor = "app"

    struct Built {
        let container: NSPersistentCloudKitContainer
        let privateURL: URL
        let sharedURL: URL
        let events: CloudEventLedger
        let eventObserver: (any NSObjectProtocol)?
    }

    @MainActor
    static func make(mode: HouseholdStore.Mode) throws -> Built {
        let container = NSPersistentCloudKitContainer(name: name, managedObjectModel: HouseholdModel.shared)
        let privateDescription = container.persistentStoreDescriptions.first ?? NSPersistentStoreDescription()
        // -copy on a store description always returns another description.
        let sharedDescription = privateDescription.copy() as! NSPersistentStoreDescription

        switch mode {
        case .inMemory:
            // No iCloud at all. Core Data keys stores on their URL, so the two
            // need different ones even in memory ("Can't add the same store
            // twice") — which is why this isn't the usual pair of SQLite files
            // at /dev/null: both at one URL won't load. In-memory stores
            // also leave nothing behind between tests.
            privateDescription.type = NSInMemoryStoreType
            sharedDescription.type = NSInMemoryStoreType
            privateDescription.url = URL(fileURLWithPath: "/dev/null/hearth-household-private")
            sharedDescription.url = URL(fileURLWithPath: "/dev/null/hearth-household-shared")
            // The default description picks up the entitlements' container on
            // its own; two stores on one container and one scope throw at load
            // (Multitrack's -InitializeCloudKitSchema crash).
            privateDescription.cloudKitContainerOptions = nil
            sharedDescription.cloudKitContainerOptions = nil

        case .cloud(let containerIdentifier):
            let base = privateDescription.url ?? NSPersistentContainer.defaultDirectoryURL().appendingPathComponent("\(name).sqlite")
            privateDescription.url = base
            sharedDescription.url = base.deletingLastPathComponent()
                .appendingPathComponent(base.deletingPathExtension().lastPathComponent + "-shared")
                .appendingPathExtension(base.pathExtension)
            for description in [privateDescription, sharedDescription] {
                // Without both, mirroring silently never happens: no error at
                // load, sync just never occurs.
                description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
                description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
                description.shouldAddStoreAsynchronously = false
            }
            privateDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerIdentifier)
            let sharedOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerIdentifier)
            // The header still says only .private and .public; .shared is how
            // Apple's own sharing sample configures the second store.
            sharedOptions.databaseScope = .shared
            sharedDescription.cloudKitContainerOptions = sharedOptions
        }

        container.persistentStoreDescriptions = [privateDescription, sharedDescription]

        // Before loading: mirroring starts the moment a store loads, and a
        // first import that finished before anyone listened would never be
        // seen — ensureHousehold would then wait out its whole bound.
        let events = CloudEventLedger()
        let observer: (any NSObjectProtocol)? = if case .cloud = mode { events.observe(container) } else { nil }

        var failures: [String] = []
        container.loadPersistentStores { description, error in
            if let error {
                let which = description.cloudKitContainerOptions?.databaseScope == .shared ? "shared" : "private"
                failures.append("\(which): \(Self.explain(error))")
            }
        }
        if !failures.isEmpty {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            Logger.household.error("Store load failed: \(failures.joined(separator: "; "), privacy: .public)")
            throw HouseholdStoreError.storeLoadFailed(store: "household", reason: failures.joined(separator: "; "))
        }

        let context = container.viewContext
        context.automaticallyMergesChangesFromParent = true
        // Last save wins per attribute (Source, Profile, MemberRole), the
        // in-memory side of a conflict trumping the store's.
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        context.transactionAuthor = appAuthor

        return Built(
            container: container,
            privateURL: privateDescription.url!,
            sharedURL: sharedDescription.url!,
            events: events,
            eventObserver: observer
        )
    }

    /// Core Data's own description is "A Core Data error occurred."; the real
    /// cause sits underneath.
    static func explain(_ error: any Error) -> String {
        let error = error as NSError
        if let reason = error.localizedFailureReason { return reason }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.localizedFailureReason ?? underlying.localizedDescription
        }
        return error.localizedDescription
    }
}

extension Logger {
    /// Store, step, counts and CloudKit codes — never a login, MAC, device id
    /// or anything a person typed (PRIV-2).
    static let household = Logger(subsystem: "com.bhavikjain.hearth", category: "Household")
}

/// One mirroring event, copied out of Core Data's notification so it can
/// cross threads.
struct CloudEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case setup, `import`, export, other }

    var id: UUID
    var store: String
    var kind: Kind
    var start: Date
    var end: Date?
    var succeeded: Bool
    var errorDescription: String?

    init(id: UUID, store: String, kind: Kind, start: Date, end: Date?, succeeded: Bool, errorDescription: String? = nil) {
        self.id = id
        self.store = store
        self.kind = kind
        self.start = start
        self.end = end
        self.succeeded = succeeded
        self.errorDescription = errorDescription
    }

    init(_ event: NSPersistentCloudKitContainer.Event) {
        let kind: Kind = switch event.type {
        case .setup: .setup
        case .import: .import
        case .export: .export
        @unknown default: .other
        }
        self.init(
            id: event.identifier,
            store: event.storeIdentifier,
            kind: kind,
            start: event.startDate,
            end: event.endDate,
            succeeded: event.succeeded,
            errorDescription: event.error.map { ($0 as NSError).localizedDescription }
        )
    }
}

/// What mirroring has done this launch, per store: imports finished, events
/// still running, the latest success and failure. Fed on CloudKit's queues,
/// read on the main actor — Multitrack's ImportTracker and CloudSyncLedger in
/// one. Waits poll it (every 250 ms) rather than parking a continuation, so an
/// event that never comes can't leave a caller hanging.
final class CloudEventLedger: Sendable {
    struct State: Sendable, Equatable {
        var inFlight: [UUID: CloudEvent] = [:]
        var lastSetupEnd: [String: Date] = [:]
        var lastImportEnd: [String: Date] = [:]
        var lastExportEnd: [String: Date] = [:]
        var lastSuccessAt: Date?
        var lastFailure: String?
        var lastFailureAt: Date?
    }

    private let state = Mutex(State())
    /// Called (on CloudKit's queue) after every recorded event.
    private let listener = Mutex<(@Sendable () -> Void)?>(nil)

    var snapshot: State { state.withLock { $0 } }

    func setListener(_ listener: @escaping @Sendable () -> Void) {
        self.listener.withLock { $0 = listener }
    }

    /// Observed on the posting queue, never `queue: .main`: a main-queue
    /// observer makes the post wait for the main thread while the container's
    /// CloudKit queue holds its request executor — half of the deadlock that
    /// killed Multitrack's TestFlight build 16 on Share.
    func observe(_ container: NSPersistentCloudKitContainer) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: nil
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            self?.record(CloudEvent(event))
        }
    }

    func record(_ event: CloudEvent) {
        state.withLock { state in
            guard let end = event.end else {
                state.inFlight[event.id] = event
                return
            }
            state.inFlight[event.id] = nil
            if event.succeeded {
                state.lastSuccessAt = max(state.lastSuccessAt ?? end, end)
                switch event.kind {
                case .setup: state.lastSetupEnd[event.store] = end
                case .import: state.lastImportEnd[event.store] = end
                case .export: state.lastExportEnd[event.store] = end
                default: break
                }
            } else {
                state.lastFailure = event.errorDescription ?? "iCloud sync failed."
                state.lastFailureAt = end
            }
        }
        if event.kind == .import, event.end != nil {
            Logger.household.debug("Import \(event.succeeded ? "succeeded" : "failed", privacy: .public) on store \(event.store, privacy: .public)")
        }
        listener.withLock { $0 }?()
    }

    func hasSetUp(store: String) -> Bool {
        state.withLock { $0.lastSetupEnd[store] != nil }
    }

    func hasImported(store: String) -> Bool {
        state.withLock { $0.lastImportEnd[store] != nil }
    }

    func importEnded(after date: Date, in stores: Set<String>) -> Bool {
        state.withLock { state in stores.contains { (state.lastImportEnd[$0] ?? .distantPast) > date } }
    }

    func exportEnded(after date: Date, in stores: Set<String>) -> Bool {
        state.withLock { state in stores.contains { (state.lastExportEnd[$0] ?? .distantPast) > date } }
    }

    func isSyncing(in stores: Set<String>) -> Bool {
        state.withLock { state in state.inFlight.values.contains { stores.contains($0.store) } }
    }

    /// When the oldest unfinished event in `stores` started, if one is running.
    func syncingSince(in stores: Set<String>) -> Date? {
        state.withLock { state in state.inFlight.values.filter { stores.contains($0.store) }.map(\.start).min() }
    }

    /// Polls `condition` until it holds or `timeout` passes (or the task is
    /// cancelled). True when it held.
    func wait(timeout: Duration, until condition: @Sendable (CloudEventLedger) -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(self) {
            guard clock.now < deadline, !Task.isCancelled else { return false }
            try? await clock.sleep(for: .milliseconds(250))
        }
        return true
    }

    /// The footer's sync line, from what has happened so far.
    static func status(_ state: State) -> HouseholdSyncStatus {
        if !state.inFlight.isEmpty { return .syncing }
        if let failedAt = state.lastFailureAt, failedAt > (state.lastSuccessAt ?? .distantPast) {
            return .failed(state.lastFailure ?? "iCloud sync failed.")
        }
        if let success = state.lastSuccessAt { return .upToDate(success) }
        return .syncing
    }
}

extension NSPersistentCloudKitContainer {
    /// The identifiers the ledger knows this container's iCloud stores by.
    var cloudKitStoreIdentifiers: Set<String> {
        Set(persistentStoreDescriptions.compactMap { description -> String? in
            guard description.cloudKitContainerOptions != nil, let url = description.url else { return nil }
            return persistentStoreCoordinator.persistentStore(for: url)?.identifier
        })
    }

    var cloudKitContainerIdentifier: String? {
        persistentStoreDescriptions.lazy.compactMap { $0.cloudKitContainerOptions?.containerIdentifier }.first
    }
}

/// Notification tokens removed when their owner goes away. Owned by the
/// main-actor store and touched only there; its deinit runs once nothing
/// holds it.
final class ObserverTokens {
    var tokens: [any NSObjectProtocol] = []

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
