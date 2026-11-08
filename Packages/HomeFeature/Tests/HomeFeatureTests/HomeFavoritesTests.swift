import CatalogKit
import Core
import Foundation
import HouseholdKit
import SourceKit
import Testing
@testable import HomeFeature

// Home on the iPhone, iPad and Mac is the profile's favorites (2026-11-08):
// favorite channels, then My List's movies and shows, with how-tos where
// nothing's saved. These pin what it shows and in which order.

@Suite struct HomePosterTests {
    @Test func aMovieNobodyStartedShowsItsYear() {
        let poster = HomePoster.movie(Fixture.movie(year: 2019), progress: nil)
        #expect(poster.title == "Harbour Lights")
        #expect(poster.caption == "2019")
        #expect(poster.badge == nil)
        #expect(poster.progress == nil)
        #expect(poster.resumePosition == nil)
        #expect(poster.route == .movie(itemKey: ItemKey.movie(source: Fixture.source, id: "film").rawValue))
        #expect(poster.favoriteKind == .movie)
    }

    @Test func aStartedMovieShowsHowFarAndWhatsLeft() {
        let poster = HomePoster.movie(Fixture.movie(), progress: Fixture.movieProgress(position: 1800, duration: 7200))
        #expect(poster.progress == 0.25)
        #expect(poster.resumePosition == 1800)
        #expect(poster.caption == HearthFormat.remaining(5400))
        #expect(poster.badge == nil)
    }

    @Test func aFinishedMovieSaysWatched() {
        let poster = HomePoster.movie(Fixture.movie(), progress: Fixture.movieProgress(position: 7000, duration: 7200, watched: true))
        #expect(poster.badge == "Watched")
        #expect(poster.progress == nil)
        #expect(poster.resumePosition == nil)
        #expect(poster.caption == "2019")
    }

    /// A few seconds in is a false start, not something to resume.
    @Test func aFalseStartIsNotProgress() {
        let poster = HomePoster.movie(Fixture.movie(), progress: Fixture.movieProgress(position: 5, duration: 7200))
        #expect(poster.progress == nil)
        #expect(poster.resumePosition == nil)
        #expect(poster.caption == "2019")
    }

    /// A row saved before the player knew the length borrows the catalog's.
    @Test func aRowWithoutALengthUsesTheMovies() {
        let poster = HomePoster.movie(Fixture.movie(duration: 6000), progress: Fixture.movieProgress(position: 1500, duration: 0))
        #expect(poster.progress == 0.25)
        #expect(poster.resumePosition == 1500)
    }

    @Test func noLengthAnywhereStillResumesWithoutABar() {
        let poster = HomePoster.movie(Fixture.movie(year: nil), progress: Fixture.movieProgress(position: 1500, duration: 0))
        #expect(poster.progress == nil)
        #expect(poster.resumePosition == 1500)
        #expect(poster.caption == nil)
    }

    @Test func aShowNobodyWatchedHasNoBadge() {
        let poster = HomePoster.series(Fixture.series(), latest: nil)
        #expect(poster.title == "The Lighthouse")
        #expect(poster.caption == "2021")
        #expect(poster.badge == nil)
        #expect(poster.progress == nil)
        #expect(poster.route == .series(itemKey: Fixture.seriesKey().rawValue))
        #expect(poster.favoriteKind == .series)
    }

    @Test func aShowPartWayThroughAnEpisodeShowsItsCodeAndBar() {
        let poster = HomePoster.series(Fixture.series(), latest: Fixture.episodeProgress(2, 5, position: 600, duration: 2400))
        #expect(poster.badge == "S2 E5")
        #expect(poster.progress == 0.25)
    }

    @Test func aFinishedEpisodeShowsItsCodeOnly() {
        let poster = HomePoster.series(Fixture.series(), latest: Fixture.episodeProgress(3, 1, position: 2390, duration: 2400, watched: true))
        #expect(poster.badge == "S3 E1")
        #expect(poster.progress == nil)
    }

    /// A row synced from an older build has no season or number of its own.
    @Test func theCodeFallsBackToTheEpisodesKey() {
        let poster = HomePoster.series(Fixture.series(), latest: Fixture.episodeProgress(1, 7, codeOnRow: false))
        #expect(poster.badge == "S1 E7")
    }

    /// Home's tiles never offer to play a show, only a movie: a movie's
    /// resume point is all a tile carries.
    @Test func aShowNeverCarriesAResumePoint() {
        let poster = HomePoster.series(Fixture.series(), latest: Fixture.episodeProgress(2, 5))
        #expect(poster.resumePosition == nil)
    }
}

@Suite struct HomeShelfTests {
    private func favorite(_ id: String, kind: FavoriteKind = .movie, order: Double) -> FavoriteRecord {
        let key = kind == .movie ? ItemKey.movie(source: Fixture.source, id: id) : ItemKey.series(source: Fixture.source, id: id)
        return FavoriteRecord(profileID: Fixture.profile, itemKey: key.rawValue, kind: kind, sortOrder: order, addedAt: Fixture.reference)
    }

    private func poster(for favorite: FavoriteRecord) -> HomePoster {
        HomePoster(itemKey: favorite.itemKey, kind: .movie, title: favorite.itemKey)
    }

    private func key(_ id: String) -> String {
        ItemKey.movie(source: Fixture.source, id: id).rawValue
    }

    /// The store gives the profile's own order (another change lets it be
    /// set by hand); the shelf keeps it.
    @Test func keepsTheOrderTheStoreGives() {
        let favorites = [favorite("c", order: 1), favorite("a", order: 2), favorite("b", order: 3)]
        let posters = HomeShelf.posters(favorites) { poster(for: $0) }
        #expect(posters.map(\.itemKey) == favorites.map(\.itemKey))
    }

    /// A title this device's catalog lacks is left off, not shown as
    /// unavailable: My List deals with those.
    @Test func leavesOffTitlesTheCatalogLacks() {
        let favorites = [favorite("a", order: 1), favorite("missing", order: 2), favorite("b", order: 3)]
        let posters = HomeShelf.posters(favorites) { $0.itemKey == key("missing") ? nil : poster(for: $0) }
        #expect(posters.map(\.itemKey) == [favorites[0].itemKey, favorites[2].itemKey])
    }

    @Test func stopsAtTheLimitAndStopsAsking() {
        let favorites = (0..<50).map { favorite("m\($0)", order: Double($0)) }
        var asked = 0
        let posters = HomeShelf.posters(favorites) { favorite in
            asked += 1
            return poster(for: favorite)
        }
        #expect(posters.count == HomeShelf.limit)
        #expect(asked == HomeShelf.limit)
        #expect(posters.first?.itemKey == favorites[0].itemKey)
    }

    @Test func titlesLeftOffDontCountTowardsTheLimit() {
        let favorites = (0..<6).map { favorite("m\($0)", order: Double($0)) }
        let posters = HomeShelf.posters(favorites, limit: 3) { favorite in
            [key("m0"), key("m2")].contains(favorite.itemKey) ? nil : poster(for: favorite)
        }
        #expect(posters.map(\.itemKey) == [favorites[1].itemKey, favorites[3].itemKey, favorites[4].itemKey])
    }

    /// A duplicate a sync fold hasn't reached yet shows once.
    @Test func aDuplicateShowsOnce() {
        let favorites = [favorite("a", order: 1), favorite("a", order: 2), favorite("b", order: 3)]
        let posters = HomeShelf.posters(favorites) { poster(for: $0) }
        #expect(posters.map(\.itemKey) == [favorites[0].itemKey, favorites[2].itemKey])
    }

    @Test func noFavoritesNoPosters() {
        #expect(HomeShelf.posters([]) { poster(for: $0) }.isEmpty)
    }

    /// `seriesInProgress` is newest first: a show's first row is its latest.
    @Test func eachShowsLatestEpisodeIsItsFirstRow() {
        let rows = [
            Fixture.episodeProgress(series: "a", 2, 3),
            Fixture.episodeProgress(series: "b", 1, 1),
            Fixture.episodeProgress(series: "a", 1, 9),
        ]
        let latest = HomeShelf.latestEpisodes(rows)
        #expect(latest.count == 2)
        #expect(latest[Fixture.seriesKey("a").rawValue]?.episode == 3)
        #expect(latest[Fixture.seriesKey("b").rawValue]?.season == 1)
    }

    @Test func rowsWithoutAShowAreIgnored() {
        let latest = HomeShelf.latestEpisodes([Fixture.movieProgress(position: 10, duration: 100)])
        #expect(latest.isEmpty)
    }
}

@Suite struct HomePlanTests {
    @Test func everythingSavedLeadsWithChannelsThenMoviesThenShows() {
        let counts = HomeCounts(channels: 6, movies: 3, shows: 2, savedMovies: 3, savedShows: 2)
        #expect(HomePlan.sections(counts, isGuest: false) == [.favoriteChannels, .myListMovies, .myListShows])
    }

    @Test func aNewProfileGetsOneWelcomeCard() {
        #expect(HomePlan.sections(HomeCounts(), isGuest: false) == [.welcome])
    }

    @Test func aGuestGetsTheWayToTheGuideOnly() {
        #expect(HomePlan.sections(HomeCounts(), isGuest: true) == [.favoriteChannelsHint])
        // A guest has nothing saved; even if a count slipped through, no shelves.
        #expect(HomePlan.sections(HomeCounts(channels: 3, movies: 2, shows: 1, savedMovies: 2, savedShows: 1), isGuest: true) == [.favoriteChannelsHint])
    }

    @Test func channelsButAnEmptyListSaysHowToAddToIt() {
        let counts = HomeCounts(channels: 4)
        #expect(HomePlan.sections(counts, isGuest: false) == [.favoriteChannels, .myListHint])
    }

    /// What's there comes first; the how-to for channels follows it.
    @Test func aListButNoChannelsPutsTheShelvesFirst() {
        let counts = HomeCounts(movies: 2, shows: 1, savedMovies: 2, savedShows: 1)
        #expect(HomePlan.sections(counts, isGuest: false) == [.myListMovies, .myListShows, .favoriteChannelsHint])
    }

    @Test func anEmptyKindHasNoShelf() {
        #expect(HomePlan.sections(HomeCounts(channels: 2, movies: 3, savedMovies: 3), isGuest: false) == [.favoriteChannels, .myListMovies])
        #expect(HomePlan.sections(HomeCounts(channels: 2, shows: 3, savedShows: 3), isGuest: false) == [.favoriteChannels, .myListShows])
    }

    /// The owner's portal: My List holds titles this device's catalog hasn't
    /// found yet. That isn't an empty list, so no "add to My List" how-to and
    /// no welcome, just no shelf until they're found.
    @Test func titlesNotFoundYetArentAnEmptyList() {
        #expect(HomePlan.sections(HomeCounts(channels: 2, savedMovies: 4, savedShows: 1), isGuest: false) == [.favoriteChannels])
        #expect(HomePlan.sections(HomeCounts(savedMovies: 4), isGuest: false) == [.favoriteChannelsHint])
    }
}

@Suite struct HomeSummaryTests {
    @Test func countsChannelsAndTheList() {
        let counts = HomeCounts(channels: 6, movies: 3, shows: 2, savedMovies: 3, savedShows: 2)
        #expect(HomeSummary.text(counts, isGuest: false) == "6 favorite channels · 3 movies and 2 shows on My List")
    }

    @Test func oneOfEachIsSingular() {
        let counts = HomeCounts(channels: 1, movies: 1, shows: 1, savedMovies: 1, savedShows: 1)
        #expect(HomeSummary.text(counts, isGuest: false) == "1 favorite channel · 1 movie and 1 show on My List")
    }

    @Test func leavesOutWhatsEmpty() {
        #expect(HomeSummary.text(HomeCounts(channels: 4), isGuest: false) == "4 favorite channels")
        #expect(HomeSummary.text(HomeCounts(movies: 2, savedMovies: 2), isGuest: false) == "2 movies on My List")
        #expect(HomeSummary.text(HomeCounts(channels: 2, shows: 1, savedShows: 1), isGuest: false) == "2 favorite channels · 1 show on My List")
    }

    /// The list's count is what My List holds, found on this device or not,
    /// so it matches the My List tab.
    @Test func countsTheWholeListNotJustTheShelf() {
        let counts = HomeCounts(channels: 0, movies: 20, shows: 0, savedMovies: 57, savedShows: 0)
        #expect(HomeSummary.text(counts, isGuest: false) == "57 movies on My List")
    }

    @Test func nothingSavedSaysNothing() {
        #expect(HomeSummary.text(HomeCounts(), isGuest: false) == nil)
    }

    @Test func aGuestGetsNoCount() {
        #expect(HomeSummary.text(HomeCounts(channels: 3), isGuest: true) == nil)
    }
}

@Suite struct HomeSnapshotCountsTests {
    @Test func countsComeFromTheSnapshot() {
        var snapshot = HomeSnapshot()
        snapshot.myListMovies = [HomePoster.movie(Fixture.movie("a"), progress: nil), HomePoster.movie(Fixture.movie("b"), progress: nil)]
        snapshot.myListShows = [HomePoster.series(Fixture.series(), latest: nil)]
        snapshot.savedMovieCount = 5
        snapshot.savedShowCount = 1
        #expect(snapshot.counts == HomeCounts(channels: 0, movies: 2, shows: 1, savedMovies: 5, savedShows: 1))
    }
}

@Suite struct HomeSalutationTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: hour))!
    }

    /// Under the switcher, which already shows the name.
    @Test func saysThePartOfTheDayWithoutAName() {
        #expect(HomeGreeting.salutation(at: at(9), calendar: calendar) == "Good morning")
        #expect(HomeGreeting.salutation(at: at(13), calendar: calendar) == "Good afternoon")
        #expect(HomeGreeting.salutation(at: at(21), calendar: calendar) == "Good evening")
        #expect(HomeGreeting.salutation(at: at(3), calendar: calendar) == "Good evening")
    }

    @Test(arguments: [0, 4, 5, 11, 12, 16, 17, 23])
    func matchesTheNamedGreetingsHours(hour: Int) {
        let salutation = HomeGreeting.salutation(at: at(hour), calendar: calendar)
        #expect(HomeGreeting.text(name: "Anya", at: at(hour), calendar: calendar) == "\(salutation), Anya")
    }
}

/// The loader against real (in-memory) stores: what it reads for which
/// layout. The catalog is empty, so every title is one it lacks.
@MainActor
@Suite struct HomeLoaderTests {
    let catalog = CatalogService(storeURL: nil)
    let store: HouseholdStore
    let profileID: UUID

    init() throws {
        store = try HouseholdStore(mode: .inMemory)
        store.ensureHousehold(defaultName: "Home", firstProfileName: "Bhavik")
        profileID = try #require(store.profiles.first?.id)
    }

    private func saveToMyList(movies: Int, shows: Int) {
        for index in 0..<movies {
            store.toggleFavorite(profileID: profileID, itemKey: ItemKey.movie(source: Fixture.source, id: "m\(index)").rawValue, kind: .movie)
        }
        for index in 0..<shows {
            store.toggleFavorite(profileID: profileID, itemKey: ItemKey.series(source: Fixture.source, id: "s\(index)").rawValue, kind: .series)
        }
    }

    /// Titles the catalog lacks stay off the shelves, but My List's counts
    /// still say what it holds.
    @Test func theListIsCountedAndMissingTitlesLeftOff() {
        saveToMyList(movies: 3, shows: 2)
        let snapshot = HomeLoader(catalog: catalog, store: store).load(profileID: profileID, layout: .compact)
        #expect(snapshot.savedMovieCount == 3)
        #expect(snapshot.savedShowCount == 2)
        #expect(snapshot.myListMovies.isEmpty)
        #expect(snapshot.myListShows.isEmpty)
        #expect(HomePlan.sections(snapshot.counts, isGuest: false) == [.favoriteChannelsHint])
    }

    /// The sidebar layout (iPad, Mac) reads the same as the phone.
    @Test func theSidebarReadsMyListToo() {
        saveToMyList(movies: 1, shows: 4)
        let snapshot = HomeLoader(catalog: catalog, store: store).load(profileID: profileID, layout: .sidebar)
        #expect(snapshot.savedMovieCount == 1)
        #expect(snapshot.savedShowCount == 4)
    }

    /// The TV's Home is as it was: no My List shelves.
    @Test func theTVDoesntReadMyList() {
        saveToMyList(movies: 2, shows: 1)
        let snapshot = HomeLoader(catalog: catalog, store: store).load(profileID: profileID, layout: .tv)
        #expect(snapshot.savedMovieCount == 0)
        #expect(snapshot.savedShowCount == 0)
        #expect(snapshot.myListMovies.isEmpty)
    }

    @Test func noProfileNothingToShow() {
        saveToMyList(movies: 2, shows: 1)
        #expect(HomeLoader(catalog: catalog, store: store).load(profileID: nil, layout: .compact) == .empty)
    }

    @Test func aGuestHasNothingSaved() throws {
        let guest = try #require(store.addProfile(name: "Guest", kind: .guest, avatarColor: .slate))
        store.toggleFavorite(profileID: guest.id, itemKey: ItemKey.movie(source: Fixture.source, id: "m0").rawValue, kind: .movie)
        let snapshot = HomeLoader(catalog: catalog, store: store).load(profileID: guest.id, layout: .compact)
        #expect(snapshot.counts == HomeCounts())
    }
}

/// The loader over the demo provider's catalog, imported into memory: what a
/// real Home reads, in which order, and that Continue watching and Up next
/// stay on the TV.
@MainActor
@Suite struct HomeLoaderCatalogTests {
    let store: HouseholdStore
    let profileID: UUID

    init() throws {
        store = try HouseholdStore(mode: .inMemory)
        store.ensureHousehold(defaultName: "Home", firstProfileName: "Bhavik")
        profileID = try #require(store.profiles.first?.id)
    }

    private func demoCatalog() async -> CatalogService {
        let catalog = CatalogService(storeURL: nil, clientFactory: { StubSourceClient(configuration: $0) })
        catalog.setSources([SourceConfiguration.stub()])
        await catalog.waitForBackgroundRefreshes()
        return catalog
    }

    @Test func myListFollowsTheProfilesOrderWithProgress() async throws {
        let catalog = await demoCatalog()
        let movies = catalog.movies(limit: 3)
        let shows = catalog.series(limit: 2)
        try #require(movies.count == 3 && shows.count == 2)
        for movie in movies {
            store.toggleFavorite(profileID: profileID, itemKey: movie.key.rawValue, kind: .movie)
        }
        for show in shows {
            store.toggleFavorite(profileID: profileID, itemKey: show.key.rawValue, kind: .series)
        }
        // The profile puts the third movie first, as reordering My List does.
        store.moveFavorites(profileID: profileID, kind: .movie, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        store.saveProgress(profileID: profileID, itemKey: movies[0].key.rawValue, kind: .movie, position: 600, duration: 6000)
        let show = shows[1]
        let episode = ItemKey.episode(source: show.sourceID, seriesID: show.remoteID, season: 1, number: 2)
        store.saveProgress(profileID: profileID, itemKey: episode.rawValue, kind: .episode, position: 300, duration: 1200,
                           seriesKey: show.key.rawValue, season: 1, episode: 2)

        let snapshot = HomeLoader(catalog: catalog, store: store).load(profileID: profileID, layout: .compact)
        #expect(snapshot.myListMovies.map(\.itemKey) == [movies[2], movies[0], movies[1]].map(\.key.rawValue))
        #expect(snapshot.myListMovies[1].progress == 0.1)
        #expect(snapshot.myListMovies[1].resumePosition == 600)
        #expect(snapshot.myListShows.map(\.itemKey) == shows.map(\.key.rawValue))
        #expect(snapshot.myListShows[0].badge == nil)
        #expect(snapshot.myListShows[1].badge == "S1 E2")
        #expect(snapshot.myListShows[1].progress == 0.25)
        #expect(snapshot.counts == HomeCounts(channels: 0, movies: 3, shows: 2, savedMovies: 3, savedShows: 2))
    }

    /// The same rows that make the TV's Continue watching give the phone and
    /// the Mac no Continue watching or Up next (the owner, 2026-11-08).
    @Test func continueWatchingAndUpNextStayOnTheTV() async throws {
        let catalog = await demoCatalog()
        let movie = try #require(catalog.movies(limit: 1).first)
        store.saveProgress(profileID: profileID, itemKey: movie.key.rawValue, kind: .movie, position: 600, duration: 6000)
        let loader = HomeLoader(catalog: catalog, store: store)

        let tv = loader.load(profileID: profileID, layout: .tv)
        #expect(tv.continueWatching?.itemKey == movie.key.rawValue)
        #expect(tv.myListMovies.isEmpty)

        for layout in [HearthLayout.compact, .sidebar] {
            let snapshot = loader.load(profileID: profileID, layout: layout)
            #expect(snapshot.continueWatching == nil, "\(layout)")
            #expect(snapshot.upNext.isEmpty, "\(layout)")
            #expect(snapshot.seriesNeedingEpisodes.isEmpty, "\(layout)")
        }
    }

    @Test func favoriteChannelsFollowTheProfilesOrder() async throws {
        let catalog = await demoCatalog()
        let channels = Array(catalog.channels().prefix(3))
        try #require(channels.count == 3)
        for channel in channels {
            store.toggleFavorite(profileID: profileID, itemKey: channel.key.rawValue, kind: .channel)
        }
        store.moveFavorites(profileID: profileID, kind: .channel, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        let snapshot = HomeLoader(catalog: catalog, store: store).load(profileID: profileID, layout: .compact)
        #expect(snapshot.favoriteChannels.map(\.key) == [channels[1], channels[2], channels[0]].map(\.key))
        #expect(HomePlan.sections(snapshot.counts, isGuest: false) == [.favoriteChannels, .myListHint])
    }
}
