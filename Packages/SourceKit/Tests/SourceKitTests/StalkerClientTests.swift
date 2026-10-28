import Foundation
import Synchronization
import Testing
@testable import SourceKit

/// `StalkerClient` against a fake Ministra portal behind `StubURLProtocol`:
/// path discovery, the MAG headers, signing in, the one re-handshake, links
/// and paging (SRC-1, SRC-4, PRIV-2).
@Suite struct StalkerClientTests {
    static let mac = "00:1A:79:00:00:01"
    static let token = "4F1C9A0E2B7D4E5F8A9B0C1D2E3F4A5B"

    /// A fake portal on a host of its own. Only `apiPath` answers; every
    /// other path is the web server's 404 page. Calls are counted by action.
    final class Portal: Sendable {
        typealias Route = @Sendable (_ action: String, _ request: URLRequest, _ attempt: Int) -> StubURLProtocol.Reply?

        let host: String
        let apiPath: String
        let session: URLSession
        private let counts: Counts

        init(apiPath: String = "/stalker_portal/server/load.php", route: @escaping Route = { _, _, _ in nil }) {
            let host = StubURLProtocol.makeHost()
            let counts = Counts()
            self.host = host
            self.apiPath = apiPath
            self.counts = counts
            session = StubURLProtocol.session(host: host) { request in
                guard request.url?.path() == apiPath else {
                    return .text("<html><body><h1>404 Not Found</h1></body></html>", status: 404)
                }
                let action = request.query["action"] ?? request.form["action"] ?? ""
                let attempt = counts.next(action)
                if let reply = route(action, request, attempt) { return reply }
                switch action {
                case "handshake": return .fixture("stalker/handshake.json")
                case "get_profile": return .fixture("stalker/profile.json")
                case "get_main_info": return .fixture("stalker/main_info.json")
                default: return .json(#"{"js":[]}"#)
                }
            }
        }

        func count(_ action: String) -> Int { counts.count(action) }

        var requests: [URLRequest] { StubURLProtocol.requests(for: host) }

        func requests(_ action: String) -> [URLRequest] {
            requests.filter { ($0.query["action"] ?? $0.form["action"]) == action }
        }

        func client(path: String = "/stalker_portal/c/", username: String = "", password: String = "", serial: String = "", model: String = "") -> StalkerClient {
            StalkerClient(
                configuration: SourceConfiguration(
                    name: "Portal", kind: .stalker, serverURL: "http://\(host)\(path)", macAddress: StalkerClientTests.mac,
                    username: username, password: password, serialNumber: serial, model: model, timeZone: "Europe/London"
                ),
                session: session
            )
        }
    }

    /// Calls per action, shared with the portal's handler.
    final class Counts: Sendable {
        private let counts = Mutex<[String: Int]>([:])

        /// Records one more call and returns which attempt it is (1-based).
        func next(_ action: String) -> Int {
            counts.withLock { counts in
                counts[action, default: 0] += 1
                return counts[action]!
            }
        }

        func count(_ action: String) -> Int { counts.withLock { $0[action] ?? 0 } }
    }

    // MARK: Signing in

    @Test func signInFindsTheAPIAndRemembersIt() async throws {
        let portal = Portal()
        // Typed as the web player's bare `/c/`: /portal.php and /load.php are
        // tried (and 404) before /stalker_portal/server/load.php answers.
        let client = portal.client(path: "/c/")
        let account = try await client.signIn()
        #expect(account.status == .active)
        #expect(account.expiresAt == utc(2027, 1, 15, 16, 31)) // main_info's `phone`, London time
        let triedFirst = portal.requests.filter { $0.url?.path() == "/portal.php" }.count
        #expect(triedFirst == 1)
        #expect(portal.requests.filter { $0.url?.path() == "/load.php" }.count == 1)

        // A second sign-in goes straight to the remembered endpoint.
        _ = try await client.signIn()
        #expect(portal.requests.filter { $0.url?.path() == "/portal.php" }.count == 1)
        #expect(portal.count("handshake") == 2)
    }

    @Test func everyCallLooksLikeAMAGBox() async throws {
        let portal = Portal()
        _ = try await portal.client().signIn()
        let profile = try #require(portal.requests("get_profile").first)
        #expect(profile.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(profile.value(forHTTPHeaderField: "User-Agent")?.contains("MAG200 stbapp") == true)
        #expect(profile.value(forHTTPHeaderField: "X-User-Agent") == "Model: MAG254; Link: Ethernet")
        let cookie = try #require(profile.value(forHTTPHeaderField: "Cookie"))
        #expect(cookie.contains("mac=\(Self.mac)"))
        #expect(cookie.contains("sn=0000000000000"))
        #expect(cookie.contains("stb_lang=en"))
        #expect(cookie.contains("timezone=Europe/London"))
        #expect(profile.value(forHTTPHeaderField: "Referer") == "http://\(portal.host)/")
        #expect(profile.value(forHTTPHeaderField: "Origin") == "http://\(portal.host)")

        let query = profile.query
        #expect(query["type"] == "stb")
        #expect(query["hd"] == "1")
        #expect(query["sn"] == "0000000000000")
        #expect(query["stb_type"] == "MAG254")
        #expect(query["device_id"] == "")
        #expect(query["device_id2"] == "")
        #expect(query["signature"] == "")
        #expect(query["auth_second_step"] == "1")

        // The handshake goes out without a bearer; everything carries 1-xml.
        let handshake = try #require(portal.requests("handshake").first)
        #expect(handshake.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(handshake.query["token"] == "")
        #expect(portal.requests.filter { $0.url?.path() == portal.apiPath }.allSatisfy { $0.query["JsHttpRequest"] == "1-xml" })
    }

    @Test func advancedFieldsReplaceTheDefaults() async throws {
        let portal = Portal()
        _ = try await portal.client(serial: "SN1234567890", model: "MAG322").signIn()
        let profile = try #require(portal.requests("get_profile").first)
        #expect(profile.query["sn"] == "SN1234567890")
        #expect(profile.query["stb_type"] == "MAG322")
        #expect(profile.value(forHTTPHeaderField: "X-User-Agent") == "Model: MAG322; Link: Ethernet")
        #expect(profile.value(forHTTPHeaderField: "Cookie")?.contains("sn=SN1234567890") == true)
    }

    @Test func doAuthPostsTheLoginWhenAUsernameIsSet() async throws {
        let portal = Portal { action, _, _ in
            action == "do_auth" ? .json(#"{"js":true}"#) : nil
        }
        _ = try await portal.client(username: "demo-user", password: "demo-pass").signIn()
        let auth = try #require(portal.requests("do_auth").first)
        #expect(auth.httpMethod == "POST")
        #expect(auth.form["login"] == "demo-user")
        #expect(auth.form["password"] == "demo-pass")
        #expect(auth.form["device_id"] == "")
        // The password never sits in a URL.
        #expect(auth.url?.absoluteString.contains("demo-pass") == false)
    }

    @Test func doAuthRefusalShowsTheProvidersWords() async {
        let portal = Portal { action, _, _ in
            action == "do_auth" ? .fixture("stalker/do_auth_refused.json") : nil
        }
        let error = await sourceError { try await portal.client(username: "demo-user", password: "wrong").signIn() }
        #expect(error?.code == .authenticationFailed)
        #expect(error?.providerMessage == "Wrong login or password")
    }

    @Test func unknownMACIsRefusedWithThePortalsWords() async {
        let portal = Portal { action, _, _ in
            action == "get_profile" ? .fixture("stalker/profile_unknown_mac.json") : nil
        }
        let error = await sourceError { try await portal.client().signIn() }
        #expect(error?.code == .authenticationFailed)
        #expect(error?.providerMessage == "Your STB is not registered. Please contact your provider.")
    }

    @Test func aDeadHostFailsWithoutTryingEveryPath() async {
        let host = StubURLProtocol.makeHost()
        let session = StubURLProtocol.session(host: host) { _ in throw StubURLProtocol.TransportFailure(code: .cannotConnectToHost) }
        let client = StalkerClient(configuration: SourceConfiguration(name: "P", kind: .stalker, serverURL: "http://\(host)/c/", macAddress: Self.mac), session: session)
        let error = await sourceError { try await client.signIn() }
        #expect(error?.code == .unreachable)
        #expect(StubURLProtocol.requests(for: host).count == 1)
    }

    @Test func noPathAnsweringIsABadResponse() async {
        let portal = Portal(apiPath: "/nowhere.php")
        let client = portal.client(path: "/c/")
        let error = await sourceError { try await client.signIn() }
        #expect(error?.code == .badResponse)
        #expect(error?.providerMessage == "404 Not Found")
        #expect(portal.requests.count >= 5)
    }

    @Test func malformedMACFailsBeforeAnyRequest() async {
        let host = StubURLProtocol.makeHost()
        let session = StubURLProtocol.session(host: host) { _ in .json("{}") }
        let client = StalkerClient(configuration: SourceConfiguration(name: "P", kind: .stalker, serverURL: "http://\(host)/c/", macAddress: "not a mac"), session: session)
        let error = await sourceError { try await client.channels() }
        #expect(error?.code == .invalidConfiguration)
        #expect(StubURLProtocol.requests(for: host).isEmpty)
    }

    // MARK: The one re-handshake

    @Test func anExpiredTokenHandshakesAgainOnce() async throws {
        let portal = Portal { action, _, attempt in
            guard action == "get_all_channels" else { return nil }
            return attempt == 1 ? .text("Authorization failed.") : .fixture("stalker/channels_data.json")
        }
        let channels = try await portal.client().channels()
        #expect(channels.count == 3)
        #expect(portal.count("handshake") == 2)
    }

    @Test func aRefusalThatPersistsFailsAfterOneRetry() async {
        let portal = Portal { action, _, _ in
            action == "get_all_channels" ? .text("Unauthorized", status: 401) : nil
        }
        let error = await sourceError { try await portal.client().channels() }
        #expect(error?.code == .authenticationFailed)
        #expect(portal.count("handshake") == 2)
        #expect(portal.count("get_all_channels") == 2)
    }

    // MARK: Catalog

    @Test func categoriesForEachKind() async throws {
        let portal = Portal { action, request, _ in
            switch (request.query["type"], action) {
            case ("itv", "get_genres"): return .fixture("stalker/genres.json")
            case ("vod", "get_categories"): return .fixture("stalker/vod_categories.json")
            default: return nil // the series module answers empty
            }
        }
        let client = portal.client()
        #expect(try await client.categories(.live).map(\.name) == ["News", "Sports", "Kids", "For adults"])
        #expect(try await client.categories(.vod).map(\.id) == ["12", "14"])
        // No series module: shows sit in VOD categories named like series.
        let series = try await client.categories(.series)
        #expect(series.map(\.id) == ["14"])
        #expect(series.allSatisfy { $0.kind == .series })
    }

    @Test func channelsFallBackToTheOrderedList() async throws {
        let portal = Portal { action, _, _ in
            action == "get_ordered_list" ? .fixture("stalker/channels_data.json") : nil
        }
        let channels = try await portal.client().channels()
        #expect(channels.map(\.id) == ["1001", "1002", "1003"])
        let list = try #require(portal.requests("get_ordered_list").first)
        #expect(list.query["p"] == "1")
        #expect(list.query["type"] == "itv")
        #expect(list.query["genre"] == "*")
    }

    @Test func moviePagesCountFromOneOnTheWire() async throws {
        let portal = Portal { action, _, _ in
            action == "get_ordered_list" ? .fixture("stalker/vod_page_data.json") : nil
        }
        let client = portal.client()
        let first = try await client.movies(categoryID: "12", page: 0)
        // The third row is a show (`is_series`), which belongs to series().
        #expect(first.items.map(\.id) == ["7001", "7002"])
        #expect(first.totalItems == 7)
        #expect(first.hasMore)
        let last = try await client.movies(categoryID: "12", page: 2)
        #expect(!last.hasMore)

        let pages = portal.requests("get_ordered_list").map { $0.query["p"] }
        #expect(pages == ["1", "3"])
        #expect(portal.requests("get_ordered_list").allSatisfy { $0.query["type"] == "vod" && $0.query["category"] == "12" })
    }

    @Test func seriesDetailWalksSeasonsThenEpisodes() async throws {
        let portal = Portal { action, request, _ in
            guard action == "get_ordered_list", request.query["movie_id"] == "9001" else { return nil }
            switch request.query["season_id"] {
            case "0": return .fixture("stalker/seasons.json")
            case "9001:1": return .fixture("stalker/episodes_s1.json")
            case "9001:2": return .fixture("stalker/episodes_s2.json")
            default: return nil
            }
        }
        let detail = try await portal.client().seriesDetail(RemoteSeries(id: "9001", name: "Salt & Signal"))
        #expect(detail.seasons.map(\.number) == [1, 2])
        #expect(detail.seasons.map(\.remoteID) == ["9001:1", "9001:2"])
        // Season 1 lists numbers on the season row; season 2 has episode rows.
        #expect(detail.episodes.map { "\($0.season)x\($0.number)" } == ["1x1", "1x2", "1x3", "2x4", "2x5"])
        #expect(detail.episodes[3].title == "Fog Bell")
        #expect(portal.requests("get_ordered_list").allSatisfy { $0.query["type"] == "series" && $0.query["episode_id"] == "0" })
    }

    @Test func shortGuideAsksByChannelID() async throws {
        let portal = Portal { action, _, _ in
            action == "get_short_epg" ? .fixture("stalker/short_epg_timestamps.json") : nil
        }
        let channel = RemoteChannel(id: "1001", name: "Cityline News", guideChannelID: "1001", command: "ffrt http://localhost/ch/1001_")
        let guide = try await portal.client().shortGuide(for: channel, limit: 4)
        #expect(guide.map(\.title) == ["Evening Bulletin", "Market Close"])
        let request = try #require(portal.requests("get_short_epg").first)
        #expect(request.query["ch_id"] == "1001")
        #expect(request.query["size"] == "4")
        #expect(request.query["type"] == "itv")
    }

    // MARK: Links

    @Test func liveLinkIsTheLastWordOfCreateLink() async throws {
        let portal = Portal { action, _, _ in
            action == "create_link" ? .fixture("stalker/create_link_ffmpeg.json") : nil
        }
        let channel = RemoteChannel(id: "1001", name: "Cityline News", command: "ffrt http://localhost/ch/1001_")
        let link = try await portal.client().streamLink(for: .live(channel))
        #expect(link.url.host() == "cdn.portal.test")
        #expect(link.url.absoluteString.hasPrefix("http://cdn.portal.test:8080/play/live.php?"))
        #expect(link.formatHint == .mpegts) // extension=ts
        #expect(link.isLive)
        #expect(link.headers["User-Agent"]?.contains("MAG200") == true)
        let request = try #require(portal.requests("create_link").first)
        #expect(request.query["cmd"] == "ffrt http://localhost/ch/1001_")
        #expect(request.query["type"] == "itv")
    }

    @Test func liveLinkWithoutAURLIsNoLink() async {
        let portal = Portal { action, _, _ in
            action == "create_link" ? .fixture("stalker/create_link_empty.json") : nil
        }
        let channel = RemoteChannel(id: "1003", name: "Lantern Drama", command: "ffrt http://localhost/ch/1003_")
        let error = await sourceError { try await portal.client().streamLink(for: .live(channel)) }
        #expect(error?.code == .noLink)
        #expect(error?.providerMessage == "nothing_to_play")
    }

    @Test func movieLinkWrapsABareCommand() async throws {
        let portal = Portal { action, _, _ in
            action == "create_link" ? .fixture("stalker/movie_link_cmd.json") : nil
        }
        let movie = RemoteMovie(id: "7101", name: "Paper Boats", command: "7101")
        let link = try await portal.client().streamLink(for: .movie(movie))
        #expect(link.url.absoluteString == "http://vod.portal.test:8080/movies/7002.mkv?token=Pq7")
        #expect(link.formatHint == .mkv)
        #expect(!link.isLive)
        let request = try #require(portal.requests("create_link").first)
        #expect(request.query["type"] == "vod")
        #expect(request.query["cmd"] == "/media/file_7101.mpg")
        #expect(request.query["series"] == nil)
    }

    @Test func searchSplitsShowsFromMoviesAndAsksTheSeriesModuleToo() async throws {
        let portal = Portal { action, request, _ in
            guard action == "get_ordered_list", let term = request.query["search"] else { return nil }
            switch request.query["type"] {
            case "vod":
                #expect(term == "lucifer")
                return .json(#"{"js":{"total_items":20,"max_page_items":14,"data":[{"id":"501","name":"Lucifer","is_series":"1","category_id":"4"},{"id":"502","name":"Lucifer's Women","is_series":"0","category_id":"9"}]}}"#)
            case "series":
                return .json(#"{"js":{"total_items":1,"max_page_items":14,"data":[{"id":"601","name":"Lucifer (2016)","category_id":"5"}]}}"#)
            default:
                return nil
            }
        }
        let page = try await portal.client().search("lucifer", page: 0)
        #expect(page.movies.map(\.name) == ["Lucifer's Women"])
        #expect(page.series.map(\.name) == ["Lucifer", "Lucifer (2016)"])
        #expect(page.series.first?.categoryID == "4")
        #expect(page.hasMore) // 20 titles, 2 on this page of 14
        let vod = try #require(portal.requests("get_ordered_list").first { $0.query["type"] == "vod" })
        #expect(vod.query["category"] == "*")
        #expect(vod.query["p"] == "1")
        #expect(portal.client().capabilities.searchesCatalog)
    }

    @Test func movieWithFileRowsLinksItsFile() async throws {
        let portal = Portal { action, request, _ in
            switch action {
            case "get_ordered_list" where request.query["movie_id"] == "7101":
                return .json(#"{"js":{"total_items":1,"max_page_items":14,"data":[{"id":"8800123","video_id":"7101","is_file":"1","quality":"6","protocol":"custom","cmd":"http://vod.portal.test/movie.m3u8"}]}}"#)
            case "create_link" where request.query["cmd"] == "/media/file_8800123.mpg":
                return .json(#"{"js":{"id":"8800123","cmd":"http://vod.portal.test:8080/movie/index.m3u8?token=Tk1"}}"#)
            default:
                return nil
            }
        }
        let movie = RemoteMovie(id: "7101", name: "Paper Boats", command: "/media/7101.mpg")
        let link = try await portal.client().streamLink(for: .movie(movie))
        #expect(link.url.absoluteString == "http://vod.portal.test:8080/movie/index.m3u8?token=Tk1")
        #expect(link.formatHint == .hls)
        // The file linked, so the movie's own cmd was never tried.
        #expect(portal.requests("create_link").count == 1)
        #expect(portal.requests("get_ordered_list").first?.query["type"] == "vod")
    }

    @Test func movieWhoseFileWontLinkFallsBackToItsCommand() async throws {
        let portal = Portal { action, request, _ in
            switch action {
            case "get_ordered_list" where request.query["movie_id"] == "7101":
                return .json(#"{"js":{"total_items":1,"max_page_items":14,"data":[{"id":"8800123","video_id":"7101","is_file":"1"}]}}"#)
            case "create_link" where request.query["cmd"] == "/media/7101.mpg":
                return .fixture("stalker/movie_link_cmd.json")
            case "create_link":
                return .fixture("stalker/create_link_empty.json")
            default:
                return nil
            }
        }
        let movie = RemoteMovie(id: "7101", name: "Paper Boats", command: "/media/7101.mpg")
        let link = try await portal.client().streamLink(for: .movie(movie))
        #expect(link.url.absoluteString == "http://vod.portal.test:8080/movies/7002.mkv?token=Pq7")
        #expect(portal.requests("create_link").map { $0.query["cmd"] } == ["/media/file_8800123.mpg", "/media/7101.mpg"])
    }

    @Test func episodeLinkSendsTheSeriesNumberAndBuildsMoviePHP() async throws {
        let portal = Portal { action, _, _ in
            action == "create_link" ? .fixture("stalker/episode_link_token.json") : nil
        }
        let command = "eyJlcGlzb2RlX2lkIjoiOTAwMToyOjQifQ=="
        let episode = RemoteEpisode(id: "9001:2:4", seriesID: "9001", season: 2, number: 4, title: "Fog Bell", containerExtension: "mp4", command: command)
        let link = try await portal.client().streamLink(for: .episode(episode, series: nil))
        #expect(link.url.host() == portal.host)
        #expect(link.url.path() == "/play/movie.php")
        let query = URLRequest(url: link.url).query
        #expect(query["stream"] == "18734.mp4")
        #expect(query["play_token"] == "Xy12Ab")
        #expect(query["type"] == "series")
        #expect(query["mac"] == Self.mac)
        #expect(link.formatHint == .mp4)

        let request = try #require(portal.requests("create_link").first)
        #expect(request.query["cmd"] == command) // base64 JSON goes back untouched
        #expect(request.query["series"] == "4")
    }

    @Test func catchupFindsTheProgrammeAndAsksTheArchive() async throws {
        let portal = Portal { action, request, _ in
            switch (request.query["type"], action) {
            case ("epg", "get_simple_data_table"): return .fixture("stalker/simple_data_table.json")
            case ("tv_archive", "create_link"): return .fixture("stalker/archive_link.json")
            default: return nil
            }
        }
        let channel = RemoteChannel(id: "1001", name: "Cityline News", guideChannelID: "1001", hasArchive: true, archiveDays: 7, command: "ffrt http://localhost/ch/1001_")
        let link = try await portal.client().streamLink(for: .catchup(channel, start: utc(2026, 10, 24, 19), duration: 3600))
        #expect(link.url.absoluteString == "http://archive.portal.test/archive/1001/1792868400.m3u8?token=Ar9")
        #expect(link.formatHint == .hls)
        #expect(!link.isLive)
        #expect(portal.requests("get_simple_data_table").first?.query["date"] == "2026-10-24")
        #expect(portal.requests("create_link").first?.query["cmd"] == "auto /media/55502.mpg")
    }

    // MARK: Session upkeep and privacy

    @Test func keepAliveSendsTheWatchdogOnlyWhenSignedIn() async throws {
        let portal = Portal()
        let client = portal.client()
        await client.keepAlive()
        #expect(portal.requests.isEmpty)
        _ = try await client.signIn()
        await client.keepAlive()
        let watchdog = try #require(portal.requests("get_events").first)
        #expect(watchdog.query["type"] == "watchdog")
        #expect(watchdog.query["event_active_id"] == "0")
        #expect(watchdog.query["cur_play_type"] == "1")
        #expect(watchdog.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
    }

    @Test func providerTextNeverCarriesTheMAC() async {
        let portal = Portal { action, _, _ in
            action == "create_link" ? .text("Stream limit reached for 00:1A:79:00:00:01 (001A79000001)", status: 500) : nil
        }
        let channel = RemoteChannel(id: "1001", name: "Cityline News", command: "ffrt http://localhost/ch/1001_")
        let error = await sourceError { try await portal.client().streamLink(for: .live(channel)) }
        #expect(error?.code == .badResponse)
        let message = error?.providerMessage ?? ""
        #expect(message.contains("Stream limit reached"))
        #expect(!message.contains(Self.mac))
        #expect(!message.contains("001A79000001"))
        #expect(message.contains("00:1A:79:••:••:01"))
    }
}
