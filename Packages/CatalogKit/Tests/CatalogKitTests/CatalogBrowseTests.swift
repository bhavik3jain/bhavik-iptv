import Foundation
import SourceKit
import Testing
@testable import CatalogKit

/// Catalogs too big to import whole (`CatalogImporter.fullImportLimit`):
/// each movie or show category keeps its first page and a `BrowseCursor`,
/// and `loadMore` fetches the rest as the category is browsed.
@MainActor
@Suite struct CatalogBrowseTests {
    /// The fixture catalog behind a portal that says it holds 160,000 movies,
    /// two titles a page, plus a movie category that lists nothing (a big
    /// Stalker portal files its series categories under `vod` too).
    ///
    /// Action (10): m1 m4 | m5 m8 | m9. Adult (11): m3. Family (12): m2 m6 | m7 m10.
    static func hugeCatalog() -> FakeSourceClient.Fixture {
        var fixture = Fixtures.catalog()
        fixture.pageSize = 2
        fixture.reportedTotals = ["vod/all": 160_000]
        fixture.categories[.vod]?.append(RemoteCategory(id: "13", name: "Shows in VOD", kind: .vod, sortOrder: 4))
        return fixture
    }

    static func key(_ fake: FakeSourceClient, _ kind: String, _ remoteID: String) -> String {
        CategoryKey.make(source: fake.configuration.id, kind: kind, remoteID: remoteID)
    }

    static func names(_ movies: [CatalogMovie]) -> Set<String> { Set(movies.map(\.name)) }

    // MARK: Importing first pages

    @Test func aHugeListImportsEachCategorysFirstPageOnly() async throws {
        let (service, fake) = await importedService(Self.hugeCatalog())
        let movieCalls = fake.calls.filter { $0.hasPrefix("movies(") }
        #expect(movieCalls.first == "movies(all,0)")
        #expect(Set(movieCalls.dropFirst()) == ["movies(10,0)", "movies(11,0)", "movies(12,0)", "movies(13,0)"])
        #expect(movieCalls.count == 5)

        #expect(service.count(CatalogModel.Entity.movie, NSPredicate(value: true)) == 5)
        #expect(Self.names(service.movies(categoryID: Self.key(fake, "vod", "10"))) == ["Grey's Day", "Alpha"])
        #expect(Self.names(service.movies(categoryID: Self.key(fake, "vod", "12"))) == ["Café Society", "Bravo"])
        // The count is the provider's, not what's stored.
        #expect(service.refreshStates[fake.configuration.id]?.movieCount == 10)
    }

    /// Xtream answers the whole list at once, however long: a list over the
    /// limit that is already complete in its first answer is kept, not
    /// thrown away and asked for again category by category.
    @Test func aWholeListInOneAnswerIsKeptHoweverLong() async throws {
        var fixture = Fixtures.catalog()
        fixture.reportedTotals = ["vod/all": 160_000]
        let (service, fake) = await importedService(fixture)
        #expect(fake.calls.filter { $0.hasPrefix("movies(") } == ["movies(all,0)"])
        #expect(service.count(CatalogModel.Entity.movie, NSPredicate(value: true)) == 10)
        #expect(!service.canLoadMore(kind: .vod, categoryID: Self.key(fake, "vod", "10")))
    }

    @Test func aCategoryWhoseFirstPageIsEmptyIsLeftOut() async throws {
        let (service, fake) = await importedService(Self.hugeCatalog())
        #expect(service.categories(kind: .vod, applyingFilter: false).map(\.name) == ["Action", "For Adults 18+", "Family"])
        #expect(!service.canLoadMore(kind: .vod, categoryID: Self.key(fake, "vod", "13")))
        #expect(service.remoteCount(kind: .vod, categoryID: Self.key(fake, "vod", "13")) == nil)
    }

    @Test func cursorsRecordWhatIsLeft() async throws {
        let (service, fake) = await importedService(Self.hugeCatalog())
        let action = Self.key(fake, "vod", "10")
        let adult = Self.key(fake, "vod", "11")
        let family = Self.key(fake, "vod", "12")
        #expect(service.canLoadMore(kind: .vod, categoryID: action))
        #expect(service.canLoadMore(kind: .vod, categoryID: family))
        #expect(!service.canLoadMore(kind: .vod, categoryID: adult)) // one page holds it all
        #expect(service.remoteCount(kind: .vod, categoryID: action) == 5)
        #expect(service.remoteCount(kind: .vod, categoryID: adult) == 1)
        #expect(service.remoteCount(kind: .vod, categoryID: family) == 4)

        // Shows were few: imported whole, nothing to browse.
        let drama = Self.key(fake, "series", "20")
        #expect(!service.canLoadMore(kind: .series, categoryID: drama))
        #expect(service.remoteCount(kind: .series, categoryID: drama) == nil)
        #expect(service.series().count == 2)
    }

    // MARK: Small catalogs

    @Test func aSmallCatalogImportsWholeWithNoCursors() async throws {
        var fixture = Fixtures.catalog()
        fixture.pageSize = 3
        let (service, fake) = await importedService(fixture)
        let action = Self.key(fake, "vod", "10")
        #expect(!fake.calls.contains { $0.hasPrefix("movies(10,") })
        #expect(service.count(CatalogModel.Entity.movie, NSPredicate(value: true)) == 10)
        #expect(!service.canLoadMore(kind: .vod, categoryID: action))
        #expect(service.remoteCount(kind: .vod, categoryID: action) == nil)
        #expect(await service.loadMore(kind: .vod, categoryID: action) == false)
        #expect(!fake.calls.contains { $0.hasPrefix("movies(10,") })
    }

    @Test(arguments: [(5_000, false), (5_001, true)])
    func theLimitIsFiveThousand(total: Int, browses: Bool) async throws {
        var fixture = Fixtures.catalog()
        fixture.pageSize = 2
        fixture.reportedTotals = ["vod/all": total]
        let (service, fake) = await importedService(fixture)
        #expect(CatalogImporter.fullImportLimit == 5_000)
        #expect(fake.calls.contains("movies(10,0)") == browses)
        #expect(service.canLoadMore(kind: .vod, categoryID: Self.key(fake, "vod", "10")) == browses)
        #expect(service.count(CatalogModel.Entity.movie, NSPredicate(value: true)) == (browses ? 5 : 10))
    }

    @Test func aProviderThatOnlyListsByCategoryIsMeasuredByItsCategories() async throws {
        // No list of everything (`notSupported`): the categories' own totals
        // decide, here one category past the limit.
        var big = Fixtures.catalog()
        big.listsNeedCategory = true
        big.pageSize = 2
        big.reportedTotals = ["vod/10": 6_000]
        let (service, fake) = await importedService(big)
        #expect(service.canLoadMore(kind: .vod, categoryID: Self.key(fake, "vod", "10")))
        #expect(service.remoteCount(kind: .vod, categoryID: Self.key(fake, "vod", "10")) == 6_000)
        #expect(service.count(CatalogModel.Entity.movie, NSPredicate(value: true)) == 5)

        // Small: every category paged to the end, no cursors.
        var small = Fixtures.catalog()
        small.listsNeedCategory = true
        small.pageSize = 2
        let (smallService, smallFake) = await importedService(small)
        #expect(!smallService.canLoadMore(kind: .vod, categoryID: Self.key(smallFake, "vod", "10")))
        #expect(smallService.count(CatalogModel.Entity.movie, NSPredicate(value: true)) == 10)
    }

    // MARK: Searching the provider

    static let searching = SourceCapabilities(hasMovies: true, hasSeries: true, hasFullGuide: false, hasCatchup: true, reportsStreamCount: false, searchesCatalog: true)

    @Test func aSearchAsksAPortalThatIsntAllHere() async throws {
        let (service, fake) = await importedService(Self.hugeCatalog(), capabilities: Self.searching)
        #expect(service.searchesProviders)
        // Echo is on Action's third page, which nobody has browsed to.
        #expect(service.search("echo").movies.isEmpty)
        let revision = service.revision

        #expect(await service.searchProviders("Echo") == 1)
        #expect(service.search("echo").movies.map(\.name) == ["Echo"])
        #expect(service.revision > revision)
        // Both pages went out at once.
        #expect(Set(fake.calls.filter { $0.hasPrefix("search(") }) == ["search(Echo,0)", "search(Echo,1)"])
        // It joined its category, where browsing won't store it twice.
        let action = Self.key(fake, "vod", "10")
        #expect(Self.names(service.movies(categoryID: action)).contains("Echo"))
        _ = await service.loadMore(kind: .vod, categoryID: action)
        _ = await service.loadMore(kind: .vod, categoryID: action)
        #expect(service.movies(categoryID: action).filter { $0.name == "Echo" }.count == 1)
    }

    @Test func aQueryIsAskedOnceALaunch() async throws {
        let (service, fake) = await importedService(Self.hugeCatalog(), capabilities: Self.searching)
        _ = await service.searchProviders("echo")
        _ = await service.searchProviders(" Echo ")
        #expect(fake.callCount("search(") == 2)
        // Too short to send.
        #expect(await service.searchProviders("e") == 0)
        #expect(fake.callCount("search(") == 2)
    }

    @Test func aCatalogKeptWholeIsNeverSearchedRemotely() async throws {
        let (service, fake) = await importedService(Fixtures.catalog(), capabilities: Self.searching)
        #expect(!service.searchesProviders)
        #expect(await service.searchProviders("echo") == 0)
        #expect(fake.callCount("search(") == 0)
    }

    // MARK: Loading more

    @Test func loadMoreAppendsPagesUntilTheProviderHasNoMore() async throws {
        let (service, fake) = await importedService(Self.hugeCatalog())
        let action = Self.key(fake, "vod", "10")
        let revision = service.revision

        #expect(await service.loadMore(kind: .vod, categoryID: action))
        #expect(fake.calls.contains("movies(10,1)"))
        #expect(Self.names(service.movies(categoryID: action)) == ["Grey's Day", "Alpha", "Zulu", "Delta"])
        #expect(service.canLoadMore(kind: .vod, categoryID: action))
        #expect(service.revision > revision)

        // The last page: added, and the end.
        #expect(await service.loadMore(kind: .vod, categoryID: action))
        #expect(Self.names(service.movies(categoryID: action)) == ["Grey's Day", "Alpha", "Zulu", "Delta", "Echo"])
        #expect(!service.canLoadMore(kind: .vod, categoryID: action))

        // Nothing more is asked for.
        #expect(await service.loadMore(kind: .vod, categoryID: action) == false)
        #expect(!fake.calls.contains("movies(10,3)"))
        #expect(fake.callCount("movies(10,") == 3)
        // Other categories are untouched.
        #expect(Self.names(service.movies(categoryID: Self.key(fake, "vod", "12"))) == ["Café Society", "Bravo"])
    }

    @Test func loadMoreNeverStoresATitleTwice() async throws {
        let (service, fake) = await importedService(Self.hugeCatalog())
        let action = Self.key(fake, "vod", "10")
        // A title added at the top shifts the pages: page 1 now repeats Alpha
        // (m4), already stored from page 0.
        fake.update { $0.movies.insert(RemoteMovie(id: "m0", name: "Aardvark", categoryID: "10"), at: 0) }

        #expect(await service.loadMore(kind: .vod, categoryID: action))
        #expect(service.count(CatalogModel.Entity.movie, NSPredicate(format: "remoteID == %@", "m4")) == 1)
        #expect(Self.names(service.movies(categoryID: action)) == ["Grey's Day", "Alpha", "Zulu"])
        #expect(service.movies(categoryID: action).count == 3)
        #expect(service.canLoadMore(kind: .vod, categoryID: action))
    }

    @Test func aFailedPageIsAskedForAgain() async throws {
        let (service, fake) = await importedService(Self.hugeCatalog())
        let action = Self.key(fake, "vod", "10")
        fake.update { $0.failure = .moviesPage(1, SourceError(.unreachable)) }
        #expect(await service.loadMore(kind: .vod, categoryID: action) == false)
        #expect(service.canLoadMore(kind: .vod, categoryID: action))
        #expect(service.movies(categoryID: action).count == 2)

        fake.update { $0.failure = nil }
        #expect(await service.loadMore(kind: .vod, categoryID: action))
        #expect(fake.callCount("movies(10,1)") == 2)
        #expect(service.movies(categoryID: action).count == 4)
    }

    @Test func loadMoreRefusesWhatItCannotPage() async throws {
        let (service, fake) = await importedService(Self.hugeCatalog())
        let before = fake.calls.count
        #expect(await service.loadMore(kind: .live, categoryID: Self.key(fake, "live", "1")) == false)
        #expect(await service.loadMore(kind: .vod, categoryID: "not-a-category-id") == false)
        #expect(await service.loadMore(kind: .vod, categoryID: Self.key(fake, "vod", "13")) == false)
        #expect(await service.loadMore(kind: .vod, categoryID: CategoryKey.make(source: UUID(), kind: "vod", remoteID: "10")) == false)
        #expect(fake.calls.count == before)
    }

    @Test func aRefreshStartsBrowsingOver() async throws {
        let (service, fake) = await importedService(Self.hugeCatalog())
        let action = Self.key(fake, "vod", "10")
        _ = await service.loadMore(kind: .vod, categoryID: action)
        _ = await service.loadMore(kind: .vod, categoryID: action)
        #expect(!service.canLoadMore(kind: .vod, categoryID: action))

        // A new generation holds first pages again, with fresh cursors.
        await service.refresh(sourceID: fake.configuration.id, force: true)
        #expect(service.canLoadMore(kind: .vod, categoryID: action))
        #expect(service.movies(categoryID: action).count == 2)
        #expect(await service.loadMore(kind: .vod, categoryID: action))
        #expect(fake.callCount("movies(10,1)") == 2)
    }

    // MARK: Relaunch

    @Test func cursorsSurviveReopeningTheStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CatalogKitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Catalog.sqlite")

        let fake = FakeSourceClient(configuration: Fixtures.configuration(), fixture: Self.hugeCatalog())
        let action = Self.key(fake, "vod", "10")
        let family = Self.key(fake, "vod", "12")
        let first = await importedService([fake], storeURL: url)
        #expect(await first.loadMore(kind: .vod, categoryID: action)) // Action reaches page 2

        // A second launch reads the cursors back (browseJSON) without importing again.
        let second = CatalogService(storeURL: url, clientFactory: { _ in fake })
        second.setSources([fake.configuration])
        await second.waitForBackgroundRefreshes()
        #expect(fake.callCount("channels") == 1)
        #expect(second.canLoadMore(kind: .vod, categoryID: action))
        #expect(second.remoteCount(kind: .vod, categoryID: action) == 5)
        #expect(second.canLoadMore(kind: .vod, categoryID: family))
        #expect(!second.canLoadMore(kind: .vod, categoryID: Self.key(fake, "vod", "11")))
        #expect(second.movies(categoryID: action).count == 4)

        // Each carries on from the page it reached.
        #expect(await second.loadMore(kind: .vod, categoryID: action))
        #expect(fake.calls.contains("movies(10,2)"))
        #expect(fake.callCount("movies(10,1)") == 1)
        #expect(!second.canLoadMore(kind: .vod, categoryID: action))
        #expect(second.movies(categoryID: action).count == 5)

        #expect(await second.loadMore(kind: .vod, categoryID: family))
        #expect(fake.calls.contains("movies(12,1)"))
    }
}
