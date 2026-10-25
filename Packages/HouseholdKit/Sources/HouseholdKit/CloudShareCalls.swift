import CloudKit
import CoreData
import Foundation
import Synchronization

/// `NSPersistentCloudKitContainer`'s sharing calls, made from background
/// queues — never the main thread (Multitrack's CloudShareCalls, adapted).
///
/// They take completion handlers, so they read as asynchronous, but each one
/// first waits synchronously for the container's request executor, which
/// mirroring's own imports and exports hold. Called from a Share button on
/// the main thread, `persistUpdatedShare` hung Multitrack's TestFlight build
/// 16 until the watchdog killed it (0x8BADF00D). Every call here returns at
/// once; the completion runs on whatever queue CloudKit picks, so callers hop
/// back to the main actor themselves.
extension NSPersistentCloudKitContainer {
    /// One serial queue for share writes, so a stamp saved on the way into the
    /// share sheet is queued ahead of anything saved after it.
    private static let shareQueue = DispatchQueue(label: "com.bhavikjain.hearth.household-share", qos: .userInitiated)

    /// Lookups on a concurrent queue of their own: one stuck behind a sync
    /// that never finishes must not hold up every later Share tap.
    private static let lookupQueue = DispatchQueue(
        label: "com.bhavikjain.hearth.household-share-lookup",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// The share `objectID` is in, if any. An error comes back as an error,
    /// never as "not shared": treating a failed lookup as "not shared" is how
    /// Multitrack's Fuel made four share zones for one car.
    func lookUpShareInBackground(for objectID: NSManagedObjectID, completion: @escaping @Sendable (Result<CKShare?, any Error>) -> Void) {
        Self.lookupQueue.async {
            completion(Result { try self.fetchShares(matching: [objectID])[objectID] })
        }
    }

    /// Several objects' shares in one `fetchShares(matching:)`: the household
    /// on screen (for `isShared`, the members and this device's role) and the
    /// duplicate households a fold must not delete if one is a share root.
    func fetchSharesInBackground(for objectIDs: [NSManagedObjectID], completion: @escaping @Sendable (Result<[NSManagedObjectID: CKShare], any Error>) -> Void) {
        Self.lookupQueue.async {
            completion(Result { try self.fetchShares(matching: objectIDs) })
        }
    }

    /// The record Core Data mirrors `objectID` to, from its local metadata,
    /// for the check for zones an earlier `share()` left behind.
    func recordIDInBackground(for objectID: NSManagedObjectID, completion: @escaping @Sendable (CKRecord.ID?) -> Void) {
        Self.lookupQueue.async {
            completion(self.recordID(for: objectID))
        }
    }

    /// Shares the object with this ID. The object is re-read in a background
    /// context of its own, so no main-queue object crosses threads; `share()`
    /// only needs its ID and entity.
    func shareInBackground(_ objectID: NSManagedObjectID, completion: @escaping @Sendable (Result<CKShare, any Error>) -> Void) {
        Self.shareQueue.async {
            let context = self.newBackgroundContext()
            let object = context.performAndWait { context.object(with: objectID) }
            // The object only weakly knows its context; held here until
            // CloudKit answers.
            let keepAlive = context
            self.share([object], to: nil) { _, share, _, error in
                _ = keepAlive
                if let share {
                    completion(.success(share))
                } else {
                    completion(.failure(error ?? HouseholdShareError.noResult))
                }
            }
        }
    }

    /// The CloudKit database `store` mirrors: an accepted share lives in the
    /// shared one, everything this person owns in the private one.
    func databaseScope(of store: NSPersistentStore) -> CKDatabase.Scope {
        persistentStoreDescriptions
            .first { $0.url == store.url }?
            .cloudKitContainerOptions?.databaseScope ?? .private
    }

    func persistUpdatedShareInBackground(_ share: CKShare, inStoreAt url: URL, completion: @escaping @Sendable (Result<CKShare, any Error>) -> Void) {
        Self.shareQueue.async {
            guard let store = self.persistentStoreCoordinator.persistentStore(for: url) else {
                completion(.failure(HouseholdShareError.iCloudUnavailable))
                return
            }
            self.persistUpdatedShare(share, in: store) { saved, error in
                if let saved {
                    completion(.success(saved))
                } else {
                    completion(.failure(error ?? HouseholdShareError.noResult))
                }
            }
        }
    }

    func acceptShareInvitationsInBackground(from metadata: CKShare.Metadata, intoStoreAt url: URL, completion: @escaping @Sendable ((any Error)?) -> Void) {
        Self.shareQueue.async {
            guard let store = self.persistentStoreCoordinator.persistentStore(for: url) else {
                completion(HouseholdShareError.iCloudUnavailable)
                return
            }
            self.acceptShareInvitations(from: [metadata], into: store) { _, error in
                completion(error)
            }
        }
    }

    /// Leaves a household someone else owns: purges the share's zone from
    /// this person's shared store, which takes them off the share and removes
    /// the local copies. Never a delete of the root — that asks iCloud to
    /// delete the owner's record (HH-4). Refuses anything outside the shared
    /// store: purging a private zone deletes the owner's own data for everyone.
    func leaveShareInBackground(of objectID: NSManagedObjectID, sharedStoreURL: URL, completion: @escaping @Sendable ((any Error)?) -> Void) {
        Self.shareQueue.async {
            guard let store = objectID.persistentStore, store.url == sharedStoreURL else {
                completion(HouseholdShareError.notSharedWithYou)
                return
            }
            let share: CKShare?
            do {
                share = try self.fetchShares(matching: [objectID])[objectID]
            } catch {
                completion(error)
                return
            }
            guard let share else {
                completion(HouseholdShareError.noShare)
                return
            }
            self.purgeObjectsAndRecordsInZone(with: share.recordID.zoneID, in: store) { _, error in
                completion(error)
            }
        }
    }
}

/// Waiting on a completion handler without waiting forever (Multitrack's
/// `Bounded`). The call itself is never stopped — Core Data's sharing calls
/// can't be — only the wait ends; a later try finds what it did.
enum Bounded {
    /// nil when `limit` or a cancel came first; a late answer is dropped.
    static func wait<T: Sendable>(
        _ limit: Duration,
        isolation: isolated (any Actor)? = #isolation,
        _ start: (@escaping @Sendable (T) -> Void) -> Void
    ) async -> T? {
        let gate = AnswerGate<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                guard gate.arm(continuation) else { return }
                start { gate.answer($0) }
                gate.startTimer(limit)
            }
        } onCancel: {
            gate.answer(nil)
        }
    }
}

/// Resumes its continuation exactly once: with the answer, or nil for the
/// timer or a cancel, whichever comes first.
final class AnswerGate<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T?, Never>?
        var answered = false
        var timer: Task<Void, Never>?
    }

    private let state = Mutex(State())

    /// False when a cancel answered before the gate was armed; the
    /// continuation has then been resumed already.
    func arm(_ continuation: CheckedContinuation<T?, Never>) -> Bool {
        let early = state.withLock { state -> Bool in
            if state.answered { return true }
            state.continuation = continuation
            return false
        }
        if early { continuation.resume(returning: nil) }
        return !early
    }

    func startTimer(_ limit: Duration) {
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: limit) } catch { return }
            self?.answer(nil)
        }
        let alreadyAnswered = state.withLock { state -> Bool in
            if !state.answered { state.timer = timer }
            return state.answered
        }
        if alreadyAnswered { timer.cancel() }
    }

    func answer(_ value: T?) {
        let (continuation, timer) = state.withLock { state -> (CheckedContinuation<T?, Never>?, Task<Void, Never>?) in
            guard !state.answered else { return (nil, nil) }
            state.answered = true
            defer {
                state.continuation = nil
                state.timer = nil
            }
            return (state.continuation, state.timer)
        }
        timer?.cancel()
        continuation?.resume(returning: value)
    }
}

/// Whether to call `share()` or wait on the call already running for the same
/// household. A share call doesn't stop when its caller stops waiting: Core
/// Data queues it behind whatever sync holds the container and it can still
/// make its zone minutes later. A second call — Try Again after a timeout —
/// made a second zone in Multitrack; here it joins the first.
struct ShareCallLedger<Key: Hashable & Sendable>: Sendable, Equatable {
    enum Begin: Sendable, Equatable { case call, join }

    private(set) var running: Set<Key> = []

    mutating func begin(_ key: Key) -> Begin {
        running.insert(key).inserted ? .call : .join
    }

    mutating func end(_ key: Key) {
        running.remove(key)
    }

    func isRunning(_ key: Key) -> Bool {
        running.contains(key)
    }
}

/// Share zones in the private database holding a copy of one record: what an
/// abandoned `share()` leaves (Multitrack, October 2026). Core Data names each
/// share's zone `com.apple.coredata.cloudkit.share.<UUID>` and keeps the
/// record's name when it moves it there.
enum LeftoverShareZones {
    static let prefix = "com.apple.coredata.cloudkit.share."

    /// Core Data's share zones other than the one the record is in now.
    static func candidates(_ zones: [CKRecordZone.ID], besides current: CKRecordZone.ID) -> [CKRecordZone.ID] {
        zones.filter { $0.zoneName.hasPrefix(prefix) && $0 != current }
    }

    /// Names of the share zones holding `recordID`'s record name, sorted.
    static func find(_ recordID: CKRecord.ID, in database: CKDatabase) async -> Result<[String], any Error> {
        do {
            let zones = try await database.allRecordZones().map(\.zoneID)
            let ids = candidates(zones, besides: recordID.zoneID).map {
                CKRecord.ID(recordName: recordID.recordName, zoneID: $0)
            }
            guard !ids.isEmpty else { return .success([]) }
            // Only whether each exists: an item error means it isn't there.
            let results = try await database.records(for: ids, desiredKeys: [])
            let found = results.compactMap { id, result in (try? result.get()) == nil ? nil : id.zoneID.zoneName }
            return .success(found.sorted())
        } catch {
            return .failure(error)
        }
    }
}
