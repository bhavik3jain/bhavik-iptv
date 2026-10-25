import Foundation
import Testing
@testable import SourceKit

/// M3U playlists: attributes, headers from `#EXTVLCOPT` and friends, stable
/// ids, categories, catch-up URLs, and the client over `file://` and HTTP
/// (SRC-3).
@Suite struct M3UTests {
    func parse(_ text: String) -> M3UPlaylist {
        var parser = M3UParser()
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) { parser.consume(line) }
        return parser.playlist
    }

    var fixture: M3UPlaylist { parse(Fixture.text("m3u/playlist.m3u")) }

    // MARK: Parsing

    @Test func headerNamesEveryGuide() {
        let playlist = fixture
        #expect(playlist.sawHeader)
        #expect(playlist.guideURLs.map(\.absoluteString) == ["http://guide.m3u.test/guide.xml.gz", "http://guide.m3u.test/extra.xml"])
        #expect(parse("#EXTM3U url-tvg=\"http://g.test/a.xml\"\n").guideURLs.map(\.absoluteString) == ["http://g.test/a.xml"])
    }

    @Test func entryAttributesAndNames() throws {
        let entries = fixture.entries
        #expect(entries.count == 9)
        let news = entries[0]
        #expect(news.name == "Cityline News")
        #expect(news.url == "http://live.m3u.test/cn/index.m3u8")
        #expect(news["tvg-id"] == "cityline.news")
        #expect(news["tvg-logo"] == "http://img.m3u.test/cn.png")
        #expect(news["tvg-chno"] == "101")
        #expect(news["group-title"] == "News")
        #expect(news["catchup-days"] == "7")
        // A quoted comma stays in the value; the name follows the first bare comma.
        #expect(entries[1]["group-title"] == "Sports, Live")
        #expect(entries[1].name == "Fieldhouse Sports")
        // An empty display name falls back to tvg-name.
        #expect(entries[5].name == "Paper Kite")
        // #EXTGRP gives the group when the #EXTINF line has none.
        #expect(entries[8]["group-title"] == "Music")
    }

    @Test func headersFromVLCOptionsPipesAndEXTHTTP() {
        let entries = fixture.entries
        #expect(entries[1].headers == ["User-Agent": "HearthTest/1.0", "Referer": "http://referrer.m3u.test/"])
        #expect(entries[2].url == "http://live.m3u.test/ld/playlist.m3u8")
        #expect(entries[2].headers == ["User-Agent": "PipeAgent/2", "Referer": "http://pipe.m3u.test/"])
        #expect(entries[3].headers == ["Cookie": "session=abc", "User-Agent": "HttpAgent/3"])
        // Options apply to the next stream only.
        #expect(entries[4].headers.isEmpty)
    }

    @Test func channelsGetStableUniqueIDs() {
        let channels = M3UCatalog.channels(fixture)
        #expect(channels.count == 9)
        #expect(Set(channels.map(\.id)).count == 9)
        #expect(channels[0].id == "cityline.news")
        #expect(channels[1].id == "fieldhouse")
        // No tvg-id: a hash of the normalised name and group.
        #expect(channels[2].id == "m3u-" + M3UCatalog.stableHash("lantern drama|drama"))
        // The same name and group again, and a repeated tvg-id, stay unique.
        #expect(channels[3].id.hasPrefix(channels[2].id + "~"))
        #expect(channels[4].id.hasPrefix("cityline.news~"))
        // A second read of the same file gives the same ids.
        #expect(M3UCatalog.channels(fixture).map(\.id) == channels.map(\.id))
    }

    @Test func channelFields() {
        let channels = M3UCatalog.channels(fixture)
        let news = channels[0]
        #expect(news.number == 101)
        #expect(news.categoryID == "News")
        #expect(news.guideChannelID == "cityline.news")
        #expect(news.logoURL?.absoluteString == "http://img.m3u.test/cn.png")
        #expect(news.command == "http://live.m3u.test/cn/index.m3u8")
        #expect(news.formatHint == .hls)
        #expect(news.hasArchive)
        #expect(news.archiveDays == 7)
        #expect(news.catchupMode == "default")
        #expect(channels[1].formatHint == .mpegts)
        #expect(channels[1].headers["User-Agent"] == "HearthTest/1.0")
        #expect(channels[1].archiveDays == 3) // the header's catchup-days
        #expect(channels[5].guideChannelID == "Paper Kite")
        #expect(channels[8].formatHint == .mkv)
    }

    @Test func catchupDaysAloneDoesNotSwitchArchiveOn() {
        let channels = M3UCatalog.channels(fixture)
        // Lantern Drama has no catchup tag; only the header's catchup-days.
        #expect(!channels[2].hasArchive)
        #expect(channels[2].catchupMode == nil)
        #expect(channels[8].archiveDays == 0)
        // SIPTV's legacy `timeshift` does switch it on.
        let legacy = M3UCatalog.channels(parse("#EXTM3U\n#EXTINF:-1 timeshift=\"2\",Old\nhttp://a.test/old.m3u8\n"))
        #expect(legacy[0].catchupMode == "shift")
        #expect(legacy[0].archiveDays == 2)
    }

    @Test func categoriesFromGroupTitlesInOrder() {
        #expect(M3UCatalog.categories(fixture).map(\.name) == ["News", "Sports, Live", "Drama", "Kids", "Docs", "Music"])
    }

    @Test func normalisedNames() {
        #expect(M3UCatalog.normalised("Cityline  News (HD)") == "cityline news hd")
        #expect(M3UCatalog.normalised("Télé Matin") == "tele matin")
        #expect(M3UCatalog.stableHash("abc").count == 16)
        #expect(M3UCatalog.stableHash("abc") == M3UCatalog.stableHash("abc"))
    }

    // MARK: Catch-up

    let start = utc(2026, 10, 24, 20)
    let now = utc(2026, 10, 24, 22, 15)

    func catchup(_ index: Int) -> URL? {
        M3UCatchup.url(for: M3UCatalog.channels(fixture)[index], start: start, duration: 3600, now: now)
    }

    @Test func defaultModeFillsEveryPlaceholder() {
        let startSeconds = Int(start.timeIntervalSince1970)
        let nowSeconds = Int(now.timeIntervalSince1970)
        #expect(catchup(0)?.absoluteString == "http://archive.m3u.test/cn/2026/10/24/20-00.m3u8?start=\(startSeconds)&end=\(startSeconds + 3600)&dur=3600&now=\(nowSeconds)")
    }

    @Test func appendModeAddsToTheChannelURL() {
        let startSeconds = Int(start.timeIntervalSince1970)
        #expect(catchup(1)?.absoluteString == "http://live.m3u.test/fs/stream.ts?utc=\(startSeconds)&lutc=\(Int(now.timeIntervalSince1970))")
    }

    @Test func shiftFlussonicAndXtreamModes() {
        let startSeconds = Int(start.timeIntervalSince1970)
        #expect(catchup(5)?.absoluteString == "http://live.m3u.test/pk/mono.m3u8?token=t1&utc=\(startSeconds)&lutc=\(Int(now.timeIntervalSince1970))")
        #expect(catchup(6)?.absoluteString == "http://fl.m3u.test/wildframe/index-\(startSeconds)-3600.m3u8?token=t2")
        #expect(catchup(7)?.absoluteString == "http://xc.m3u.test:8080/timeshift/user/pass/60/2026-10-24:20-00/4242.ts")
        #expect(catchup(2) == nil) // no catch-up
    }

    @Test func formattedAndDividedPlaceholders() {
        let filled = M3UCatchup.fill("x?d={utc:Y-m-d}&e={utcend:HMS}&n=${now}&o={offset:60}&m={duration:60}", start: start, duration: 5400, now: now)
        #expect(filled == "x?d=2026-10-24&e=213000&n=\(Int(now.timeIntervalSince1970))&o=135&m=90")
    }

    // MARK: The client

    @Test func clientReadsAFilePlaylist() async throws {
        let configuration = SourceConfiguration(name: "File", kind: .m3u, playlistURL: Fixture.url("m3u/playlist.m3u").absoluteString)
        let client = M3UClient(configuration: configuration)
        let account = try await client.signIn()
        #expect(account.status == .active)
        let channels = try await client.channels()
        #expect(channels.count == 9)
        #expect(try await client.categories(.live).count == 6)
        #expect(try await client.categories(.vod).isEmpty)
        let link = try await client.streamLink(for: .live(channels[1]))
        #expect(link.url.absoluteString == "http://live.m3u.test/fs/stream.ts")
        #expect(link.headers["Referer"] == "http://referrer.m3u.test/")
        #expect(link.formatHint == .mpegts)
        #expect(link.isLive)
    }

    @Test func clientFetchesOverHTTPAndReadsHeaderGuides() async throws {
        let host = StubURLProtocol.makeHost("m3u")
        let playlist = """
        #EXTM3U x-tvg-url="http://\(host)/guide.xml.gz,http://\(host)/extra.xml"
        #EXTINF:-1 tvg-id="cityline.news" group-title="News",Cityline News
        http://live.m3u.test/cn/index.m3u8
        """
        let session = StubURLProtocol.session(host: host) { request in
            switch request.url?.path() {
            case "/list.m3u": return .text(playlist)
            case "/guide.xml.gz": return .fixture("xmltv/guide.xml.gz")
            case "/extra.xml": return .text(#"<tv><programme start="20261025000000 +0000" stop="20261025010000 +0000" channel="extra"><title>Extra</title></programme></tv>"#)
            default: return .text("Not Found", status: 404)
            }
        }
        let client = M3UClient(configuration: SourceConfiguration(name: "Web", kind: .m3u, playlistURL: "http://\(host)/list.m3u"), session: session)
        #expect(try await client.channels().map(\.id) == ["cityline.news"])
        let stream = try #require(client.fullGuide())
        var programmes: [RemoteProgramme] = []
        for try await programme in stream { programmes.append(programme) }
        #expect(programmes.count == 6)
        #expect(programmes.last?.guideChannelID == "extra")
    }

    @Test func missingPlaylistShowsTheServersWords() async {
        let host = StubURLProtocol.makeHost("m3u")
        let session = StubURLProtocol.session(host: host) { _ in .text("<h1>Playlist expired</h1>", status: 403) }
        let client = M3UClient(configuration: SourceConfiguration(name: "Web", kind: .m3u, playlistURL: "http://\(host)/get.php?username=u&password=secret"), session: session)
        let error = await sourceError { try await client.signIn() }
        #expect(error?.code == .authenticationFailed)
        #expect(error?.providerMessage == "Playlist expired")
    }

    @Test func notAPlaylist() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "hearth-test-\(UUID().uuidString).m3u")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let client = M3UClient(configuration: SourceConfiguration(name: "Empty", kind: .m3u, playlistURL: file.absoluteString))
        let error = await sourceError { try await client.signIn() }
        #expect(error?.code == .badResponse)
    }

    @Test func badPlaylistAddress() async {
        let client = M3UClient(configuration: SourceConfiguration(name: "Bad", kind: .m3u, playlistURL: "not a url"))
        let error = await sourceError { try await client.signIn() }
        #expect(error?.code == .invalidConfiguration)
    }
}
