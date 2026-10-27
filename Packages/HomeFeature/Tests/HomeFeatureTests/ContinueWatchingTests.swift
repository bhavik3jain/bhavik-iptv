import CatalogKit
import Core
import Foundation
import HouseholdKit
import Testing
@testable import HomeFeature

@Suite struct ContinueItemTests {
    @Test func movieTakesTheRowsPositionAndDuration() {
        let poster = URL(string: "https://example.com/film.jpg")!
        let item = ContinueItem.movie(Fixture.movie(duration: 9000, poster: poster), progress: Fixture.movieProgress(position: 1800, duration: 7200))
        #expect(item.kind == .movie)
        #expect(item.title == "Harbour Lights")
        #expect(item.subtitle == "2019 · Drama")
        #expect(item.posterURL == poster)
        #expect(item.backdropURL == nil)
        #expect(item.position == 1800)
        #expect(item.duration == 7200)
        #expect(item.seriesKey == nil)
        #expect(item.queue.isEmpty)
        #expect(item.id == Fixture.movieProgress(position: 0, duration: 0).itemKey)
    }

    @Test func movieFallsBackToTheCatalogsDurationThenZero() {
        let fromCatalog = ContinueItem.movie(Fixture.movie(duration: 5400), progress: Fixture.movieProgress(position: 60, duration: 0))
        #expect(fromCatalog.duration == 5400)
        let unknown = ContinueItem.movie(Fixture.movie(duration: nil), progress: Fixture.movieProgress(position: 60, duration: 0))
        #expect(unknown.duration == 0)
        #expect(unknown.progress == nil)
        #expect(unknown.remainingText == nil)
    }

    @Test func progressIsClamped() {
        var item = ContinueItem.movie(Fixture.movie(), progress: Fixture.movieProgress(position: 1800, duration: 7200))
        #expect(item.progress == 0.25)
        item.position = 9000
        #expect(item.progress == 1)
        item.position = -10
        #expect(item.progress == 0)
    }

    @Test func remainingTextNeverGoesNegative() {
        var item = ContinueItem.movie(Fixture.movie(), progress: Fixture.movieProgress(position: 3000, duration: 5400))
        #expect(item.remainingText == "40 min left")
        item.position = 6000
        #expect(item.remainingText == "0 min left")
    }

    @Test func tappingAMovieOpensTheMovie() {
        let item = ContinueItem.movie(Fixture.movie(), progress: Fixture.movieProgress(position: 60, duration: 600))
        #expect(item.route == .movie(itemKey: item.itemKey))
    }

    @Test func moviePlayIntentResumesWithThePoster() {
        let poster = URL(string: "https://example.com/film.jpg")!
        let item = ContinueItem.movie(Fixture.movie(poster: poster), progress: Fixture.movieProgress(position: 1200, duration: 6000))
        let intent = item.playIntent
        #expect(intent.kind == .movie)
        #expect(intent.itemKey == item.itemKey)
        #expect(intent.title == "Harbour Lights")
        #expect(intent.subtitle == "2019 · Drama")
        #expect(intent.artworkURL == poster)
        #expect(intent.startPosition == 1200)
        #expect(intent.queue.isEmpty)
    }

    @Test func episodeOpensItsShowAndQueuesWhatFollows() {
        let series = Fixture.series()
        let episode = Fixture.episode(2, 5, title: "The Lighthouse Keeper", duration: 2700, poster: Fixture.stillA)
        let queue = [Fixture.episodeKey(2, 6).rawValue]
        let item = ContinueItem.episode(series: series, episode: episode, season: 2, number: 5, progress: Fixture.episodeProgress(2, 5, position: 900, duration: 0), queue: queue)

        #expect(item.kind == .episode(season: 2, number: 5))
        #expect(item.title == "The Lighthouse")
        #expect(item.subtitle == "S2 · E5 — The Lighthouse Keeper")
        #expect(item.backdropURL == Fixture.stillA)
        #expect(item.posterURL == Fixture.seriesPoster)
        #expect(item.duration == 2700)
        #expect(item.seriesKey == series.key.rawValue)
        #expect(item.route == .series(itemKey: series.key.rawValue))

        let intent = item.playIntent
        #expect(intent.kind == .episode)
        #expect(intent.artworkURL == Fixture.stillA)
        #expect(intent.startPosition == 900)
        #expect(intent.queue == queue)
    }

    @Test func anEpisodeStillThatIsJustTheShowPosterIsNoBackdrop() {
        let series = Fixture.series()
        let episode = Fixture.episode(1, 1, poster: Fixture.seriesPoster)
        let item = ContinueItem.episode(series: series, episode: episode, season: 1, number: 1, progress: Fixture.episodeProgress(1, 1), queue: [])
        #expect(item.backdropURL == nil)
        // The player falls back to the show's poster.
        #expect(item.playIntent.artworkURL == Fixture.seriesPoster)
    }

    @Test func anEpisodeNotCachedHereStillShowsTheShowAndCode() {
        let item = ContinueItem.episode(series: Fixture.series(), episode: nil, season: 3, number: 2, progress: Fixture.episodeProgress(3, 2, duration: 0), queue: [])
        #expect(item.subtitle == "S3 · E2")
        #expect(item.backdropURL == nil)
        #expect(item.duration == 0)
        #expect(item.progress == nil)
    }

    @Test func movieSubtitleUsesTheYearAndFirstGenre() {
        #expect(ContinueItem.movieSubtitle(Fixture.movie(year: 2019, genre: "Drama")) == "2019 · Drama")
        #expect(ContinueItem.movieSubtitle(Fixture.movie(year: 2019, genre: "Drama, Thriller")) == "2019 · Drama")
        #expect(ContinueItem.movieSubtitle(Fixture.movie(year: nil, genre: "Action / Adventure")) == "Action")
        #expect(ContinueItem.movieSubtitle(Fixture.movie(year: nil, genre: "Comedy|Romance")) == "Comedy")
        #expect(ContinueItem.movieSubtitle(Fixture.movie(year: nil, genre: ", Horror")) == "Horror")
        #expect(ContinueItem.movieSubtitle(Fixture.movie(year: 2001, genre: nil)) == "2001")
        #expect(ContinueItem.movieSubtitle(Fixture.movie(year: 2001, genre: "   ")) == "2001")
        #expect(ContinueItem.movieSubtitle(Fixture.movie(year: nil, genre: "")) == nil)
        #expect(ContinueItem.movieSubtitle(Fixture.movie(year: nil, genre: nil)) == nil)
    }
}

@Suite struct ContinueWatchingPickerTests {
    private func item(for row: ProgressRecord) -> ContinueItem {
        ContinueItem.movie(Fixture.movie(), progress: row)
    }

    @Test func picksTheFirstUnfinishedRowThatResolves() {
        let rows = [
            Fixture.movieProgress("a", position: 100, duration: 1000),
            Fixture.movieProgress("b", position: 200, duration: 1000),
        ]
        let picked = ContinueWatchingPicker.pick(rows) { item(for: $0) }
        #expect(picked?.itemKey == rows[0].itemKey)
    }

    @Test func skipsWatchedRowsAndRowsNeverStarted() {
        let rows = [
            Fixture.movieProgress("watched", position: 900, duration: 1000, watched: true),
            Fixture.movieProgress("unstarted", position: 0, duration: 1000),
            Fixture.movieProgress("current", position: 300, duration: 1000),
        ]
        var asked: [String] = []
        let picked = ContinueWatchingPicker.pick(rows) { row in
            asked.append(row.itemKey)
            return item(for: row)
        }
        #expect(picked?.itemKey == rows[2].itemKey)
        // Rows that can't be the hero are never resolved against the catalog.
        #expect(asked == [rows[2].itemKey])
    }

    @Test func skipsRowsTheCatalogNoLongerHas() {
        let rows = [
            Fixture.movieProgress("gone", position: 100, duration: 1000),
            Fixture.movieProgress("hidden", position: 100, duration: 1000),
            Fixture.movieProgress("here", position: 100, duration: 1000),
        ]
        let picked = ContinueWatchingPicker.pick(rows) { row in
            row.itemKey == rows[2].itemKey ? item(for: row) : nil
        }
        #expect(picked?.itemKey == rows[2].itemKey)
    }

    @Test func nothingToContinue() {
        #expect(ContinueWatchingPicker.pick([]) { item(for: $0) } == nil)
        let rows = [Fixture.movieProgress(position: 100, duration: 1000)]
        #expect(ContinueWatchingPicker.pick(rows) { _ in nil } == nil)
    }
}
