import CloudKit
import CoreData
import Foundation
import os
// The one platform conditional in HouseholdKit: telling mirroring the app
// became active is the only public way to prompt an import (CloudNudge).
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The share the household on screen is in, as this device last looked it
/// up (off the main thread). `isShared`, the members and this device's role
/// are read from it.
struct ShareState {
    var householdObjectID: NSManagedObjectID?
    var share: CKShare?
    var lookedUpAt: Date?
    var isLookingUp = false
}

// MARK: - Sharing (HH-2…HH-4), roles (SRC-8), refresh

extension HouseholdStore {
    /// A share status this old is looked up again on the next rebuild.
    static let shareStatusMaxAge: TimeInterval = 60
    static let acceptLimit: Duration = .seconds(60)
    static let leaveLimit: Duration = .seconds(60)
    static let removeMemberLimit: Duration = .seconds(30)
    /// How long, after accepting, to wait for the household to download.
    static let importAfterAcceptWait: Duration = .seconds(20)
    /// How long `refreshFromCloud` waits for an import.
    static let refreshWait: Duration = .seconds(15)
    /// The record type the share's `shareType` system field names.
    nonisolated static let shareType = "CD_\(HouseholdModel.Entity.household)"

    // MARK: Share status

    /// Looks the household's share up off the main thread — at most once a
    /// minute, or when the household on screen changed — and rebuilds the
    /// snapshots when the answer differs. Never on an in-memory store.
    func scheduleShareLookup(force: Bool = false) {
        guard case .cloud = mode, !shareState.isLookingUp, let household = currentHouseholdEntity() else { return }
        let objectID = household.objectID
        guard !objectID.isTemporaryID else { return }
        let isFresh = shareState.householdObjectID == objectID
            && (shareState.lookedUpAt.map { Date.now.timeIntervalSince($0) < Self.shareStatusMaxAge } ?? false)
        guard force || !isFresh else { return }
        shareState.isLookingUp = true
        let container = container
        shareLookupTask = Task { [weak self] in
            let result: Result<CKShare?, ShareCallError>? = await Bounded.wait(Self.shareLookupLimit) { done in
                container.lookUpShareInBackground(for: objectID) { done($0.mapError(ShareCallError.init)) }
            }
            guard let self else { return }
            self.shareState.isLookingUp = false
            self.shareLookupTask = nil
            switch result {
            case .success(let share)?:
                let changed = self.shareState.householdObjectID != objectID || !Self.sameShare(self.shareState.share, share)
                self.shareState = ShareState(householdObjectID: objectID, share: share, lookedUpAt: .now)
                if changed { self.rebuildSnapshots() }
            case .failure(let error)?:
                // The last answer stands (a failure is never "not shared");
                // tried again after `shareStatusMaxAge`.
                self.recordFailedLookup(of: objectID)
                Logger.household.error("Share lookup failed: \(error.codeLabel, privacy: .public)")
            case nil:
                self.recordFailedLookup(of: objectID)
                Logger.household.notice("Share lookup didn't answer")
            }
        }
    }

    private func recordFailedLookup(of objectID: NSManagedObjectID) {
        if shareState.householdObjectID != objectID {
            shareState.householdObjectID = objectID
            shareState.share = nil
        }
        shareState.lookedUpAt = .now
    }

    /// Looks the share up again now: after the share sheet closes (people
    /// added or removed) or when the Household screen opens.
    public func refreshShareStatus() {
        scheduleShareLookup(force: true)
    }

    /// Whether two answers would show the same members and role.
    static func sameShare(_ lhs: CKShare?, _ rhs: CKShare?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            return lhs.recordID == rhs.recordID
                && lhs.url == rhs.url
                && lhs.currentUserParticipant?.participantID == rhs.currentUserParticipant?.participantID
                && ShareParticipantInfo.list(from: lhs) == ShareParticipantInfo.list(from: rhs)
        default: return false
        }
    }

    /// A share this person made, or one `share()` just returned (whose
    /// current participant is its owner).
    static func isOwner(of share: CKShare) -> Bool {
        share.currentUserParticipant.map { $0.role == .owner } ?? true
    }

    // MARK: Invite (HH-2)

    /// Prepares the household's share off the main thread (never a bare
    /// `share()` on main: Multitrack's build 16 deadlocked), bounded wait.
    public func prepareShare() async throws -> (share: CKShare, container: CKContainer) {
        try await prepareShare(ignoringEarlierTries: false)
    }

    /// `prepareShare()`, with Share Anyway: `ignoringEarlierTries` after the
    /// person was told an earlier invite left a copy in iCloud
    /// (`HouseholdShareError.offersShareAnyway`).
    ///
    /// Looks up an existing share first, makes at most one `share()` per
    /// household (joining one still running from an earlier try), saves the
    /// household's name as the share's title, and waits for the link. Every
    /// step is bounded (`HouseholdSharePlan.Limits`); a failure throws
    /// `HouseholdShareError` with a sentence for the sheet. The app hands the
    /// result to `UICloudSharingController(share:container:)` on iOS and the
    /// sharing service on the Mac. `sharePreparationStatus` says what it's
    /// doing meanwhile.
    public func prepareShare(ignoringEarlierTries: Bool) async throws -> (share: CKShare, container: CKContainer) {
        guard case .cloud(let identifier) = mode else { throw HouseholdShareError.iCloudUnavailable }
        guard let household = currentHouseholdEntity() else { throw HouseholdShareError.noHousehold }
        let objectID = household.objectID
        guard !objectID.isTemporaryID, let store = objectID.persistentStore else { throw HouseholdShareError.noHousehold }
        defer { sharePreparationStatus = nil }
        let share = try await runSharePlan(objectID: objectID, store: store, title: household.name, ignoringEarlierTries: ignoringEarlierTries)
        shareState = ShareState(householdObjectID: objectID, share: share, lookedUpAt: .now)
        rebuildSnapshots()
        return (share, CKContainer(identifier: identifier))
    }

    private func runSharePlan(objectID: NSManagedObjectID, store: NSPersistentStore, title: String, ignoringEarlierTries: Bool) async throws -> CKShare {
        let began = ContinuousClock.now
        let limits = HouseholdSharePlan.Limits.standard
        var plan = HouseholdSharePlan(ignoresEarlierTries: ignoringEarlierTries)
        var action = plan.start()
        var current: CKShare?
        sharePreparationStatus = plan.step.statusText
        Logger.household.notice("Share: start\(ignoringEarlierTries ? ", share anyway" : "", privacy: .public)")

        while true {
            try Task.checkCancellation()
            let event: HouseholdSharePlan.Event
            switch action {
            case .lookUp:
                let (outcome, found) = await shareLookUp(objectID, title: title, limit: limits.lookup)
                if let found { current = found }
                event = outcome
            case .waitForSync:
                let stores = container.cloudKitStoreIdentifiers
                let settled = await cloudEvents.wait(timeout: limits.sync) { !$0.isSyncing(in: stores) }
                event = .syncSettled(timedOut: !settled)
            case .checkEarlierTries:
                event = await shareCheckEarlierTries(objectID, store: store, limit: limits.earlierTries)
            case .create:
                let (outcome, made) = await shareCreate(objectID, title: title, limit: limits.create)
                if let made { current = made }
                event = outcome
            case .save:
                let (outcome, saved) = await shareSave(current, store: store, limit: limits.save)
                if let saved { current = saved }
                event = outcome
            case .waitForUpload:
                let stores = container.cloudKitStoreIdentifiers
                let since = Date.now
                let finished = await cloudEvents.wait(timeout: limits.upload) { $0.exportEnded(after: since, in: stores) }
                event = .uploadFinished(timedOut: !finished)
            case .fetchLink:
                let (outcome, fetched) = await shareFetchLink(current, store: store, title: title, limit: limits.fetchLink)
                if let fetched { current = fetched }
                event = outcome
            case .present:
                guard let current else { throw HouseholdShareError.noResult }
                Logger.household.notice("Share: ready in \(Self.ms(ContinuousClock.now - began), privacy: .public) ms, participants \(current.participants.count, privacy: .public)")
                return current
            case .fail(let failure):
                Logger.household.error("Share: failed after \(Self.ms(ContinuousClock.now - began), privacy: .public) ms: \(failure.title, privacy: .public), \(failure.errorLabel, privacy: .public)")
                throw HouseholdShareError(failure)
            }
            action = plan.handle(event)
            sharePreparationStatus = plan.step.statusText
        }
    }

    private func shareLookUp(_ objectID: NSManagedObjectID, title: String, limit: Duration) async -> (HouseholdSharePlan.Event, CKShare?) {
        let container = container
        let result: Result<CKShare?, ShareCallError>? = await Bounded.wait(limit) { done in
            container.lookUpShareInBackground(for: objectID) { done($0.mapError(ShareCallError.init)) }
        }
        switch result {
        case nil:
            return (.lookedUp(.failed(.timedOut(after: limit))), nil)
        case .failure(let error)?:
            return (.lookedUp(.failed(error)), nil)
        case .success(let found?)?:
            // Only the owner can save a share.
            let needsSave = Self.isOwner(of: found) && Self.applyTitle(title, to: found)
            return (.lookedUp(.shared(hasLink: found.url != nil, needsSave: needsSave)), found)
        case .success(nil)?:
            let since = cloudEvents.syncingSince(in: container.cloudKitStoreIdentifiers)
            return (.lookedUp(.notShared(isSyncing: HouseholdSharePlan.isWorthWaiting(forSyncSince: since))), nil)
        }
    }

    /// Asks iCloud whether an earlier `share()` left a share zone holding
    /// the household's record (`LeftoverShareZones`).
    private func shareCheckEarlierTries(_ objectID: NSManagedObjectID, store: NSPersistentStore, limit: Duration) async -> HouseholdSharePlan.Event {
        // A call still running here may have made its zone already; the
        // create step joins it rather than calling again.
        if shareCalls.isRunning(objectID) { return .earlierTriesChecked(.none) }
        guard let identifier = container.cloudKitContainerIdentifier, container.databaseScope(of: store) == .private else {
            // Someone else's household is always found by the lookup.
            return .earlierTriesChecked(.none)
        }
        let container = container
        let result: Result<[String], ShareCallError>? = await Bounded.wait(limit) { done in
            container.recordIDInBackground(for: objectID) { recordID in
                // Never uploaded: no `share()` can have carried it.
                guard let recordID else {
                    done(.success([]))
                    return
                }
                let database = CKContainer(identifier: identifier).privateCloudDatabase
                Task { done(await LeftoverShareZones.find(recordID, in: database).mapError(ShareCallError.init)) }
            }
        }
        switch result {
        case nil: return .earlierTriesChecked(.failed(.timedOut(after: limit)))
        case .failure(let error)?: return .earlierTriesChecked(.failed(error))
        case .success(let zones)? where zones.isEmpty: return .earlierTriesChecked(.none)
        case .success(let zones)?: return .earlierTriesChecked(.found(zones))
        }
    }

    /// `share()`, at most once per household at a time: a second Invite
    /// while one is still running (Try Again after a timeout) waits on it.
    private func shareCreate(_ objectID: NSManagedObjectID, title: String, limit: Duration) async -> (HouseholdSharePlan.Event, CKShare?) {
        let call: Task<Result<CKShare, ShareCallError>, Never>
        if shareCalls.begin(objectID) == .call {
            let container = container
            call = Task {
                await withCheckedContinuation { continuation in
                    container.shareInBackground(objectID) { continuation.resume(returning: $0.mapError(ShareCallError.init)) }
                }
            }
            runningShareCalls[objectID] = call
            Task { [weak self] in
                _ = await call.value
                self?.shareCalls.end(objectID)
                self?.runningShareCalls[objectID] = nil
            }
        } else if let running = runningShareCalls[objectID] {
            Logger.household.notice("Share: joining the share() still running")
            call = running
        } else {
            return (.created(.failed(.noResult)), nil)
        }
        let answer: Result<CKShare, ShareCallError>? = await Bounded.wait(limit) { done in
            Task { done(await call.value) }
        }
        switch answer {
        case nil:
            return (.created(.failed(.timedOut(after: limit))), nil)
        case .failure(let error)?:
            return (.created(.failed(error)), nil)
        case .success(let made)?:
            _ = Self.applyTitle(title, to: made)
            return (.created(.share(hasLink: made.url != nil)), made)
        }
    }

    private func shareSave(_ share: CKShare?, store: NSPersistentStore, limit: Duration) async -> (HouseholdSharePlan.Event, CKShare?) {
        guard let share, let url = store.url else { return (.saved(.failed(.noResult)), nil) }
        let container = container
        let result: Result<CKShare, ShareCallError>? = await Bounded.wait(limit) { done in
            container.persistUpdatedShareInBackground(share, inStoreAt: url) { done($0.mapError(ShareCallError.init)) }
        }
        switch result {
        case nil:
            return (.saved(.failed(.timedOut(after: limit))), nil)
        case .failure(let error)?:
            return (.saved(.failed(error)), nil)
        case .success(let saved)?:
            let kept = saved.url != nil || share.url == nil ? saved : share
            return (.saved(.share(hasLink: kept.url != nil)), kept)
        }
    }

    /// The share's own record straight from CloudKit: it carries the link
    /// once it reached the server, and the fetch doesn't wait on the
    /// container's executor.
    private func shareFetchLink(_ share: CKShare?, store: NSPersistentStore, title: String, limit: Duration) async -> (HouseholdSharePlan.Event, CKShare?) {
        guard let share, let identifier = container.cloudKitContainerIdentifier else { return (.linkFetched(.failed(.noResult)), nil) }
        let ckContainer = CKContainer(identifier: identifier)
        let database = container.databaseScope(of: store) == .shared ? ckContainer.sharedCloudDatabase : ckContainer.privateCloudDatabase
        let recordID = share.recordID
        let result: Result<CKShare?, ShareCallError>? = await Bounded.wait(limit) { done in
            database.fetch(withRecordID: recordID) { record, error in
                if let fetched = record as? CKShare {
                    done(.success(fetched))
                } else if let error, (error as? CKError)?.code == .unknownItem {
                    // Not on the server yet: the upload hasn't carried it.
                    done(.success(nil))
                } else {
                    done(.failure(error.map(ShareCallError.init) ?? .noResult))
                }
            }
        }
        switch result {
        case nil:
            return (.linkFetched(.failed(.timedOut(after: limit))), nil)
        case .failure(let error)?:
            return (.linkFetched(.failed(error)), nil)
        case .success(nil)?:
            return (.linkFetched(.share(hasLink: false)), nil)
        case .success(let fetched?)?:
            if Self.isOwner(of: fetched) { _ = Self.applyTitle(title, to: fetched) }
            return (.linkFetched(.share(hasLink: fetched.url != nil)), fetched.url != nil ? fetched : nil)
        }
    }

    /// Sets the share's title (the household's name, which the invitation
    /// shows) and its type stamp, in memory. True when either changed.
    static func applyTitle(_ title: String, to share: CKShare) -> Bool {
        var changed = false
        if !title.isEmpty, (share[CKShare.SystemFieldKey.title] as? String)?.isEmpty ?? true {
            share[CKShare.SystemFieldKey.title] = title as CKRecordValue
            changed = true
        }
        if share[CKShare.SystemFieldKey.shareType] as? String != shareType {
            share[CKShare.SystemFieldKey.shareType] = shareType as CKRecordValue
            changed = true
        }
        return changed
    }

    // MARK: Accept (HH-3)

    /// Accepts an invitation the system routed to the app, into the shared
    /// store, from a background queue (it waits on the container's executor,
    /// like `persistUpdatedShare`). Then waits, bounded, for the household to
    /// download, so the screen can switch to it at once; a slow download
    /// still lands later. Throws `HouseholdShareError`.
    public func acceptShare(_ metadata: CKShare.Metadata) async throws {
        guard case .cloud = mode, let sharedStore else { throw HouseholdShareError.iCloudUnavailable }
        let began = Date.now
        let container = container
        let url = sharedStoreURL
        let answer: (any Error)?? = await Bounded.wait(Self.acceptLimit) { done in
            container.acceptShareInvitationsInBackground(from: metadata, intoStoreAt: url) { done($0) }
        }
        switch answer {
        case nil:
            throw HouseholdShareError.timedOut("accepting the invitation")
        case .some(.some(let error)):
            Logger.household.error("Accept failed: \(ShareCallError(error).codeLabel, privacy: .public)")
            throw HouseholdShareError.failed(error.localizedDescription)
        case .some(nil):
            Logger.household.notice("Accepted a household share")
        }
        let storeID = sharedStore.identifier ?? ""
        let arrived = await cloudEvents.wait(timeout: Self.importAfterAcceptWait) { $0.importEnded(after: began, in: [storeID]) }
        if !arrived { Logger.household.notice("Accepted household not downloaded yet") }
        tidyAfterImport()
        rebuildSnapshots()
        scheduleShareLookup(force: true)
    }

    // MARK: Leave and remove (HH-4)

    /// A participant leaves by purging the share's zone, never deleting the
    /// root (which would ask iCloud to delete the owner's record). Clears
    /// the household from this person's devices only; their own household,
    /// kept underneath since their first launch, shows again (or a new one
    /// is made). Throws `HouseholdShareError.notSharedWithYou` for the owner.
    public func leaveHousehold() async throws {
        guard case .cloud = mode else { throw HouseholdShareError.iCloudUnavailable }
        guard let household = currentHouseholdEntity() else { throw HouseholdShareError.noHousehold }
        guard isInSharedStore(household) else { throw HouseholdShareError.notSharedWithYou }
        let objectID = household.objectID
        let container = container
        let url = sharedStoreURL
        let answer: (any Error)?? = await Bounded.wait(Self.leaveLimit) { done in
            container.leaveShareInBackground(of: objectID, sharedStoreURL: url) { done($0) }
        }
        switch answer {
        case nil:
            throw HouseholdShareError.timedOut("leaving the household")
        case .some(.some(let error)):
            if let shareError = error as? HouseholdShareError { throw shareError }
            Logger.household.error("Leave failed: \(ShareCallError(error).codeLabel, privacy: .public)")
            throw HouseholdShareError.failed(error.localizedDescription)
        case .some(nil):
            Logger.household.notice("Left a household share")
        }
        // The purge deleted the zone's objects under the context; drop every
        // object it holds (only snapshots leave this class, so none is in use).
        viewContext.reset()
        shareState = ShareState()
        ownPlaybackIDs.removeAll()
        rebuildSnapshots()
        if currentHouseholdEntity() == nil, let names = ensureNames {
            ensureHousehold(defaultName: names.household, firstProfileName: names.profile)
        }
    }

    /// The owner takes someone off the household's share (HH-4), and their
    /// role row with it. Usually done in the system share sheet; this is for
    /// the Household screen's member list.
    public func removeMember(participantID: String) async throws {
        guard case .cloud = mode else { throw HouseholdShareError.iCloudUnavailable }
        guard let household = currentHouseholdEntity() else { throw HouseholdShareError.noHousehold }
        guard !isInSharedStore(household), self.household.currentRole == .owner else { throw HouseholdShareError.notOwner }
        guard let url = household.objectID.persistentStore?.url else { throw HouseholdShareError.noHousehold }
        let objectID = household.objectID
        let container = container
        let found: Result<CKShare?, ShareCallError>? = await Bounded.wait(Self.shareLookupLimit) { done in
            container.lookUpShareInBackground(for: objectID) { done($0.mapError(ShareCallError.init)) }
        }
        let share: CKShare
        switch found {
        case nil: throw HouseholdShareError.timedOut("looking up the share")
        case .failure(let error)?: throw HouseholdShareError.failed(error.message)
        case .success(nil)?: throw HouseholdShareError.noShare
        case .success(let existing?)?: share = existing
        }
        if let participant = share.participants.first(where: { $0.participantID == participantID && $0.role != .owner }) {
            share.removeParticipant(participant)
            let saved: Result<CKShare, ShareCallError>? = await Bounded.wait(Self.removeMemberLimit) { done in
                container.persistUpdatedShareInBackground(share, inStoreAt: url) { done($0.mapError(ShareCallError.init)) }
            }
            switch saved {
            case nil: throw HouseholdShareError.timedOut("saving the share")
            case .failure(let error)?: throw HouseholdShareError.failed(error.message)
            case .success(let updated)?: shareState = ShareState(householdObjectID: objectID, share: updated, lookedUpAt: .now)
            }
        }
        if let current = currentHouseholdEntity() {
            live(current.memberRoles).filter { $0.participantID == participantID }.forEach(viewContext.delete)
        }
        commit("remove member")
    }

    // MARK: Roles (SRC-8)

    /// The owner sets a member's role (MemberRole rows are owner-written).
    /// Every row already there for the participant is rewritten rather than
    /// folded: MemberRole has no synced id to break a tie, so two devices
    /// deleting "the extra one" could delete both. Nobody else can call it
    /// usefully: a manager or watcher, or a participant's device, changes
    /// nothing. `.owner` can't be given.
    public func setRole(_ role: MemberRole, forParticipant participantID: String) {
        guard role != .owner, !participantID.isEmpty, household.currentRole == .owner,
              let household = currentHouseholdEntity(), !isInSharedStore(household) else { return }
        let rows = live(household.memberRoles).filter { $0.participantID == participantID }
        if rows.isEmpty {
            let row = insert(HouseholdModel.Entity.memberRole, as: MemberRoleEntity.self, into: targetStore(for: household))
            row.participantID = participantID
            row.roleRaw = role.rawValue
            row.household = household
        } else {
            for row in rows { set(row, \.roleRaw, role.rawValue) }
        }
        commit("set role")
    }

    // MARK: Refresh from iCloud

    /// Re-reads iCloud at most once a minute, waiting (bounded) for an import.
    ///
    /// Mirroring has no sync-now call; this re-posts the app's own
    /// did-become-active notification, which mirroring answers with an
    /// import (Multitrack's CloudSyncMonitor), then waits for that import.
    /// Nudges are spaced `CloudNudge.cooldown` apart: asking more often
    /// trips the system's rate limit, which stops all syncing for hours
    /// (TN3163). Inside the cooldown it waits on the nudge still in effect.
    /// A call while one runs joins it. Never removes and re-adds stores.
    public func refreshFromCloud() async {
        guard case .cloud = mode else { return }
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        let stores = container.cloudKitStoreIdentifiers
        guard !stores.isEmpty, syncStatus != .noAccount else { return }
        let now = Date.now
        let since: Date
        if CloudNudge.shouldNudge(lastNudgeAt: lastNudgeAt, asOf: now) {
            lastNudgeAt = now
            since = now
            CloudNudge.postDidBecomeActive()
        } else {
            since = lastNudgeAt ?? now
        }
        let arrived = await cloudEvents.wait(timeout: Self.refreshWait) { $0.importEnded(after: since, in: stores) }
        // Merged already; this re-reads anything the context had cached.
        if arrived { viewContext.refreshAllObjects() }
        tidyAfterImport()
        rebuildSnapshots()
        scheduleShareLookup(force: arrived)
    }

    nonisolated static func ms(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

extension HouseholdSharePlan.Failure {
    /// CloudKit's code for the log, never a name or address.
    var errorLabel: String {
        switch self {
        case .lookupFailed(let error): error.codeLabel
        case .earlierTriesLeftCopies(let count): "\(count) leftover zone(s)"
        case .notCreated(let error), .noLink(let error): error?.codeLabel ?? "no error"
        }
    }
}

/// A share's participants reduced to what the Household screen shows. Names
/// and addresses stay in memory: never logged (PRIV-2).
extension ShareParticipantInfo {
    static func list(from share: CKShare) -> [ShareParticipantInfo] {
        let current = share.currentUserParticipant?.participantID
        return share.participants.map { participant in
            ShareParticipantInfo(
                id: participant.participantID,
                displayName: displayName(of: participant),
                isOwner: participant.role == .owner,
                isCurrentUser: participant.participantID == current,
                isRemoved: participant.acceptanceStatus == .removed
            )
        }
    }

    static func displayName(of participant: CKShare.Participant) -> String {
        if let components = participant.userIdentity.nameComponents {
            let name = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
            if !name.isEmpty { return name }
        }
        if let email = participant.userIdentity.lookupInfo?.emailAddress, !email.isEmpty { return email }
        if let phone = participant.userIdentity.lookupInfo?.phoneNumber, !phone.isEmpty { return phone }
        return "Someone"
    }
}

/// Prompting mirroring to import: the only public trigger is the app's own
/// did-become-active notification (Multitrack's CloudSyncMonitor).
enum CloudNudge {
    /// Nudges are spaced at least this far apart (TN3163's rate limit).
    static let cooldown: TimeInterval = 60

    static func shouldNudge(lastNudgeAt: Date?, asOf now: Date) -> Bool {
        guard let lastNudgeAt else { return true }
        return now.timeIntervalSince(lastNudgeAt) >= cooldown
    }

    /// Only while the app really is active, so nothing else that observes the
    /// notification is told something untrue.
    @MainActor
    static func postDidBecomeActive() {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .active else { return }
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
        #elseif canImport(AppKit)
        guard let app = NSApp, app.isActive else { return }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
        #endif
    }
}
