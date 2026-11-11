import Foundation
import SourceKit
import Testing
@testable import CatalogKit

/// Titles the household holds that this device's catalog never stored
/// (`resolveHeldItems`): a show found by search and favorited on the iPhone
/// reaches the Apple TV's My List as a key and a name, and the Apple TV
/// searches its provider by the name.
@MainActor
@Suite struct HeldItemTests {
    /// A show list too big to import whole, one show a page: Drama's first
    /// page holds The Office, and Grey's Anatomy (with a poster) is on its
    /// second, where nobody has browsed.
    static func hugeShowList() -> FakeSourceClient.Fixture {
        var fixture = CatalogBrowseTests.hugeShowList()
        if let index = fixture.series.firstIndex(where: { $0.id == "s1" }) {
            fixture.series[index].posterURL = URL(string: "http://portal.example/posters/s1.jpg")
        }
        return fixture
    }

    /// Another device on the same provider: its own client and catalog.
    static func device(_ fixture: FakeSourceClient.Fixture, configuration: SourceConfiguration) async -> (CatalogService, FakeSourceClient) {
        let fake = FakeSourceClient(configuration: configuration, capabilities: CatalogBrowseTests.searching, fixture: fixture)
        return (await importedService([fake]), fake)
    }

    static func service(_ fixture: FakeSourceClient.Fixture = hugeShowList()) async -> (CatalogService, FakeSourceClient) {
        await importedService(fixture, capabilities: CatalogBrowseTests.searching)
    }

    // The owner's case: Grey's Anatomy found by search and favorited on the
    // iPhone was "Unavailable" in the Apple TV's My List and "No longer
    // available" on its page.
    @Test func aShowFoundBySearchOnOneDeviceResolvesOnAnother() async throws {
        let configuration = Fixtures.configuration()
        let (phone, _) = await Self.device(Self.hugeShowList(), configuration: configuration)
        let (tv, tvProvider) = await Self.device(Self.hugeShowList(), configuration: configuration)
        let key = ItemKey.series(source: configuration.id, id: "s1")
        #expect(await phone.searchProviders("anatomy") == 1)
        let title = try #require(phone.heldTitle(for: key))
        #expect(title == "Grey's Anatomy")
        #expect(!tv.contains(key))

        #expect(await tv.resolveHeldItems([HeldItem(key: key, title: title)]) == 1)
        let show = try #require(tv.seriesItem(key))
        #expect(show.name == "Grey's Anatomy")
        #expect(show.posterURL == URL(string: "http://portal.example/posters/s1.jpg"))
        #expect(tvProvider.calls.contains("search(Grey's Anatomy,0)"))
        // It plays: its episodes load, and an episode links.
        let episodes = try await tv.episodes(for: show)
        #expect(episodes.count == 3)
        let link = try await tv.streamLink(for: try #require(episodes.first).key)
        #expect(link.url.absoluteString.hasPrefix("https://fake.test/episode/s1/"))
        // And it's in search and in its category on this device now.
        #expect(tv.search("anatomy").series.map(\.name) == ["Grey's Anatomy"])
        #expect(tv.series(categoryID: CatalogBrowseTests.key(tvProvider, "series", "20")).map(\.name).contains("Grey's Anatomy"))
    }

    /// The owner's portal names the show "Greys Anatomy - ENGLISH | TV
    /// SERIES", and its search finds nothing for that whole name; "Greys
    /// Anatomy" finds it first (checked on the portal, 2026-11-07).
    static func decoratedShowList() -> (FakeSourceClient.Fixture, String) {
        var fixture = hugeShowList()
        let decorated = "Grey's Anatomy - ENGLISH | TV SERIES"
        fixture.series = fixture.series.map { show in
            var show = show
            if show.id == "s1" { show.name = decorated }
            return show
        }
        fixture.unmatchedQueries = [decorated]
        return (fixture, decorated)
    }

    @Test func aDecoratedNameIsSearchedByItsPlainPart() async throws {
        let (fixture, decorated) = Self.decoratedShowList()
        let (service, fake) = await Self.service(fixture)
        let key = ItemKey.series(source: fake.configuration.id, id: "s1")
        #expect(await service.resolveHeldItems([HeldItem(key: key, title: decorated)]) == 1)
        #expect(service.seriesItem(key)?.name == decorated)
        // Found by the plain part, the whole name is never sent.
        #expect(Set(fake.calls.filter { $0.hasPrefix("search(") }) == ["search(Grey's Anatomy,0)", "search(Grey's Anatomy,1)"])
    }

    /// A portal whose search matches only the whole name gets that next.
    @Test func theWholeNameFollowsWhenThePlainPartFindsNothing() async throws {
        var (fixture, decorated) = Self.decoratedShowList()
        fixture.unmatchedQueries = ["Grey's Anatomy"]
        let (service, fake) = await Self.service(fixture)
        let key = ItemKey.series(source: fake.configuration.id, id: "s1")
        #expect(await service.resolveHeldItems([HeldItem(key: key, title: decorated)]) == 1)
        // The plain part's nothing is asked twice before it's believed
        // (EmptyAnswerTests).
        #expect(fake.calls.filter { $0.hasPrefix("search(") && $0.hasSuffix(",0)") } == ["search(Grey's Anatomy,0)", "search(Grey's Anatomy,0)", "search(\(decorated),0)"])
    }

    /// A plain name is one query.
    @Test func aPlainNameIsAskedOnce() async throws {
        let (service, fake) = await Self.service()
        let key = ItemKey.series(source: fake.configuration.id, id: "s1")
        _ = await service.resolveHeldItems([HeldItem(key: key, title: "Grey's Anatomy")])
        #expect(Set(fake.calls.filter { $0.hasPrefix("search(") }) == ["search(Grey's Anatomy,0)", "search(Grey's Anatomy,1)"])
    }

    /// The plain part, the whole name, then the plain part's most distinctive
    /// word (`HeldOverRefreshTests` has why).
    @Test func searchQueriesForANameAndItsPlainPart() {
        #expect(HeldTitleSearch.queries(for: "Greys Anatomy - ENGLISH | TV SERIES") == ["Greys Anatomy", "Greys Anatomy - ENGLISH | TV SERIES", "Anatomy"])
        #expect(HeldTitleSearch.queries(for: "EN | Lupin (2021)") == ["Lupin", "EN | Lupin (2021)"])
        #expect(HeldTitleSearch.queries(for: "  The   Office ") == ["The Office", "Office"])
        #expect(HeldTitleSearch.queries(for: "Grey's Anatomy") == ["Grey's Anatomy", "Anatomy"])
        #expect(HeldTitleSearch.queries(for: "x").isEmpty)
        #expect(HeldTitleSearch.queries(for: "").isEmpty)
    }

    /// The Mac's My List read "Unavailable" for these (2026-11-11): each was
    /// searched by its longest part, a label the portal answers with nothing.
    @Test(arguments: [
        ("Iron Man - DISNEY+ | ENGLISH MOVIES", "Iron Man"),
        ("Inception - PRIME VIDEO | ENGLISH MOVIES", "Inception"),
        ("Black Panther - DISNEY+ | ENGLISH MOVIES", "Black Panther"),
        ("Oppenheimer - ENGLISH | LATEST MOVIES", "Oppenheimer"),
        ("The Avengers - ENGLISH | OLD COLLECTION", "The Avengers"),
        ("Suits - ENGLISH | TV SERIES", "Suits"),
        ("The Pitt - HBO | ENGLISH SERIES", "The Pitt"),
        ("The Resident - HULU | ENGLISH SERIES", "The Resident"),
        ("Greys Anatomy - APPLE TV+ | ENGLISH SERIES", "Greys Anatomy"),
        ("Avatar: The Last Airbender - KIDS | TV SERIES", "Avatar: The Last Airbender"),
        ("Mousetrap (Eng Subtitle)", "Mousetrap"),
        ("SUITS - ENGLISH | TV SERIES", "SUITS"),
        ("UP - DISNEY+ | ENGLISH MOVIES", "UP"),
        ("CRUNCHYROLL | Frieren", "Frieren"),
    ])
    func aNameIsSearchedByItsTitleNotItsLongestTag(name: String, title: String) {
        #expect(HeldTitleSearch.queries(for: name).first == title)
        #expect(HeldTitleSearch.queries(for: name).dropFirst().first == name)
    }

    /// The owner's portal: a decorated name, its trailing labels and the
    /// whole name find nothing; the title finds it.
    @Test func aMovieNamedShorterThanItsTagsIsFound() async throws {
        var fixture = CatalogBrowseTests.hugeCatalog()
        let decorated = "Iron Man - DISNEY+ | ENGLISH MOVIES"
        fixture.movies = fixture.movies.map { movie in
            var movie = movie
            if movie.id == "m9" { movie.name = decorated }
            return movie
        }
        fixture.unmatchedQueries = [decorated, "ENGLISH MOVIES"]
        let (service, fake) = await Self.service(fixture)
        let key = ItemKey.movie(source: fake.configuration.id, id: "m9")
        #expect(!service.contains(key))

        #expect(await service.resolveHeldItems([HeldItem(key: key, title: decorated)]) == 1)
        #expect(service.movie(key)?.name == decorated)
        #expect(fake.callCount("search(ENGLISH MOVIES") == 0)
    }

    @Test func aMovieInProgressElsewhereResolvesAndPlays() async throws {
        let (service, fake) = await Self.service(CatalogBrowseTests.hugeCatalog())
        // Echo is on Action's third page.
        let echo = ItemKey.movie(source: fake.configuration.id, id: "m9")
        #expect(!service.contains(echo))
        #expect(await service.resolveHeldItems([HeldItem(key: echo, title: "Echo")]) == 1)
        #expect(service.movie(echo)?.name == "Echo")
        let link = try await service.streamLink(for: echo)
        #expect(link.url.absoluteString == "https://fake.test/movie/m9.mp4")
    }

    /// Continue watching holds an episode's key; its show is what's missing,
    /// and the row carries the show's name.
    @Test func anEpisodeKeyBringsItsShow() async throws {
        let (service, fake) = await Self.service()
        let episode = ItemKey.episode(source: fake.configuration.id, seriesID: "s1", season: 1, number: 2)
        let items = [HeldItem(key: episode), HeldItem(key: episode, title: "Grey's Anatomy")]
        #expect(await service.resolveHeldItems(items) == 1)
        #expect(service.seriesItem(.series(source: fake.configuration.id, id: "s1"))?.name == "Grey's Anatomy")
        #expect(fake.callCount("search(") == 2)
    }

    @Test func aResolvedShowStaysOverARefresh() async throws {
        let (service, fake) = await Self.service()
        let held = HeldItem(key: .series(source: fake.configuration.id, id: "s1"), title: "Grey's Anatomy")
        _ = await service.resolveHeldItems([held])
        await service.refresh(sourceID: fake.configuration.id, force: true)
        #expect(service.seriesItem(held.key)?.name == "Grey's Anatomy")
        // Held, and still here: nobody asks again.
        #expect(await service.resolveHeldItems([held]) == 0)
        #expect(fake.callCount("search(") == 2)
    }

    @Test func eachNameIsAskedOnceACatalog() async throws {
        let (service, fake) = await Self.service()
        let gone = HeldItem(key: .series(source: fake.configuration.id, id: "dropped"), title: "Nothing Like It")
        #expect(await service.resolveHeldItems([gone]) == 0)
        #expect(await service.resolveHeldItems([gone]) == 0)
        // The name, then its word "Nothing": two pages each, the last page
        // saying there's no more, and each answer of nothing asked twice
        // before it's believed (EmptyAnswerTests).
        #expect(fake.callCount("search(") == 8)
        // A new catalog asks again.
        await service.refresh(sourceID: fake.configuration.id, force: true)
        _ = await service.resolveHeldItems([gone])
        #expect(fake.callCount("search(") == 16)
    }

    @Test func aSearchThatFailedIsAskedAgain() async throws {
        let (service, fake) = await Self.service()
        let held = HeldItem(key: .series(source: fake.configuration.id, id: "s1"), title: "Grey's Anatomy")
        fake.update { $0.failure = .search(SourceError(.unreachable)) }
        #expect(await service.resolveHeldItems([held]) == 0)
        #expect(!service.isLookingUp(held.key))
        fake.update { $0.failure = nil }
        #expect(await service.resolveHeldItems([held]) == 1)
        #expect(service.contains(held.key))
    }

    /// A list kept whole holds everything its provider offers, so a title
    /// missing from it is gone, and a show list kept whole isn't searched
    /// just because the movie list is kept in part.
    @Test func aListKeptWholeIsNeverSearched() async throws {
        let (whole, wholeProvider) = await Self.service(Fixtures.catalog())
        let source = wholeProvider.configuration.id
        #expect(await whole.resolveHeldItems([HeldItem(key: .series(source: source, id: "dropped"), title: "Dropped Show"), HeldItem(key: .movie(source: source, id: "dropped"), title: "Dropped Film")]) == 0)

        let (moviesInPart, provider) = await Self.service(CatalogBrowseTests.hugeCatalog())
        #expect(await moviesInPart.resolveHeldItems([HeldItem(key: .series(source: provider.configuration.id, id: "dropped"), title: "Dropped Show")]) == 0)
        #expect(wholeProvider.callCount("search(") + provider.callCount("search(") == 0)
    }

    /// No device has written a name yet (a favorite made by an older build):
    /// there's nothing to search by.
    @Test func withoutANameNothingIsAsked() async throws {
        let (service, fake) = await Self.service()
        #expect(await service.resolveHeldItems([HeldItem(key: .series(source: fake.configuration.id, id: "s1"))]) == 0)
        #expect(fake.callCount("search(") == 0)
    }

    @Test func channelsAndOtherSourcesAreLeftAlone() async throws {
        let (service, fake) = await Self.service()
        let items = [
            HeldItem(key: .channel(source: fake.configuration.id, id: "999"), title: "Channel"),
            HeldItem(key: .series(source: UUID(), id: "s1"), title: "Grey's Anatomy"),
            HeldItem(key: ItemKey(rawValue: "not a key"), title: "Grey's Anatomy"),
        ]
        #expect(await service.resolveHeldItems(items) == 0)
        #expect(fake.callCount("search(") == 0)
    }

    /// My List and the title's page wait while the search runs; Search, which
    /// nobody typed into, doesn't spin for it.
    @Test func aTitleIsLookingUpWhileItsSearchedFor() async throws {
        var fixture = Self.hugeShowList()
        fixture.searchDelay = .milliseconds(300)
        let (service, fake) = await Self.service(fixture)
        let held = HeldItem(key: .series(source: fake.configuration.id, id: "s1"), title: "Grey's Anatomy")
        let revision = service.revision
        let lookup = Task { await service.resolveHeldItems([held]) }
        let deadline = ContinuousClock.now + .seconds(5)
        while fake.callCount("search(") == 0, ContinuousClock.now < deadline { await Task.yield() }
        try #require(fake.callCount("search(") > 0)
        #expect(service.isLookingUp(held.key))
        #expect(service.providerSearchesRunning == 0)
        #expect(await lookup.value == 1)
        #expect(!service.isLookingUp(held.key))
        #expect(service.revision > revision)
    }

    /// The name written down for another device comes from the row itself,
    /// whatever the current profile may see.
    @Test func aHeldTitleIsReadWhateverTheProfileHides() async throws {
        let (service, fake) = await Self.service(Fixtures.catalog())
        let source = fake.configuration.id
        let show = ItemKey.series(source: source, id: "s1")
        service.filter = CatalogFilter(hiddenCategoryIDs: [CategoryKey.make(source: source, kind: "series", remoteID: "20")])
        #expect(service.seriesItem(show) == nil)
        #expect(service.heldTitle(for: show) == "Grey's Anatomy")
        #expect(service.heldTitle(for: .episode(source: source, seriesID: "s1", season: 2, number: 1)) == "Grey's Anatomy")
        #expect(service.heldTitle(for: .movie(source: source, id: "m9")) == "Echo")
        #expect(service.heldTitle(for: .channel(source: source, id: "101")) == nil)
        #expect(service.heldTitle(for: .movie(source: source, id: "nope")) == nil)
    }
}
