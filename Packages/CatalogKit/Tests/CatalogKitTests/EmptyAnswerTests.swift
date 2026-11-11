import Foundation
import SourceKit
import Testing
@testable import CatalogKit

/// Titles and shows went missing again on build 114 (the owner, 2026-11-10).
/// One answer of nothing used to hide titles until the next day's refresh:
/// a held title's search was remembered as asked (My List read
/// "Unavailable"), a browsed category ended there, a refresh dropped the
/// category, a show's cached episodes were replaced with none. The owner's
/// portal has answered pages with nothing while the household's devices used
/// it (2026-11-08). An answer of nothing where titles were expected is now
/// asked once more before it's believed, and what was stored stays.
@MainActor
@Suite struct EmptyAnswerTests {
    static func service(_ fixture: FakeSourceClient.Fixture = CatalogBrowseTests.hugeCatalog()) async -> (CatalogService, FakeSourceClient) {
        await importedService(fixture, capabilities: CatalogBrowseTests.searching)
    }

    // MARK: Search

    @Test func aSearchAnsweredWithNothingIsAskedAgain() async throws {
        let (service, fake) = await Self.service()
        fake.update { $0.emptyAnswers = 2 }

        #expect(await service.searchProviders("Echo") == 1)
        #expect(service.search("echo").movies.map(\.name) == ["Echo"])
        #expect(fake.callCount("search(Echo") == 4)
    }

    /// A held title (My List's, from another device) is looked up by name.
    @Test func aHeldTitleIsFoundThoughTheFirstAnswerWasEmpty() async throws {
        let (service, fake) = await Self.service()
        let echo = ItemKey.movie(source: fake.configuration.id, id: "m9")
        #expect(!service.contains(echo))
        fake.update { $0.emptyAnswers = 2 }

        await service.resolveHeldItems([HeldItem(key: echo, title: "Echo")])
        #expect(service.movie(echo)?.name == "Echo")
    }

    /// Nothing twice is believed: the query is remembered as asked, and no
    /// sign-in is spent on it.
    @Test func nothingTwiceIsBelieved() async throws {
        var fixture = CatalogBrowseTests.hugeCatalog()
        fixture.unmatchedQueries = ["Nowhere"]
        let (service, fake) = await Self.service(fixture)
        let signIns = fake.callCount("signIn")

        #expect(await service.searchProviders("Nowhere") == 0)
        #expect(fake.callCount("search(Nowhere") == 4)
        #expect(await service.searchProviders("Nowhere") == 0)
        #expect(fake.callCount("search(Nowhere") == 4)
        #expect(fake.callCount("signIn") == signIns)
    }

    // MARK: Browsing

    @Test func aCategoryKeepsLoadingAfterAnEmptyPage() async throws {
        let (service, fake) = await Self.service()
        let action = CatalogBrowseTests.key(fake, "vod", "10")
        #expect(CatalogBrowseTests.names(service.movies(categoryID: action)) == ["Grey's Day", "Alpha"])
        fake.update { $0.emptyAnswers = 1 }

        #expect(await service.loadMore(kind: .vod, categoryID: action))
        #expect(CatalogBrowseTests.names(service.movies(categoryID: action)) == ["Grey's Day", "Alpha", "Zulu", "Delta"])
        #expect(service.canLoadMore(kind: .vod, categoryID: action))
    }

    /// The end of a category is still the end: an empty page asked twice.
    @Test func aCategoryThatReallyEndsStopsLoading() async throws {
        let (service, fake) = await Self.service()
        let action = CatalogBrowseTests.key(fake, "vod", "10")
        fake.update { $0.emptyAnswers = 2 }
        #expect(await !service.loadMore(kind: .vod, categoryID: action))
        #expect(!service.canLoadMore(kind: .vod, categoryID: action))
    }

    // MARK: Refreshing

    @Test func aRefreshAsksAgainForACategoryThatCameBackEmpty() async throws {
        let (service, fake) = await Self.service()
        let family = CatalogBrowseTests.key(fake, "vod", "12")
        let before = Set(service.categories(kind: .vod, applyingFilter: false).map(\.id))
        let signIns = fake.callCount("signIn")

        fake.update { $0.emptyOnceForMovieCategory = "12" }
        await service.refresh(sourceID: fake.configuration.id, force: true)

        #expect(Set(service.categories(kind: .vod, applyingFilter: false).map(\.id)) == before)
        #expect(CatalogBrowseTests.names(service.movies(categoryID: family)) == ["Café Society", "Bravo"])
        #expect(service.canLoadMore(kind: .vod, categoryID: family))
        #expect(fake.callCount("movies(12,0)") == 3)
        // Only the refresh's own sign-in.
        #expect(fake.callCount("signIn") == signIns + 1)
    }

    /// A category still listed whose first page answers nothing twice keeps
    /// its row, its titles and its cursor.
    @Test func aCategoryThatStaysEmptyIsKeptAsItWas() async throws {
        let (service, fake) = await Self.service()
        let family = CatalogBrowseTests.key(fake, "vod", "12")
        let stored = CatalogBrowseTests.names(service.movies(categoryID: family))
        #expect(stored == ["Café Society", "Bravo"])

        fake.update { fixture in
            fixture.movies.removeAll { $0.categoryID == "12" }
        }
        await service.refresh(sourceID: fake.configuration.id, force: true)

        #expect(service.categories(kind: .vod, applyingFilter: false).contains { $0.id == family })
        #expect(CatalogBrowseTests.names(service.movies(categoryID: family)) == stored)
        #expect(service.canLoadMore(kind: .vod, categoryID: family))
    }

    /// A category that never listed anything (a big portal files its series
    /// categories under `vod` too, with no movies) is still left out.
    @Test func aCategoryThatNeverListedAnythingIsStillLeftOut() async throws {
        let (service, fake) = await Self.service()
        let showsInVOD = CatalogBrowseTests.key(fake, "vod", "13")
        await service.refresh(sourceID: fake.configuration.id, force: true)
        #expect(!service.categories(kind: .vod, applyingFilter: false).contains { $0.id == showsInVOD })
    }

    // MARK: Episodes

    @Test func aShowKeepsItsEpisodesWhenTheProviderListsNone() async throws {
        let (service, fake) = await Self.service(Fixtures.catalog())
        let sourceID = fake.configuration.id
        let anatomy = try #require(service.seriesItem(.series(source: sourceID, id: "s1")))
        // Cached two days ago, so the next open asks the provider.
        let detail = try #require(Fixtures.catalog().details["s1"])
        try await CatalogWriter.saveEpisodes(detail, seriesID: "s1", sourceID: sourceID, fetchedAt: .now.addingTimeInterval(-2 * 86_400), store: try #require(service.openedStore))
        service.catalogDidChange()
        fake.update { $0.details["s1"] = SeriesDetail(series: detail.series, seasons: [], episodes: []) }

        #expect(try await service.episodes(for: anatomy).count == 3)
        #expect(service.cachedEpisodes(seriesKey: anatomy.key).count == 3)
        #expect(fake.callCount("seriesDetail") == 2)
    }

    @Test func aShowsEpisodesComeOnTheSecondAsk() async throws {
        let (service, fake) = await Self.service(Fixtures.catalog())
        let anatomy = try #require(service.seriesItem(.series(source: fake.configuration.id, id: "s1")))
        fake.update { $0.emptyAnswers = 1 }
        #expect(try await service.episodes(for: anatomy).count == 3)
    }
}
