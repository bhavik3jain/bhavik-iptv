import Foundation
import Testing
@testable import SourceKit

/// The `-StubProvider YES` catalog: believable, deterministic, and wide
/// enough to exercise every screen (adult filtering, archive, the VLC engine).
@Suite struct StubSourceClientTests {
    let client = StubSourceClient(configuration: .stub(), latency: .zero)

    @Test func theFactoryServesTheStubURL() {
        #expect(SourceClientFactory.make(.stub()) is StubSourceClient)
        #expect(SourceClientFactory.make(SourceConfiguration(name: "M", kind: .m3u, playlistURL: StubSourceClient.serverURL)) is StubSourceClient)
        #expect(SourceClientFactory.make(SourceConfiguration(name: "S", kind: .stalker, serverURL: "http://portal.test/c/", macAddress: "00:1A:79:00:00:01")) is StalkerClient)
        #expect(SourceClientFactory.make(SourceConfiguration(name: "X", kind: .xtream, serverURL: "http://x.test")) is XtreamClient)
        #expect(SourceClientFactory.make(SourceConfiguration(name: "P", kind: .m3u, playlistURL: "http://p.test/a.m3u")) is M3UClient)
    }

    @Test func channelsMatchTheMockups() async throws {
        let channels = try await client.channels()
        #expect((24...26).contains(channels.count))
        #expect(Set(channels.map(\.id)).count == channels.count)
        let named = Dictionary(uniqueKeysWithValues: channels.compactMap { channel in channel.number.map { ($0, channel.name) } })
        #expect(named[101] == "Cityline News")
        #expect(named[102] == "Fieldhouse Sports")
        #expect(named[103] == "Lantern Drama")
        #expect(named[104] == "Northwind Docs")
        #expect(named[105] == "Kestrel Cinema")
        #expect(named[106] == "Little Owl Kids")
        #expect(named[107] == "Pulse Music")
        let archived = channels.filter(\.hasArchive)
        #expect(archived.count * 3 >= channels.count) // about half
        #expect(archived.allSatisfy { $0.archiveDays == 7 })
        #expect(channels.allSatisfy { $0.logoURL == nil && $0.categoryID != nil })
    }

    @Test func oneInnocuousAdultChannel() async throws {
        let categories = try await client.categories(.live)
        #expect(categories.map(\.name) == ["News", "Sports", "Drama", "Docs", "Movies", "Kids", "Music", "Adult"])
        let adult = try await client.channels().filter { $0.categoryID == "adult" }
        #expect(adult.count == 1)
    }

    @Test func oneRawMPEGTSChannelForTheVLCEngine() async throws {
        let channels = try await client.channels()
        let ts = try #require(channels.first { $0.name == "MPEG-TS Test" })
        #expect(ts.formatHint == .mpegts)
        #expect(ts.command == "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/gear1/fileSequence0.ts")
        #expect(channels.filter { $0.formatHint == .hls }.count == channels.count - 1)
        let link = try await client.streamLink(for: .live(ts))
        #expect(link.formatHint == .mpegts)
        #expect(link.isLive)
    }

    @Test func linksAreApplesPublicSamples() async throws {
        let channel = try #require(try await client.channels().first { $0.hasArchive })
        let live = try await client.streamLink(for: .live(channel))
        #expect(live.url.host() == "devstreaming-cdn.apple.com")
        let catchup = try await client.streamLink(for: .catchup(channel, start: Date().addingTimeInterval(-7200), duration: 3600))
        #expect(catchup.url.host() == "devstreaming-cdn.apple.com")
        #expect(!catchup.isLive)
        let movie = try #require(try await client.movies(categoryID: nil, page: 0).items.first)
        #expect(try await client.streamLink(for: .movie(movie)).url.host() == "devstreaming-cdn.apple.com")
        let noArchive = try #require(try await client.channels().first { !$0.hasArchive })
        let error = await sourceError { try await client.streamLink(for: .catchup(noArchive, start: Date(), duration: 60)) }
        #expect(error?.code == .notSupported)
    }

    @Test func guideCoversAFortnightWithoutGaps() {
        let now = utc(2026, 10, 24, 20, 10)
        let channel = StubCatalog.channels[0]
        let from = now.addingTimeInterval(-7 * 86_400)
        let to = now.addingTimeInterval(7 * 86_400)
        let programmes = StubCatalog.programmes(for: channel, from: from, to: to, now: now)
        #expect(programmes.first.map { $0.start <= from } == true)
        #expect(programmes.last.map { $0.end >= to } == true)
        for (previous, next) in zip(programmes, programmes.dropFirst()) {
            #expect(previous.end == next.start)
        }
        let lengths = Set(programmes.map { Int($0.end.timeIntervalSince($0.start) / 60) })
        #expect(lengths.isSubset(of: [30, 60, 90]))
        #expect(programmes.allSatisfy { $0.guideChannelID == channel.guideChannelID })
        // Archive marks only aired programmes on archived channels.
        #expect(programmes.filter(\.hasArchive).allSatisfy { $0.end < now })
        #expect(programmes.contains { $0.hasArchive })
        // Any window agrees with any other.
        let window = StubCatalog.programmes(for: channel, from: now, to: now.addingTimeInterval(3 * 3600), now: now)
        #expect(window.allSatisfy(programmes.contains))
    }

    @Test func guideTitlesLookLikeTheMockups() {
        let now = utc(2026, 10, 24, 20)
        let titles = Set(StubCatalog.channels.flatMap {
            StubCatalog.programmes(for: $0, from: now.addingTimeInterval(-3 * 86_400), to: now.addingTimeInterval(3 * 86_400), now: now).map(\.title)
        })
        #expect(titles.contains("Evening Bulletin"))
        #expect(titles.contains("Premier Cricket · Final"))
        #expect(titles.contains { $0.hasPrefix("The Long Harbor · S3 E") })
    }

    @Test func fullGuideStreamsEveryChannel() async throws {
        let stream = try #require(client.fullGuide())
        var channels: Set<String> = []
        var count = 0
        for try await programme in stream {
            channels.insert(programme.guideChannelID)
            count += 1
        }
        #expect(channels.count == StubCatalog.channels.count)
        #expect(count > 5_000)
    }

    @Test func shortGuideStartsNow() async throws {
        let channel = StubCatalog.channels[1]
        let guide = try await client.shortGuide(for: channel, limit: 4)
        #expect(guide.count == 4)
        #expect(guide[0].start <= Date() && guide[0].end > Date())
    }

    @Test func fortyMoviesPagedByTwenty() async throws {
        let first = try await client.movies(categoryID: nil, page: 0)
        #expect(first.items.count == 20)
        #expect(first.totalItems == 40)
        #expect(first.hasMore)
        let second = try await client.movies(categoryID: nil, page: 1)
        #expect(second.items.count == 20)
        #expect(!second.hasMore)
        let all = first.items + second.items
        #expect(Set(all.map(\.id)).count == 40)
        #expect(all.allSatisfy { $0.year != nil && $0.plot != nil && $0.rating != nil && $0.durationSeconds != nil && $0.posterURL == nil })
        let added = all.compactMap(\.addedAt)
        #expect(added.count == 40)
        #expect((added.max()!).timeIntervalSince(added.min()!) > 90 * 86_400) // spread over months
        let drama = try await client.movies(categoryID: "m-drama", page: 0)
        #expect(drama.items.allSatisfy { $0.categoryID == "m-drama" })
    }

    @Test func seriesWithSeasonsAndEpisodes() async throws {
        let page = try await client.series(categoryID: nil, page: 0)
        #expect(page.items.count == 10)
        let names = page.items.map(\.name)
        for name in ["Salt & Signal", "The Long Harbor", "Kitchen Wars", "Night Shift Dispatch"] { #expect(names.contains(name)) }
        let salt = try #require(page.items.first { $0.name == "Salt & Signal" })
        let detail = try await client.seriesDetail(salt)
        #expect(detail.seasons.map(\.number) == [1, 2, 3])
        let seasonTwo = detail.episodes.filter { $0.season == 2 }
        #expect(seasonTwo.first { $0.number == 4 }?.title == "Fog Bell")
        #expect(detail.episodes.allSatisfy { $0.seriesID == salt.id && $0.durationSeconds != nil })
        let link = try await client.streamLink(for: .episode(detail.episodes[0], series: salt))
        #expect(link.formatHint == .hls)
    }

    @Test func theSameDayGivesTheSameCatalog() {
        let now = utc(2026, 10, 24, 20)
        #expect(StubCatalog.movies(now: now) == StubCatalog.movies(now: now.addingTimeInterval(3600)))
        #expect(StubCatalog.series(now: now) == StubCatalog.series(now: now))
        let channel = StubCatalog.channels[3]
        #expect(StubCatalog.programmes(for: channel, from: now, to: now.addingTimeInterval(86_400), now: now)
            == StubCatalog.programmes(for: channel, from: now, to: now.addingTimeInterval(86_400), now: now))
    }

    @Test func accountIsActiveWithAnExpiry() async throws {
        let account = try await client.signIn()
        #expect(account.status == .active)
        #expect(account.expiresAt.map { $0 > Date() } == true)
    }
}
