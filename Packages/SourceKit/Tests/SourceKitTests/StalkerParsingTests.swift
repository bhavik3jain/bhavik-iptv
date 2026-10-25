import Foundation
import Testing
@testable import SourceKit

/// Parsing of saved Stalker answers (technical spec, Testing): `js` as an
/// array or as `data`, pages, the link inside `create_link`'s `cmd`, guide
/// spellings and time zones.
@Suite struct StalkerParsingTests {
    let api = URL(string: "http://portal.test/stalker_portal/server/load.php")!
    let london = TimeZone(identifier: "Europe/London")!

    @Test func envelopeReadsJSAndIgnoresMinistraTimings() throws {
        let envelope = try #require(StalkerEnvelope(data: Fixture.data("stalker/handshake.json")))
        #expect(envelope.js.string("token") == "4F1C9A0E2B7D4E5F8A9B0C1D2E3F4A5B")
        #expect(envelope.message == nil)
    }

    @Test func envelopeUnwrapsSecureFraming() throws {
        let envelope = try #require(StalkerEnvelope(data: Data(#"/*-secure- {"js":{"token":"T"}} */"#.utf8)))
        #expect(envelope.js.string("token") == "T")
    }

    @Test func plainTextIsNotAnEnvelope() {
        #expect(StalkerEnvelope(data: Data("Authorization failed.".utf8)) == nil)
    }

    @Test func profileSignedInOnlyWithAnID() throws {
        #expect(StalkerParse.profileIsSignedIn(Fixture.json("stalker/profile.json")["js"]!))
        let unknown = try #require(StalkerEnvelope(data: Fixture.data("stalker/profile_unknown_mac.json")))
        #expect(!StalkerParse.profileIsSignedIn(unknown.js))
        #expect(unknown.message == "Your STB is not registered. Please contact your provider.")
    }

    @Test func genresSkipAllAndKeepOrder() {
        let categories = StalkerParse.categories(Fixture.json("stalker/genres.json")["js"]!, kind: .live)
        #expect(categories.map(\.id) == ["1", "4", "7", "9"])
        #expect(categories.map(\.name) == ["News", "Sports", "Kids", "For adults"])
        #expect(categories.allSatisfy { $0.kind == .live })
    }

    @Test func channelsFromJSData() throws {
        let channels = StalkerParse.channels(Fixture.json("stalker/channels_data.json")["js"]!, api: api)
        #expect(channels.count == 3)
        let news = try #require(channels.first)
        #expect(news.id == "1001")
        #expect(news.number == 101)
        #expect(news.name == "Cityline News HD")
        #expect(news.categoryID == "1")
        #expect(news.guideChannelID == "1001")
        #expect(news.command == "ffrt http://localhost/ch/1001_")
        #expect(news.hasArchive)
        #expect(news.archiveDays == 7) // 168 hours
        #expect(news.logoURL?.absoluteString == "http://portal.test/stalker_portal/misc/logos/320/1001.png")

        let sports = channels[1]
        #expect(sports.number == 102)
        #expect(!sports.hasArchive)
        #expect(sports.archiveDays == 0)
        #expect(sports.formatHint == .mpegts)
        #expect(sports.logoURL?.absoluteString == "http://img.portal.test/logos/1002.png")

        // tv_archive_duration under a month is days; no cmds falls back to the id.
        #expect(channels[2].archiveDays == 3)
        #expect(channels[2].guideChannelID == "1003")
        #expect(channels[2].logoURL == nil)
    }

    @Test func channelsFromBareArray() throws {
        let channels = StalkerParse.channels(Fixture.json("stalker/channels_array.json")["js"]!, api: api)
        let channel = try #require(channels.first)
        #expect(channels.count == 1)
        #expect(channel.id == "2001")
        #expect(channel.guideChannelID == "2001")
        #expect(channel.hasArchive)
        #expect(channel.formatHint == .hls)
        #expect(channel.logoURL?.absoluteString == "http://portal.test/stalker_portal/misc/logos/320/2001.png")
    }

    @Test func liveLinkIsLastWordOfCmd() throws {
        let js = Fixture.json("stalker/create_link_ffmpeg.json")["js"]!
        let link = try #require(StalkerParse.liveLink(js))
        #expect(link.hasPrefix("http://cdn.portal.test:8080/play/live.php?"))
        #expect(!link.contains("ffmpeg"))
        #expect(StreamFormatHint.guess(fromURL: link) == .mpegts)
        #expect(StalkerParse.liveLink(Fixture.json("stalker/create_link_empty.json")["js"]!) == nil)
    }

    @Test func vodLinkOrder() throws {
        // A URL in js.cmd, after an advert entry.
        let fromCmd = StalkerParse.vodLink(Fixture.json("stalker/movie_link_cmd.json")["js"]!, streamServerBase: "http://portal.test", mac: "00:1A:79:00:00:01", linkType: "movie")
        #expect(fromCmd == "http://vod.portal.test:8080/movies/7002.mkv?token=Pq7")
        // js.url wins.
        let fromURL = StalkerParse.vodLink(.object(["url": .string("http://vod.portal.test/a.mp4"), "cmd": .string("ffmpeg http://other.test/b.mp4")]), streamServerBase: nil, mac: "", linkType: "movie")
        #expect(fromURL == "http://vod.portal.test/a.mp4")
        // Else play/movie.php from id and play_token.
        let built = try #require(StalkerParse.vodLink(Fixture.json("stalker/episode_link_token.json")["js"]!, streamServerBase: "http://portal.test", mac: "00:1A:79:00:00:01", linkType: "series"))
        let components = try #require(URLComponents(string: built))
        #expect(components.path == "/play/movie.php")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["stream"] == "18734.mp4")
        #expect(query["play_token"] == "Xy12Ab")
        #expect(query["type"] == "series")
        #expect(query["mac"] == "00:1A:79:00:00:01")
    }

    @Test func movieCommandWrapping() {
        #expect(StalkerParse.movieCommand("7101") == "/media/file_7101.mpg")
        #expect(StalkerParse.movieCommand("/media/7002.mpg") == "/media/7002.mpg")
        #expect(StalkerParse.movieCommand("ffmpeg http://vod.test/1.mp4") == "ffmpeg http://vod.test/1.mp4")
        // Base64 JSON commands go back untouched.
        #expect(StalkerParse.movieCommand("eyJ0eXBlIjoibW92aWUiLCJzdHJlYW1faWQiOiI3MDAxIn0=") == "eyJ0eXBlIjoibW92aWUiLCJzdHJlYW1faWQiOiI3MDAxIn0=")
    }

    @Test func shortGuideFromArrayWithTimestamps() {
        let programmes = StalkerParse.programmes(Fixture.json("stalker/short_epg_timestamps.json")["js"]!, guideChannelID: "1001", timeZone: london)
        #expect(programmes.count == 2)
        #expect(programmes[0].title == "Evening Bulletin")
        #expect(programmes[0].summary == "The day's headlines.")
        #expect(programmes[0].start == utc(2026, 10, 24, 19))
        #expect(programmes[0].end == utc(2026, 10, 24, 20))
        #expect(programmes[0].hasArchive)
        #expect(programmes[0].category == "News")
        // Timestamps as strings, and an empty descr is no summary.
        #expect(programmes[1].start == utc(2026, 10, 24, 20))
        #expect(programmes[1].summary == nil)
    }

    @Test func shortGuideFromEPGKeyReadsWallClockInPortalZone() {
        let programmes = StalkerParse.programmes(Fixture.json("stalker/short_epg_epg_key.json")["js"]!, guideChannelID: "1001", timeZone: london)
        #expect(programmes.map(\.title) == ["World Desk", "After the clocks change"])
        // 21:30 BST is 20:30 UTC…
        #expect(programmes[0].start == utc(2026, 10, 24, 20, 30))
        #expect(programmes[0].summary == "Correspondents on tonight's stories.")
        // …and after the clocks go back on the 25th, 20:00 GMT is 20:00 UTC.
        #expect(programmes[1].start == utc(2026, 10, 25, 20))
        #expect(programmes[1].guideChannelID == "1001")
    }

    @Test func shortGuideFromDataKeyHonoursExplicitOffsets() {
        let programmes = StalkerParse.programmes(Fixture.json("stalker/short_epg_data_key.json")["js"]!, guideChannelID: "1001", timeZone: london)
        #expect(programmes.count == 1) // the one with no end is dropped
        #expect(programmes[0].title == "Late Edition")
        #expect(programmes[0].start == utc(2026, 10, 24, 20))
        #expect(programmes[0].summary == "With an offset, so the zone doesn't matter.")
    }

    @Test func sameWallClockDiffersByPortalZone() {
        let row: JSONValue = .object(["name": .string("Bulletin"), "time": .string("2026-07-01 20:00:00"), "time_to": .string("2026-07-01 21:00:00")])
        let inLondon = StalkerParse.programme(row, guideChannelID: "1", timeZone: london)
        let inNewYork = StalkerParse.programme(row, guideChannelID: "1", timeZone: TimeZone(identifier: "America/New_York")!)
        #expect(inLondon?.start == utc(2026, 7, 1, 19))
        #expect(inNewYork?.start == utc(2026, 7, 2, 0))
    }

    @Test func orderedListWithDataAndPaging() {
        let list = StalkerParse.listPage(Fixture.json("stalker/vod_page_data.json")["js"]!)
        #expect(list.items.count == 3)
        #expect(list.totalItems == 7)
        #expect(list.pageSize == 3)
        #expect(list.hasMore(after: 0))
        #expect(list.hasMore(after: 1))
        #expect(!list.hasMore(after: 2))
    }

    @Test func orderedListAsBareArrayIsTheWholeList() {
        let list = StalkerParse.listPage(Fixture.json("stalker/vod_page_bare.json")["js"]!)
        #expect(list.items.count == 2)
        #expect(list.totalItems == nil)
        #expect(!list.hasMore(after: 0))
    }

    /// Ministra reads `p=0` as "the page with the last-watched item" and
    /// `p=N` as page N-1, so our 0-based page 0 goes out as `p=1`.
    @Test func portalPagesCountFromOne() {
        #expect(StalkerParse.portalPage(0) == "1")
        #expect(StalkerParse.portalPage(4) == "5")
        #expect(StalkerParse.portalPage(-3) == "1")
    }

    @Test func movieRows() throws {
        let rows = StalkerParse.listPage(Fixture.json("stalker/vod_page_data.json")["js"]!).items
        let movie = try #require(StalkerParse.movie(rows[0], api: api, timeZone: london))
        #expect(movie.id == "7001")
        #expect(movie.year == 2019)
        #expect(movie.rating == 7.4)
        #expect(movie.durationSeconds == 104 * 60)
        #expect(movie.posterURL?.absoluteString == "http://portal.test/stalker_portal/screenshots/7001.jpg")
        #expect(movie.addedAt == utc(2026, 8, 14, 9, 21, 45)) // BST
        #expect(movie.containerExtension == "mkv")
        #expect(movie.genre == "Drama")

        let classic = try #require(StalkerParse.movie(rows[1], api: api, timeZone: london))
        #expect(classic.durationSeconds == 98 * 60)
        #expect(classic.rating == 6.9) // IMDb "N/A" falls through to Kinopoisk
        #expect(classic.plot == nil)
    }

    @Test func episodesNumberedBySeriesNumberOrName() {
        let rows = StalkerParse.listPage(Fixture.json("stalker/episodes_s2.json")["js"]!).items
        let episodes = StalkerParse.episodes(rows, seriesID: "9001", season: 2, api: api)
        #expect(episodes.map(\.number) == [4, 5])
        #expect(episodes.map(\.title) == ["Fog Bell", "Episode 5"])
        #expect(episodes[0].containerExtension == "mp4")
        #expect(episodes.allSatisfy { $0.season == 2 && $0.seriesID == "9001" })
    }

    @Test func numberedEpisodesFromSeasonRow() throws {
        let row = try #require(StalkerParse.listPage(Fixture.json("stalker/seasons.json")["js"]!).items.first)
        let episodes = StalkerParse.numberedEpisodes(row, seriesID: "9001", season: 1)
        #expect(episodes.map(\.number) == [1, 2, 3])
        #expect(episodes.allSatisfy { $0.command == "/media/9001_s1.mpg" })
    }

    @Test func seriesStyleCategoryNames() {
        #expect(StalkerParse.isSeriesStyleCategory("TV Series"))
        #expect(StalkerParse.isSeriesStyleCategory("Kids TV"))
        #expect(!StalkerParse.isSeriesStyleCategory("Drama"))
    }

    @Test func accountExpiryFromMainInfoPhone() {
        let account = StalkerParse.account(
            profile: Fixture.json("stalker/profile.json")["js"],
            mainInfo: Fixture.json("stalker/main_info.json")["js"],
            timeZone: london,
            now: utc(2026, 10, 24, 20)
        )
        #expect(account.status == .active)
        #expect(account.expiresAt == utc(2027, 1, 15, 16, 31))
    }

    @Test func accountExpiredAndBlocked() {
        let expired = StalkerParse.account(profile: .object(["id": .string("1"), "end_date": .string("2026-01-01 00:00:00")]), mainInfo: nil, timeZone: london, now: utc(2026, 10, 24, 20))
        #expect(expired.status == .expired)
        let blocked = StalkerParse.account(profile: .object(["id": .string("1"), "blocked": .string("1"), "block_msg": .string("Account blocked")]), mainInfo: nil, timeZone: london, now: utc(2026, 10, 24, 20))
        #expect(blocked.status == .disabled)
        #expect(blocked.message == "Account blocked")
        // MySQL's zero date is no expiry.
        let none = StalkerParse.account(profile: Fixture.json("stalker/profile.json")["js"], mainInfo: nil, timeZone: london, now: utc(2026, 10, 24, 20))
        #expect(none.expiresAt == nil)
        #expect(none.status == .active)
    }

    @Test func programmeIDForArchive() {
        let rows = StalkerParse.listPage(Fixture.json("stalker/simple_data_table.json")["js"]!).items
        #expect(StalkerParse.programmeID(in: rows, startingAt: utc(2026, 10, 24, 19), timeZone: london) == "55502")
        #expect(StalkerParse.programmeID(in: rows, startingAt: utc(2026, 10, 24, 19, 3), timeZone: london) == "55502")
        #expect(StalkerParse.programmeID(in: rows, startingAt: utc(2026, 10, 24, 12), timeZone: london) == nil)
        #expect(StalkerParse.dayString(utc(2026, 10, 24, 23, 30), timeZone: london) == "2026-10-25")
    }
}

@Suite struct StalkerPortalTests {
    @Test func advancedFieldDefaults() throws {
        let portal = try StalkerPortal(configuration: SourceConfiguration(name: "P", kind: .stalker, serverURL: "portal.test/c/", macAddress: "00-1a-79-aa-bb-41"))
        #expect(portal.mac == "00:1A:79:AA:BB:41")
        #expect(portal.serial == "0000000000000")
        #expect(portal.deviceID == String(repeating: "f", count: 64))
        #expect(portal.deviceID2 == String(repeating: "f", count: 64))
        #expect(portal.signature == String(repeating: "f", count: 64))
        #expect(portal.model == "MAG254")
        #expect(portal.typedURL.absoluteString == "http://portal.test/c/")
    }

    @Test func candidatePathsStripTheWebPlayer() throws {
        let portal = try StalkerPortal(configuration: SourceConfiguration(name: "P", kind: .stalker, serverURL: "http://portal.test:8080/stalker_portal/c/", macAddress: "00:1A:79:00:00:01"))
        let paths = portal.candidateAPIURLs.map { $0.absoluteString }
        #expect(paths.first == "http://portal.test:8080/stalker_portal/server/load.php")
        #expect(paths.contains("http://portal.test:8080/portal.php"))
        #expect(paths.contains("http://portal.test:8080/load.php"))
        #expect(paths.contains("http://portal.test:8080/stalker_portal/server/portal.php"))
        #expect(Set(paths).count == paths.count)
    }

    @Test func typedPHPPathIsTriedFirst() throws {
        let portal = try StalkerPortal(configuration: SourceConfiguration(name: "P", kind: .stalker, serverURL: "http://portal.test/custom/api.php", macAddress: "00:1A:79:00:00:01"))
        #expect(portal.candidateAPIURLs.first?.absoluteString == "http://portal.test/custom/api.php")
    }

    @Test func malformedLoginsAreRefusedUpFront() {
        #expect(throws: SourceError.self) { try StalkerPortal(configuration: SourceConfiguration(name: "P", kind: .stalker, serverURL: "", macAddress: "00:1A:79:00:00:01")) }
        #expect(throws: SourceError.self) { try StalkerPortal(configuration: SourceConfiguration(name: "P", kind: .stalker, serverURL: "http://portal.test", macAddress: "00:1A:79")) }
    }

    @Test func streamServerBase() {
        #expect(StalkerPortal.streamServerBase(for: URL(string: "http://portal.test:8080/stalker_portal/server/load.php")!) == "http://portal.test:8080")
        #expect(StalkerPortal.streamServerBase(for: URL(string: "http://portal.test/portal.php")!) == "http://portal.test")
    }
}
