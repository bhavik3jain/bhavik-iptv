import CatalogKit
import Foundation
import HouseholdKit
import Testing
@testable import LibraryFeature

private func codes(_ episodes: [CatalogEpisode]) -> [String] {
    episodes.map { "\($0.season).\($0.number)" }
}

@Suite struct SeasonGroupingTests {
    let grouping = SeasonGrouping([
        Fixture.episode(2, 2), Fixture.episode(1, 2), Fixture.episode(0, 1, title: "Christmas special"),
        Fixture.episode(1, 1), Fixture.episode(2, 1),
    ])

    @Test func seasonsAscendWithSpecialsLast() {
        #expect(grouping.seasonNumbers == [1, 2, 0])
        #expect(grouping.seasons.map(\.id) == [1, 2, 0])
    }

    @Test func episodesAreInNumberOrderWithinASeason() {
        #expect(grouping.season(1).map { codes($0.episodes) } == ["1.1", "1.2"])
        #expect(grouping.season(2).map { codes($0.episodes) } == ["2.1", "2.2"])
        #expect(grouping.season(7) == nil)
    }

    @Test func watchingOrderIsSeasonBySeasonThenSpecials() {
        #expect(codes(grouping.orderedEpisodes) == ["1.1", "1.2", "2.1", "2.2", "0.1"])
    }

    @Test func specialsAreNotCountedAsASeason() {
        #expect(grouping.numberedSeasonCount == 2)
        #expect(SeasonGrouping([Fixture.episode(0, 1), Fixture.episode(0, 2)]).numberedSeasonCount == 0)
    }

    @Test func noEpisodesNoSeasons() {
        let empty = SeasonGrouping([])
        #expect(empty.seasons.isEmpty && empty.orderedEpisodes.isEmpty && empty.numberedSeasonCount == 0)
    }

    @Test func aRepeatedEpisodeNumberIsOrderedByTitle() {
        let doubled = SeasonGrouping([Fixture.episode(1, 1, title: "Part B"), Fixture.episode(1, 1, title: "Part A")])
        #expect(doubled.orderedEpisodes.map(\.title) == ["Part A", "Part B"])
    }

    @Test func seasonTitles() {
        #expect(grouping.season(0)?.title == "Specials")
        #expect(grouping.season(2)?.title == "Season 2")
    }

    @Test func seasonOrderPutsZeroAfterEverything() {
        #expect(SeasonGrouping.seasonOrder(1, 2))
        #expect(!SeasonGrouping.seasonOrder(2, 1))
        #expect(SeasonGrouping.seasonOrder(9, 0))
        #expect(!SeasonGrouping.seasonOrder(0, 1))
        #expect(!SeasonGrouping.seasonOrder(0, 0))
        #expect(!SeasonGrouping.seasonOrder(3, 3))
    }

    @Test func upNextFollowsTheWatchingOrderAcrossSeasons() {
        let keys = grouping.keys(following: Fixture.episode(1, 2).key)
        #expect(keys == [Fixture.episode(2, 1).key, Fixture.episode(2, 2).key, Fixture.episode(0, 1).key])
    }

    @Test func upNextIsCapped() {
        #expect(grouping.keys(following: Fixture.episode(1, 1).key, limit: 2) == [Fixture.episode(1, 2).key, Fixture.episode(2, 1).key])
        let soap = SeasonGrouping((1...900).map { Fixture.episode(1, $0) })
        #expect(soap.keys(following: Fixture.episode(1, 1).key).count == 50)
    }

    @Test func upNextAfterTheLastOrAnUnknownEpisodeIsEmpty() {
        #expect(grouping.keys(following: Fixture.episode(0, 1).key).isEmpty)
        #expect(grouping.keys(following: Fixture.episode(5, 5).key).isEmpty)
    }
}

@Suite struct ShowPlayTargetTests {
    let s1e1 = Fixture.episode(1, 1)
    let s1e2 = Fixture.episode(1, 2)
    let s1e3 = Fixture.episode(1, 3)
    let s2e1 = Fixture.episode(2, 1)
    var episodes: [CatalogEpisode] { [s1e1, s1e2, s1e3, s2e1] }

    private func choose(_ rows: [ProgressRecord], episodes: [CatalogEpisode]? = nil) -> ShowPlayTarget? {
        ShowPlayTarget.choose(episodes: episodes ?? self.episodes, progress: Dictionary(uniqueKeysWithValues: rows.map { ($0.itemKey, $0) }))
    }

    @Test func aShowWithNoEpisodesHasNoTarget() {
        #expect(ShowPlayTarget.choose(episodes: [], progress: [:]) == nil)
    }

    @Test func aNewShowPlaysTheFirstEpisode() {
        let target = choose([])
        #expect(target == ShowPlayTarget(episode: s1e1, action: .play))
        #expect(target?.title == "Play S1 E1")
        #expect(target?.spokenTitle == "Play Season 1, episode 1")
        #expect(target?.startPosition == 0)
    }

    @Test func anUnfinishedEpisodeIsResumed() {
        let target = choose([Fixture.progress(s1e2, position: 600, minutesAgo: 5)])
        #expect(target == ShowPlayTarget(episode: s1e2, action: .resume(600)))
        #expect(target?.title == "Resume S1 E2")
        #expect(target?.spokenTitle == "Resume Season 1, episode 2")
        #expect(target?.startPosition == 600)
    }

    @Test func aFalseStartPlaysFromTheTop() {
        #expect(choose([Fixture.progress(s1e2, position: 9, minutesAgo: 5)]) == ShowPlayTarget(episode: s1e2, action: .play))
        #expect(choose([Fixture.progress(s1e2, position: 10, minutesAgo: 5)]) == ShowPlayTarget(episode: s1e2, action: .resume(10)))
    }

    @Test func afterAFinishedEpisodeTheNextUnwatchedOnePlays() {
        let target = choose([Fixture.progress(s1e2, position: 2_700, watched: true, minutesAgo: 5)])
        #expect(target == ShowPlayTarget(episode: s1e3, action: .play))
    }

    @Test func watchedEpisodesAheadAreSkipped() {
        let target = choose([
            Fixture.progress(s1e2, position: 2_700, watched: true, minutesAgo: 5),
            Fixture.progress(s1e3, position: 2_700, watched: true, minutesAgo: 60),
        ])
        #expect(target == ShowPlayTarget(episode: s2e1, action: .play))
    }

    @Test func theNextEpisodeResumesWhereAnEarlierVisitLeftIt() {
        let target = choose([
            Fixture.progress(s1e2, position: 2_700, watched: true, minutesAgo: 5),
            Fixture.progress(s1e3, position: 300, minutesAgo: 600),
        ])
        #expect(target == ShowPlayTarget(episode: s1e3, action: .resume(300)))
    }

    @Test func afterTheLastEpisodeTheFirstUnwatchedOneAnywherePlays() {
        let target = choose([
            Fixture.progress(s1e1, position: 2_700, watched: true, minutesAgo: 600),
            Fixture.progress(s2e1, position: 2_700, watched: true, minutesAgo: 5),
        ])
        #expect(target == ShowPlayTarget(episode: s1e2, action: .play))
    }

    @Test func theMostRecentlyTouchedRowDecidesNotTheEpisodeOrder() {
        let target = choose([
            Fixture.progress(s1e3, position: 2_700, watched: true, minutesAgo: 60),
            Fixture.progress(s1e1, position: 400, minutesAgo: 1),
        ])
        #expect(target == ShowPlayTarget(episode: s1e1, action: .resume(400)))
    }

    @Test func everythingWatchedStartsAgain() {
        let target = choose(episodes.enumerated().map { index, episode in Fixture.progress(episode, position: 2_700, watched: true, minutesAgo: Double(index)) })
        #expect(target == ShowPlayTarget(episode: s1e1, action: .playAgain))
        #expect(target?.title == "Play again")
        #expect(target?.spokenTitle == "Play again from Season 1, episode 1")
        #expect(target?.startPosition == 0)
    }

    @Test func afterTheFinalSeasonSpecialsComeNext() {
        let special = Fixture.episode(0, 1)
        let ordered = SeasonGrouping([special, s1e1, s1e2]).orderedEpisodes
        let target = choose([Fixture.progress(s1e2, position: 2_700, watched: true, minutesAgo: 5)], episodes: ordered)
        #expect(target == ShowPlayTarget(episode: special, action: .play))
    }
}

@Suite struct MoviePlayStateTests {
    @Test func notStartedPlays() {
        let state = MoviePlayState(progress: nil)
        #expect(state.action == .play)
        #expect(state.fraction == nil && state.remaining == nil)
        #expect(state.title == "Play")
        #expect(state.spokenTitle == "Play")
        #expect(state.startPosition == 0)
        #expect(!state.isResumable)
    }

    @Test func startedResumesWithItsBarAndTimeLeft() {
        let state = MoviePlayState(progress: Fixture.movieRow(position: 2_472, duration: 6_720))
        #expect(state.action == .resume(2_472))
        #expect(state.title == "Resume 41:12")
        #expect(state.spokenTitle.hasPrefix("Resume from "))
        #expect(state.startPosition == 2_472)
        #expect(state.isResumable)
        #expect(state.remaining == 4_248)
        #expect(abs((state.fraction ?? 0) - 2_472.0 / 6_720.0) < 1e-9)
    }

    @Test func underTenSecondsIsAFalseStart() {
        #expect(MoviePlayState(progress: Fixture.movieRow(position: 9.9, duration: 6_000)).action == .play)
        #expect(MoviePlayState(progress: Fixture.movieRow(position: 10, duration: 6_000)).action == .resume(10))
        #expect(MoviePlayState.minimumResume == 10)
    }

    @Test func ninetyFivePercentIsWatchedEvenWithoutTheFlag() {
        #expect(MoviePlayState(progress: Fixture.movieRow(position: 950, duration: 1_000)).action == .playAgain)
        #expect(MoviePlayState(progress: Fixture.movieRow(position: 949, duration: 1_000)).action == .resume(949))
    }

    @Test func theWatchedFlagWins() {
        let state = MoviePlayState(progress: Fixture.movieRow(position: 0, duration: 6_000, watched: true))
        #expect(state.action == .playAgain)
        #expect(state.title == "Play again")
        #expect(state.fraction == nil && state.remaining == nil)
        #expect(state.startPosition == 0)
        #expect(!state.isResumable)
    }

    @Test func anUnknownLengthResumesWithoutABar() {
        let state = MoviePlayState(progress: Fixture.movieRow(position: 600, duration: 0))
        #expect(state.action == .resume(600))
        #expect(state.fraction == nil)
        #expect(state.remaining == nil)
    }
}

@Suite struct HouseholdShowLineTests {
    let anya = UUID(uuidString: "00000000-0000-0000-0000-00000000A0A0")!

    @Test(arguments: [
        // (other season, episode, my season, episode, relation)
        (3, 1, 3, 1, HouseholdShowLine.Relation.sameEpisode),
        (3, 2, 3, 1, .ahead),
        (3, 1, 3, 2, .behind),
        (4, 1, 3, 9, .ahead),
        (2, 9, 3, 1, .behind),
        // Specials count after every season, as the picker orders them.
        (0, 1, 3, 1, .ahead),
        (3, 1, 0, 1, .behind),
        (0, 2, 0, 1, .ahead),
    ])
    func relation(otherSeason: Int, otherEpisode: Int, mySeason: Int, myEpisode: Int, expected: HouseholdShowLine.Relation) {
        #expect(HouseholdShowLine.relation(of: (otherSeason, otherEpisode), to: (mySeason, myEpisode)) == expected)
    }

    @Test func myLineSaysTimeLeft() throws {
        let line = try #require(HouseholdShowLine.mine(id: anya, progress: Fixture.row(season: 3, episode: 1)))
        #expect(line.name == "You")
        #expect(line.isCurrentProfile)
        #expect(line.episodeCode == "S3 E1")
        #expect(line.trailing == "31 min left")
    }

    @Test func aRowWithoutAnEpisodeMakesNoLine() {
        #expect(HouseholdShowLine.mine(id: anya, progress: Fixture.row(season: nil, episode: 1)) == nil)
        #expect(HouseholdShowLine.other(id: anya, name: "Anya", progress: Fixture.row(season: 3, episode: nil), mine: nil) == nil)
    }

    @Test func someoneElseIsComparedWithYou() throws {
        let mine = Fixture.row(season: 3, episode: 1)
        let ahead = try #require(HouseholdShowLine.other(id: anya, name: "Anya", progress: Fixture.row(season: 3, episode: 3), mine: mine))
        #expect(ahead.trailing == "ahead of you")
        #expect(!ahead.isCurrentProfile)
        #expect(ahead.spokenText == "Anya, Season 3, episode 3, ahead of you")
        #expect(HouseholdShowLine.other(id: anya, name: "Anya", progress: Fixture.row(season: 2, episode: 8), mine: mine)?.trailing == "behind you")
        #expect(HouseholdShowLine.other(id: anya, name: "Anya", progress: Fixture.row(season: 3, episode: 1, watched: true), mine: mine)?.trailing == "same episode")
    }

    @Test func withoutYourOwnPlaceItSaysHowFarTheyAre() {
        let theirs = Fixture.row(season: 3, episode: 3)
        #expect(HouseholdShowLine.other(id: anya, name: "Anya", progress: theirs, mine: nil)?.trailing == "31 min left")
        // A row of yours with no episode (as a Guest sees it) is no place.
        #expect(HouseholdShowLine.other(id: anya, name: "Anya", progress: theirs, mine: Fixture.row(season: nil, episode: nil))?.trailing == "31 min left")
    }

    @Test func stateOfAnEpisode() {
        #expect(HouseholdShowLine.state(of: Fixture.row(season: 1, episode: 1, position: 0, watched: true)) == "watched")
        #expect(HouseholdShowLine.state(of: Fixture.row(season: 1, episode: 1, position: 9)) == "up next")
        #expect(HouseholdShowLine.state(of: Fixture.row(season: 1, episode: 1, position: 600, duration: 2_460)) == "31 min left")
        #expect(HouseholdShowLine.state(of: Fixture.row(season: 1, episode: 1, position: 600, duration: 0)) == "started")
    }
}
