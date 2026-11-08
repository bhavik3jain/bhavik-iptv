import Foundation
import SourceKit
import Testing
@testable import CatalogKit

/// My List said "Unavailable" for movies and shows the owner had added the
/// day before (2026-11-08, build 113, a portal of 162,000 titles kept a page
/// per category). A title the household holds must stay in a list kept in
/// part over every refresh, and a device that lacks it must look hard enough
/// before calling it gone.
@MainActor
@Suite struct HeldOverRefreshTests {
    /// Waits (bounded) for a condition another task makes true.
    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    static func service(_ fixture: FakeSourceClient.Fixture = CatalogBrowseTests.hugeCatalog()) async -> (CatalogService, FakeSourceClient) {
        await importedService(fixture, capabilities: CatalogBrowseTests.searching)
    }

    // MARK: The owner's scenario

    /// A favorite taken from a category's first page, then newer titles push
    /// it to the second: absent from the new first page isn't gone.
    @Test func aFavoriteFromAFirstPageSurvivesANewFirstPage() async throws {
        let (service, fake) = await Self.service()
        let alpha = ItemKey.movie(source: fake.configuration.id, id: "m4")
        let action = CatalogBrowseTests.key(fake, "vod", "10")
        #expect(CatalogBrowseTests.names(service.movies(categoryID: action)) == ["Grey's Day", "Alpha"])

        fake.update {
            $0.movies.insert(contentsOf: [
                RemoteMovie(id: "n1", name: "Newer One", categoryID: "10"),
                RemoteMovie(id: "n2", name: "Newer Two", categoryID: "10"),
            ], at: 0)
        }
        for _ in 0..<2 {
            await service.refresh(sourceID: fake.configuration.id, force: true)
            #expect(service.movie(alpha)?.name == "Alpha")
        }
        #expect(CatalogBrowseTests.names(service.movies(categoryID: action)) == ["Newer One", "Newer Two", "Grey's Day", "Alpha"])
    }

    @Test func aShowFromAFirstPageSurvivesANewFirstPage() async throws {
        let (service, fake) = await Self.service(CatalogBrowseTests.hugeShowList())
        let office = ItemKey.series(source: fake.configuration.id, id: "s2")
        #expect(service.seriesItem(office)?.name == "The Office")
        fake.update { $0.series.insert(RemoteSeries(id: "s3", name: "Newer Show", categoryID: "20"), at: 0) }
        await service.refresh(sourceID: fake.configuration.id, force: true)
        #expect(service.seriesItem(office)?.name == "The Office")
    }

    // MARK: Found while a refresh runs

    /// A refresh copied the old catalog's extra titles into the new one once
    /// its movies were in, then spent its shows' time before swapping. A
    /// movie found by search (or browsed) in that window went into the old
    /// catalog after the copy, showed, could be added to My List, and was
    /// thrown away with the old catalog at the swap. The daily refresh runs
    /// at launch, which is when the owner searches.
    @Test func aTitleFoundBySearchWhileARefreshRunsSurvivesIt() async throws {
        let (service, fake) = await Self.service()
        let echo = ItemKey.movie(source: fake.configuration.id, id: "m9")
        fake.update { $0.seriesPageDelay = .milliseconds(300) }
        let showCalls = fake.callCount("series(")
        let refresh = Task { await service.refresh(sourceID: fake.configuration.id, force: true) }
        try await Self.waitUntil { fake.callCount("series(") > showCalls }

        #expect(await service.searchProviders("echo") == 1)
        #expect(service.movie(echo)?.name == "Echo")
        await refresh.value
        #expect(service.movie(echo)?.name == "Echo")
        #expect(service.count(CatalogModel.Entity.movie, NSPredicate(format: "remoteID == %@", "m9")) == 1)
    }

    @Test func aPageBrowsedWhileARefreshRunsSurvivesIt() async throws {
        let (service, fake) = await Self.service()
        let action = CatalogBrowseTests.key(fake, "vod", "10")
        let zulu = ItemKey.movie(source: fake.configuration.id, id: "m5")
        fake.update { $0.seriesPageDelay = .milliseconds(300) }
        let showCalls = fake.callCount("series(")
        let refresh = Task { await service.refresh(sourceID: fake.configuration.id, force: true) }
        try await Self.waitUntil { fake.callCount("series(") > showCalls }

        #expect(await service.loadMore(kind: .vod, categoryID: action))
        #expect(service.contains(zulu))
        await refresh.value
        #expect(service.movie(zulu)?.name == "Zulu")
        #expect(service.movies(categoryID: action).count == 4)
    }

    /// A page asked for before the swap and answered after it: its rows go
    /// into the catalog that's live when they land, not the one that was
    /// live when it was asked for (which the refresh then deleted).
    @Test func aPageAnsweredAfterTheSwapLandsInTheNewCatalog() async throws {
        let (service, fake) = await Self.service()
        let action = CatalogBrowseTests.key(fake, "vod", "10")
        let zulu = ItemKey.movie(source: fake.configuration.id, id: "m5")
        fake.update { $0.seriesPageDelay = .milliseconds(100) }
        let showCalls = fake.callCount("series(")
        let refresh = Task { await service.refresh(sourceID: fake.configuration.id, force: true) }
        try await Self.waitUntil { fake.callCount("series(") > showCalls }

        fake.update { $0.holdsLaterMoviePages = true }
        let browse = Task { await service.loadMore(kind: .vod, categoryID: action) }
        try await Self.waitUntil { fake.callCount("movies(10,1)") == 1 }
        await refresh.value
        fake.update { $0.holdsLaterMoviePages = false }
        #expect(await browse.value)
        #expect(service.movie(zulu)?.name == "Zulu")
        #expect(service.movies(categoryID: action).count == 4)
    }

    // MARK: A list answered with nothing

    /// A portal answers a session that another sign-in from the same MAC
    /// ended (the owner's iPhone, Mac and Apple TV share one) with empty
    /// lists. The refresh took an empty movie or show list for the whole
    /// list, kept nothing it had, and stopped treating the list as kept in
    /// part, so held titles weren't even searched for.
    /// Movies and shows both kept in part: Drama's first page holds two of
    /// its three shows.
    static func bothInPart() -> FakeSourceClient.Fixture {
        var fixture = CatalogBrowseTests.hugeCatalog()
        fixture.reportedTotals["series/all"] = 20_000
        fixture.series.append(RemoteSeries(id: "s3", name: "Mad Men", categoryID: "20"))
        return fixture
    }

    @Test(arguments: [ContentKind.vod, .series])
    func aListAnsweredWithNothingKeepsWhatItHad(kind: ContentKind) async throws {
        let (service, fake) = await Self.service(Self.bothInPart())
        let source = fake.configuration.id
        _ = await service.searchProviders("echo")
        let movies = [ItemKey.movie(source: source, id: "m1"), .movie(source: source, id: "m9")]
        let shows = [ItemKey.series(source: source, id: "s1"), .series(source: source, id: "s2")]
        let action = CatalogBrowseTests.key(fake, "vod", "10")
        let drama = CatalogBrowseTests.key(fake, "series", "20")
        #expect((movies + shows).allSatisfy(service.contains))
        #expect(service.keepsInPart(source, .movie) && service.keepsInPart(source, .series))
        let before = try #require(service.refreshStates[source])

        fake.update { $0.emptyLists = [kind] }
        await service.refresh(sourceID: source, force: true)

        #expect((movies + shows).allSatisfy(service.contains))
        #expect(service.categories(kind: .vod, applyingFilter: false).map(\.id).contains(action))
        #expect(service.categories(kind: .series, applyingFilter: false).map(\.id).contains(drama))
        #expect(service.keepsInPart(source, .movie))
        #expect(service.keepsInPart(source, .series))
        #expect(service.canLoadMore(kind: .vod, categoryID: action))
        #expect(service.canLoadMore(kind: .series, categoryID: drama))
        let after = try #require(service.refreshStates[source])
        #expect(after.movieCount == before.movieCount)
        #expect(after.seriesCount == before.seriesCount)
        #expect(after.catalogRefreshedAt != before.catalogRefreshedAt)
    }

    /// The list that did answer is still refreshed, and a list kept whole is
    /// the provider's whole list, empty or not.
    @Test func theOtherListStillRefreshes() async throws {
        let (service, fake) = await Self.service(Self.bothInPart())
        fake.update {
            $0.emptyLists = [.series]
            $0.movies.insert(RemoteMovie(id: "n1", name: "Newer One", categoryID: "10"), at: 0)
        }
        await service.refresh(sourceID: fake.configuration.id, force: true)
        #expect(service.movie(.movie(source: fake.configuration.id, id: "n1"))?.name == "Newer One")
        #expect(service.series().count == 2)

        let (whole, wholeFake) = await Self.service()
        #expect(whole.series().count == 2)
        wholeFake.update { $0.emptyLists = [.series] }
        await whole.refresh(sourceID: wholeFake.configuration.id, force: true)
        #expect(whole.series().isEmpty)
    }
}
