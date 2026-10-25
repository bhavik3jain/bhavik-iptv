import CoreData
import Foundation
import Testing
@testable import HouseholdKit

@MainActor
@Suite struct PlaybackTests {
    // HH-5
    @Test func startHeartbeatAndStop() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        let id = store.startPlayback(profileID: profile, sourceID: TestKeys.sourceA, itemKey: TestKeys.channel("1"), title: "News", deviceName: "Living Room")
        #expect(store.activePlaybacks.map(\.id) == [id])
        #expect(store.activePlaybacks.first?.deviceName == "Living Room")

        let row = try #require(store.fetch(PlaybackEntity.self, HouseholdModel.Entity.playback).first)
        row.lastSeenAt = .now.addingTimeInterval(-600)
        store.save("test")
        store.heartbeat(playbackID: id)
        #expect(abs(row.lastSeenAt.timeIntervalSinceNow) < 5)

        store.stopPlayback(playbackID: id)
        #expect(store.activePlaybacks.isEmpty)
        #expect(store.count(HouseholdModel.Entity.playback) == 0)
    }

    @Test func stalePlaybacksArePurgedAndIgnored() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        let fresh = store.startPlayback(profileID: profile, sourceID: TestKeys.sourceA, itemKey: TestKeys.channel("1"), title: "News", deviceName: "iPhone")
        let stale = store.startPlayback(profileID: profile, sourceID: TestKeys.sourceA, itemKey: TestKeys.channel("2"), title: "Sport", deviceName: "iPad")
        let row = try #require(store.fetch(PlaybackEntity.self, HouseholdModel.Entity.playback).first { $0.id == stale })
        row.lastSeenAt = .now.addingTimeInterval(-(PlaybackRecord.staleAfter + 60))
        store.save("test")
        store.rebuildSnapshots()

        #expect(store.activePlaybacks.map(\.id) == [fresh], "stale rows are filtered out of the snapshot")
        #expect(store.streamUsage(sourceID: TestKeys.sourceA, limit: 1).inUse.map(\.id) == [fresh])
        #expect(store.count(HouseholdModel.Entity.playback) == 2)

        store.purgeStalePlaybacks()
        #expect(store.count(HouseholdModel.Entity.playback) == 1)
        #expect(store.activePlaybacks.map(\.id) == [fresh])
    }

    @Test func purgeUsesTheGivenClock() throws {
        let store = try makeStore()
        store.startPlayback(profileID: store.firstProfile.id, sourceID: TestKeys.sourceA, itemKey: "k", title: "t", deviceName: "d")
        store.purgeStalePlaybacks(now: .now.addingTimeInterval(60))
        #expect(store.count(HouseholdModel.Entity.playback) == 1)
        store.purgeStalePlaybacks(now: .now.addingTimeInterval(PlaybackRecord.staleAfter + 1))
        #expect(store.count(HouseholdModel.Entity.playback) == 0)
    }

    // HH-6
    @Test func streamUsageCountsOneSourceExcludingAGivenPlayback() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        let mine = store.startPlayback(profileID: profile, sourceID: TestKeys.sourceA, itemKey: TestKeys.channel("1"), title: "News", deviceName: "iPhone")
        let otherSource = store.startPlayback(profileID: profile, sourceID: TestKeys.sourceB, itemKey: TestKeys.channel("2", source: TestKeys.sourceB), title: "Film", deviceName: "Mac")

        let usage = store.streamUsage(sourceID: TestKeys.sourceA, limit: 1)
        #expect(usage.inUse.map(\.id) == [mine])
        #expect(usage.isAtLimit)
        #expect(usage.free == 0)

        // Switching channel on this device doesn't count its own stream.
        let switching = store.streamUsage(sourceID: TestKeys.sourceA, limit: 1, excludingPlaybackID: mine)
        #expect(switching.inUse.isEmpty)
        #expect(!switching.isAtLimit)

        let unlimited = store.streamUsage(sourceID: TestKeys.sourceB, limit: nil)
        #expect(unlimited.inUse.map(\.id) == [otherSource])
        #expect(unlimited.free == nil)
        #expect(!unlimited.isAtLimit)
    }

    @Test func otherDevicesComeFirst() {
        let now = Date.now
        let own = PlaybackRecord(deviceName: "This iPhone", profileID: UUID(), sourceID: TestKeys.sourceA, itemKey: "a", title: "A", startedAt: now.addingTimeInterval(-300), lastSeenAt: now)
        let other = PlaybackRecord(deviceName: "Living Room", profileID: UUID(), sourceID: TestKeys.sourceA, itemKey: "b", title: "B", startedAt: now, lastSeenAt: now)
        let usage = StreamRules.usage(sourceID: TestKeys.sourceA, limit: 2, playbacks: [own, other], excluding: nil, ownPlaybackIDs: [own.id], now: now)
        #expect(usage.inUse.map(\.deviceName) == ["Living Room", "This iPhone"])
        #expect(usage.free == 0)
    }

    // HH-5: another device purged this one's row while it was offline.
    @Test func aHeartbeatWritesAPurgedRowAgain() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        let id = store.startPlayback(profileID: profile, sourceID: TestKeys.sourceA, itemKey: TestKeys.channel("1"), title: "News", deviceName: "iPhone")
        store.purgeStalePlaybacks(now: .now.addingTimeInterval(PlaybackRecord.staleAfter + 1))
        #expect(store.activePlaybacks.isEmpty)

        store.heartbeat(playbackID: id)
        #expect(store.activePlaybacks.map(\.id) == [id])
        #expect(store.activePlaybacks.first?.title == "News")
        #expect(store.count(HouseholdModel.Entity.playback) == 1)

        // A stopped stream stays stopped, and a stranger's id writes nothing.
        store.stopPlayback(playbackID: id)
        store.heartbeat(playbackID: id)
        store.heartbeat(playbackID: UUID())
        #expect(store.count(HouseholdModel.Entity.playback) == 0)
    }

    @Test func tidyPurgesStaleRowsInMemory() throws {
        let store = try makeStore()
        store.startPlayback(profileID: store.firstProfile.id, sourceID: TestKeys.sourceA, itemKey: "k", title: "t", deviceName: "d")
        let household = try #require(store.currentHouseholdEntity())
        #expect(store.hasImportedThisLaunch(household), "no iCloud import to wait for in memory")
        store.tidyAfterImport(now: .now.addingTimeInterval(PlaybackRecord.staleAfter + 1))
        #expect(store.count(HouseholdModel.Entity.playback) == 0)
    }
}

/// What the store does when an import brings duplicates (technical spec,
/// Sync and sharing rules).
@MainActor
@Suite struct ImportFoldTests {
    // FAV-4: duplicates folded by profile plus itemKey, earliest addedAt kept.
    @Test func duplicateFavoritesKeepTheEarliest() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        let key = TestKeys.channel("1")
        let early = Date(timeIntervalSince1970: 1_000)
        let earliestID = UUID()
        store.simulateImport { store in
            store.importFavorite(profileID: profile, itemKey: key, sortOrder: 7, addedAt: early.addingTimeInterval(60))
            store.importFavorite(profileID: profile, itemKey: key, sortOrder: 3, addedAt: early, id: earliestID)
            store.importFavorite(profileID: profile, itemKey: key, sortOrder: 9, addedAt: early.addingTimeInterval(120))
            store.importFavorite(profileID: profile, itemKey: TestKeys.channel("2"), sortOrder: 5, addedAt: early)
        }
        // Before the fold, reads already show one.
        #expect(store.favorites(profileID: profile, kind: .channel).filter { $0.itemKey == key }.map(\.id) == [earliestID])

        store.tidyAfterImport()
        store.rebuildSnapshots()
        #expect(store.count(HouseholdModel.Entity.favorite) == 2)
        let kept = try #require(store.favorites(profileID: profile, kind: .channel).first { $0.itemKey == key })
        #expect(kept.id == earliestID)
        #expect(kept.sortOrder == 3)
    }

    @Test func favoritesOfDifferentProfilesAreNotDuplicates() throws {
        let store = try makeStore()
        let other = try #require(store.addProfile(name: "Anya", kind: .standard, avatarColor: .teal))
        let key = TestKeys.channel("1")
        store.toggleFavorite(profileID: store.firstProfile.id, itemKey: key, kind: .channel)
        store.toggleFavorite(profileID: other.id, itemKey: key, kind: .channel)
        store.tidyAfterImport()
        #expect(store.count(HouseholdModel.Entity.favorite) == 2)
    }

    // VOD-3: the later updatedAt wins, whole row.
    @Test func duplicateProgressKeepsTheLaterRowWhole() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        let key = TestKeys.movie("m")
        let base = Date(timeIntervalSince1970: 50_000)
        let laterID = UUID()
        store.simulateImport { store in
            // Further along but older: loses.
            store.importProgress(profileID: profile, itemKey: key, position: 900, duration: 1000, watched: false, updatedAt: base)
            store.importProgress(profileID: profile, itemKey: key, position: 120, duration: 1000, watched: false, updatedAt: base.addingTimeInterval(30), id: laterID)
        }
        #expect(store.progress(profileID: profile, itemKey: key)?.id == laterID, "reads pick the keeper before the fold")

        store.tidyAfterImport()
        #expect(store.count(HouseholdModel.Entity.progress) == 1)
        let kept = try #require(store.progress(profileID: profile, itemKey: key))
        #expect(kept.id == laterID)
        #expect(kept.position == 120)
        #expect(kept.updatedAt == base.addingTimeInterval(30))
    }

    @Test func saveProgressUpdatesTheKeeperOfUnfoldedDuplicates() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        let key = TestKeys.movie("m")
        let laterID = UUID()
        store.simulateImport { store in
            store.importProgress(profileID: profile, itemKey: key, position: 10, duration: 100, updatedAt: .now.addingTimeInterval(-100))
            store.importProgress(profileID: profile, itemKey: key, position: 20, duration: 100, updatedAt: .now.addingTimeInterval(-50), id: laterID)
        }
        store.saveProgress(profileID: profile, itemKey: key, kind: .movie, position: 40, duration: 100)
        store.tidyAfterImport()
        let kept = try #require(store.progress(profileID: profile, itemKey: key))
        #expect(kept.id == laterID)
        #expect(kept.position == 40)
    }

    // HH-1: two devices that each made a household before syncing.
    @Test func duplicateHouseholdsFoldIntoTheOldest() throws {
        let store = try makeStore()
        let keeperID = store.household.id
        let keeperProfile = store.firstProfile.id
        store.toggleFavorite(profileID: keeperProfile, itemKey: TestKeys.channel("1"), kind: .channel)

        // The other device's household, made a minute later, with its own
        // "Bhavik", a second profile, a source and favorites.
        var twinID: UUID?
        store.simulateImport { store in
            let privateStore = store.privateStore
            let household = store.insert(HouseholdModel.Entity.household, as: HouseholdEntity.self, into: privateStore)
            household.id = UUID()
            household.name = "Jain Household"
            household.createdAt = .now.addingTimeInterval(60)
            household.adultCategoryKeys = JSONList.encode(["s/cat/x"])
            let twin = store.insert(HouseholdModel.Entity.profile, as: ProfileEntity.self, into: privateStore)
            twin.id = UUID()
            twin.name = "bhavik"
            twin.household = household
            twinID = twin.id
            let anya = store.insert(HouseholdModel.Entity.profile, as: ProfileEntity.self, into: privateStore)
            anya.id = UUID()
            anya.name = "Anya"
            anya.sortOrder = 1
            anya.household = household
            let source = store.insert(HouseholdModel.Entity.source, as: SourceEntity.self, into: privateStore)
            source.id = TestKeys.sourceB
            source.name = "Their Portal"
            source.household = household
            for key in ["1", "2"] {
                let favorite = store.insert(HouseholdModel.Entity.favorite, as: FavoriteEntity.self, into: privateStore)
                favorite.id = UUID()
                favorite.itemKey = TestKeys.channel(key)
                favorite.sortOrder = 10
                favorite.addedAt = .now.addingTimeInterval(120)
                favorite.profile = twin
            }
        }
        #expect(store.count(HouseholdModel.Entity.household) == 2)
        #expect(twinID != nil)

        store.tidyAfterImport()
        store.rebuildSnapshots()
        #expect(store.count(HouseholdModel.Entity.household) == 1)
        #expect(store.household.id == keeperID)
        #expect(store.profiles.map(\.name) == ["Bhavik", "Anya"])
        #expect(store.profiles.first?.id == keeperProfile)
        #expect(store.sources.map(\.id) == [TestKeys.sourceB])
        #expect(store.household.adultCategoryKeys == ["s/cat/x"])
        // The twin's favorites moved to the keeper's profile, duplicates folded.
        #expect(store.favorites(profileID: keeperProfile, kind: .channel).map(\.itemKey) == [TestKeys.channel("1"), TestKeys.channel("2")])
        #expect(store.count(HouseholdModel.Entity.favorite) == 2)
    }

    @Test func householdKeeperPrefersAShareRootThenTheOldest() {
        let old = FoldRules.Row(date: Date(timeIntervalSince1970: 1), id: "b")
        let new = FoldRules.Row(date: Date(timeIntervalSince1970: 2), id: "a")
        #expect(FoldRules.householdKeeper([new, old]) == 1)
        var sharedNew = new
        sharedNew.isShared = true
        #expect(FoldRules.householdKeeper([old, sharedNew]) == 1)
    }

    @Test func foldTiesBreakBySyncedIDOnEveryDevice() {
        let instant = Date(timeIntervalSince1970: 1_000)
        // Less than CloudKit's millisecond apart: the same instant.
        let a = FoldRules.Row(date: instant.addingTimeInterval(0.0004), id: "A")
        let b = FoldRules.Row(date: instant, id: "B")
        #expect(FoldRules.favoriteKeeper([b, a]) == 1)
        #expect(FoldRules.favoriteKeeper([a, b]) == 0)
        #expect(FoldRules.progressKeeper([b, a]) == 1)
        #expect(FoldRules.favoriteKeeper([]) == nil)
    }
}
