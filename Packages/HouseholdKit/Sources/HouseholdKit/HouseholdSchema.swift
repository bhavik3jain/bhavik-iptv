import CloudKit
import CoreData
import Foundation
import os
import Synchronization

extension HouseholdStore {
    /// The schema ritual behind `-InitializeCloudKitSchema YES`: sends
    /// `HouseholdModel`'s record types (`CD_Household`, `CD_Source`, …) to the
    /// container's **Development** environment, and makes and deletes one
    /// test share so `cloudkit.share` is among them. Returns every record type
    /// sent, sorted.
    ///
    /// CloudKit learns a record type only when something creates it, and
    /// Production never creates one on its own — not even `cloudkit.share`.
    /// So after a build that adds an entity or attribute, and before its
    /// TestFlight upload:
    ///
    /// 1. Run a Debug build with `-InitializeCloudKitSchema YES`, signed in to
    ///    iCloud (Debug always talks to Development).
    /// 2. In the CloudKit Console, check the record types in Development —
    ///    the Source login fields show as encrypted.
    /// 3. Deploy Schema Changes to Production.
    ///
    /// Encryption (`allowsCloudEncryption`) can't be added to a field after
    /// its first Production deploy, which is why every login field exists
    /// from the start (PRIV-3).
    ///
    /// Works on a throwaway store in a temporary folder and never opens the
    /// real one; the app should open `.inMemory` on a launch that runs it.
    /// Blocks while CloudKit is contacted (up to a few minutes): call it off
    /// the main thread. Its container stays open until the process ends — a
    /// schema launch does nothing else — because detaching a store while
    /// mirroring still has an import queued for it crashed Multitrack's run.
    @discardableResult
    public nonisolated static func initializeCloudKitSchema(containerIdentifier: String) throws -> [String] {
        try HouseholdSchemaRitual.run(containerIdentifier: containerIdentifier)
    }
}

/// Multitrack's CloudKitSchemaInitializer, for one model.
enum HouseholdSchemaRitual {
    enum Failure: LocalizedError {
        case storeLoad(String)
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .storeLoad(let detail): "The throwaway schema store wouldn't open: \(detail)"
            case .timedOut(let step): "iCloud didn't answer in time: \(step)."
            }
        }
    }

    private static let folderPrefix = "household-schema-"
    /// The schema containers and their ledgers, open until the process ends.
    private static let keptOpen = Mutex<[AnyObject]>([])

    static func run(containerIdentifier: String) throws -> [String] {
        // Earlier runs' folders go; this run's stays under its open store.
        let temporary = FileManager.default.temporaryDirectory
        for leftover in (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
        where leftover.lastPathComponent.hasPrefix(folderPrefix) {
            try? FileManager.default.removeItem(at: leftover)
        }
        let folder = temporary.appendingPathComponent(folderPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let description = NSPersistentStoreDescription(url: folder.appendingPathComponent("HouseholdSchema.sqlite"))
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: containerIdentifier)
        description.shouldAddStoreAsynchronously = false
        // The share probe saves and shares, and mirroring needs history for
        // that ("couldn't be opened", SQLite error 1, without it).
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        let container = NSPersistentCloudKitContainer(name: "HouseholdSchema", managedObjectModel: HouseholdModel.shared)
        container.persistentStoreDescriptions = [description]
        // Before loading, so a fast setup and first import aren't missed.
        let events = CloudEventLedger()
        let observer = events.observe(container)
        keptOpen.withLock { $0 += [container, events, observer] }

        let loadError = Mutex<String?>(nil)
        container.loadPersistentStores { _, error in
            if let error { loadError.withLock { $0 = HouseholdContainer.explain(error) } }
        }
        if let message = loadError.withLock({ $0 }) { throw Failure.storeLoad(message) }
        guard let store = container.persistentStoreCoordinator.persistentStores.first else {
            throw Failure.storeLoad("no store was added")
        }
        let storeID: String = store.identifier

        let recordTypes = HouseholdModel.recordTypes
        Logger.household.notice("Schema: sending \(recordTypes.count, privacy: .public) record types: \(recordTypes.joined(separator: ", "), privacy: .public)")
        do {
            try container.initializeCloudKitSchema(options: [])
        } catch {
            // A just-opened store sets up and imports at once, holding the
            // container's executor; the schema call queued behind that and
            // gave up after 30 s in Multitrack. Once settled, once more.
            Logger.household.notice("Schema: trying again once sync settles (\(HouseholdContainer.explain(error), privacy: .public))")
            _ = waitUntil(events, timeout: 240) { $0.hasSetUp(store: storeID) && $0.hasImported(store: storeID) && !$0.isSyncing(in: [storeID]) }
            try container.initializeCloudKitSchema(options: [])
        }

        try makeAndRemoveTestShare(in: container, store: store, storeID: storeID, events: events)
        return (recordTypes + ["cloudkit.share"]).sorted()
    }

    /// A share is a record of CloudKit's own `cloudkit.share` type, and
    /// Production won't create that either: on Multitrack's first TestFlight
    /// every Share failed at the link until a share had been made in
    /// Development and deployed. Shares one throwaway household (with a
    /// title and type stamp, so those fields are in the schema too), then
    /// purges its zone.
    private static func makeAndRemoveTestShare(in container: NSPersistentCloudKitContainer, store: NSPersistentStore, storeID: String, events: CloudEventLedger) throws {
        // Mirroring builds its tables after the store loads; sharing before
        // that failed with "no such table: ANSCKRECORDMETADATA".
        guard waitUntil(events, timeout: 60, { $0.hasSetUp(store: storeID) }) else {
            throw Failure.timedOut("CloudKit setup didn't finish within a minute")
        }
        let context = container.newBackgroundContext()
        let object = try context.performAndWait {
            let probe = NSEntityDescription.insertNewObject(forEntityName: HouseholdModel.Entity.household, into: context)
            probe.setValue(UUID(), forKey: "id")
            probe.setValue("Schema probe", forKey: "name")
            probe.setValue(Date.now, forKey: "createdAt")
            try context.save()
            return probe
        }

        let (share, shareError) = try waitForCompletion(timeout: 120, step: "making the test share") { (finish: @escaping @Sendable ((CKShare?, (any Error)?)) -> Void) in
            container.share([object], to: nil) { _, share, _, error in finish((share, error)) }
        }
        withExtendedLifetime(context) {}
        if let shareError { throw shareError }
        guard let share else { throw Failure.timedOut("the test share came back empty") }

        share[CKShare.SystemFieldKey.title] = "Schema probe" as CKRecordValue
        share[CKShare.SystemFieldKey.shareType] = HouseholdStore.shareType as CKRecordValue
        let saveError = try waitForCompletion(timeout: 60, step: "saving the test share") { (finish: @escaping @Sendable ((any Error)?) -> Void) in
            container.persistUpdatedShare(share, in: store) { _, error in finish(error) }
        }
        if let saveError { throw saveError }

        // The type is what's wanted, not the share.
        let zoneID = share.recordID.zoneID
        let purgeError = try waitForCompletion(timeout: 120, step: "removing the test share") { (finish: @escaping @Sendable ((any Error)?) -> Void) in
            container.purgeObjectsAndRecordsInZone(with: zoneID, in: store) { _, error in finish(error) }
        }
        if let purgeError {
            Logger.household.error("Schema: test share made but its zone wasn't removed: \(HouseholdContainer.explain(purgeError), privacy: .public)")
        }
        Logger.household.notice("Schema: made and removed a test share, so cloudkit.share exists")
    }

    /// Polls `condition` every 250 ms until it holds or `timeout` seconds pass.
    private static func waitUntil(_ events: CloudEventLedger, timeout: TimeInterval, _ condition: (CloudEventLedger) -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition(events) {
            guard Date.now < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return true
    }

    /// Runs `start`, blocks until the completion it hands CloudKit fires, and
    /// returns what it was called with. The value rides back in a locked box:
    /// the completion runs on CloudKit's queue.
    private static func waitForCompletion<Value: Sendable>(
        timeout: TimeInterval,
        step: String,
        _ start: (@escaping @Sendable (Value) -> Void) -> Void
    ) throws -> Value {
        let box = CompletionBox<Value>()
        let done = DispatchSemaphore(value: 0)
        start { value in
            box.store(value)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, let value = box.take() else {
            throw Failure.timedOut(step)
        }
        return value
    }
}

/// Written once from CloudKit's queue, read once after the semaphore.
private final class CompletionBox<Value: Sendable>: Sendable {
    private let value = Mutex<Value?>(nil)

    func store(_ newValue: Value) { value.withLock { $0 = newValue } }
    func take() -> Value? { value.withLock { $0 } }
}
