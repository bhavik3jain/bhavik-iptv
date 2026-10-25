import Foundation
import SourceKit
import Testing
@testable import CatalogKit

/// A service over the in-memory store whose sources are served by fakes,
/// with every source imported.
@MainActor
func importedService(_ fakes: [FakeSourceClient], storeURL: URL? = nil) async -> CatalogService {
    let byID = Dictionary(uniqueKeysWithValues: fakes.map { ($0.configuration.id, $0) })
    let service = CatalogService(storeURL: storeURL, clientFactory: { byID[$0.id]! })
    service.setSources(fakes.map(\.configuration))
    await service.waitForBackgroundRefreshes()
    return service
}

@MainActor
func importedService(_ fixture: FakeSourceClient.Fixture = Fixtures.catalog(), capabilities: SourceCapabilities = FakeSourceClient.fullCapabilities) async -> (CatalogService, FakeSourceClient) {
    let fake = FakeSourceClient(configuration: Fixtures.configuration(), capabilities: capabilities, fixture: fixture)
    return (await importedService([fake]), fake)
}

@MainActor
@Suite struct ImportTests {
    @Test func importsTheFixtureCatalog() async throws {
        let (service, fake) = await importedService()
        let sourceID = fake.configuration.id
        let state = try #require(service.refreshStates[sourceID])
        #expect(state.phase == .idle)
        #expect(state.channelCount == 6)
        #expect(state.movieCount == 10)
        #expect(state.seriesCount == 2)
        #expect(state.account?.status == .active)
        #expect(state.catalogRefreshedAt != nil)
        #expect(state.guideRefreshedAt != nil)
        #expect(service.account(sourceID: sourceID)?.maxConnections == 2)
        #expect(service.revision > 0)

        // By number then name, unnumbered last; every source labelled (SRC-7).
        let all = service.channels(applyingFilter: false)
        #expect(all.map(\.name) == ["BBC One", "Café TV", "No Category", "Cartoon Fun", "Sky Sports", "Late Night"])
        #expect(all.allSatisfy { $0.sourceName == "Provider A" })
        let bbc = try #require(all.first)
        #expect(bbc.key == .channel(source: sourceID, id: "101"))
        #expect(bbc.categoryID == CategoryKey.make(source: sourceID, kind: "live", remoteID: "1"))
        #expect(bbc.guideChannelID == "bbc1.uk")
        #expect(bbc.hasArchive && bbc.archiveDays == 3)

        let news = CategoryKey.make(source: sourceID, kind: "live", remoteID: "1")
        #expect(service.channels(categoryID: news).map(\.name) == ["BBC One", "Café TV"])
        #expect(service.categories(kind: .vod).map(\.name) == ["Action", "Family"])
        #expect(service.categories(kind: .series).map(\.name) == ["Drama"])
        #expect(service.series().map(\.name) == ["Grey's Anatomy", "The Office"])
    }

    @Test func pagesUntilTheProviderHasNoMore() async throws {
        var fixture = Fixtures.catalog()
        fixture.pageSize = 3
        let (service, fake) = await importedService(fixture)
        #expect(fake.calls.filter { $0.hasPrefix("movies(") } == ["movies(all,0)", "movies(all,1)", "movies(all,2)", "movies(all,3)"])
        #expect(service.refreshStates[fake.configuration.id]?.movieCount == 10)
        #expect(service.movies(sort: .name).count == 9) // the adult one is filtered
    }

    @Test func listsByCategoryWhenTheProviderWontListEverything() async throws {
        var fixture = Fixtures.catalog()
        fixture.listsNeedCategory = true
        fixture.pageSize = 2
        let (service, fake) = await importedService(fixture)
        let sourceID = fake.configuration.id
        #expect(fake.calls.contains("movies(10,0)") && fake.calls.contains("movies(12,0)"))
        // Items listed without a category are filed under the one asked for.
        let family = CategoryKey.make(source: sourceID, kind: "vod", remoteID: "12")
        #expect(Set(service.movies(categoryID: family).map(\.name)) == ["Café Society", "Bravo", "Charlie", "Foxtrot"])
        #expect(service.refreshStates[sourceID]?.movieCount == 10)
    }

    @Test func movieSorts() async throws {
        let (service, _) = await importedService()
        #expect(service.movies(sort: .dateAdded, limit: 3).map(\.name) == ["Grey's Day", "Café Society", "Zulu"])
        #expect(service.movies(sort: .name, limit: 3).map(\.name) == ["Alpha", "Bravo", "Café Society"])
        #expect(service.movies(sort: .year, limit: 2).map(\.name) == ["Zulu", "Grey's Day"])
        // Undated titles trail when sorting by date added.
        #expect(service.movies(sort: .dateAdded).last?.name == "Bravo")
    }

    @Test func aFailedRefreshKeepsTheLastGoodCatalog() async throws {
        let (service, fake) = await importedService()
        let sourceID = fake.configuration.id
        let before = service.channels(applyingFilter: false)
        let revision = service.revision

        fake.update {
            $0.channels[0].name = "BBC One HD"
            $0.movies.append(RemoteMovie(id: "m11", name: "Golf", categoryID: "10"))
            $0.failure = .moviesPage(0, SourceError(.unreachable, providerMessage: "Server busy, try later"))
        }
        await service.refresh(sourceID: sourceID, force: true)

        #expect(service.refreshStates[sourceID]?.phase == .failed(message: "Server busy, try later"))
        #expect(service.channels(applyingFilter: false) == before)
        #expect(service.movies().count == 9)
        #expect(service.revision == revision)

        // The next good refresh swaps in and clears out the old generation.
        fake.update { $0.failure = nil }
        await service.refresh(sourceID: sourceID, force: true)
        #expect(service.refreshStates[sourceID]?.phase == .idle)
        #expect(service.channels(applyingFilter: false).first?.name == "BBC One HD")
        #expect(service.movies().count == 10)
        #expect(service.count(CatalogModel.Entity.channel, NSPredicate(value: true)) == 6)
        #expect(service.count(CatalogModel.Entity.movie, NSPredicate(value: true)) == 11)
        #expect(service.count(CatalogModel.Entity.category, NSPredicate(value: true)) == 8)
    }

    @Test func aFailedGuideKeepsTheLastGuide() async throws {
        let (service, fake) = await importedService()
        let bbc = try #require(service.channels().first)
        fake.update { $0.failure = .guide(SourceError(.badResponse)) }
        await service.refreshGuide(sourceID: fake.configuration.id)
        guard case .failed = service.refreshStates[fake.configuration.id]?.phase else {
            Issue.record("expected the guide failure to show")
            return
        }
        #expect(service.nowAndNext(for: bbc).now?.title == "News at Noon")
        #expect(service.count(CatalogModel.Entity.programme, NSPredicate(value: true)) == 6)
    }

    @Test func freshCatalogsAreSkippedUnlessForced() async throws {
        let (service, fake) = await importedService()
        let sourceID = fake.configuration.id
        #expect(fake.callCount("channels") == 1)
        await service.refresh(sourceID: sourceID)
        await service.refreshAllIfStale()
        #expect(fake.callCount("channels") == 1)
        await service.refresh(sourceID: sourceID, force: true)
        #expect(fake.callCount("channels") == 2)
    }

    @Test func removedSourcesStopShowing() async throws {
        let a = FakeSourceClient(configuration: Fixtures.configuration("Provider A"), fixture: Fixtures.catalog())
        var other = Fixtures.catalog()
        other.channels = [RemoteChannel(id: "1", number: 4, name: "Channel Four", command: "x")]
        let b = FakeSourceClient(configuration: Fixtures.configuration("Provider B"), fixture: other)
        let service = await importedService([a, b])

        // Across sources by number, each labelled with its source (SRC-7).
        let names = service.channels(applyingFilter: false).map { "\($0.name)/\($0.sourceName)" }
        #expect(names.prefix(5) == ["BBC One/Provider A", "Café TV/Provider A", "No Category/Provider A", "Channel Four/Provider B", "Cartoon Fun/Provider A"])

        service.setSources([a.configuration])
        #expect(!service.channels().contains { $0.sourceID == b.configuration.id })
        #expect(service.refreshStates[b.configuration.id] == nil)
        #expect(!service.contains(.channel(source: b.configuration.id, id: "1")))

        // Added back, its rows are still there: no import needed (SRC-9).
        service.setSources([a.configuration, b.configuration])
        await service.waitForBackgroundRefreshes()
        #expect(service.channels().contains { $0.name == "Channel Four" })
        #expect(b.callCount("channels") == 1)
    }

    @Test func theStoreSurvivesARelaunchAndACorruptFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CatalogKitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Catalog.sqlite")
        try Data("not a database".utf8).write(to: url)

        let fake = FakeSourceClient(configuration: Fixtures.configuration(), fixture: Fixtures.catalog())
        let first = await importedService([fake], storeURL: url)
        #expect(first.refreshStates[fake.configuration.id]?.phase == .idle)
        #expect(first.channels().count == 5)

        // A second launch reads the catalog from disk without asking the provider.
        let second = CatalogService(storeURL: url, clientFactory: { _ in fake })
        second.setSources([fake.configuration])
        await second.waitForBackgroundRefreshes()
        #expect(second.channels().count == 5)
        #expect(second.refreshStates[fake.configuration.id]?.channelCount == 6)
        #expect(second.refreshStates[fake.configuration.id]?.account?.status == .active)
        #expect(fake.callCount("channels") == 1)
    }

    @Test(.timeLimit(.minutes(2)))
    func fiftyThousandMoviesImportQuickly() async throws {
        var fixture = Fixtures.catalog()
        fixture.movies = (0..<50_000).map { RemoteMovie(id: "bulk\($0)", name: "Movie number \($0)", categoryID: "10", year: 1950 + $0 % 70) }
        fixture.pageSize = 2_500
        let clock = ContinuousClock()
        let start = clock.now
        let (service, fake) = await importedService(fixture)
        let elapsed = clock.now - start
        #expect(service.refreshStates[fake.configuration.id]?.movieCount == 50_000)
        #expect(elapsed < .seconds(120))
        #expect(service.search("movie number 4999").movies.count == 15)
    }
}

@MainActor
@Suite struct FilterTests {
    @Test func adultCategoriesAreHiddenByNameAndByID() async throws {
        let (service, fake) = await importedService()
        let sourceID = fake.configuration.id
        #expect(!service.channels().contains { $0.name == "Late Night" })
        #expect(!service.movies().contains { $0.name == "Night Moves" })
        #expect(service.categories(kind: .live).map(\.name) == ["News", "Sports", "Kids"])
        let unfiltered = service.categories(kind: .live, applyingFilter: false)
        #expect(unfiltered.first { $0.name == "XXX Adult" }?.isAdult == true)

        let sports = CategoryKey.make(source: sourceID, kind: "live", remoteID: "2")
        service.filter.adultCategoryIDs = [sports]
        #expect(!service.channels().contains { $0.name == "Sky Sports" })
        #expect(service.categories(kind: .live, applyingFilter: false).first { $0.id == sports }?.isAdult == true)

        service.filter = .unrestricted
        #expect(service.channels().count == 6)
        #expect(service.movies().count == 10)
    }

    @Test func kidsSeeOnlyAllowedCategories() async throws {
        let (service, fake) = await importedService()
        let sourceID = fake.configuration.id
        let kids = CategoryKey.make(source: sourceID, kind: "live", remoteID: "4")
        let family = CategoryKey.make(source: sourceID, kind: "vod", remoteID: "12")
        service.filter = CatalogFilter(allowedCategoryIDs: [kids, family])
        #expect(service.channels().map(\.name) == ["Cartoon Fun"])
        #expect(service.categories(kind: .live).map(\.name) == ["Kids"])
        #expect(Set(service.movies().map(\.name)) == ["Café Society", "Bravo", "Charlie", "Foxtrot"])
        #expect(service.series().isEmpty)
        #expect(service.channel(.channel(source: sourceID, id: "101")) == nil)
        #expect(service.channels(applyingFilter: false).count == 6)

        // SRCH-3: search sees only what the profile may watch.
        let results = service.search("cafe", now: Fixtures.now)
        #expect(results.channels.isEmpty)
        #expect(results.programmes.isEmpty)
        #expect(results.movies.map(\.name) == ["Café Society"])
    }

    @Test func hiddenCategoriesAndSources() async throws {
        let a = FakeSourceClient(configuration: Fixtures.configuration("Provider A"), fixture: Fixtures.catalog())
        let b = FakeSourceClient(configuration: Fixtures.configuration("Provider B"), fixture: Fixtures.catalog())
        let service = await importedService([a, b])
        #expect(service.channels().count == 10)

        let news = CategoryKey.make(source: a.configuration.id, kind: "live", remoteID: "1")
        service.filter.hiddenCategoryIDs = [news]
        let visible = service.channels()
        #expect(visible.count == 8)
        // Uncategorised channels stay visible under a hide rule.
        #expect(visible.filter { $0.name == "No Category" }.count == 2)
        #expect(!visible.contains { $0.sourceID == a.configuration.id && $0.name == "BBC One" })

        service.filter = CatalogFilter(visibleSourceIDs: [b.configuration.id])
        #expect(service.channels().allSatisfy { $0.sourceID == b.configuration.id })
        #expect(service.categories(kind: .live).allSatisfy { $0.sourceID == b.configuration.id })
        #expect(service.search("bbc").channels.count == 1)
        #expect(service.channels(applyingFilter: false).count == 12)
    }

    @Test func changingTheFilterBumpsTheRevision() async throws {
        let (service, _) = await importedService()
        let revision = service.revision
        service.filter = CatalogFilter()
        #expect(service.revision == revision)
        service.filter.hidesAdult = false
        #expect(service.revision == revision + 1)
    }
}

@MainActor
@Suite struct GuideTests {
    @Test func nowAndNextAndTheWindow() async throws {
        let (service, _) = await importedService()
        let channels = service.channels()
        let bbc = try #require(channels.first { $0.name == "BBC One" })
        let cafe = try #require(channels.first { $0.name == "Café TV" })
        let now = Fixtures.now

        let (current, next) = service.nowAndNext(for: bbc, at: now)
        #expect(current?.title == "News at Noon")
        #expect(next?.title == "Café Culture")
        #expect(current?.progress(at: now) == 0.5)
        // A channel without a guide id is joined on its own id.
        #expect(service.nowAndNext(for: cafe, at: now).now?.title == "Morning Café")

        let hour = service.programmes(for: bbc, from: now.addingTimeInterval(-3_600), to: now.addingTimeInterval(3_600))
        #expect(hour.map(\.title) == ["News at Noon", "Café Culture"])

        // Kept from 7 days back to 7 ahead.
        let range = try #require(service.guideRange())
        #expect(range.lowerBound == now.addingTimeInterval(-86_400))
        #expect(range.upperBound == now.addingTimeInterval(2 * 86_400 + 3_600))

        // LIV-4: aired programmes inside the channel's archive can be replayed.
        let week = service.programmes(for: bbc, from: now.addingTimeInterval(-7 * 86_400), to: now.addingTimeInterval(7 * 86_400))
        #expect(week.first { $0.title == "Old Show" }?.hasArchive == true)
        #expect(week.first { $0.title == "Café Culture" }?.hasArchive == false)
        #expect(service.nowAndNext(for: cafe, at: now).now?.hasArchive == false)
    }

    @Test func shortGuidesLoadOnDemandAndAreThrottled() async throws {
        var fixture = Fixtures.catalog()
        let now = Date.now
        fixture.shortGuides = ["101": [
            RemoteProgramme(guideChannelID: "bbc1.uk", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(600), title: "Short Now"),
            RemoteProgramme(guideChannelID: "bbc1.uk", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1_800), title: "Short Next"),
        ]]
        let stalkerLike = SourceCapabilities(hasMovies: true, hasSeries: true, hasFullGuide: false, hasCatchup: true, reportsStreamCount: false)
        let (service, fake) = await importedService(fixture, capabilities: stalkerLike)
        #expect(fake.callCount("fullGuide") == 0)
        let bbc = try #require(service.channels().first)
        #expect(service.nowAndNext(for: bbc).now == nil)

        let revision = service.revision
        await service.loadShortGuide(for: Array(service.channels().prefix(3)))
        #expect(service.revision == revision + 1)
        #expect(service.nowAndNext(for: bbc).now?.title == "Short Now")
        #expect(service.nowAndNext(for: bbc).next?.title == "Short Next")
        #expect(fake.callCount("shortGuide") == 3)

        await service.loadShortGuide(for: [bbc])
        #expect(fake.callCount("shortGuide") == 3)
    }
}

@MainActor
@Suite struct SearchTests {
    @Test func normalisation() {
        #expect(SearchKey.normalize("Café") == "cafe")
        #expect(SearchKey.normalize("Grey's Anatomy") == "greys anatomy")
        #expect(SearchKey.normalize("S.W.A.T.") == "swat")
        #expect(SearchKey.normalize("  Hello,   World!! ") == "hello world")
        #expect(SearchKey.normalize("Ñandú – Señor") == "nandu senor")
        #expect(SearchKey.normalize("ＦＵＬＬ ｗｉｄｔｈ") == "full width")
        #expect(SearchKey.normalize("BBC One HD") == "bbc one hd")
        #expect(SearchKey.normalize("!!!") == "")
        #expect(SearchKey.tokens("Café-Society") == ["cafe", "society"])
    }

    @Test func adultNames() {
        #expect(AdultContent.matches("XXX Adult"))
        #expect(AdultContent.matches("For Adults 18+"))
        #expect(AdultContent.matches("+18 Movies"))
        #expect(AdultContent.matches("PORN"))
        #expect(!AdultContent.matches("Sports 1"))
        #expect(!AdultContent.matches("Kids"))
    }

    @Test func searchFindsEveryGroup() async throws {
        let (service, _) = await importedService()
        let results = service.search("CAFÉ!!", now: Fixtures.now)
        #expect(results.channels.map(\.name) == ["Café TV"])
        #expect(results.movies.map(\.name) == ["Café Society"])
        // The next 24 hours only, each shown with its channel.
        #expect(results.programmes.map(\.programme.title) == ["Morning Café", "Café Culture"])
        #expect(results.programmes.map(\.channel.name) == ["Café TV", "BBC One"])

        let greys = service.search("grey's", now: Fixtures.now)
        #expect(greys.series.map(\.name) == ["Grey's Anatomy"])
        #expect(greys.movies.map(\.name) == ["Grey's Day"])
        #expect(service.search("greys anatomy").series.count == 1)
        #expect(service.search("anatomy greys").series.count == 1)
        #expect(service.search("   ").isEmpty)
        #expect(service.search("zzz").isEmpty)
        // Adult content stays out of search too.
        #expect(service.search("night").movies.isEmpty)
        #expect(service.search("night").channels.isEmpty)
    }

    @Test func searchRanksPrefixMatchesFirst() async throws {
        var fixture = Fixtures.catalog()
        fixture.movies = [
            RemoteMovie(id: "a", name: "A Star Is Born", categoryID: "10"),
            RemoteMovie(id: "b", name: "Star Wars", categoryID: "10"),
            RemoteMovie(id: "c", name: "Lone Star", categoryID: "10"),
        ]
        let (service, _) = await importedService(fixture)
        #expect(service.search("star").movies.map(\.name) == ["Star Wars", "A Star Is Born", "Lone Star"])
        #expect(service.search("star", limitPerGroup: 1).movies.map(\.name) == ["Star Wars"])
    }

    @Test func findChannelByNameOrNumber() async throws {
        let (service, _) = await importedService()
        #expect(service.findChannels("1").map(\.name) == ["BBC One", "Sky Sports"])
        #expect(service.findChannels("10").map(\.name) == ["Sky Sports"])
        #expect(service.findChannels("sky").map(\.name) == ["Sky Sports"])
        #expect(service.findChannels("cafe").map(\.name) == ["Café TV"])
        #expect(service.findChannels("").isEmpty)
    }
}

@MainActor
@Suite struct StableKeyTests {
    @Test func episodesAreKeyedBySeasonAndNumber() async throws {
        let (service, fake) = await importedService()
        let sourceID = fake.configuration.id
        let anatomy = try #require(service.seriesItem(.series(source: sourceID, id: "s1")))
        let episodes = try await service.episodes(for: anatomy)
        #expect(episodes.map(\.key) == [
            .episode(source: sourceID, seriesID: "s1", season: 1, number: 1),
            .episode(source: sourceID, seriesID: "s1", season: 1, number: 2),
            .episode(source: sourceID, seriesID: "s1", season: 2, number: 1),
        ])
        #expect(episodes.allSatisfy { $0.seriesKey == anatomy.key })
        #expect(service.cachedEpisodes(seriesKey: anatomy.key) == episodes)

        // Fetched in the last day: served from the cache.
        _ = try await service.episodes(for: anatomy)
        #expect(fake.callCount("seriesDetail") == 1)

        // A provider reissuing episode ids keeps every key; the link is
        // asked with the new id.
        let key = ItemKey.episode(source: sourceID, seriesID: "s1", season: 1, number: 2)
        var detail = try #require(Fixtures.catalog().details["s1"])
        detail.episodes = detail.episodes.map { var episode = $0; episode.id = "new-" + episode.id; return episode }
        try await CatalogWriter.saveEpisodes(detail, seriesID: "s1", sourceID: sourceID, fetchedAt: .now, store: try #require(service.openedStore))
        service.catalogDidChange()
        #expect(service.cachedEpisodes(seriesKey: anatomy.key).map(\.key) == episodes.map(\.key))
        #expect(service.episode(key)?.remoteID == "new-e12")
        #expect(service.contains(key))

        let link = try await service.streamLink(for: key)
        #expect(link.url.absoluteString == "https://fake.test/episode/s1/new-e12")
    }

    @Test func replacementKeysFollowRenumberingAndNewIDs() async throws {
        var fixture = Fixtures.catalog()
        fixture.channels.append(RemoteChannel(id: "201", number: 20, name: "News 24", command: "x"))
        let (service, fake) = await importedService(fixture)
        let sourceID = fake.configuration.id

        let bbc = ItemKey.channel(source: sourceID, id: "101")
        let sky = ItemKey.channel(source: sourceID, id: "103")
        let news = ItemKey.channel(source: sourceID, id: "201")
        let movie = ItemKey.movie(source: sourceID, id: "m1")
        let show = ItemKey.series(source: sourceID, id: "s1")
        let episode = ItemKey.episode(source: sourceID, seriesID: "s1", season: 1, number: 2)
        let missing = ItemKey.movie(source: sourceID, id: "never-existed")
        #expect(service.replacementKeys(for: [bbc, sky, news, movie, show, episode]).isEmpty)

        // The provider renumbers and re-ids: BBC One moves to 7 under a new
        // id, a movie and a show get new ids, News 24 now has a twin.
        fake.update {
            $0.channels[0] = RemoteChannel(id: "901", number: 7, name: "BBC  ONE", categoryID: "1", command: "y")
            $0.channels.removeLast()
            $0.channels.append(RemoteChannel(id: "202", number: 21, name: "News 24", command: "x"))
            $0.channels.append(RemoteChannel(id: "203", number: 22, name: "News-24", command: "x"))
            $0.movies[0].id = "m1-new"
            $0.series[0].id = "s9"
        }
        await service.refresh(sourceID: sourceID, force: true)

        #expect(!service.contains(bbc))
        #expect(service.contains(sky))
        #expect(service.contains(.channel(source: sourceID, id: "901")))
        let replacements = service.replacementKeys(for: [bbc, sky, news, movie, show, episode, missing])
        #expect(replacements == [
            bbc: .channel(source: sourceID, id: "901"),
            movie: .movie(source: sourceID, id: "m1-new"),
            show: .series(source: sourceID, id: "s9"),
            episode: .episode(source: sourceID, seriesID: "s9", season: 1, number: 2),
        ])

        // A key that comes back is no longer reported missing.
        fake.update { $0.channels[0].id = "101" }
        await service.refresh(sourceID: sourceID, force: true)
        #expect(service.contains(bbc))
        #expect(service.replacementKeys(for: [bbc]).isEmpty)
    }

    @Test func keysForOtherSourcesAndKindsAreNotContained() async throws {
        let (service, fake) = await importedService()
        let sourceID = fake.configuration.id
        #expect(service.contains(.movie(source: sourceID, id: "m1")))
        #expect(!service.contains(.channel(source: sourceID, id: "m1")))
        #expect(!service.contains(.movie(source: UUID(), id: "m1")))
        #expect(!service.contains(ItemKey(rawValue: "garbage")))
        // Episodes count while their show is in the catalog.
        #expect(service.contains(.episode(source: sourceID, seriesID: "s2", season: 4, number: 1)))
        #expect(!service.contains(.episode(source: sourceID, seriesID: "s404", season: 1, number: 1)))
    }
}

@MainActor
@Suite struct PlayingTests {
    @Test func streamLinksRebuildTheRequestFromTheStore() async throws {
        let (service, fake) = await importedService()
        let sourceID = fake.configuration.id
        let bbc = ItemKey.channel(source: sourceID, id: "101")

        let live = try await service.streamLink(for: bbc)
        #expect(live.url.absoluteString == "https://fake.test/live/101")
        #expect(live.headers == ["User-Agent": "FakeBox/1.0"])
        guard case .live(let channel) = fake.streamRequests.last else {
            Issue.record("expected a live request")
            return
        }
        #expect(channel == Fixtures.catalog().channels[0])

        let start = Fixtures.now.addingTimeInterval(-86_400)
        _ = try await service.streamLink(for: .channel(source: sourceID, id: "103"), catchupStart: start, catchupDuration: 1_800)
        guard case .catchup(let sports, let catchupStart, let duration) = fake.streamRequests.last else {
            Issue.record("expected a catch-up request")
            return
        }
        #expect(sports.catchupMode == "default" && sports.catchupSource == "?utc={utc}&lutc={lutc}")
        #expect(catchupStart == start && duration == 1_800)

        let movie = try await service.streamLink(for: .movie(source: sourceID, id: "m1"))
        #expect(movie.url.absoluteString == "https://fake.test/movie/m1.mkv")
        guard case .movie(let remoteMovie) = fake.streamRequests.last else {
            Issue.record("expected a movie request")
            return
        }
        #expect(remoteMovie.command == "/media/m1.mkv" && remoteMovie.durationSeconds == 5_400)

        await #expect(throws: SourceError.self) {
            try await service.streamLink(for: .series(source: sourceID, id: "s1"))
        }
        await #expect(throws: SourceError.self) {
            try await service.streamLink(for: .movie(source: UUID(), id: "m1"))
        }
        await #expect(throws: SourceError.self) {
            try await service.streamLink(for: .episode(source: sourceID, seriesID: "s2", season: 1, number: 1))
        }

        await service.keepAlive(sourceID: sourceID)
        #expect(fake.callCount("keepAlive") == 1)
    }

    @Test func aFreshClientSignsInBeforeItsFirstLink() async throws {
        let (service, fake) = await importedService()
        let url = try #require(service.openedStore).container.persistentStoreDescriptions.first?.url
        #expect(url == CatalogStore.inMemoryURL)
        // An edited login gets a new client, which must sign in again.
        var edited = fake.configuration
        edited.password = "changed"
        service.setSources([edited])
        let before = fake.callCount("signIn")
        _ = try await service.streamLink(for: .channel(source: edited.id, id: "101"))
        _ = try await service.streamLink(for: .channel(source: edited.id, id: "101"))
        #expect(fake.callCount("signIn") == before + 1)
    }

    @Test func refreshAccountReadsAndRemembers() async throws {
        let (service, fake) = await importedService()
        let sourceID = fake.configuration.id
        fake.update { $0.account.activeConnections = 1 }
        let account = await service.refreshAccount(sourceID: sourceID)
        #expect(account?.activeConnections == 1)
        #expect(service.account(sourceID: sourceID)?.activeConnections == 1)
        #expect(await service.refreshAccount(sourceID: UUID()) == nil)
    }
}

@MainActor
@Suite struct SourceTestTests {
    @Test func countsWithoutWriting() async throws {
        var fixture = Fixtures.catalog()
        fixture.pageSize = 3
        let configuration = Fixtures.configuration()
        let fake = FakeSourceClient(configuration: configuration, fixture: fixture)
        let service = CatalogService(storeURL: nil, clientFactory: { _ in fake })

        let result = await service.testSource(configuration)
        #expect(result.succeeded)
        #expect(result.channelCount == 6)
        #expect(result.movieCount == 10)
        #expect(result.seriesCount == 2)
        #expect(result.account?.status == .active)
        #expect(result.steps.count == 5)
        #expect(result.steps.allSatisfy { $0.hasSuffix(" s)") })
        #expect(!result.steps.joined().contains(configuration.macAddress))
        #expect(service.channels(applyingFilter: false).isEmpty)
        #expect(service.refreshStates.isEmpty)
    }

    @Test func reportsTheProvidersOwnWords() async throws {
        var fixture = Fixtures.catalog()
        fixture.failure = .channels(SourceError(.authenticationFailed, providerMessage: "Your STB is blocked"))
        let configuration = Fixtures.configuration()
        let fake = FakeSourceClient(configuration: configuration, fixture: fixture)
        let service = CatalogService(storeURL: nil, clientFactory: { _ in fake })

        let result = await service.testSource(configuration)
        #expect(!result.succeeded)
        #expect(result.message == "Your STB is blocked")
        #expect(result.steps.count == 3)
        #expect(result.steps.last?.contains("Your STB is blocked") == true)
    }
}

@Suite struct RefreshPolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func state(catalogAge: TimeInterval?, guideAge: TimeInterval?) -> PersistedSourceState {
        var state = PersistedSourceState()
        state.generation = catalogAge == nil ? 0 : 1
        state.catalogRefreshedAt = catalogAge.map { now.addingTimeInterval(-$0) }
        state.guideRefreshedAt = guideAge.map { now.addingTimeInterval(-$0) }
        return state
    }

    @Test func catalogDailyGuideEverySixHours() {
        let hour: TimeInterval = 3_600
        #expect(RefreshPolicy.plan(for: state(catalogAge: nil, guideAge: nil), hasFullGuide: true, now: now, force: false) == .init(catalog: true, guide: true))
        #expect(RefreshPolicy.plan(for: state(catalogAge: hour, guideAge: hour), hasFullGuide: true, now: now, force: false).isEmpty)
        #expect(RefreshPolicy.plan(for: state(catalogAge: hour, guideAge: 7 * hour), hasFullGuide: true, now: now, force: false) == .init(catalog: false, guide: true))
        #expect(RefreshPolicy.plan(for: state(catalogAge: 25 * hour, guideAge: hour), hasFullGuide: true, now: now, force: false) == .init(catalog: true, guide: true))
        #expect(RefreshPolicy.plan(for: state(catalogAge: hour, guideAge: 7 * hour), hasFullGuide: false, now: now, force: false).isEmpty)
        #expect(RefreshPolicy.plan(for: state(catalogAge: hour, guideAge: hour), hasFullGuide: false, now: now, force: true) == .init(catalog: true, guide: false))
        // A stamp in the future (the clock moved) counts as stale.
        #expect(RefreshPolicy.plan(for: state(catalogAge: -hour, guideAge: hour), hasFullGuide: false, now: now, force: false).catalog)
    }
}
