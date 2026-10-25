import Core
import Foundation
import Testing
@testable import HouseholdKit

@MainActor
@Suite struct FavoriteTests {
    // FAV-1, FAV-3
    @Test func toggleAddsAtTheEndAndRemoves() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        store.toggleFavorite(profileID: profile, itemKey: TestKeys.channel("1"), kind: .channel)
        store.toggleFavorite(profileID: profile, itemKey: TestKeys.channel("2"), kind: .channel)
        store.toggleFavorite(profileID: profile, itemKey: TestKeys.movie("m"), kind: .movie)
        #expect(store.favorites(profileID: profile, kind: .channel).map(\.itemKey) == [TestKeys.channel("1"), TestKeys.channel("2")])
        #expect(store.favorites(profileID: profile, kind: .movie).map(\.itemKey) == [TestKeys.movie("m")])
        #expect(store.isFavorite(profileID: profile, itemKey: TestKeys.channel("2")))

        store.toggleFavorite(profileID: profile, itemKey: TestKeys.channel("1"), kind: .channel)
        #expect(!store.isFavorite(profileID: profile, itemKey: TestKeys.channel("1")))
        #expect(store.favorites(profileID: profile, kind: .channel).map(\.itemKey) == [TestKeys.channel("2")])
    }

    // PRF-7
    @Test func favoritesBelongToOneProfile() throws {
        let store = try makeStore()
        let other = try #require(store.addProfile(name: "Anya", kind: .standard, avatarColor: .teal))
        store.toggleFavorite(profileID: store.firstProfile.id, itemKey: TestKeys.channel("1"), kind: .channel)
        #expect(store.favorites(profileID: other.id, kind: .channel).isEmpty)
        #expect(!store.isFavorite(profileID: other.id, itemKey: TestKeys.channel("1")))
    }

    // FAV-1: a move writes the moved row only.
    @Test func movingAFavoriteWritesOneRow() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        for id in ["a", "b", "c", "d"] {
            store.toggleFavorite(profileID: profile, itemKey: TestKeys.channel(id), kind: .channel)
        }
        let before = store.favorites(profileID: profile, kind: .channel)
        store.moveFavorites(profileID: profile, kind: .channel, fromOffsets: [3], toOffset: 1)
        let after = store.favorites(profileID: profile, kind: .channel)
        #expect(after.map(\.itemKey) == ["a", "d", "b", "c"].map { TestKeys.channel($0) })
        let changed = after.filter { row in before.first { $0.id == row.id }?.sortOrder != row.sortOrder }
        #expect(changed.map(\.itemKey) == [TestKeys.channel("d")])
    }

    @Test func rewriteItemKeysRenamesAndFolds() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        store.toggleFavorite(profileID: profile, itemKey: TestKeys.channel("old"), kind: .channel)
        store.toggleFavorite(profileID: profile, itemKey: TestKeys.channel("kept"), kind: .channel)
        store.toggleFavorite(profileID: profile, itemKey: TestKeys.channel("dupe"), kind: .channel)
        store.saveProgress(profileID: profile, itemKey: TestKeys.movie("old"), kind: .movie, position: 10, duration: 100)
        store.rewriteItemKeys([
            TestKeys.channel("old"): TestKeys.channel("new"),
            TestKeys.channel("dupe"): TestKeys.channel("kept"),
            TestKeys.movie("old"): TestKeys.movie("new"),
        ])
        #expect(Set(store.favorites(profileID: profile, kind: .channel).map(\.itemKey)) == [TestKeys.channel("new"), TestKeys.channel("kept")])
        #expect(store.count(HouseholdModel.Entity.favorite) == 2)
        #expect(store.progress(profileID: profile, itemKey: TestKeys.movie("new"))?.position == 10)
        #expect(store.progress(profileID: profile, itemKey: TestKeys.movie("old")) == nil)
    }
}

@MainActor
@Suite struct ProgressTests {
    // VOD-3
    @Test func savesInPlaceAndMarksWatchedAt95Percent() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        let key = TestKeys.movie("m")
        store.saveProgress(profileID: profile, itemKey: key, kind: .movie, position: 100, duration: 1000)
        #expect(store.progress(profileID: profile, itemKey: key)?.watched == false)
        store.saveProgress(profileID: profile, itemKey: key, kind: .movie, position: 949, duration: 1000)
        #expect(store.progress(profileID: profile, itemKey: key)?.watched == false)
        store.saveProgress(profileID: profile, itemKey: key, kind: .movie, position: 950, duration: 1000)
        let row = try #require(store.progress(profileID: profile, itemKey: key))
        #expect(row.watched)
        #expect(row.position == 950)
        #expect(store.count(HouseholdModel.Entity.progress) == 1, "one row per profile and item")
    }

    @Test func watchedRule() {
        #expect(ProgressRules.isWatched(position: 95, duration: 100))
        #expect(!ProgressRules.isWatched(position: 94.9, duration: 100))
        #expect(!ProgressRules.isWatched(position: 10, duration: 0), "unknown length is never watched")
    }

    @Test func setWatchedByHand() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        let key = TestKeys.episode("show", 2, 3)
        store.setWatched(true, profileID: profile, itemKey: key)
        let row = try #require(store.progress(profileID: profile, itemKey: key))
        #expect(row.watched)
        #expect(row.kind == .episode)
        #expect(row.seriesKey == TestKeys.series("show"))
        #expect(row.season == 2 && row.episode == 3)

        store.saveProgress(profileID: profile, itemKey: key, kind: .episode, position: 300, duration: 1000)
        store.setWatched(false, profileID: profile, itemKey: key)
        #expect(store.progress(profileID: profile, itemKey: key)?.watched == false)
        #expect(store.progress(profileID: profile, itemKey: key)?.position == 0)
    }

    @Test func episodeKeysCarryTheirSeries() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        store.saveProgress(profileID: profile, itemKey: TestKeys.episode("show", 1, 4), kind: .episode, position: 10, duration: 100)
        let row = try #require(store.seriesProgress(profileID: profile, seriesKey: TestKeys.series("show")).first)
        #expect(row.season == 1 && row.episode == 4)
    }

    // HOME-1
    @Test func continueWatchingIsUnfinishedMostRecentFirst() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        store.saveProgress(profileID: profile, itemKey: TestKeys.movie("old"), kind: .movie, position: 100, duration: 1000)
        store.saveProgress(profileID: profile, itemKey: TestKeys.movie("done"), kind: .movie, position: 990, duration: 1000)
        store.saveProgress(profileID: profile, itemKey: TestKeys.movie("unstarted"), kind: .movie, position: 0, duration: 1000)
        store.saveProgress(profileID: profile, itemKey: TestKeys.episode("show", 1, 1), kind: .episode, position: 200, duration: 1000)
        store.saveProgress(profileID: profile, itemKey: TestKeys.episode("show", 1, 2), kind: .episode, position: 300, duration: 1000)
        store.saveProgress(profileID: profile, itemKey: TestKeys.movie("new"), kind: .movie, position: 50, duration: 1000)

        let rows = store.continueWatching(profileID: profile)
        // One per series (its latest episode), nothing finished or unstarted.
        #expect(rows.map(\.itemKey) == [TestKeys.movie("new"), TestKeys.episode("show", 1, 2), TestKeys.movie("old")])
        #expect(store.continueWatching(profileID: profile, limit: 1).map(\.itemKey) == [TestKeys.movie("new")])
    }

    @Test func continueWatchingRuleOnValues() {
        let profile = UUID()
        let now = Date.now
        func row(_ key: String, _ minutesAgo: Double, position: Double = 10, watched: Bool = false, kind: HouseholdKit.ProgressKind = .movie, series: String? = nil) -> ProgressRecord {
            ProgressRecord(profileID: profile, itemKey: key, kind: kind, position: position, duration: 100, watched: watched, updatedAt: now.addingTimeInterval(-minutesAgo * 60), seriesKey: series)
        }
        let rows = [
            row("a", 5),
            row("b", 1),
            row("live", 0, kind: .catchup),
            row("s1e2", 2, watched: true, kind: .episode, series: "s1"),
            row("s1e1", 3, kind: .episode, series: "s1"),
            row("s2e1", 4, kind: .episode, series: "s2"),
        ]
        // s1's newest row is finished, so s1 isn't "in progress" at e1.
        #expect(ProgressRules.continueWatching(rows, limit: 20).map(\.itemKey) == ["b", "s2e1", "a"])
        #expect(ProgressRules.seriesInProgress(rows, limit: 20).map(\.itemKey) == ["s1e2", "s2e1"])
    }

    // SER-2
    @Test func seriesInProgressGivesEachSeriesLatestEpisode() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        store.saveProgress(profileID: profile, itemKey: TestKeys.episode("a", 1, 1), kind: .episode, position: 990, duration: 1000)
        store.saveProgress(profileID: profile, itemKey: TestKeys.episode("b", 2, 5), kind: .episode, position: 990, duration: 1000)
        store.saveProgress(profileID: profile, itemKey: TestKeys.episode("a", 1, 2), kind: .episode, position: 990, duration: 1000)
        store.saveProgress(profileID: profile, itemKey: TestKeys.movie("m"), kind: .movie, position: 10, duration: 1000)
        #expect(store.seriesInProgress(profileID: profile).map(\.itemKey) == [TestKeys.episode("a", 1, 2), TestKeys.episode("b", 2, 5)])
    }

    // SER-3
    @Test func householdProgressExcludesGuestsAndSelf() throws {
        let store = try makeStore()
        let me = store.firstProfile.id
        let anya = try #require(store.addProfile(name: "Anya", kind: .standard, avatarColor: .teal))
        let ravi = try #require(store.addProfile(name: "Ravi", kind: .kids, avatarColor: .coral))
        let guest = try #require(store.addProfile(name: "Guest", kind: .guest, avatarColor: .slate))
        let series = TestKeys.series("show")
        store.saveProgress(profileID: me, itemKey: TestKeys.episode("show", 1, 5), kind: .episode, position: 10, duration: 100)
        store.saveProgress(profileID: anya.id, itemKey: TestKeys.episode("show", 3, 1), kind: .episode, position: 10, duration: 100)
        store.saveProgress(profileID: anya.id, itemKey: TestKeys.episode("show", 2, 9), kind: .episode, position: 10, duration: 100)
        store.saveProgress(profileID: ravi.id, itemKey: TestKeys.episode("other", 1, 1), kind: .episode, position: 10, duration: 100)
        // A guest's row can't be written through the store; one an older
        // build left still never shows.
        store.simulateImport { store in
            store.importProgress(profileID: guest.id, itemKey: TestKeys.episode("show", 4, 1), kind: .episode, position: 1, duration: 100, updatedAt: .now, seriesKey: series)
        }

        let others = store.householdProgress(seriesKey: series, excluding: me)
        #expect(others.map(\.profile.id) == [anya.id])
        #expect(others.first?.progress.itemKey == TestKeys.episode("show", 2, 9), "the latest row, not the highest episode")
    }

    // PRF-5, PAR-4
    @Test func aGuestWritesNothing() throws {
        let store = try makeStore()
        let guest = try #require(store.addProfile(name: "Guest", kind: .guest, avatarColor: .slate))
        let before = (store.count(HouseholdModel.Entity.favorite), store.count(HouseholdModel.Entity.progress))
        store.toggleFavorite(profileID: guest.id, itemKey: TestKeys.channel("1"), kind: .channel)
        store.saveProgress(profileID: guest.id, itemKey: TestKeys.movie("m"), kind: .movie, position: 10, duration: 100)
        store.setWatched(true, profileID: guest.id, itemKey: TestKeys.movie("n"))
        #expect(store.count(HouseholdModel.Entity.favorite) == before.0)
        #expect(store.count(HouseholdModel.Entity.progress) == before.1)
        #expect(store.favorites(profileID: guest.id, kind: .channel).isEmpty)
        #expect(store.progress(profileID: guest.id, itemKey: TestKeys.movie("m")) == nil)
        #expect(store.continueWatching(profileID: guest.id).isEmpty)
        #expect(!store.isFavorite(profileID: guest.id, itemKey: TestKeys.channel("1")))
    }

    @Test func clearGuestDataRemovesLeftovers() throws {
        let store = try makeStore()
        let guest = try #require(store.addProfile(name: "Guest", kind: .guest, avatarColor: .slate))
        store.simulateImport { store in
            store.importFavorite(profileID: guest.id, itemKey: TestKeys.channel("1"), sortOrder: 1, addedAt: .now)
            store.importProgress(profileID: guest.id, itemKey: TestKeys.movie("m"), position: 1, duration: 100, updatedAt: .now)
        }
        store.clearGuestData(profileID: guest.id)
        #expect(store.count(HouseholdModel.Entity.favorite) == 0)
        #expect(store.count(HouseholdModel.Entity.progress) == 0)

        // Never touches a profile that isn't a Guest.
        store.toggleFavorite(profileID: store.firstProfile.id, itemKey: TestKeys.channel("1"), kind: .channel)
        store.clearGuestData(profileID: store.firstProfile.id)
        #expect(store.count(HouseholdModel.Entity.favorite) == 1)
    }
}
