import Foundation
import SourceKit
import Synchronization

/// A provider in memory: serves a fixture catalog through the `SourceClient`
/// protocol, pages lists the way Stalker does, records every call and can be
/// told to fail at a given step. Tests change the fixture between refreshes.
final class FakeSourceClient: SourceClient {
    struct Fixture: Sendable {
        var account = AccountInfo(status: .active, expiresAt: Date(timeIntervalSinceNow: 30 * 86_400), maxConnections: 2, activeConnections: 0)
        var categories: [ContentKind: [RemoteCategory]] = [:]
        var channels: [RemoteChannel] = []
        var movies: [RemoteMovie] = []
        var series: [RemoteSeries] = []
        var details: [String: SeriesDetail] = [:]
        var guide: [RemoteProgramme] = []
        /// Short guides by channel id.
        var shortGuides: [String: [RemoteProgramme]] = [:]
        var pageSize = 1_000
        /// Answer `notSupported` to lists without a category, and drop the
        /// category from items listed by one (as some portals do).
        var listsNeedCategory = false
        /// How long each page takes, so a test can cancel mid-import.
        var pageDelay: Duration?
        /// What a list claims as its `totalItems`, by `"<kind>/<category id>"`
        /// (`"vod/all"` for every movie): a big portal's count without the
        /// fixture holding that many titles. Unset lists report what they hold.
        var reportedTotals: [String: Int] = [:]
        var failure: Failure?
    }

    enum Failure: Sendable {
        case signIn(SourceError)
        case channels(SourceError)
        case moviesPage(Int, SourceError)
        case guide(SourceError)
    }

    let configuration: SourceConfiguration
    let capabilities: SourceCapabilities
    private let state: Mutex<Fixture>
    private let log = Mutex<[String]>([])
    private let requests = Mutex<[StreamRequest]>([])

    static let fullCapabilities = SourceCapabilities(hasMovies: true, hasSeries: true, hasFullGuide: true, hasCatchup: true, reportsStreamCount: true)

    init(configuration: SourceConfiguration, capabilities: SourceCapabilities = FakeSourceClient.fullCapabilities, fixture: Fixture) {
        self.configuration = configuration
        self.capabilities = capabilities
        self.state = Mutex(fixture)
    }

    func update(_ change: (inout Fixture) -> Void) {
        state.withLock { change(&$0) }
    }

    var calls: [String] { log.withLock { $0 } }
    func callCount(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }
    var streamRequests: [StreamRequest] { requests.withLock { $0 } }

    private var fixture: Fixture { state.withLock { $0 } }
    private func record(_ call: String) { log.withLock { $0.append(call) } }

    // MARK: SourceClient

    func signIn() async throws -> AccountInfo {
        record("signIn")
        let fixture = self.fixture
        if case .signIn(let error) = fixture.failure { throw error }
        return fixture.account
    }

    func accountInfo() async throws -> AccountInfo {
        record("accountInfo")
        return fixture.account
    }

    func categories(_ kind: ContentKind) async throws -> [RemoteCategory] {
        record("categories(\(kind.rawValue))")
        return fixture.categories[kind] ?? []
    }

    func channels() async throws -> [RemoteChannel] {
        record("channels")
        let fixture = self.fixture
        if case .channels(let error) = fixture.failure { throw error }
        return fixture.channels
    }

    func movies(categoryID: String?, page: Int) async throws -> Page<RemoteMovie> {
        record("movies(\(categoryID ?? "all"),\(page))")
        let fixture = self.fixture
        if let pageDelay = fixture.pageDelay { try await Task.sleep(for: pageDelay) }
        if case .moviesPage(let failingPage, let error) = fixture.failure, failingPage == page { throw error }
        return try paged(fixture.movies, kind: .vod, categoryID: categoryID, page: page, fixture: fixture, category: \.categoryID)
    }

    func series(categoryID: String?, page: Int) async throws -> Page<RemoteSeries> {
        record("series(\(categoryID ?? "all"),\(page))")
        let fixture = self.fixture
        return try paged(fixture.series, kind: .series, categoryID: categoryID, page: page, fixture: fixture, category: \.categoryID)
    }

    func seriesDetail(_ series: RemoteSeries) async throws -> SeriesDetail {
        record("seriesDetail(\(series.id))")
        guard let detail = fixture.details[series.id] else { throw SourceError(.badResponse, detail: "no detail") }
        return detail
    }

    func shortGuide(for channel: RemoteChannel, limit: Int) async throws -> [RemoteProgramme] {
        record("shortGuide(\(channel.id))")
        return Array((fixture.shortGuides[channel.id] ?? []).prefix(limit))
    }

    func fullGuide() -> AsyncThrowingStream<RemoteProgramme, Error>? {
        guard capabilities.hasFullGuide else { return nil }
        record("fullGuide")
        let fixture = self.fixture
        return AsyncThrowingStream { continuation in
            for programme in fixture.guide { continuation.yield(programme) }
            if case .guide(let error) = fixture.failure {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    func streamLink(for request: StreamRequest) async throws -> StreamLink {
        record("streamLink")
        requests.withLock { $0.append(request) }
        switch request {
        case .live(let channel):
            return StreamLink(url: URL(string: "https://fake.test/live/\(channel.id)")!, headers: channel.headers, formatHint: channel.formatHint, isLive: true)
        case .catchup(let channel, let start, let duration):
            return StreamLink(url: URL(string: "https://fake.test/catchup/\(channel.id)?start=\(Int(start.timeIntervalSince1970))&duration=\(Int(duration))")!)
        case .movie(let movie):
            return StreamLink(url: URL(string: "https://fake.test/movie/\(movie.id).\(movie.containerExtension ?? "mp4")")!)
        case .episode(let episode, let series):
            return StreamLink(url: URL(string: "https://fake.test/episode/\(series?.id ?? "-")/\(episode.id)")!)
        }
    }

    func keepAlive() async {
        record("keepAlive")
    }

    private func paged<Item: Sendable & Hashable>(_ all: [Item], kind: ContentKind, categoryID: String?, page: Int, fixture: Fixture, category: WritableKeyPath<Item, String?>) throws -> Page<Item> {
        var items = all
        if fixture.listsNeedCategory {
            guard let categoryID else { throw SourceError(.notSupported) }
            items = all.filter { $0[keyPath: category] == categoryID }.map { item in
                var item = item
                item[keyPath: category] = nil
                return item
            }
        } else if let categoryID {
            items = all.filter { $0[keyPath: category] == categoryID }
        }
        let start = page * fixture.pageSize
        let end = min(start + fixture.pageSize, items.count)
        let slice = start < end ? Array(items[start..<end]) : []
        let total = fixture.reportedTotals["\(kind.rawValue)/\(categoryID ?? "all")"] ?? items.count
        return Page(items: slice, page: page, totalItems: total, hasMore: end < items.count)
    }
}

/// The fixture catalog most tests start from: scrubbed, made-up names in
/// the shapes real providers send (an adult category, a channel without a
/// number, one without a category, accents and apostrophes in titles).
enum Fixtures {
    static func configuration(_ name: String = "Provider A", id: UUID = UUID()) -> SourceConfiguration {
        SourceConfiguration(id: id, name: name, kind: .stalker, serverURL: "http://portal.example/c/", macAddress: "00:1A:79:12:34:56")
    }

    /// Fixed to the minute so programme ids are stable within a test.
    static let now = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 / 60).rounded(.down) * 60)

    static func catalog(now: Date = Fixtures.now) -> FakeSourceClient.Fixture {
        var fixture = FakeSourceClient.Fixture()
        fixture.categories = [
            .live: [
                RemoteCategory(id: "1", name: "News", kind: .live, sortOrder: 1),
                RemoteCategory(id: "2", name: "Sports", kind: .live, sortOrder: 2),
                RemoteCategory(id: "3", name: "XXX Adult", kind: .live, sortOrder: 3),
                RemoteCategory(id: "4", name: "Kids", kind: .live, sortOrder: 4),
            ],
            .vod: [
                RemoteCategory(id: "10", name: "Action", kind: .vod, sortOrder: 1),
                RemoteCategory(id: "11", name: "For Adults 18+", kind: .vod, sortOrder: 2),
                RemoteCategory(id: "12", name: "Family", kind: .vod, sortOrder: 3),
            ],
            .series: [
                RemoteCategory(id: "20", name: "Drama", kind: .series, sortOrder: 1),
            ],
        ]
        fixture.channels = [
            RemoteChannel(id: "101", number: 1, name: "BBC One", categoryID: "1", guideChannelID: "bbc1.uk", hasArchive: true, archiveDays: 3, command: "ffrt http://portal.example/ch/101", formatHint: .mpegts, headers: ["User-Agent": "FakeBox/1.0"]),
            RemoteChannel(id: "102", number: 2, name: "Café TV", categoryID: "1", command: "ffrt http://portal.example/ch/102"),
            RemoteChannel(id: "103", number: 10, name: "Sky Sports", categoryID: "2", guideChannelID: "sky.sports", command: "ffrt http://portal.example/ch/103", catchupMode: "default", catchupSource: "?utc={utc}&lutc={lutc}"),
            RemoteChannel(id: "104", name: "Late Night", categoryID: "3", command: "ffrt http://portal.example/ch/104"),
            RemoteChannel(id: "105", number: 5, name: "Cartoon Fun", categoryID: "4", command: "ffrt http://portal.example/ch/105"),
            RemoteChannel(id: "106", number: 3, name: "No Category", command: "ffrt http://portal.example/ch/106"),
        ]
        fixture.movies = [
            RemoteMovie(id: "m1", name: "Grey's Day", categoryID: "10", year: 2021, durationSeconds: 5_400, containerExtension: "mkv", addedAt: now.addingTimeInterval(-86_400), command: "/media/m1.mkv"),
            RemoteMovie(id: "m2", name: "Café Society", categoryID: "12", year: 2016, addedAt: now.addingTimeInterval(-3 * 86_400)),
            RemoteMovie(id: "m3", name: "Night Moves", categoryID: "11", year: 2019, addedAt: now.addingTimeInterval(-2 * 86_400)),
            RemoteMovie(id: "m4", name: "Alpha", categoryID: "10", year: 1999, addedAt: now.addingTimeInterval(-10 * 86_400)),
            RemoteMovie(id: "m5", name: "Zulu", categoryID: "10", year: 2024, addedAt: now.addingTimeInterval(-5 * 86_400)),
            RemoteMovie(id: "m6", name: "Bravo", categoryID: "12", year: 2010),
            RemoteMovie(id: "m7", name: "Charlie", categoryID: "12", year: 2001, addedAt: now.addingTimeInterval(-7 * 86_400)),
            RemoteMovie(id: "m8", name: "Delta", categoryID: "10", year: 2005, addedAt: now.addingTimeInterval(-8 * 86_400)),
            RemoteMovie(id: "m9", name: "Echo", categoryID: "10", year: 2012, addedAt: now.addingTimeInterval(-9 * 86_400)),
            RemoteMovie(id: "m10", name: "Foxtrot", categoryID: "12", year: 2015, addedAt: now.addingTimeInterval(-11 * 86_400)),
        ]
        let anatomy = RemoteSeries(id: "s1", name: "Grey's Anatomy", categoryID: "20", year: 2005, addedAt: now.addingTimeInterval(-86_400))
        let office = RemoteSeries(id: "s2", name: "The Office", categoryID: "20", year: 2005, addedAt: now.addingTimeInterval(-2 * 86_400))
        fixture.series = [anatomy, office]
        fixture.details = [
            "s1": SeriesDetail(
                series: anatomy,
                seasons: [RemoteSeason(number: 1, name: "Season 1", remoteID: "s1-season-1"), RemoteSeason(number: 2, remoteID: "s1-season-2")],
                episodes: [
                    RemoteEpisode(id: "e11", seriesID: "s1", season: 1, number: 1, title: "A Hard Day's Night", command: "/media/e11.mp4"),
                    RemoteEpisode(id: "e12", seriesID: "s1", season: 1, number: 2, title: "The First Cut", command: "/media/e12.mp4"),
                    RemoteEpisode(id: "e21", seriesID: "s1", season: 2, number: 1, title: "Raindrops", command: "/media/e21.mp4"),
                ]
            ),
        ]
        fixture.guide = [
            RemoteProgramme(guideChannelID: "bbc1.uk", start: now.addingTimeInterval(-30 * 60), end: now.addingTimeInterval(30 * 60), title: "News at Noon"),
            RemoteProgramme(guideChannelID: "bbc1.uk", start: now.addingTimeInterval(30 * 60), end: now.addingTimeInterval(90 * 60), title: "Café Culture", summary: "Coffee, talked about."),
            RemoteProgramme(guideChannelID: "bbc1.uk", start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(-86_400 + 3_600), title: "Old Show"),
            // Outside the 7-day window: never stored.
            RemoteProgramme(guideChannelID: "bbc1.uk", start: now.addingTimeInterval(-9 * 86_400), end: now.addingTimeInterval(-9 * 86_400 + 3_600), title: "Ancient Show"),
            // Past the next 24 hours: in the guide, not in search.
            RemoteProgramme(guideChannelID: "bbc1.uk", start: now.addingTimeInterval(2 * 86_400), end: now.addingTimeInterval(2 * 86_400 + 3_600), title: "Café Weekly"),
            // No guide id on the channel: joined on its own id.
            RemoteProgramme(guideChannelID: "102", start: now.addingTimeInterval(-15 * 60), end: now.addingTimeInterval(45 * 60), title: "Morning Café"),
            RemoteProgramme(guideChannelID: "sky.sports", start: now.addingTimeInterval(-60 * 60), end: now.addingTimeInterval(60 * 60), title: "Match of the Day"),
        ]
        return fixture
    }
}
