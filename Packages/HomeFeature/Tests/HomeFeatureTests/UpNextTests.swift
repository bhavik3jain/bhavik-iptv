import CatalogKit
import Core
import Foundation
import HouseholdKit
import Testing
@testable import HomeFeature

@Suite struct UpNextPlannerTests {
    /// Two seasons and two specials, deliberately out of order.
    let episodes: [CatalogEpisode] = [
        Fixture.episode(2, 1, title: "Return"),
        Fixture.episode(1, 2),
        Fixture.episode(0, 2, title: "Christmas Special"),
        Fixture.episode(1, 3, title: "Low Tide"),
        Fixture.episode(1, 1, title: "Pilot"),
        Fixture.episode(0, 1, title: "Behind the Scenes"),
    ]

    private func key(_ season: Int, _ number: Int) -> String {
        Fixture.episodeKey(season, number).rawValue
    }

    @Test func ordersBySeasonThenNumberWithSpecialsFirst() {
        let codes = UpNextPlanner.ordered(episodes).map { "\($0.season)x\($0.number)" }
        #expect(codes == ["0x1", "0x2", "1x1", "1x2", "1x3", "2x1"])
    }

    @Test func tiesBreakByKeySoTheOrderIsStable() {
        let a = Fixture.episode(series: "a", 1, 1)
        let b = Fixture.episode(series: "b", 1, 1)
        #expect(UpNextPlanner.ordered([b, a]).map(\.key) == [a.key, b.key])
        #expect(UpNextPlanner.ordered([a, b]).map(\.key) == [a.key, b.key])
    }

    @Test func anUnfinishedEpisodeIsResumed() {
        let last = Fixture.episodeProgress(1, 2, position: 754)
        let pick = UpNextPlanner.pick(last: last, episodes: episodes, watchedKeys: [])
        #expect(pick == .resume(Fixture.episode(1, 2), position: 754))
    }

    @Test func anUnfinishedEpisodeIsFoundBySeasonAndNumberWhenItsKeyDiffers() {
        var last = Fixture.episodeProgress(1, 3, position: 30)
        last.itemKey = "legacy-key"
        let pick = UpNextPlanner.pick(last: last, episodes: episodes, watchedKeys: [])
        #expect(pick?.episode.key.rawValue == key(1, 3))
    }

    @Test func anUnfinishedEpisodeMissingFromTheCacheIsNoPick() {
        let last = Fixture.episodeProgress(3, 1)
        #expect(UpNextPlanner.pick(last: last, episodes: episodes, watchedKeys: []) == nil)
    }

    @Test func aFinishedEpisodeLeadsToTheNextOne() {
        let last = Fixture.episodeProgress(1, 1, watched: true)
        #expect(UpNextPlanner.pick(last: last, episodes: episodes, watchedKeys: [key(1, 1)]) == .next(Fixture.episode(1, 2)))
    }

    @Test func theNextCrossesIntoTheNextSeason() {
        let last = Fixture.episodeProgress(1, 3, watched: true)
        #expect(UpNextPlanner.pick(last: last, episodes: episodes, watchedKeys: [])?.episode.key.rawValue == key(2, 1))
    }

    @Test func episodesThisProfileWatchedAreSkipped() {
        let last = Fixture.episodeProgress(1, 1, watched: true)
        let pick = UpNextPlanner.pick(last: last, episodes: episodes, watchedKeys: [key(1, 2), key(1, 3)])
        #expect(pick?.episode.key.rawValue == key(2, 1))
    }

    @Test func aRegularEpisodeNeverLeadsToASpecial() {
        // Specials sort first, so nothing after S1 E1 is in season 0.
        let last = Fixture.episodeProgress(1, 1, watched: true)
        let all = UpNextPlanner.ordered(episodes)
        let pick = UpNextPlanner.pick(last: last, episodes: all, watchedKeys: [])
        #expect(pick?.episode.season == 1)
    }

    @Test func aSpecialLeadsToTheNextSpecialThenTheFirstEpisode() {
        let first = Fixture.episodeProgress(0, 1, watched: true)
        #expect(UpNextPlanner.pick(last: first, episodes: episodes, watchedKeys: [])?.episode.key.rawValue == key(0, 2))
        let second = Fixture.episodeProgress(0, 2, watched: true)
        #expect(UpNextPlanner.pick(last: second, episodes: episodes, watchedKeys: [])?.episode.key.rawValue == key(1, 1))
    }

    @Test func caughtUpIsNoPick() {
        let last = Fixture.episodeProgress(2, 1, watched: true)
        #expect(UpNextPlanner.pick(last: last, episodes: episodes, watchedKeys: []) == nil)
        let allWatched = Set(episodes.map(\.key.rawValue))
        let early = Fixture.episodeProgress(1, 1, watched: true)
        #expect(UpNextPlanner.pick(last: early, episodes: episodes, watchedKeys: allWatched) == nil)
    }

    @Test func noEpisodesIsNoPick() {
        #expect(UpNextPlanner.pick(last: Fixture.episodeProgress(1, 1), episodes: [], watchedKeys: []) == nil)
        #expect(UpNextPlanner.pick(last: Fixture.episodeProgress(1, 1, watched: true), episodes: [], watchedKeys: []) == nil)
    }

    @Test func seasonAndNumberComeFromTheRowThenTheKey() {
        #expect(UpNextPlanner.seasonAndNumber(of: Fixture.episodeProgress(4, 7)).map { [$0.0, $0.1] } == [4, 7])
        #expect(UpNextPlanner.seasonAndNumber(of: Fixture.episodeProgress(4, 7, codeOnRow: false)).map { [$0.0, $0.1] } == [4, 7])

        var mismatch = Fixture.episodeProgress(4, 7)
        mismatch.season = 5
        mismatch.episode = 1
        #expect(UpNextPlanner.seasonAndNumber(of: mismatch).map { [$0.0, $0.1] } == [5, 1])

        var halfRow = Fixture.episodeProgress(4, 7, codeOnRow: false)
        halfRow.season = 9
        #expect(UpNextPlanner.seasonAndNumber(of: halfRow).map { [$0.0, $0.1] } == [4, 7])

        #expect(UpNextPlanner.seasonAndNumber(of: Fixture.movieProgress(position: 1, duration: 2)) == nil)
    }

    @Test func aRowWithNoCodeAnywhereIsNoPick() {
        var row = Fixture.episodeProgress(1, 1, codeOnRow: false)
        row.itemKey = "not-an-episode-key"
        #expect(UpNextPlanner.pick(last: row, episodes: episodes, watchedKeys: []) == nil)
    }

    @Test func queueListsTheEpisodesAfterInOrder() {
        let queue = UpNextPlanner.queue(after: Fixture.episodeKey(1, 1), in: episodes)
        #expect(queue == [key(1, 2), key(1, 3), key(2, 1)])
        #expect(UpNextPlanner.queue(after: Fixture.episodeKey(1, 1), in: episodes, limit: 2) == [key(1, 2), key(1, 3)])
        #expect(UpNextPlanner.queue(after: Fixture.episodeKey(2, 1), in: episodes).isEmpty)
        #expect(UpNextPlanner.queue(after: Fixture.episodeKey(9, 9), in: episodes).isEmpty)
    }

    @Test func queueStopsAtFiftyByDefault() {
        let long = (1...80).map { Fixture.episode(1, $0) }
        let queue = UpNextPlanner.queue(after: Fixture.episodeKey(1, 1), in: long)
        #expect(queue.count == 50)
        #expect(queue.first == key(1, 2))
        #expect(queue.last == key(1, 51))
    }

    @Test func newOnlyWhenFinishedAndTheShowChangedSince() {
        let finishedAt = Fixture.reference
        let finished = Fixture.episodeProgress(1, 3, watched: true, updatedAt: finishedAt)
        #expect(UpNextPlanner.isNew(last: finished, seriesChangedAt: finishedAt.addingTimeInterval(1)))
        #expect(!UpNextPlanner.isNew(last: finished, seriesChangedAt: finishedAt))
        #expect(!UpNextPlanner.isNew(last: finished, seriesChangedAt: finishedAt.addingTimeInterval(-86_400)))
        #expect(!UpNextPlanner.isNew(last: finished, seriesChangedAt: nil))

        let unfinished = Fixture.episodeProgress(1, 3, watched: false, updatedAt: finishedAt)
        #expect(!UpNextPlanner.isNew(last: unfinished, seriesChangedAt: finishedAt.addingTimeInterval(86_400)))
    }
}

@Suite struct UpNextItemTests {
    let episodes: [CatalogEpisode] = [
        Fixture.episode(1, 1, title: "Pilot"),
        Fixture.episode(1, 2, title: "Episode 2"),
        Fixture.episode(1, 3, title: "Low Tide"),
    ]

    @Test func resumingCarriesThePositionAndProgress() {
        let last = Fixture.episodeProgress(1, 2, position: 600, duration: 2400)
        let item = UpNextItem.make(series: Fixture.series(), pick: .resume(episodes[1], position: 600), last: last, episodes: episodes)
        #expect(item.resumePosition == 600)
        #expect(item.progress == 0.25)
        #expect(item.isNew == false)
        #expect(item.episodeKey == episodes[1].key.rawValue)
        #expect(item.queue == [episodes[2].key.rawValue])
        #expect(item.badge == "S1 E2")
        #expect(item.caption == "Episode 2")
    }

    @Test func resumingWithoutADurationHasNoProgressBar() {
        let last = Fixture.episodeProgress(1, 2, position: 600, duration: 0)
        let item = UpNextItem.make(series: Fixture.series(), pick: .resume(episodes[1], position: 600), last: last, episodes: episodes)
        #expect(item.resumePosition == 600)
        #expect(item.progress == nil)
    }

    @Test func aClearedPositionStartsAgainFromTheTop() {
        let last = Fixture.episodeProgress(1, 2, position: 0, duration: 2400)
        let item = UpNextItem.make(series: Fixture.series(), pick: .resume(episodes[1], position: 0), last: last, episodes: episodes)
        #expect(item.resumePosition == nil)
        #expect(item.progress == nil)
        #expect(item.playIntent.startPosition == nil)
    }

    @Test func theNextEpisodeIsMarkedNewWhenTheShowChanged() {
        let last = Fixture.episodeProgress(1, 2, watched: true, updatedAt: Fixture.reference)
        let changed = Fixture.series(addedAt: Fixture.reference.addingTimeInterval(3600))
        let item = UpNextItem.make(series: changed, pick: .next(episodes[2]), last: last, episodes: episodes)
        #expect(item.isNew)
        #expect(item.badge == "New · S1 E3")
        #expect(item.caption == "Low Tide")
        #expect(item.resumePosition == nil)
        #expect(item.queue.isEmpty)

        let unchanged = Fixture.series(addedAt: Fixture.reference.addingTimeInterval(-3600))
        #expect(!UpNextItem.make(series: unchanged, pick: .next(episodes[2]), last: last, episodes: episodes).isNew)
    }

    @Test func oneTilePerShow() {
        let series = Fixture.series()
        let item = UpNextItem.make(series: series, pick: .next(episodes[0]), last: Fixture.episodeProgress(1, 1, watched: true), episodes: episodes)
        #expect(item.id == series.key.rawValue)
        #expect(item.seriesName == "The Lighthouse")
        #expect(item.posterURL == Fixture.seriesPoster)
    }

    @Test func playIntentPlaysTheEpisodeWithItsQueue() {
        let last = Fixture.episodeProgress(1, 1, position: 120, duration: 2400)
        let item = UpNextItem.make(series: Fixture.series(), pick: .resume(episodes[0], position: 120), last: last, episodes: episodes)
        let intent = item.playIntent
        #expect(intent.kind == .episode)
        #expect(intent.itemKey == episodes[0].key.rawValue)
        #expect(intent.title == "The Lighthouse")
        #expect(intent.subtitle == "S1 · E1 — Pilot")
        #expect(intent.artworkURL == Fixture.seriesPoster)
        #expect(intent.startPosition == 120)
        #expect(intent.queue == [episodes[1].key.rawValue, episodes[2].key.rawValue])
    }
}
