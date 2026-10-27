import CatalogKit
import Core
import Foundation
import HouseholdKit
import PlayerKit
import SourceKit
import Testing
@testable import Hearth

// The player's items from play intents: what each kind records, which item
// channel up/down and next episode reach, and where a play resumes. The
// catalog is in memory, fed by a fake provider; nothing reaches the network.

/// A provider in memory: four channels in two categories, one film, one show.
struct FixtureSourceClient: SourceClient {
    let configuration: SourceConfiguration
    var capabilities: SourceCapabilities {
        SourceCapabilities(hasMovies: true, hasSeries: true, hasFullGuide: false, hasCatchup: true, reportsStreamCount: false)
    }

    static let channels = [
        RemoteChannel(id: "ch101", number: 101, name: "Cityline News", categoryID: "news", hasArchive: true, archiveDays: 7, command: "https://stream.invalid/101.m3u8", formatHint: .hls),
        RemoteChannel(id: "ch108", number: 108, name: "Harbourside News 24", categoryID: "news", command: "https://stream.invalid/108.ts", formatHint: .mpegts),
        RemoteChannel(id: "ch109", number: 109, name: "Meridian Business", categoryID: "news", command: "https://stream.invalid/109.m3u8", formatHint: .hls),
        RemoteChannel(id: "ch102", number: 102, name: "Fieldhouse Sports", categoryID: "sports", command: "https://stream.invalid/102.m3u8", formatHint: .hls),
    ]
    static let movie = RemoteMovie(id: "m1", name: "The Quiet Engine", categoryID: "drama", year: 1962, durationSeconds: 6000, genre: "Drama", command: "https://stream.invalid/m1.mp4")
    static let series = RemoteSeries(id: "s1", name: "The Long Harbor", categoryID: "s-drama")
    static let episodes = [
        RemoteEpisode(id: "e3", seriesID: "s1", season: 2, number: 1, title: "Low Tide", durationSeconds: 2700),
        RemoteEpisode(id: "e1", seriesID: "s1", season: 1, number: 1, title: "Arrival", durationSeconds: 2700),
        RemoteEpisode(id: "e2", seriesID: "s1", season: 1, number: 2, title: "The Lighthouse Keeper", durationSeconds: 2700),
    ]

    func signIn() async throws -> AccountInfo { AccountInfo(status: .active) }
    func accountInfo() async throws -> AccountInfo { AccountInfo(status: .active) }

    func categories(_ kind: ContentKind) async throws -> [RemoteCategory] {
        switch kind {
        case .live: [RemoteCategory(id: "news", name: "News", kind: .live, sortOrder: 0), RemoteCategory(id: "sports", name: "Sports", kind: .live, sortOrder: 1)]
        case .vod: [RemoteCategory(id: "drama", name: "Drama", kind: .vod)]
        case .series: [RemoteCategory(id: "s-drama", name: "Drama", kind: .series)]
        }
    }

    func channels() async throws -> [RemoteChannel] { Self.channels }

    func movies(categoryID: String?, page: Int) async throws -> Page<RemoteMovie> {
        Page(items: page == 0 ? [Self.movie] : [], page: page, totalItems: 1, hasMore: false)
    }

    func series(categoryID: String?, page: Int) async throws -> Page<RemoteSeries> {
        Page(items: page == 0 ? [Self.series] : [], page: page, totalItems: 1, hasMore: false)
    }

    func seriesDetail(_ series: RemoteSeries) async throws -> SeriesDetail {
        SeriesDetail(series: series, seasons: [RemoteSeason(number: 1), RemoteSeason(number: 2)], episodes: Self.episodes)
    }

    func shortGuide(for channel: RemoteChannel, limit: Int) async throws -> [RemoteProgramme] { [] }
    func fullGuide() -> AsyncThrowingStream<RemoteProgramme, Error>? { nil }

    func streamLink(for request: StreamRequest) async throws -> StreamLink {
        switch request {
        case .live(let channel):
            StreamLink(url: URL(string: channel.command)!, headers: ["User-Agent": "Fixture"], formatHint: channel.formatHint, isLive: true)
        case .catchup(let channel, _, _):
            StreamLink(url: URL(string: channel.command + "?archive")!, formatHint: channel.formatHint)
        case .movie(let movie):
            StreamLink(url: URL(string: movie.command ?? "https://stream.invalid/none")!, formatHint: .mp4)
        case .episode(let episode, _):
            StreamLink(url: URL(string: "https://stream.invalid/\(episode.id).mkv")!, formatHint: .mkv)
        }
    }

    func keepAlive() async {}
}

@MainActor
struct FactoryFixture {
    let catalog: CatalogService
    let store: HouseholdStore
    let factory: PlayerItemFactory
    let source: UUID
    var profileID: UUID { store.profiles[0].id }

    init() async throws {
        let configuration = SourceConfiguration(id: UUID(), name: "Fixture Provider", kind: .stalker, serverURL: "http://portal.invalid/c/")
        let client = FixtureSourceClient(configuration: configuration)
        catalog = CatalogService(storeURL: nil, clientFactory: { _ in client })
        catalog.setSources([configuration])
        await catalog.waitForBackgroundRefreshes()
        store = try makeHouseholdStore()
        source = configuration.id
        factory = PlayerItemFactory(catalog: catalog, store: store, profileID: store.profiles[0].id)
    }

    func channelKey(_ id: String) -> ItemKey { .channel(source: source, id: id) }
    func episodeKey(_ season: Int, _ number: Int) -> ItemKey { .episode(source: source, seriesID: "s1", season: season, number: number) }
    var movieKey: ItemKey { .movie(source: source, id: "m1") }
}

@MainActor
@Suite struct PlayerItemFactoryTests {
    // MARK: Live (LIV-5)

    @Test func aLiveChannelRecordsNoProgressAndPlaysLive() async throws {
        let fixture = try await FactoryFixture()
        let key = fixture.channelKey("ch101")
        let prepared = try #require(fixture.factory.prepare(PlayIntent(itemKey: key.rawValue, kind: .live, title: "Cityline News")))
        #expect(prepared.item.id == key.rawValue)
        #expect(prepared.item.isLive)
        #expect(prepared.item.channelNumber == 101)
        #expect(prepared.item.subtitle == "101 Cityline News")
        #expect(prepared.item.hasArchive)
        #expect(!prepared.startsFromBeginning)
        #expect(prepared.context.progressKind == nil)
        #expect(prepared.context.sourceID == fixture.source)
        #expect(prepared.context.recordTitle == "Cityline News")
        #expect(prepared.context.channel?.key == key)
        #expect(fixture.factory.context(for: key.rawValue)?.itemKey == key)

        // A fresh link each time, mapped to the player's descriptor.
        let descriptor = try await prepared.item.resolve(.standard)
        #expect(descriptor.url.absoluteString == "https://stream.invalid/101.m3u8")
        #expect(descriptor.format == .hls)
        #expect(descriptor.isLive)
        #expect(descriptor.headers == ["User-Agent": "Fixture"])
    }

    /// No queue given: channel up and down walk the channel's own category,
    /// in guide order, and stop at its ends.
    @Test func withoutAQueueChannelUpAndDownWalkTheCategory() async throws {
        let fixture = try await FactoryFixture()
        let first = try #require(fixture.factory.prepare(PlayIntent(itemKey: fixture.channelKey("ch101").rawValue, kind: .live, title: "")))
        #expect(fixture.factory.neighbour(of: first.item, offset: -1) == nil)

        let second = try #require(fixture.factory.neighbour(of: first.item, offset: 1))
        #expect(second.id == fixture.channelKey("ch108").rawValue)
        #expect(second.isLive)
        let third = try #require(fixture.factory.neighbour(of: second, offset: 1))
        #expect(third.id == fixture.channelKey("ch109").rawValue)
        // Sports is another category: the end of News stops here.
        #expect(fixture.factory.neighbour(of: third, offset: 1) == nil)
        // The neighbour is registered, so its progress and stream are recorded.
        #expect(fixture.factory.context(for: third.id)?.recordTitle == "Meridian Business")
    }

    @Test func theIntentsQueueDecidesChannelUpAndDown() async throws {
        let fixture = try await FactoryFixture()
        let queue = [fixture.channelKey("ch102"), fixture.channelKey("ch101"), fixture.channelKey("ch109")].map(\.rawValue)
        let prepared = try #require(fixture.factory.prepare(PlayIntent(itemKey: fixture.channelKey("ch101").rawValue, kind: .live, title: "", queue: queue)))
        #expect(fixture.factory.neighbour(of: prepared.item, offset: -1)?.id == queue[0])
        #expect(fixture.factory.neighbour(of: prepared.item, offset: 1)?.id == queue[2])
        #expect(fixture.factory.neighbour(of: prepared.item, offset: 2) == nil)
    }

    // MARK: Catch-up (LIV-4)

    /// An aired programme plays like a recording, with its own progress row.
    @Test func anAiredProgrammePlaysFromTheArchive() async throws {
        let fixture = try await FactoryFixture()
        // Long gone, whatever today's date.
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        let end = start.addingTimeInterval(1800)
        let intent = PlayIntent(itemKey: fixture.channelKey("ch101").rawValue, kind: .catchup, title: "Evening Bulletin", catchupStart: start, catchupEnd: end)
        let prepared = try #require(fixture.factory.prepare(intent))
        #expect(prepared.item.id == intent.id)
        #expect(prepared.item.id.contains("@"))
        #expect(!prepared.item.isLive)
        #expect(!prepared.startsFromBeginning)
        #expect(prepared.context.progressKey == intent.id)
        #expect(prepared.context.progressKind == .catchup)
        #expect(prepared.context.durationHint == 1800)
        #expect(prepared.context.recordTitle == "Evening Bulletin")
        // Aired programmes have no channel up and down.
        #expect(fixture.factory.neighbour(of: prepared.item, offset: 1) == nil)
        #expect(try await prepared.item.resolve(.standard).url.absoluteString.hasSuffix("?archive"))
    }

    /// "From the start" on a programme still on air: the live channel,
    /// replayed from its start, so Jump to live still works.
    @Test func aProgrammeStillOnAirOpensLiveFromItsStart() async throws {
        let fixture = try await FactoryFixture()
        let start = Date.now.addingTimeInterval(-600)
        let intent = PlayIntent(itemKey: fixture.channelKey("ch101").rawValue, kind: .catchup, title: "Evening Bulletin", catchupStart: start, catchupEnd: start.addingTimeInterval(86_400))
        let prepared = try #require(fixture.factory.prepare(intent))
        #expect(prepared.startsFromBeginning)
        #expect(prepared.item.id == fixture.channelKey("ch101").rawValue)
        #expect(prepared.item.isLive)
        #expect(prepared.item.title == "Evening Bulletin")
        #expect(prepared.item.programmeStart == start)
        #expect(prepared.context.progressKind == nil)
    }

    @Test func catchupWithoutAStartIsUnplayable() async throws {
        let fixture = try await FactoryFixture()
        #expect(fixture.factory.prepare(PlayIntent(itemKey: fixture.channelKey("ch101").rawValue, kind: .catchup, title: "")) == nil)
    }

    // MARK: Movies

    @Test func aMovieRecordsProgressAndHasNoNeighbours() async throws {
        let fixture = try await FactoryFixture()
        let prepared = try #require(fixture.factory.prepare(PlayIntent(itemKey: fixture.movieKey.rawValue, kind: .movie, title: "")))
        #expect(prepared.item.title == "The Quiet Engine")
        #expect(prepared.item.subtitle == "1962 · Drama")
        #expect(!prepared.item.isLive)
        #expect(prepared.item.startPosition == nil)
        #expect(prepared.context.progressKind == .movie)
        #expect(prepared.context.progressKey == fixture.movieKey.rawValue)
        #expect(prepared.context.durationHint == 6000)
        #expect(prepared.context.channel == nil)
        #expect(fixture.factory.neighbour(of: prepared.item, offset: 1) == nil)
        #expect(try await prepared.item.resolve(.standard).format == .mp4)
    }

    @Test func aMovieResumesFromTheProfilesProgressUnlessAskedNotTo() async throws {
        let fixture = try await FactoryFixture()
        fixture.store.saveProgress(profileID: fixture.profileID, itemKey: fixture.movieKey.rawValue, kind: .movie, position: 900, duration: 6000)
        let resumed = try #require(fixture.factory.prepare(PlayIntent(itemKey: fixture.movieKey.rawValue, kind: .movie, title: "")))
        #expect(resumed.item.startPosition == 900)
        let fromStart = try #require(fixture.factory.prepare(PlayIntent(itemKey: fixture.movieKey.rawValue, kind: .movie, title: "", startPosition: 0)))
        #expect(fromStart.item.startPosition == nil)
    }

    // MARK: Episodes (SER-2)

    @Test func nextEpisodeFollowsSeasonAndNumberWithoutAQueue() async throws {
        let fixture = try await FactoryFixture()
        let series = try #require(fixture.catalog.series().first)
        _ = try await fixture.catalog.episodes(for: series)

        let first = fixture.episodeKey(1, 1)
        let prepared = try #require(fixture.factory.prepare(PlayIntent(itemKey: first.rawValue, kind: .episode, title: "The Long Harbor")))
        #expect(prepared.item.title == "The Long Harbor")
        #expect(prepared.item.subtitle == "S1 · E1 — Arrival")
        #expect(prepared.context.progressKind == .episode)
        #expect(prepared.context.recordTitle == "The Long Harbor · \(HearthFormat.episodeCode(season: 1, episode: 1))")
        #expect(prepared.context.durationHint == 2700)

        // Up next has no intent: its title and line come from the catalog.
        let second = try #require(fixture.factory.neighbour(of: prepared.item, offset: 1))
        #expect(second.id == fixture.episodeKey(1, 2).rawValue)
        #expect(second.title == "The Long Harbor")
        #expect(second.subtitle == "S1 · E2 — The Lighthouse Keeper")
        #expect(fixture.factory.neighbour(of: second, offset: -1)?.id == first.rawValue)
        let third = try #require(fixture.factory.neighbour(of: second, offset: 1))
        #expect(third.id == fixture.episodeKey(2, 1).rawValue)
        #expect(fixture.factory.neighbour(of: third, offset: 1) == nil)
        #expect(try await third.resolve(.standard).format == .mkv)
    }

    /// Episodes load lazily: the show being in the catalog is enough to play.
    @Test func anEpisodeOfAVisibleShowPlaysBeforeItsEpisodesLoad() async throws {
        let fixture = try await FactoryFixture()
        let prepared = try #require(fixture.factory.prepare(PlayIntent(itemKey: fixture.episodeKey(1, 2).rawValue, kind: .episode, title: "")))
        #expect(prepared.item.subtitle == "S1 · E2")
        #expect(prepared.context.recordTitle == "The Long Harbor · \(HearthFormat.episodeCode(season: 1, episode: 2))")
        #expect(prepared.context.sourceID == fixture.source)
        #expect(prepared.context.durationHint == nil)
    }

    // MARK: Gone

    @Test func anItemNotInTheCatalogIsUnplayable() async throws {
        let fixture = try await FactoryFixture()
        let factory = fixture.factory
        #expect(factory.prepare(PlayIntent(itemKey: fixture.channelKey("gone").rawValue, kind: .live, title: "")) == nil)
        #expect(factory.prepare(PlayIntent(itemKey: ItemKey.movie(source: fixture.source, id: "gone").rawValue, kind: .movie, title: "")) == nil)
        #expect(factory.prepare(PlayIntent(itemKey: ItemKey.episode(source: fixture.source, seriesID: "gone", season: 1, number: 1).rawValue, kind: .episode, title: "")) == nil)
        // An episode key with no source can't name a stream.
        #expect(factory.prepare(PlayIntent(itemKey: "not-a-key/episode/s1/1/1", kind: .episode, title: "")) == nil)
        // Another source's channel, which the household doesn't have.
        #expect(factory.prepare(PlayIntent(itemKey: ItemKey.channel(source: UUID(), id: "ch101").rawValue, kind: .live, title: "")) == nil)
    }
}
