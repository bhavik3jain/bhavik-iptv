import CatalogKit
import Core
import Foundation
import HouseholdKit
import SourceKit
import Testing
@testable import LibraryFeature

@Suite struct MetaLineTests {
    @Test func aMovieLineHasYearGenreLengthRatingAndSource() throws {
        let rating = try #require(MetaLine.ratingText(7.4))
        #expect(MetaLine.movie(Fixture.movie(genre: "Drama, Thriller")) == ["2024", "Drama", "1 h 52 min", rating, "from Provider B"])
    }

    @Test func missingOrEmptyPiecesAreLeftOut() {
        let bare = Fixture.movie(year: 0, genre: " , ", duration: 0, rating: 0, sourceName: "   ")
        #expect(MetaLine.movie(bare).isEmpty)
        let nils = Fixture.movie(year: nil, genre: nil, duration: nil, rating: nil, sourceName: "")
        #expect(MetaLine.movie(nils).isEmpty)
    }

    @Test func theSourceNameIsTrimmed() {
        #expect(MetaLine.parts(year: nil, genre: nil, middle: nil, rating: nil, sourceName: "  Provider B \n") == ["from Provider B"])
    }

    @Test func aShowLineCountsSeasons() {
        let show = Fixture.series(genre: "Drama/Mystery")
        #expect(MetaLine.series(show, seasonCount: 3) == ["2024", "Drama", "3 seasons", "from Provider B"])
        #expect(MetaLine.series(show, seasonCount: 1) == ["2024", "Drama", "1 season", "from Provider B"])
        #expect(MetaLine.series(show, seasonCount: 0) == ["2024", "Drama", "from Provider B"])
        #expect(MetaLine.series(show, seasonCount: nil) == ["2024", "Drama", "from Provider B"])
    }

    @Test func joinedForTheEyeAndSpokenWithCommas() {
        #expect(MetaLine.joined(["2024", "Drama", "1 h 52 min"]) == "2024 · Drama · 1 h 52 min")
        #expect(MetaLine.spoken(["2024", "Drama", "1 h 52 min"]) == "2024, Drama, 1 h 52 min")
        #expect(MetaLine.joined([]) == "")
    }

    @Test func genresSplitOnEverySeparatorProvidersUse() {
        #expect(MetaLine.allGenres("Drama, Thriller / Crime|War;  ;Comedy") == ["Drama", "Thriller", "Crime", "War", "Comedy"])
        #expect(MetaLine.allGenres(nil).isEmpty)
        #expect(MetaLine.allGenres("").isEmpty)
        #expect(MetaLine.primaryGenre(" / Sci-Fi, Drama") == "Sci-Fi")
        #expect(MetaLine.primaryGenre(nil) == nil)
    }

    @Test func noRatingForMissingZeroOrNegative() {
        #expect(MetaLine.ratingText(nil) == nil)
        #expect(MetaLine.ratingText(0) == nil)
        #expect(MetaLine.ratingText(-1) == nil)
    }

    @Test func ratingsBelowTenKeepOneDecimalAndTenHasNone() {
        // The decimal separator follows the locale; the precision is ours.
        #expect(MetaLine.ratingText(7) == "★ " + 7.0.formatted(.number.precision(.fractionLength(1))))
        #expect(MetaLine.ratingText(7.45)?.hasPrefix("★ 7") == true)
        #expect(MetaLine.ratingText(10) == "★ 10")
    }

    @Test func castIsTrimmedAndCapped() {
        #expect(MetaLine.castNames("Ana Ruiz, Ben Ode,, Cy Lam , ") == ["Ana Ruiz", "Ben Ode", "Cy Lam"])
        #expect(MetaLine.castNames(nil).isEmpty)
        let forty = (1...40).map { "Actor \($0)" }.joined(separator: ",")
        #expect(MetaLine.castNames(forty).count == 12)
        #expect(MetaLine.castNames(forty, limit: 3) == ["Actor 1", "Actor 2", "Actor 3"])
    }
}

@Suite struct PosterDecorationTests {
    let now = Fixture.now

    @Test func newMeansAddedInTheLastWeek() {
        #expect(!PosterDecoration.isNew(addedAt: nil, now: now))
        #expect(PosterDecoration.isNew(addedAt: now, now: now))
        #expect(PosterDecoration.isNew(addedAt: now.addingTimeInterval(-7 * 86_400 + 1), now: now))
        #expect(!PosterDecoration.isNew(addedAt: now.addingTimeInterval(-7 * 86_400), now: now))
        // A date in the future is a provider's clock, not news.
        #expect(!PosterDecoration.isNew(addedAt: now.addingTimeInterval(60), now: now))
    }

    @Test func aWatchedMovieSaysSoEvenWhenNew() {
        let decoration = PosterDecoration.movie(addedAt: now, progress: Fixture.movieRow(position: 6_000, duration: 6_000, watched: true), now: now)
        #expect(decoration == PosterDecoration(badge: "Watched", progress: nil))
    }

    @Test func aStartedMovieShowsItsBarInsteadOfABadge() {
        let decoration = PosterDecoration.movie(addedAt: now, progress: Fixture.movieRow(position: 1_500, duration: 6_000), now: now)
        #expect(decoration == PosterDecoration(badge: nil, progress: 0.25))
    }

    @Test func aFalseStartOrUnknownLengthFallsBackToNew() {
        #expect(PosterDecoration.movie(addedAt: now, progress: Fixture.movieRow(position: 5, duration: 6_000), now: now).badge == "New")
        #expect(PosterDecoration.movie(addedAt: now, progress: Fixture.movieRow(position: 600, duration: 0), now: now) == PosterDecoration(badge: "New", progress: nil))
        #expect(PosterDecoration.movie(addedAt: nil, progress: Fixture.movieRow(position: 5, duration: 6_000), now: now) == PosterDecoration(badge: nil, progress: nil))
    }

    @Test func anUntouchedMovieIsNewOrPlain() {
        #expect(PosterDecoration.movie(addedAt: now.addingTimeInterval(-86_400), progress: nil, now: now) == PosterDecoration(badge: "New", progress: nil))
        #expect(PosterDecoration.movie(addedAt: now.addingTimeInterval(-30 * 86_400), progress: nil, now: now) == PosterDecoration(badge: nil, progress: nil))
    }

    @Test func aShowNamesTheLatestEpisodeWithItsBar() {
        let decoration = PosterDecoration.series(addedAt: nil, latest: Fixture.row(season: 2, episode: 5, position: 1_230, duration: 2_460), now: now)
        #expect(decoration == PosterDecoration(badge: "S2 E5", progress: 0.5))
    }

    @Test func aFinishedOrUnstartedEpisodeHasNoBar() {
        #expect(PosterDecoration.series(addedAt: nil, latest: Fixture.row(season: 2, episode: 5, position: 2_460, duration: 2_460, watched: true), now: now) == PosterDecoration(badge: "S2 E5", progress: nil))
        #expect(PosterDecoration.series(addedAt: nil, latest: Fixture.row(season: 2, episode: 6, position: 0), now: now) == PosterDecoration(badge: "S2 E6", progress: nil))
        #expect(PosterDecoration.series(addedAt: nil, latest: Fixture.row(season: 2, episode: 6, position: 600, duration: 0), now: now).progress == nil)
    }

    @Test func aNewShowSaysNewWithOrWithoutAnEpisode() {
        #expect(PosterDecoration.series(addedAt: now, latest: Fixture.row(season: 3, episode: 3), now: now).badge == "New · S3 E3")
        #expect(PosterDecoration.series(addedAt: now, latest: nil, now: now) == PosterDecoration(badge: "New", progress: nil))
        // A row without an episode number counts as none.
        #expect(PosterDecoration.series(addedAt: now, latest: Fixture.row(season: 3, episode: nil), now: now) == PosterDecoration(badge: "New", progress: nil))
        #expect(PosterDecoration.series(addedAt: nil, latest: nil, now: now) == PosterDecoration(badge: nil, progress: nil))
    }
}

@Suite struct CategoryChipsTests {
    let names = [Fixture.sourceA: "Provider A", Fixture.sourceB: "Provider B"]

    @Test func allComesFirst() {
        let chips = CategoryChips(categories: [], sourceNames: names)
        #expect(chips.chips == [CategoryChips.Chip(categoryID: nil, title: "All")])
        #expect(chips.chips.first?.id == "")
    }

    @Test func groupedBySourceThenInTheProvidersOrder() {
        let chips = CategoryChips(categories: [
            Fixture.category("k", name: "Kids", source: Fixture.sourceB, sortOrder: 2),
            Fixture.category("a", name: "Action", source: Fixture.sourceA, sortOrder: 1),
            Fixture.category("b", name: "Action", source: Fixture.sourceB, sortOrder: 0),
            Fixture.category("d", name: "Drama", source: Fixture.sourceA, sortOrder: 0),
        ], sourceNames: names)
        #expect(chips.chips.map(\.title) == ["All", "Drama", "Action · Provider A", "Action · Provider B", "Kids"])
        #expect(chips.chips.dropFirst().map(\.categoryID) == [
            Fixture.category("d", name: "", source: Fixture.sourceA).id,
            Fixture.category("a", name: "", source: Fixture.sourceA).id,
            Fixture.category("b", name: "", source: Fixture.sourceB).id,
            Fixture.category("k", name: "", source: Fixture.sourceB).id,
        ])
    }

    @Test func sourcesAreOrderedByNameNotID() {
        let chips = CategoryChips(categories: [
            Fixture.category("1", name: "One", source: Fixture.sourceA),
            Fixture.category("2", name: "Two", source: Fixture.sourceB),
        ], sourceNames: [Fixture.sourceA: "Zeta", Fixture.sourceB: "Alpha"])
        #expect(chips.chips.map(\.title) == ["All", "Two", "One"])
    }

    @Test func equalSortOrdersFallBackToTheName() {
        let chips = CategoryChips(categories: [
            Fixture.category("2", name: "Western"),
            Fixture.category("1", name: "Comedy"),
        ], sourceNames: names)
        #expect(chips.chips.map(\.title) == ["All", "Comedy", "Western"])
    }

    @Test func aNameTwiceInOneSourceGetsNoSuffix() {
        let chips = CategoryChips(categories: [
            Fixture.category("1", name: "Action", sortOrder: 0),
            Fixture.category("2", name: "Action", sortOrder: 1),
        ], sourceNames: names)
        #expect(chips.chips.map(\.title) == ["All", "Action", "Action"])
    }

    @Test func namesMatchTheWaySearchDoes() {
        let chips = CategoryChips(categories: [
            Fixture.category("1", name: "  Sci-Fi ", source: Fixture.sourceA),
            Fixture.category("2", name: "sci fi", source: Fixture.sourceB),
        ], sourceNames: names)
        #expect(chips.chips.map(\.title) == ["All", "Sci-Fi · Provider A", "sci fi · Provider B"])
    }

    @Test func aStoredSelectionIsKeptOnlyWhileItsChipExists() {
        let drama = Fixture.category("d", name: "Drama")
        let chips = CategoryChips(categories: [drama], sourceNames: names)
        #expect(chips.validSelection(drama.id) == drama.id)
        #expect(chips.validSelection("gone") == nil)
        #expect(chips.validSelection(nil) == nil)
    }
}

@Suite struct GridPagingTests {
    @Test func startsWithOnePage() {
        let paging = GridPaging()
        #expect(paging.limit == 90)
        #expect(GridPaging.pageSize == 90)
    }

    @Test func moreMayExistOnlyWhenTheLastQueryFilledItsLimit() {
        let paging = GridPaging()
        #expect(!paging.hasMore(loaded: 0))
        #expect(!paging.hasMore(loaded: 89))
        #expect(paging.hasMore(loaded: 90))
    }

    @Test func growsAPageAtATimeAndResets() {
        var paging = GridPaging()
        paging.grow()
        paging.grow()
        #expect(paging.limit == 270)
        paging.reset()
        #expect(paging == GridPaging())
    }

    @Test func growsWhenATileWithinEighteenOfTheEndAppears() {
        let paging = GridPaging()
        #expect(!paging.shouldGrow(appearingIndex: 0, loaded: 90))
        #expect(!paging.shouldGrow(appearingIndex: 71, loaded: 90))
        #expect(paging.shouldGrow(appearingIndex: 72, loaded: 90))
        #expect(paging.shouldGrow(appearingIndex: 89, loaded: 90))
    }

    @Test func neverGrowsPastTheEndOfTheCatalog() {
        let paging = GridPaging()
        #expect(!paging.shouldGrow(appearingIndex: 60, loaded: 61))
        #expect(!paging.shouldGrow(appearingIndex: 0, loaded: 0))
    }

    @Test func theThresholdMovesWithTheLimit() {
        var paging = GridPaging()
        paging.grow()
        #expect(!paging.shouldGrow(appearingIndex: 89, loaded: 90))
        #expect(!paging.shouldGrow(appearingIndex: 161, loaded: 180))
        #expect(paging.shouldGrow(appearingIndex: 162, loaded: 180))
    }
}

@Suite struct ShelfStateTests {
    let a = Fixture.sourceA
    let b = Fixture.sourceB
    let refreshed = Fixture.now

    private func resolve(hasItems: Bool = false, categorySelected: Bool = false, sourceCount: Int = 1, states: [SourceRefreshState], offered: Int = 0) -> ShelfState {
        ShelfState.resolve(hasItems: hasItems, categorySelected: categorySelected, sourceCount: sourceCount, states: states, offeredCount: offered)
    }

    @Test func itemsAlwaysMeanContent() {
        #expect(resolve(hasItems: true, sourceCount: 0, states: []) == .content)
        #expect(resolve(hasItems: true, categorySelected: true, states: [SourceRefreshState(sourceID: a, phase: .failed(message: "x"))]) == .content)
    }

    @Test func noSourcesComesBeforeEverythingElse() {
        #expect(resolve(categorySelected: true, sourceCount: 0, states: [SourceRefreshState(sourceID: a, phase: .refreshing(progress: 0.5, message: "Loading"))]) == .noSources)
    }

    @Test func anEmptyCategoryIsSaidBeforeAnImport() {
        #expect(resolve(categorySelected: true, states: [SourceRefreshState(sourceID: a, phase: .refreshing(progress: nil, message: "Loading"))]) == .categoryEmpty)
    }

    @Test func anImportInProgressShowsTheFirstSourcesProgress() {
        let state = resolve(sourceCount: 2, states: [
            SourceRefreshState(sourceID: a, phase: .failed(message: "Login failed"), catalogRefreshedAt: refreshed),
            SourceRefreshState(sourceID: b, phase: .refreshing(progress: 0.4, message: "Movies 400 of 1,000")),
        ], offered: 12)
        #expect(state == .importing(message: "Movies 400 of 1,000", progress: 0.4))
    }

    @Test func titlesTheProfileHidesAreSaidToBeHidden() {
        let state = resolve(sourceCount: 2, states: [
            SourceRefreshState(sourceID: a, phase: .failed(message: "Login failed"), catalogRefreshedAt: refreshed),
            SourceRefreshState(sourceID: b, catalogRefreshedAt: refreshed),
        ], offered: 3)
        #expect(state == .hiddenByProfile)
    }

    @Test func aFailedImportNamesItsSource() {
        let state = resolve(sourceCount: 2, states: [
            SourceRefreshState(sourceID: a, catalogRefreshedAt: refreshed),
            SourceRefreshState(sourceID: b, phase: .failed(message: "Portal unreachable")),
        ])
        #expect(state == .failed(message: "Portal unreachable", sourceID: b))
    }

    @Test func aSourceNeverImportedOnThisDeviceIsStillLoading() {
        let state = resolve(sourceCount: 2, states: [
            SourceRefreshState(sourceID: a, catalogRefreshedAt: refreshed),
            SourceRefreshState(sourceID: b),
        ])
        #expect(state == .importing(message: "Waiting to load your sources…", progress: nil))
    }

    @Test func importedSourcesWithNoneOfThisKindOfferNone() {
        #expect(resolve(states: [SourceRefreshState(sourceID: a, catalogRefreshedAt: refreshed)]) == .noneOffered)
        // Sources counted but no refresh state yet reported.
        #expect(resolve(states: []) == .noneOffered)
    }
}

@Suite struct MyListEntryTests {
    let entry = GridEntry(movie: Fixture.movie(), index: 0)

    @Test func aTitleTheCatalogHoldsIsAvailable() {
        #expect(MyListEntry.status(found: entry, catalogContains: true, sourceImported: true) == .available(entry))
        #expect(MyListEntry.status(found: entry, catalogContains: false, sourceImported: false) == .available(entry))
    }

    @Test func aTitleThisProfileMayNotSeeIsLeftOff() {
        #expect(MyListEntry.status(found: nil, catalogContains: true, sourceImported: true) == nil)
        #expect(MyListEntry.status(found: nil, catalogContains: true, sourceImported: false) == nil)
    }

    @Test func aMissingTitleIsPendingUntilItsSourceHasImported() {
        #expect(MyListEntry.status(found: nil, catalogContains: false, sourceImported: false) == .pending)
        #expect(MyListEntry.status(found: nil, catalogContains: false, sourceImported: true) == .unavailable)
    }

    @Test func anEntryIsIdentifiedByItsFavorite() {
        let favorite = FavoriteRecord(profileID: Fixture.profile, itemKey: entry.id.rawValue, kind: .movie, sortOrder: 1, addedAt: Fixture.now)
        #expect(MyListEntry(favorite: favorite, status: .pending).id == favorite.id)
    }
}

@Suite struct GridEntryTests {
    @Test func aMovieEntryRoutesToTheMovie() {
        let movie = Fixture.movie(year: 2024)
        let entry = GridEntry(movie: movie, index: 4)
        #expect(entry.id == movie.key)
        #expect(entry.index == 4)
        #expect(entry.title == "The Long Night")
        #expect(entry.caption == "2024")
        #expect(entry.route == .movie(itemKey: movie.key.rawValue))
        #expect(entry.favoriteKind == .movie)
    }

    @Test func aShowEntryCarriesItsLatestRow() {
        let show = Fixture.series(year: nil)
        let latest = Fixture.row(season: 1, episode: 2)
        let entry = GridEntry(series: show, index: 0, latest: latest)
        #expect(entry.caption == nil)
        #expect(entry.kind == .series(latest: latest))
        #expect(entry.route == .series(itemKey: show.key.rawValue))
        #expect(entry.favoriteKind == .series)
    }

    @Test func shelvesMapToTheirKinds() {
        #expect(LibraryShelf.movies.contentKind == .vod && LibraryShelf.movies.favoriteKind == .movie)
        #expect(LibraryShelf.shows.contentKind == .series && LibraryShelf.shows.favoriteKind == .series)
        #expect(LibraryShelf.movies.title == "Movies" && LibraryShelf.shows.title == "Shows")
    }
}

@Suite struct LibraryFormatTests {
    static let timecodes: [(TimeInterval, String)] = [
        (0, "0:00"),
        (59.4, "0:59"),
        (59.6, "1:00"),
        (2_472, "41:12"),
        (3_599, "59:59"),
        (3_600, "1:00:00"),
        (3_723, "1:02:03"),
        (36_000, "10:00:00"),
        (-30, "0:00"),
    ]

    static let durations: [(TimeInterval, String)] = [
        (0, "0 min"),
        (-120, "0 min"),
        (89, "1 min"),
        (2_880, "48 min"),
        (3_569, "59 min"),
        (3_570, "1 h"),
        (6_720, "1 h 52 min"),
        (7_200, "2 h"),
        (7_500, "2 h 5 min"),
    ]

    @Test(arguments: timecodes)
    func timecode(seconds: TimeInterval, expected: String) {
        #expect(LibraryFormat.timecode(seconds) == expected)
    }

    @Test(arguments: durations)
    func duration(seconds: TimeInterval, expected: String) {
        #expect(LibraryFormat.duration(seconds) == expected)
    }

    @Test func remainingAddsLeft() {
        #expect(LibraryFormat.remaining(31 * 60) == "31 min left")
        #expect(LibraryFormat.remaining(71 * 60) == "1 h 11 min left")
    }

    @Test func spokenDurationNeverGoesNegative() {
        #expect(LibraryFormat.spokenDuration(-5) == LibraryFormat.spokenDuration(0))
        #expect(LibraryFormat.spokenDuration(2_472.4) == LibraryFormat.spokenDuration(2_472))
    }

    @Test func episodeCodes() {
        #expect(EpisodeCode.short(season: 2, episode: 5) == "S2 E5")
        #expect(EpisodeCode.spoken(season: 2, episode: 5) == "Season 2, episode 5")
        #expect(EpisodeCode.short(season: 0, episode: 12) == "S0 E12")
    }

    @Test func thePlayersSubtitleSkipsABlankTitle() {
        #expect(Fixture.episode(2, 5, title: "The Lighthouse Keeper").playerSubtitle == "S2 E5 · The Lighthouse Keeper")
        #expect(Fixture.episode(2, 5, title: "  The Lighthouse Keeper ").playerSubtitle == "S2 E5 · The Lighthouse Keeper")
        #expect(Fixture.episode(2, 5, title: "   ").playerSubtitle == "S2 E5")
        #expect(Fixture.episode(2, 5).playerSubtitle == "S2 E5")
    }

    @Test func sortTitles() {
        #expect(CatalogSort.allCases.map(\.title) == ["Date added", "Name", "Year"])
    }
}
