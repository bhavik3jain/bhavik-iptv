import Foundation
import HouseholdKit
import SourceKit
import Testing
@testable import HouseholdFeature

/// `SourceDraft`: the source editor's rules for Test and Save (SRC-1…SRC-3).
@Suite struct SourceDraftTests {
    let id = UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000001")!

    func stalker(server: String = "portal.example.com/c/", mac: String = "00:1A:79:12:34:56") -> SourceDraft {
        var draft = SourceDraft(kind: .stalker)
        draft.serverURL = server
        draft.macAddress = mac
        return draft
    }

    func xtream(server: String = "http://xtream.example.com:8080", username: String = "demo-user", password: String = "demo-pass") -> SourceDraft {
        var draft = SourceDraft(kind: .xtream)
        draft.serverURL = server
        draft.username = username
        draft.password = password
        return draft
    }

    func m3u(_ playlist: String = "https://lists.example.com/get.php?type=m3u") -> SourceDraft {
        var draft = SourceDraft(kind: .m3u)
        draft.playlistURL = playlist
        return draft
    }

    // MARK: Kind

    @Test func eachKindStartsWithItsOwnStreamLimit() {
        #expect(SourceDraft(kind: .stalker).maxStreams == 1)
        #expect(SourceDraft(kind: .xtream).maxStreams == 1)
        #expect(SourceDraft(kind: .m3u).maxStreams == 0)
    }

    @Test func theStreamsFieldTakesTypedNumbers() {
        #expect(StreamCountField.count(from: "3") == 3)
        #expect(StreamCountField.count(from: " 12 ") == 12)
        #expect(StreamCountField.count(from: "") == 0)
        #expect(StreamCountField.count(from: "abc") == 0)
        #expect(StreamCountField.count(from: "4a") == 4)
        #expect(StreamCountField.count(from: "250") == 99)
        #expect(StreamCountField.text(for: 0) == "")
        #expect(StreamCountField.text(for: 5) == "5")
    }

    @Test func switchingKindTakesThatKindsLimitButReselectingKeepsAnEdit() {
        var draft = SourceDraft(kind: .stalker)
        draft.maxStreams = 3
        draft.changeKind(to: .stalker)
        #expect(draft.maxStreams == 3)
        draft.changeKind(to: .m3u)
        #expect(draft.kind == .m3u)
        #expect(draft.maxStreams == 0)
        draft.changeKind(to: .stalker)
        #expect(draft.maxStreams == 1)
    }

    // MARK: Required fields

    @Test func requiredFieldsPerKind() {
        #expect(SourceDraft(kind: .stalker).missingFields == [.serverURL, .macAddress])
        #expect(SourceDraft(kind: .xtream).missingFields == [.serverURL, .username, .password])
        #expect(SourceDraft(kind: .m3u).missingFields == [.playlistURL])
        #expect(stalker().missingFields.isEmpty)
        #expect(xtream().missingFields.isEmpty)
        #expect(m3u().missingFields.isEmpty)
    }

    @Test func whitespaceIsNotAValue() {
        #expect(stalker(server: "  \n", mac: " ").missingFields == [.serverURL, .macAddress])
        #expect(xtream(password: "   ").missingFields == [.password])
        #expect(!xtream(password: "   ").isComplete)
    }

    // MARK: Malformed fields

    @Test func stalkerChecks() {
        // Portals are usually typed without a scheme.
        #expect(stalker(server: "portal.example.com/c/").problem(with: .serverURL) == nil)
        #expect(stalker(server: "https://portal.example.com:8080/stalker_portal/c/").problem(with: .serverURL) == nil)
        #expect(stalker(server: "portal example com").problem(with: .serverURL) != nil)
        #expect(stalker(server: "ftp://portal.example.com").problem(with: .serverURL) != nil)
        #expect(stalker(mac: "00:1A:79:12:34").problem(with: .macAddress) != nil)
        #expect(stalker(mac: "00-1a-79-12-34-56").problem(with: .macAddress) == nil)

        var zoned = stalker()
        zoned.timeZone = "Europe/London"
        #expect(zoned.problem(with: .timeZone) == nil)
        #expect(zoned.isComplete)
        zoned.timeZone = "Mars/Olympus_Mons"
        #expect(zoned.problem(with: .timeZone) != nil)
        #expect(!zoned.isComplete)
    }

    @Test func emptyFieldsAreMissingNotMalformed() {
        let empty = SourceDraft(kind: .stalker)
        for field: SourceDraft.Field in [.serverURL, .macAddress, .playlistURL, .guideURL, .timeZone, .username, .password] {
            #expect(empty.problem(with: field) == nil)
        }
        #expect(!empty.isComplete)
    }

    @Test func fieldsOfAnotherKindAreNeverChecked() {
        // A bad MAC or time zone left over from Stalker doesn't block an M3U.
        var draft = m3u()
        draft.macAddress = "nonsense"
        draft.timeZone = "Nowhere/Special"
        draft.serverURL = "not a url"
        #expect(draft.problem(with: .macAddress) == nil)
        #expect(draft.problem(with: .timeZone) == nil)
        #expect(draft.problem(with: .serverURL) == nil)
        #expect(draft.isComplete)

        // Stalker has no guide field.
        var portal = stalker()
        portal.guideURL = "not a url"
        #expect(portal.problem(with: .guideURL) == nil)
        #expect(portal.isComplete)
    }

    @Test func guideAndPlaylistNeedAScheme() {
        var draft = xtream()
        draft.guideURL = "guide.example.com/epg.xml"
        #expect(draft.problem(with: .guideURL) != nil)
        #expect(!draft.isComplete)
        draft.guideURL = "https://guide.example.com/epg.xml.gz"
        #expect(draft.problem(with: .guideURL) == nil)
        #expect(draft.isComplete)

        #expect(m3u("lists.example.com/list.m3u").problem(with: .playlistURL) != nil)
        #expect(m3u("file:///Users/someone/Playlists/list.m3u").problem(with: .playlistURL) == nil)
        #expect(m3u("http://lists.example.com/list.m3u").isComplete)
    }

    // MARK: Names

    @Test func theNameFallsBackToTheHostThenTheKind() {
        var draft = stalker(server: "portal.example.com/c/")
        #expect(draft.resolvedName == "portal.example.com")
        draft.name = "  Living Room  "
        #expect(draft.resolvedName == "Living Room")

        #expect(m3u("https://lists.example.com/get.php").resolvedName == "lists.example.com")
        // A picked file is named after the file.
        #expect(m3u("file:///Users/someone/Playlists/Family%20List.m3u").resolvedName == "Family List")
        // Nothing usable typed: the kind's name.
        #expect(SourceDraft(kind: .xtream).resolvedName == "Xtream Codes")
        #expect(stalker(server: "not a url").resolvedName == "Stalker portal")
    }

    @Test func advancedValuesOpenTheSection() {
        var draft = stalker()
        #expect(!draft.hasAdvancedValues)
        draft.model = "   "
        #expect(!draft.hasAdvancedValues)
        draft.model = "MAG322"
        #expect(draft.hasAdvancedValues)

        var withLogin = stalker()
        withLogin.username = "demo-user"
        #expect(withLogin.hasAdvancedValues)
    }

    // MARK: Output

    @Test func stalkerConfigurationTrimsAndNormalises() {
        var draft = stalker(server: "  portal.example.com/c/ ", mac: "00-1a-79-12-34-56")
        draft.name = "Portal"
        draft.username = " demo-user "
        draft.password = " pass with spaces "
        draft.serialNumber = " SN123 "
        draft.deviceID = " DEV1 "
        draft.deviceID2 = " DEV2 "
        draft.signature = " SIG "
        draft.model = " MAG322 "
        draft.timeZone = " Europe/London "
        // Left over from another kind: not saved with a portal.
        draft.playlistURL = "https://lists.example.com/list.m3u"
        draft.guideURL = "https://guide.example.com/epg.xml"

        let configuration = draft.configuration(id: id)
        #expect(configuration == SourceConfiguration(
            id: id, name: "Portal", kind: .stalker,
            serverURL: "portal.example.com/c/", macAddress: "00:1A:79:12:34:56",
            username: "demo-user", password: " pass with spaces ",
            serialNumber: "SN123", deviceID: "DEV1", deviceID2: "DEV2", signature: "SIG",
            model: "MAG322", timeZone: "Europe/London"
        ))
    }

    @Test func switchingKindLeavesNoStrayLoginBehind() {
        var draft = stalker()
        draft.deviceID = "DEV1"
        draft.username = "portal-user"
        draft.password = "portal-pass"
        draft.changeKind(to: .m3u)
        draft.playlistURL = "https://lists.example.com/list.m3u"
        draft.guideURL = " https://guide.example.com/epg.xml "

        let configuration = draft.configuration(id: id)
        #expect(configuration.kind == .m3u)
        #expect(configuration.playlistURL == "https://lists.example.com/list.m3u")
        #expect(configuration.guideURL == "https://guide.example.com/epg.xml")
        #expect(configuration.serverURL.isEmpty)
        #expect(configuration.macAddress.isEmpty)
        #expect(configuration.username.isEmpty)
        #expect(configuration.password.isEmpty)
        #expect(configuration.deviceID.isEmpty)
    }

    @Test func xtreamConfigurationKeepsOnlyItsFields() {
        var draft = xtream(server: " http://xtream.example.com:8080 ", username: " demo-user ", password: " p ")
        draft.guideURL = "https://guide.example.com/epg.xml"
        draft.macAddress = "00:1A:79:12:34:56"
        draft.timeZone = "Europe/London"
        let configuration = draft.configuration(id: id)
        #expect(configuration.serverURL == "http://xtream.example.com:8080")
        #expect(configuration.username == "demo-user")
        #expect(configuration.password == " p ")
        #expect(configuration.guideURL == "https://guide.example.com/epg.xml")
        #expect(configuration.macAddress.isEmpty)
        #expect(configuration.timeZone.isEmpty)
        #expect(configuration.name == "xtream.example.com")
    }

    // MARK: From a saved record

    @Test func editingASavedRecord() {
        let record = SourceRecord(
            id: id, name: "Provider B", kindRaw: "stalker", serverURL: "http://portal.example.com/c/",
            maxStreams: -2,
            credentials: SourceCredentials(macAddress: "001a79123456", deviceID: "DEV1", timeZone: "Europe/London")
        )
        let draft = SourceDraft(record: record)
        #expect(draft.kind == .stalker)
        #expect(draft.name == "Provider B")
        #expect(draft.macAddress == "00:1A:79:12:34:56")
        #expect(draft.deviceID == "DEV1")
        #expect(draft.maxStreams == 0) // never negative
        #expect(draft.hasAdvancedValues)

        // A kind this build doesn't know opens as a playlist; a bad MAC as typed.
        let unknown = SourceDraft(record: SourceRecord(name: "Future", kindRaw: "hologram", credentials: SourceCredentials(macAddress: "garbled")))
        #expect(unknown.kind == .m3u)
        #expect(unknown.macAddress == "garbled")
    }
}

/// `SourceURLCheck`: loose checks on typed addresses.
@Suite struct SourceURLCheckTests {
    @Test func schemelessAddressesAreTakenAsHTTPOnlyWhenAllowed() {
        #expect(SourceURLCheck.url(from: "portal.example.com/c/", allowingSchemeless: true)?.absoluteString == "http://portal.example.com/c/")
        #expect(SourceURLCheck.url(from: " https://portal.example.com/c/ ", allowingSchemeless: true)?.absoluteString == "https://portal.example.com/c/")
        #expect(SourceURLCheck.isWebAddress("portal.example.com", allowingSchemeless: true))
        #expect(!SourceURLCheck.isWebAddress("portal.example.com", allowingSchemeless: false))
    }

    @Test func spacesAndEmptyAreNoAddress() {
        #expect(SourceURLCheck.url(from: "", allowingSchemeless: true) == nil)
        #expect(SourceURLCheck.url(from: "   ", allowingSchemeless: true) == nil)
        #expect(SourceURLCheck.url(from: "http://portal example.com", allowingSchemeless: true) == nil)
    }

    @Test func onlyWebSchemesWithAHost() {
        #expect(SourceURLCheck.isWebAddress("http://portal.example.com", allowingSchemeless: false))
        #expect(SourceURLCheck.isWebAddress("HTTPS://portal.example.com", allowingSchemeless: false))
        // The demo provider (`-StubProvider YES`).
        #expect(SourceURLCheck.isWebAddress("stub://demo", allowingSchemeless: false))
        #expect(!SourceURLCheck.isWebAddress("ftp://portal.example.com", allowingSchemeless: false))
        #expect(!SourceURLCheck.isWebAddress("http://", allowingSchemeless: false))
        #expect(!SourceURLCheck.isWebAddress("file:///Users/someone/list.m3u", allowingSchemeless: false))
    }

    @Test func playlistsMayBeFiles() {
        #expect(SourceURLCheck.isPlaylistAddress("file:///Users/someone/list.m3u"))
        #expect(SourceURLCheck.isPlaylistAddress("https://lists.example.com/list.m3u8"))
        #expect(!SourceURLCheck.isPlaylistAddress("lists.example.com/list.m3u"))
        #expect(!SourceURLCheck.isPlaylistAddress("ftp://lists.example.com/list.m3u"))
    }
}

/// `PlaylistFile.resolved`: a picked playlist's copy survives iOS moving the
/// app's container.
@Suite struct PlaylistFileTests {
    @Test func aStaleCopyIsReRootedAtTodaysFolder() {
        let stale = "file:///var/mobile/Containers/Data/Application/OLD-CONTAINER/Library/Application%20Support/Playlists/ABC.m3u"
        let resolved = PlaylistFile.resolved(stale)
        #expect(resolved == PlaylistFile.directory.appending(path: "ABC.m3u").absoluteString)
        #expect(!resolved.contains("OLD-CONTAINER"))
        // Already where it belongs: unchanged.
        #expect(PlaylistFile.resolved(resolved) == resolved)
    }

    @Test func webLinksAndOtherFilesStayAsTheyAre() {
        #expect(PlaylistFile.resolved("https://lists.example.com/Playlists/ABC.m3u") == "https://lists.example.com/Playlists/ABC.m3u")
        #expect(PlaylistFile.resolved("file:///Users/someone/Downloads/ABC.m3u") == "file:///Users/someone/Downloads/ABC.m3u")
        #expect(PlaylistFile.resolved("") == "")
    }
}
