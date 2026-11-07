import CatalogKit
import Core
import Foundation
import HouseholdKit
import SourceKit
import Testing
@testable import Hearth

// The app's part in making a title found by search on one device resolve on
// another (`HeldItems`): the device that holds the title writes its name on
// the household's row, and a device that lacks it searches its provider by
// that name. Two catalogs on one provider stand in for the iPhone and the
// Apple TV, each with the app's observer running, and one in-memory household
// store for what iCloud syncs between them.

/// A big portal in memory, a title a page: its lists say they hold 20,000
/// titles, so a catalog keeps each category's first page (The Office, The
/// Quiet Engine) and finds the rest by searching. Like the owner's portal, it
/// can't be asked for a title by id.
struct BigPortalClient: SourceClient {
    let configuration: SourceConfiguration
    var capabilities: SourceCapabilities {
        SourceCapabilities(hasMovies: true, hasSeries: true, hasFullGuide: false, hasCatchup: false, reportsStreamCount: false, searchesCatalog: true)
    }

    static let office = RemoteSeries(id: "s2", name: "The Office", categoryID: "drama")
    static let harbor = RemoteSeries(id: "s1", name: "The Long Harbor", categoryID: "drama", posterURL: URL(string: "https://posters.invalid/s1.jpg"))
    static let shows = [office, harbor]
    static let film = RemoteMovie(id: "m1", name: "The Quiet Engine", categoryID: "films")
    static let laterFilm = RemoteMovie(id: "m2", name: "Lantern Season", categoryID: "films", posterURL: URL(string: "https://posters.invalid/m2.jpg"))
    static let films = [film, laterFilm]

    func signIn() async throws -> AccountInfo { AccountInfo(status: .active) }
    func accountInfo() async throws -> AccountInfo { AccountInfo(status: .active) }

    func categories(_ kind: ContentKind) async throws -> [RemoteCategory] {
        switch kind {
        case .live: []
        case .vod: [RemoteCategory(id: "films", name: "Films", kind: .vod)]
        case .series: [RemoteCategory(id: "drama", name: "Drama", kind: .series)]
        }
    }

    func channels() async throws -> [RemoteChannel] { [] }

    func movies(categoryID: String?, page: Int) async throws -> Page<RemoteMovie> {
        Self.page(Self.films, page: page)
    }

    func series(categoryID: String?, page: Int) async throws -> Page<RemoteSeries> {
        Self.page(Self.shows, page: page)
    }

    static func page<Item: Sendable & Hashable>(_ items: [Item], page: Int) -> Page<Item> {
        Page(items: items.indices.contains(page) ? [items[page]] : [], page: page, totalItems: 20_000, hasMore: page + 1 < items.count)
    }

    func search(_ query: String, page: Int) async throws -> RemoteSearchPage {
        guard page == 0 else { return RemoteSearchPage(page: page, hasMore: false) }
        return RemoteSearchPage(
            movies: Self.films.filter { $0.name.localizedCaseInsensitiveContains(query) },
            series: Self.shows.filter { $0.name.localizedCaseInsensitiveContains(query) },
            page: 0,
            hasMore: false
        )
    }

    func seriesDetail(_ series: RemoteSeries) async throws -> SeriesDetail {
        SeriesDetail(series: series, seasons: [RemoteSeason(number: 1)], episodes: [
            RemoteEpisode(id: "\(series.id)-e1", seriesID: series.id, season: 1, number: 1, title: "Arrival"),
            RemoteEpisode(id: "\(series.id)-e2", seriesID: series.id, season: 1, number: 2, title: "The Lighthouse Keeper"),
        ])
    }

    func shortGuide(for channel: RemoteChannel, limit: Int) async throws -> [RemoteProgramme] { [] }
    func fullGuide() -> AsyncThrowingStream<RemoteProgramme, Error>? { nil }

    func streamLink(for request: StreamRequest) async throws -> StreamLink {
        switch request {
        case .episode(let episode, let series):
            StreamLink(url: URL(string: "https://stream.invalid/\(series?.id ?? "-")/\(episode.number).mp4")!)
        case .movie(let movie):
            StreamLink(url: URL(string: "https://stream.invalid/\(movie.id).mp4")!)
        case .live, .catchup:
            throw SourceError(.noLink)
        }
    }

    func keepAlive() async {}
}

@MainActor
@Suite struct HeldItemsTests {
    static let configuration = SourceConfiguration(id: TestIDs.sourceA, name: "Big Portal", kind: .stalker, serverURL: "http://portal.invalid/c/")
    static let harbor = ItemKey.series(source: TestIDs.sourceA, id: "s1")
    static let lantern = ItemKey.movie(source: TestIDs.sourceA, id: "m2")

    /// One device's catalog of the big portal, its first import done.
    static func device() async -> CatalogService {
        let client = BigPortalClient(configuration: configuration)
        let catalog = CatalogService(storeURL: nil, clientFactory: { _ in client })
        catalog.setSources([configuration])
        await catalog.waitForBackgroundRefreshes()
        return catalog
    }

    /// Waits (at most five seconds) for the observers' work to land.
    static func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // The owner's Grey's Anatomy: found by search and favorited on the
    // iPhone, then "Unavailable" in the Apple TV's My List and "No longer
    // available" on its page, because the Apple TV's catalog never stored it.
    @Test func aShowFavoritedAfterASearchOnOneDeviceResolvesOnAnother() async throws {
        let store = try makeHouseholdStore()
        let profileID = store.profiles[0].id
        let phone = await Self.device()
        let tv = await Self.device()
        let phoneObserver = HeldItems.observe(store: store, catalog: phone)
        let tvObserver = HeldItems.observe(store: store, catalog: tv)
        defer { phoneObserver.cancel(); tvObserver.cancel() }

        #expect(await phone.searchProviders("harbor") == 1)
        store.toggleFavorite(profileID: profileID, itemKey: Self.harbor.rawValue, kind: .series)

        await Self.waitUntil { tv.seriesItem(Self.harbor) != nil }
        // The phone wrote the name on the favorite; the Apple TV searched by it.
        #expect(store.favorites(profileID: profileID, kind: .series).map(\.title) == ["The Long Harbor"])
        let show = try #require(tv.seriesItem(Self.harbor))
        #expect(show.name == "The Long Harbor")
        #expect(show.posterURL == URL(string: "https://posters.invalid/s1.jpg"))
        // And it plays there.
        let episodes = try await tv.episodes(for: show)
        #expect(episodes.map(\.title) == ["Arrival", "The Lighthouse Keeper"])
        let link = try await tv.streamLink(for: episodes[1].key)
        #expect(link.url.absoluteString == "https://stream.invalid/s1/2.mp4")
    }

    /// Continue watching: an episode and a movie the phone found by search
    /// and started bring their show and the movie to the Apple TV.
    @Test func titlesInProgressOnOneDeviceResolveOnAnother() async throws {
        let store = try makeHouseholdStore()
        let profileID = store.profiles[0].id
        let phone = await Self.device()
        let tv = await Self.device()
        _ = await phone.searchProviders("harbor")
        _ = await phone.searchProviders("lantern")
        let episode = ItemKey.episode(source: TestIDs.sourceA, seriesID: "s1", season: 1, number: 2)
        store.saveProgress(profileID: profileID, itemKey: episode.rawValue, kind: .episode, position: 600, duration: 2_700,
                           seriesKey: Self.harbor.rawValue, season: 1, episode: 2)
        store.saveProgress(profileID: profileID, itemKey: Self.lantern.rawValue, kind: .movie, position: 900, duration: 6_000)

        let phoneObserver = HeldItems.observe(store: store, catalog: phone)
        let tvObserver = HeldItems.observe(store: store, catalog: tv)
        defer { phoneObserver.cancel(); tvObserver.cancel() }
        await Self.waitUntil { tv.movie(Self.lantern) != nil && tv.seriesItem(Self.harbor) != nil }
        #expect(store.progress(profileID: profileID, itemKey: episode.rawValue)?.title == "The Long Harbor")
        #expect(tv.seriesItem(Self.harbor)?.name == "The Long Harbor")
        #expect(tv.movie(Self.lantern)?.name == "Lantern Season")
        #expect(tv.movie(Self.lantern)?.posterURL == URL(string: "https://posters.invalid/m2.jpg"))
    }

    /// A favorite made before titles were written (an older build) gets its
    /// name from the first device running this one whose catalog holds it.
    @Test func anOlderFavoriteGetsItsNameFromADeviceThatHoldsIt() async throws {
        let store = try makeHouseholdStore()
        let profileID = store.profiles[0].id
        store.toggleFavorite(profileID: profileID, itemKey: Self.harbor.rawValue, kind: .series)
        let tv = await Self.device()
        let tvObserver = HeldItems.observe(store: store, catalog: tv)
        defer { tvObserver.cancel() }
        // Nobody holds it: no name, nothing to search by.
        try await Task.sleep(for: .milliseconds(200))
        #expect(tv.seriesItem(Self.harbor) == nil)

        let phone = await Self.device()
        _ = await phone.searchProviders("harbor")
        let phoneObserver = HeldItems.observe(store: store, catalog: phone)
        defer { phoneObserver.cancel() }
        await Self.waitUntil { tv.seriesItem(Self.harbor) != nil }
        #expect(store.favorites(profileID: profileID, kind: .series).first?.title == "The Long Harbor")
        #expect(tv.seriesItem(Self.harbor)?.name == "The Long Harbor")
    }

    @Test func rowsAreEveryProfilesMoviesShowsAndProgress() throws {
        let store = try makeHouseholdStore()
        let first = store.profiles[0].id
        let second = try #require(store.addProfile(name: "Asha", kind: .standard, avatarColor: .blue)).id
        let source = TestIDs.sourceA
        let channel = ItemKey.channel(source: source, id: "101")
        let episode = ItemKey.episode(source: source, seriesID: "s3", season: 2, number: 4)
        let showInProgress = ItemKey.series(source: source, id: "s3")
        store.toggleFavorite(profileID: first, itemKey: Self.harbor.rawValue, kind: .series)
        store.toggleFavorite(profileID: first, itemKey: channel.rawValue, kind: .channel)
        store.toggleFavorite(profileID: second, itemKey: Self.lantern.rawValue, kind: .movie)
        store.saveProgress(profileID: second, itemKey: episode.rawValue, kind: .episode, position: 60, duration: 2_700,
                           seriesKey: showInProgress.rawValue, season: 2, episode: 4)
        store.saveProgress(profileID: first, itemKey: "\(channel.rawValue)@1800000000", kind: .catchup, position: 60, duration: 3_600)
        store.fillInTitles([episode.rawValue: "Third Show"])

        let rows = HeldItems.rows(in: store)
        #expect(Set(rows.map(\.heldKey)) == [Self.harbor, Self.lantern, episode, showInProgress])
        // The show in progress is held through its episode's row, and named by it.
        #expect(rows.contains(HeldItems.Row(itemKey: episode.rawValue, heldKey: showInProgress, title: "Third Show")))
        #expect(Set(HeldItems.items(rows)).contains(HeldItem(key: showInProgress, title: "Third Show")))
    }

    /// Names come from this device's catalog, for rows that have none; an
    /// episode's row gets its show's name.
    @Test func namesAreFilledInFromTheCatalogForRowsWithout() async throws {
        let phone = await Self.device()
        _ = await phone.searchProviders("harbor")
        let episode = ItemKey.episode(source: TestIDs.sourceA, seriesID: "s1", season: 1, number: 2)
        let rows = [
            HeldItems.Row(itemKey: Self.harbor.rawValue, heldKey: Self.harbor, title: ""),
            HeldItems.Row(itemKey: episode.rawValue, heldKey: Self.harbor, title: ""),
            HeldItems.Row(itemKey: Self.lantern.rawValue, heldKey: Self.lantern, title: ""),
            HeldItems.Row(itemKey: ItemKey.movie(source: TestIDs.sourceA, id: "m1").rawValue, heldKey: .movie(source: TestIDs.sourceA, id: "m1"), title: "Kept"),
        ]
        #expect(HeldItems.titlesToFillIn(rows, catalog: phone) == [
            Self.harbor.rawValue: "The Long Harbor",
            episode.rawValue: "The Long Harbor",
        ])
    }
}
