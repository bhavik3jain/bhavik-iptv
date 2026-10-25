import Foundation
import Testing
@testable import SourceKit

/// `XtreamClient` and its readers against saved `player_api.php` answers:
/// numbers as strings, `[]` for empty objects, base64 guide text and the
/// stream URL shapes (SRC-2, SRC-4).
@Suite struct XtreamClientTests {
    let london = TimeZone(identifier: "Europe/London")!

    /// A fake panel on its own host: `player_api.php` routed by `action`.
    func panel(
        account: String = "xtream/account.json",
        route: @escaping @Sendable (_ action: String?, _ request: URLRequest) -> StubURLProtocol.Reply? = { _, _ in nil }
    ) -> (client: XtreamClient, host: String) {
        let host = StubURLProtocol.makeHost("xtream")
        let session = StubURLProtocol.session(host: host) { request in
            let action = request.query["action"]
            if let reply = route(action, request) { return reply }
            guard request.url?.path() == "/player_api.php" else { return .text("Not Found", status: 404) }
            switch action {
            case nil: return .fixture(account)
            case "get_live_categories": return .fixture("xtream/live_categories.json")
            case "get_live_streams": return .fixture("xtream/live_streams.json")
            case "get_vod_streams": return .fixture("xtream/vod_streams.json")
            case "get_series_info": return .fixture("xtream/series_info.json")
            case "get_short_epg": return .fixture("xtream/short_epg.json")
            default: return .json("[]")
            }
        }
        let configuration = SourceConfiguration(name: "Panel", kind: .xtream, serverURL: "http://\(host):8080/", username: "demo-user", password: "demo-pass")
        return (XtreamClient(configuration: configuration, session: session), host)
    }

    // MARK: Account

    @Test func accountReadsNumbersWrittenAsStrings() async throws {
        let (client, host) = panel()
        let account = try await client.signIn()
        #expect(account.status == .active)
        #expect(account.expiresAt == utc(2027, 1, 1, 0))
        #expect(account.maxConnections == 2)
        #expect(account.activeConnections == 1)
        #expect(!account.isTrial)
        #expect(account.allowedOutputFormats == ["m3u8", "ts", "rtmp"])
        #expect(account.message == "Welcome to Demo IPTV")
        let request = try #require(StubURLProtocol.requests(for: host).first)
        #expect(request.url?.path() == "/player_api.php")
        #expect(request.query["username"] == "demo-user")
        #expect(request.query["action"] == nil)
    }

    @Test func emptyObjectsAsArraysAreARefusal() {
        let error = #expect(throws: SourceError.self) { try XtreamParse.account(Fixture.json("xtream/account_empty.json")) }
        #expect(error?.code == .authenticationFailed)
    }

    @Test func refusalCarriesTheProvidersWords() async {
        let (client, _) = panel(account: "xtream/account_refused.json")
        let error = await sourceError { try await client.signIn() }
        #expect(error?.code == .authenticationFailed)
        #expect(error?.providerMessage == "Your subscription is suspended")
    }

    @Test func trialWithoutExpiryAndTSOnly() throws {
        let account = try XtreamParse.account(Fixture.json("xtream/account_ts_only.json"))
        #expect(account.isTrial)
        #expect(account.expiresAt == nil)
        #expect(account.maxConnections == 1)
        #expect(account.activeConnections == 0)
        #expect(account.allowedOutputFormats == ["ts"])
    }

    @Test func expiredStatusAndPastDate() throws {
        let past: JSONValue = .object(["user_info": .object(["auth": .int(1), "status": .string("Active"), "exp_date": .string("1600000000")])])
        #expect(try XtreamParse.account(past).status == .expired)
        let banned: JSONValue = .object(["user_info": .object(["auth": .string("1"), "status": .string("Banned")])])
        #expect(try XtreamParse.account(banned).status == .disabled)
    }

    @Test func httpRefusalNeverQuotesThePassword() async {
        let (client, _) = panel { _, _ in .text("Access denied for demo-pass", status: 403) }
        let error = await sourceError { try await client.signIn() }
        #expect(error?.code == .authenticationFailed)
        #expect(error?.providerMessage?.contains("demo-pass") == false)
        #expect(error?.detail?.contains("demo-pass") != true)
    }

    @Test func aLoginWithoutPasswordIsRefusedUpFront() async {
        let client = XtreamClient(configuration: SourceConfiguration(name: "P", kind: .xtream, serverURL: "http://x.test", username: "u"))
        let error = await sourceError { try await client.signIn() }
        #expect(error?.code == .invalidConfiguration)
    }

    @Test func baseURLDropsTheAPIPathAndSlashes() {
        #expect(XtreamParse.baseURL("xtream.test:8080/player_api.php?username=a") == "http://xtream.test:8080")
        #expect(XtreamParse.baseURL("https://xtream.test/") == "https://xtream.test")
        #expect(XtreamParse.baseURL("http://xtream.test/panel/get.php") == "http://xtream.test/panel")
        #expect(XtreamParse.baseURL("") == nil)
        #expect(XtreamParse.baseURL("ftp://xtream.test") == nil)
    }

    // MARK: Catalog

    @Test func categoriesWithNumericIDs() async throws {
        let (client, _) = panel()
        let categories = try await client.categories(.live)
        #expect(categories.map(\.id) == ["1", "2", "66"])
        #expect(categories.map(\.name) == ["News", "Sports", "Adult | XXX"])
        #expect(categories.map(\.sortOrder) == [0, 1, 2])
    }

    @Test func channelsWithArchiveAndGuideIDs() async throws {
        let (client, _) = panel()
        let channels = try await client.channels()
        #expect(channels.count == 2)
        let news = channels[0]
        #expect(news.id == "101")
        #expect(news.number == 1)
        #expect(news.guideChannelID == "cityline.news")
        #expect(news.hasArchive)
        #expect(news.archiveDays == 7)
        #expect(news.command == "101")
        #expect(news.formatHint == .hls) // the account allows m3u8
        #expect(news.logoURL?.absoluteString == "http://img.xtream.test/101.png")
        let sports = channels[1]
        #expect(sports.number == 2)
        #expect(sports.guideChannelID == "102") // epg_channel_id null
        #expect(!sports.hasArchive)
        #expect(sports.logoURL == nil)
    }

    @Test func moviesComeInOnePage() async throws {
        let (client, host) = panel()
        let page = try await client.movies(categoryID: "10", page: 0)
        #expect(!page.hasMore)
        #expect(page.items.map(\.id) == ["3001", "3002"])
        #expect(page.items[0].year == 2019) // from "Glass Orchard (2019)"
        #expect(page.items[0].rating == 7.2)
        #expect(page.items[0].containerExtension == "mkv")
        #expect(page.items[0].addedAt == Date(timeIntervalSince1970: 1_755_166_905))
        #expect(page.items[1].rating == 8) // rating_5based "4" doubled
        #expect(page.items[1].addedAt == nil)
        #expect(StubURLProtocol.requests(for: host).last?.query["category_id"] == "10")
        #expect(try await client.movies(categoryID: nil, page: 1).items.isEmpty)
    }

    @Test func seriesInfoBySeriesID() async throws {
        let (client, host) = panel()
        let detail = try await client.seriesDetail(RemoteSeries(id: "9001", name: "Salt & Signal"))
        #expect(StubURLProtocol.requests(for: host).last?.query["series_id"] == "9001")
        #expect(detail.seasons.map(\.number) == [1, 2])
        #expect(detail.episodes.map { "\($0.season)x\($0.number)" } == ["1x1", "2x4", "2x5"])
        #expect(detail.episodes.map(\.title) == ["Arrivals", "Fog Bell", "Episode 5"])
        #expect(detail.episodes[0].durationSeconds == 3060)
        #expect(detail.episodes[0].containerExtension == "mkv")
        #expect(detail.episodes[0].plot == "The station gets a new keeper.")
        #expect(detail.episodes[1].durationSeconds == 3060) // "00:51:00"
        #expect(detail.series.plot == "Keepers of an old signal station.")
        #expect(detail.series.year == 2024)
    }

    @Test func emptySeriesInfo() {
        let detail = XtreamParse.seriesDetail(Fixture.json("xtream/series_info_empty.json"), series: RemoteSeries(id: "1", name: "Empty"))
        #expect(detail.seasons.isEmpty)
        #expect(detail.episodes.isEmpty)
    }

    // MARK: Guide

    @Test func shortGuideDecodesBase64WhenItDecodesCleanly() async throws {
        let (client, host) = panel()
        let channel = RemoteChannel(id: "101", name: "Cityline News", guideChannelID: "cityline.news", command: "101")
        let guide = try await client.shortGuide(for: channel, limit: 4)
        #expect(guide.map(\.title) == ["Evening Bulletin", "News", "Café Société"])
        #expect(guide[0].summary == "Tonight's news.")
        #expect(guide[1].summary == "Not base64 at all.")
        #expect(guide[2].summary == nil)
        #expect(guide[0].start == utc(2026, 10, 24, 19)) // start_timestamp
        #expect(guide[0].hasArchive)
        // Wall-clock times are read in the account call's server zone when
        // known; here no account call ran, so they're read as UTC.
        #expect(guide[1].start == utc(2026, 10, 24, 21))
        #expect(guide.allSatisfy { $0.guideChannelID == "cityline.news" })
        let request = try #require(StubURLProtocol.requests(for: host).last)
        #expect(request.query["stream_id"] == "101")
        #expect(request.query["limit"] == "4")
    }

    @Test func wallClockGuideTimesUseTheServerZone() {
        let guide = XtreamParse.shortGuide(Fixture.json("xtream/short_epg.json"), guideChannelID: "c", timeZone: london)
        #expect(guide[1].start == utc(2026, 10, 24, 20)) // 21:00 BST
    }

    @Test func base64OnlyWhenItDecodesToText() {
        #expect(Base64.decodedText("RXZlbmluZyBCdWxsZXRpbg==") == "Evening Bulletin")
        #expect(Base64.decodedText("News") == nil)
        #expect(Base64.decodedText("Late Edition") == nil)
        #expect(Base64.decodedText("abc") == nil)
    }

    @Test func fullGuideStreamsXMLTV() async throws {
        let (client, host) = panel { _, request in
            request.url?.path() == "/xmltv.php" ? .fixture("xmltv/guide.xml.gz") : nil
        }
        let stream = try #require(client.fullGuide())
        var titles: [String] = []
        for try await programme in stream { titles.append(programme.title) }
        #expect(titles.count == 5)
        #expect(titles.first == "Evening Bulletin")
        let request = try #require(StubURLProtocol.requests(for: host).first { $0.url?.path() == "/xmltv.php" })
        #expect(request.query["username"] == "demo-user")
        #expect(request.query["password"] == "demo-pass")
    }

    @Test func aTypedGuideURLOverridesXMLTVPHP() throws {
        let configuration = SourceConfiguration(name: "P", kind: .xtream, serverURL: "http://x.test", username: "u", password: "p", guideURL: Fixture.url("xmltv/guide.xml").absoluteString)
        #expect(XtreamClient(configuration: configuration).fullGuide() != nil)
    }

    // MARK: Links

    @Test func liveAsksForHLSWhenTheAccountAllowsIt() async throws {
        let (client, host) = panel()
        let link = try await client.streamLink(for: .live(RemoteChannel(id: "101", name: "News", command: "101")))
        #expect(link.url.absoluteString == "http://\(host):8080/live/demo-user/demo-pass/101.m3u8")
        #expect(link.formatHint == .hls)
        #expect(link.isLive)
    }

    @Test func liveFallsBackToTSWhenHLSIsNotAllowed() async throws {
        let (client, host) = panel(account: "xtream/account_ts_only.json")
        let link = try await client.streamLink(for: .live(RemoteChannel(id: "101", name: "News", command: "101")))
        #expect(link.url.absoluteString == "http://\(host):8080/live/demo-user/demo-pass/101.ts")
        #expect(link.formatHint == .mpegts)
    }

    @Test func movieAndEpisodeURLs() async throws {
        let (client, host) = panel()
        let movie = try await client.streamLink(for: .movie(RemoteMovie(id: "3001", name: "Glass Orchard", containerExtension: "mkv")))
        #expect(movie.url.absoluteString == "http://\(host):8080/movie/demo-user/demo-pass/3001.mkv")
        #expect(movie.formatHint == .mkv)
        #expect(!movie.isLive)
        let episode = try await client.streamLink(for: .episode(RemoteEpisode(id: "50204", seriesID: "9001", season: 2, number: 4, title: "Fog Bell", containerExtension: "mp4"), series: nil))
        #expect(episode.url.absoluteString == "http://\(host):8080/series/demo-user/demo-pass/50204.mp4")
        #expect(episode.formatHint == .mp4)
    }

    @Test func catchupIsATimeshiftURLInTheServerZone() async throws {
        let (client, host) = panel()
        let channel = RemoteChannel(id: "101", name: "News", hasArchive: true, archiveDays: 7, command: "101")
        let link = try await client.streamLink(for: .catchup(channel, start: utc(2026, 10, 24, 19), duration: 3600))
        // 19:00 UTC is 20:00 in the account's Europe/London.
        #expect(link.url.absoluteString == "http://\(host):8080/timeshift/demo-user/demo-pass/60/2026-10-24:20-00/101.ts")
        #expect(link.formatHint == .mpegts)
    }

    @Test func credentialsAreEscapedInPaths() {
        let builder = XtreamURLBuilder(base: "http://x.test", username: "a b", password: "p/w#1")
        #expect(builder.live(streamID: "7", hls: false)?.absoluteString == "http://x.test/live/a%20b/p%2Fw%231/7.ts")
    }
}
