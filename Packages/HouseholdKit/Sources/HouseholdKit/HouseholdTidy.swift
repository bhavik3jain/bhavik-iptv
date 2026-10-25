import CloudKit
import CoreData
import Foundation
import os

// What the store does when iCloud brings changes (technical spec, Sync and
// sharing rules). Nothing in CloudKit is unique, so two devices can each
// write "the same" favorite, progress row or household before seeing the
// other's; here the duplicates are folded, by `FoldRules`, the same way on
// every device. Stale who's-watching rows go too: any device may delete them.

extension HouseholdStore {
    /// How long a share lookup may take before the answer is "don't know".
    static let shareLookupLimit: Duration = .seconds(20)
    /// A failed or unanswered household fold is tried again no sooner.
    static let householdFoldRetry: TimeInterval = 60

    /// Folds duplicates and purges stale playback rows in every household
    /// this device holds, then saves. Runs at launch, after every import
    /// (debounced) and after this device's own writes when an import is
    /// pending. Cheap when there is nothing to fold: it only reads.
    func tidyAfterImport(now: Date = .now) {
        foldHouseholds()
        for household in fetch(HouseholdEntity.self, HouseholdModel.Entity.household) {
            foldFavorites(in: household)
            foldProgress(in: household)
            if hasImportedThisLaunch(household) { purgeStalePlaybacks(in: household, now: now) }
        }
        save("tidy")
    }

    /// Whether the store `household` lives in has finished an iCloud import
    /// this launch (always, in memory). A device that was offline holds
    /// every row as it last saw it: purging before the import that brings
    /// the fresh heartbeats would delete streams still playing elsewhere.
    /// Until then stale rows are only ignored (`activePlaybacks`,
    /// `streamUsage`).
    func hasImportedThisLaunch(_ household: HouseholdEntity) -> Bool {
        guard case .cloud = mode else { return true }
        guard let storeID = household.objectID.persistentStore?.identifier else { return false }
        return cloudEvents.hasImported(store: storeID)
    }

    // MARK: Households (HH-1)

    /// Households two of this person's devices made before either synced:
    /// everything moves into the oldest, and the others are deleted. Only
    /// this person's own (the private store) — a household shared with them
    /// is someone else's, never folded or deleted here.
    ///
    /// A household that is the root of a share is never folded away (deleting
    /// it would end the share for everyone in it). Whether one is takes a
    /// share lookup, which never runs on the main thread, so in cloud mode
    /// the fold happens when that answer comes back — and not at all when it
    /// doesn't: not knowing is no reason to delete.
    func foldHouseholds() {
        let own = fetch(HouseholdEntity.self, HouseholdModel.Entity.household).filter { !isInSharedStore($0) }
        guard own.count > 1 else { return }
        switch mode {
        case .inMemory:
            // No iCloud, so no shares.
            mergeHouseholds(own, shareRoots: [])
        case .cloud:
            scheduleHouseholdFold(own.map(\.objectID))
        }
    }

    private func scheduleHouseholdFold(_ ids: [NSManagedObjectID]) {
        guard householdFoldTask == nil, !ids.contains(where: \.isTemporaryID) else { return }
        if let last = lastHouseholdFoldAttempt, Date.now.timeIntervalSince(last) < Self.householdFoldRetry { return }
        lastHouseholdFoldAttempt = .now
        let container = container
        householdFoldTask = Task { [weak self] in
            let result: Result<[NSManagedObjectID: CKShare], ShareCallError>? = await Bounded.wait(Self.shareLookupLimit) { done in
                container.fetchSharesInBackground(for: ids) { done($0.mapError(ShareCallError.init)) }
            }
            guard let self else { return }
            self.householdFoldTask = nil
            switch result {
            case .success(let shares)?:
                let households = ids
                    .compactMap { try? self.viewContext.existingObject(with: $0) as? HouseholdEntity }
                    .filter { !$0.isDeleted }
                guard households.count > 1 else { return }
                Logger.household.notice("Folding \(households.count, privacy: .public) households, \(shares.count, privacy: .public) shared")
                self.mergeHouseholds(households, shareRoots: Set(shares.keys))
                self.commit("fold households")
            case .failure(let error)?:
                Logger.household.error("Household fold skipped: share lookup failed (\(error.codeLabel, privacy: .public))")
            case nil:
                Logger.household.notice("Household fold skipped: share lookup didn't answer")
            }
        }
    }

    /// Moves everything into the household `FoldRules.householdKeeper` picks
    /// and deletes the rest, leaving any share root alone. Doesn't save.
    func mergeHouseholds(_ households: [HouseholdEntity], shareRoots: Set<NSManagedObjectID>) {
        let rows = households.map { household in
            FoldRules.Row(
                date: household.createdAt,
                id: household.id?.uuidString ?? household.objectID.uriRepresentation().absoluteString,
                isShared: shareRoots.contains(household.objectID)
            )
        }
        guard let keeperIndex = FoldRules.householdKeeper(rows) else { return }
        let keeper = households[keeperIndex]
        for loser in households where loser !== keeper && !shareRoots.contains(loser.objectID) {
            fold(loser, into: keeper)
        }
    }

    /// Sources, roles and playback rows move as they are. A profile the
    /// keeper already has (same kind and name — the built-in first profile
    /// both devices made) hands its favorites and progress to that one and
    /// goes; the favorite and progress folds then settle any duplicates.
    /// Every device picks the same keeper and the same twins, so two folding
    /// at once make the same moves.
    private func fold(_ loser: HouseholdEntity, into keeper: HouseholdEntity) {
        for source in live(loser.sources) { source.household = keeper }
        for role in live(loser.memberRoles) { role.household = keeper }
        for playback in live(loser.playbacks) { playback.household = keeper }

        let keeperProfiles = live(keeper.profiles).sorted { Self.profileOrder($0.record, $1.record) }
        var nextOrder = (keeperProfiles.map(\.sortOrder).max() ?? -1) + 1
        var leaving: [ProfileEntity] = []
        for profile in live(loser.profiles).sorted(by: { Self.profileOrder($0.record, $1.record) }) {
            if let twin = keeperProfiles.first(where: { Self.isSameProfile($0, profile) }) {
                for favorite in live(profile.favorites) { favorite.profile = twin }
                for row in live(profile.progress) { row.profile = twin }
                leaving.append(profile)
            } else {
                profile.household = keeper
                set(profile, \.sortOrder, nextOrder)
                nextOrder += 1
            }
        }

        let keys = JSONList.decode(keeper.adultCategoryKeys).union(JSONList.decode(loser.adultCategoryKeys))
        set(keeper, \.adultCategoryKeys, JSONList.encode(keys))

        // Inverse relationships settle before the deletes cascade, so
        // nothing that moved goes with them.
        viewContext.processPendingChanges()
        leaving.forEach(viewContext.delete)
        viewContext.delete(loser)
    }

    static func isSameProfile(_ lhs: ProfileEntity, _ rhs: ProfileEntity) -> Bool {
        lhs.kindRaw == rhs.kindRaw
            && lhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(rhs.name.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    // MARK: Favorites and progress (FAV-4, VOD-3)

    /// One favorite per profile and item key: the earliest `addedAt` stays,
    /// with its hand-set place. Doesn't save.
    func foldFavorites(in household: HouseholdEntity) {
        for profile in live(household.profiles) {
            for (_, group) in Dictionary(grouping: live(profile.favorites), by: \.itemKey) where group.count > 1 {
                guard let keeper = FoldRules.favoriteKeeper(group.map(\.foldRow)) else { continue }
                for (index, row) in group.enumerated() where index != keeper { viewContext.delete(row) }
            }
        }
    }

    /// One progress row per profile and item key: the later `updatedAt`
    /// wins, whole row. Doesn't save.
    func foldProgress(in household: HouseholdEntity) {
        for profile in live(household.profiles) {
            for (_, group) in Dictionary(grouping: live(profile.progress), by: \.itemKey) where group.count > 1 {
                guard let keeper = FoldRules.progressKeeper(group.map(\.foldRow)) else { continue }
                for (index, row) in group.enumerated() where index != keeper { viewContext.delete(row) }
            }
        }
    }

    // MARK: Who's watching (HH-5)

    /// Deletes rows unseen for `PlaybackRecord.staleAfter` (a device that
    /// crashed or lost its connection mid-stream). True when any went.
    /// Doesn't save.
    @discardableResult
    func purgeStalePlaybacks(in household: HouseholdEntity, now: Date) -> Bool {
        let stale = live(household.playbacks).filter { $0.record.isStale(at: now) }
        stale.forEach(viewContext.delete)
        return !stale.isEmpty
    }
}
