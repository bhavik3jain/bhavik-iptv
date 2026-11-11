import CatalogKit
import Core
import Foundation
import HouseholdKit
import SourceKit
import Testing
@testable import LibraryFeature

/// "Continue watching" at the top of Movies and Shows (the owner,
/// 2026-11-10, "like Netflix does").
@Suite struct ContinueWatchingRowTests {
    private func movieRow(_ id: String, position: TimeInterval, duration: TimeInterval = 6_000, watched: Bool = false, minutesAgo: Double = 0) -> ProgressRecord {
        ProgressRecord(profileID: Fixture.profile, itemKey: ItemKey.movie(source: Fixture.sourceA, id: id).rawValue, kind: .movie,
                       position: position, duration: duration, watched: watched, updatedAt: Fixture.now.addingTimeInterval(-minutesAgo * 60))
    }

    private func movies(_ ids: [String]) -> (ItemKey) -> CatalogMovie? {
        { key in ids.contains(key.remoteID ?? "") ? Fixture.movie(key.remoteID!, name: "Film \(key.remoteID!)") : nil }
    }

    // MARK: Movies

    @Test func startedMoviesInTheOrderTheyWereWatched() {
        let rows = [movieRow("a", position: 1_200, minutesAgo: 1), movieRow("b", position: 3_000, minutesAgo: 30)]
        let cards = LibraryContinue.movies(rows, movie: movies(["a", "b"]))
        #expect(cards.map(\.title) == ["Film a", "Film b"])
        #expect(cards[0].progress == 0.2)
        #expect(cards[0].caption == LibraryFormat.remaining(4_800))
        #expect(cards[0].playIntent?.startPosition == 1_200)
        #expect(cards[0].playIntent?.kind == .movie)
        #expect(cards[0].route == .movie(itemKey: rows[0].itemKey))
        #expect(cards[0].isMovie)
    }

    @Test func falseStartsFinishedFilmsAndEpisodesStayOff() {
        let episode = Fixture.progress(Fixture.episode(1, 2), position: 900, minutesAgo: 2)
        let rows = [
            movieRow("a", position: 4, minutesAgo: 1),
            movieRow("b", position: 5_900, watched: true, minutesAgo: 3),
            episode,
            movieRow("c", position: 600, minutesAgo: 4),
        ]
        #expect(LibraryContinue.movies(rows, movie: movies(["a", "b", "c"])).map(\.title) == ["Film c"])
    }

    /// The catalog lookup goes through the profile's filter: a film it hides
    /// (or this device doesn't hold) isn't a dead card.
    @Test func aMovieTheCatalogDoesntGiveIsLeftOut() {
        let rows = [movieRow("hidden", position: 600), movieRow("c", position: 600)]
        #expect(LibraryContinue.movies(rows, movie: movies(["c"])).map(\.title) == ["Film c"])
    }

    @Test func theRowStopsAtItsLimit() {
        let rows = (0..<30).map { movieRow("m\($0)", position: 600, minutesAgo: Double($0)) }
        #expect(LibraryContinue.movies(rows, movie: movies(rows.map { ItemKey(rawValue: $0.itemKey).remoteID! })).count == LibraryContinue.limit)
    }

    // MARK: Shows

    private let show = Fixture.series("lighthouse", name: "Lighthouse")
    private var episodes: [CatalogEpisode] { [Fixture.episode(1, 1), Fixture.episode(1, 2, title: "Undertow"), Fixture.episode(2, 1)] }

    private func shows(_ latest: [ProgressRecord], all: [ProgressRecord], cached: Bool = true) -> (cards: [ContinueCard], needingEpisodes: [CatalogSeries]) {
        let episodes = self.episodes
        return LibraryContinue.shows(
            latest,
            series: { $0 == Fixture.seriesKey ? show : nil },
            episodes: { _ in cached ? episodes : [] },
            progress: { _ in Dictionary(all.map { ($0.itemKey, $0) }, uniquingKeysWith: { first, _ in first }) }
        )
    }

    @Test func anUnfinishedEpisodeResumes() throws {
        let row = Fixture.progress(Fixture.episode(1, 2), position: 1_350, minutesAgo: 5)
        let card = try #require(shows([row], all: [row]).cards.first)
        #expect(card.title == "Lighthouse")
        #expect(card.caption == "Resume S1 E2")
        #expect(card.progress == 0.5)
        #expect(card.playIntent?.itemKey == Fixture.episode(1, 2).key.rawValue)
        #expect(card.playIntent?.startPosition == 1_350)
        #expect(card.playIntent?.subtitle == "S1 E2 — Undertow")
        #expect(card.playIntent?.queue == [Fixture.episode(2, 1).key.rawValue])
        #expect(card.route == .series(itemKey: Fixture.seriesKey.rawValue))
        #expect(card.episodeCode == "S1 E2")
    }

    @Test func aFinishedEpisodeGoesOnToTheNext() throws {
        let row = Fixture.progress(Fixture.episode(1, 2), position: 2_700, watched: true, minutesAgo: 5)
        let card = try #require(shows([row], all: [row]).cards.first)
        #expect(card.caption == "Play S2 E1")
        #expect(card.progress == nil)
        #expect(card.playIntent?.itemKey == Fixture.episode(2, 1).key.rawValue)
        #expect(card.playIntent?.startPosition == 0)
    }

    @Test func aShowCaughtUpLeavesTheRow() {
        let all = episodes.enumerated().map { Fixture.progress($1, position: 2_700, watched: true, minutesAgo: Double(10 - $0)) }
        #expect(shows([all.last!], all: all).cards.isEmpty)
    }

    /// Progress from another device, before this one cached the episodes:
    /// the card shows where the row is and opens the show, and the show's
    /// episodes are asked for.
    @Test func aShowWithoutCachedEpisodesOpensTheShowAndAsksForThem() throws {
        let row = Fixture.progress(Fixture.episode(1, 2), position: 1_350, minutesAgo: 5)
        let result = shows([row], all: [row], cached: false)
        let card = try #require(result.cards.first)
        #expect(card.caption == "Resume S1 E2")
        #expect(card.progress == 0.5)
        #expect(card.playIntent == nil)
        #expect(result.needingEpisodes.map(\.key) == [Fixture.seriesKey])
    }

    @Test func aShowTheCatalogDoesntGiveIsLeftOut() {
        var row = Fixture.progress(Fixture.episode(1, 2), position: 1_350, minutesAgo: 5)
        row.seriesKey = ItemKey.series(source: Fixture.sourceA, id: "gone").rawValue
        let result = shows([row], all: [row])
        #expect(result.cards.isEmpty)
        #expect(result.needingEpisodes.isEmpty)
    }
}
