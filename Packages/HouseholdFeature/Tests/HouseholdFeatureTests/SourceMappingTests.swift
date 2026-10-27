import Core
import Foundation
import HouseholdKit
import SourceKit
import Testing
@testable import HouseholdFeature

/// `SourceMapping`: the household's records and SourceKit's configurations
/// are the same login in two shapes (SRC-1…SRC-3, SRC-9).
@Suite struct SourceMappingTests {
    let id = UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000002")!

    var stalkerRecord: SourceRecord {
        SourceRecord(
            id: id, name: "Provider B", kindRaw: "stalker", serverURL: "http://portal.example.com/c/",
            sortOrder: 3, isRemoved: false, maxStreams: 2, expiresAt: utc(2027, 3, 12),
            credentials: SourceCredentials(
                macAddress: "00:1A:79:12:34:56", username: "demo-user", password: "demo-pass",
                serialNumber: "SN123", deviceID: "DEV1", deviceID2: "DEV2", signature: "SIG",
                model: "MAG322", timeZone: "Europe/London"
            )
        )
    }

    @Test func kinds() {
        #expect(SourceMapping.kind(of: SourceRecord(name: "", kindRaw: "stalker")) == .stalker)
        #expect(SourceMapping.kind(of: SourceRecord(name: "", kindRaw: "xtream")) == .xtream)
        #expect(SourceMapping.kind(of: SourceRecord(name: "", kindRaw: "m3u")) == .m3u)
        #expect(SourceMapping.kind(of: SourceRecord(name: "", kindRaw: "Stalker")) == nil)
        #expect(SourceMapping.kind(of: SourceRecord(name: "", kindRaw: "")) == nil)
    }

    @Test func aRecordBecomesTheConfigurationItSignsInWith() {
        let configuration = SourceMapping.configuration(from: stalkerRecord)
        #expect(configuration == SourceConfiguration(
            id: id, name: "Provider B", kind: .stalker,
            serverURL: "http://portal.example.com/c/", macAddress: "00:1A:79:12:34:56",
            username: "demo-user", password: "demo-pass",
            serialNumber: "SN123", deviceID: "DEV1", deviceID2: "DEV2", signature: "SIG",
            model: "MAG322", timeZone: "Europe/London"
        ))
    }

    @Test func mappingTrimsEverythingButThePassword() {
        let record = SourceRecord(
            name: "P", kindRaw: "stalker", serverURL: "  http://portal.example.com/c/\n",
            credentials: SourceCredentials(macAddress: "00-1a-79-12-34-56", username: " u ", password: " p ", deviceID: " D ", timeZone: " Europe/London ")
        )
        let configuration = SourceMapping.configuration(from: record)
        #expect(configuration.serverURL == "http://portal.example.com/c/")
        #expect(configuration.macAddress == "00:1A:79:12:34:56")
        #expect(configuration.username == "u")
        #expect(configuration.password == " p ")
        #expect(configuration.deviceID == "D")
        #expect(configuration.timeZone == "Europe/London")
        // A MAC that can't be normalised goes as typed (trimmed): SourceKit refuses it.
        let garbled = SourceRecord(name: "P", kindRaw: "stalker", credentials: SourceCredentials(macAddress: " zz "))
        #expect(SourceMapping.configuration(from: garbled).macAddress == "zz")
    }

    @Test func anUnknownKindSendsNoAddressAnywhere() {
        let record = SourceRecord(
            id: id, name: "From a newer build", kindRaw: "hologram", serverURL: "http://portal.example.com/c/",
            credentials: SourceCredentials(username: "u", password: "p", playlistURL: "https://lists.example.com/list.m3u")
        )
        let configuration = SourceMapping.configuration(from: record)
        #expect(configuration.kind == .m3u)
        #expect(configuration.serverURL.isEmpty)
        #expect(configuration.playlistURL.isEmpty)
    }

    @Test func configurationsSkipRemovedAndUnknownAndFollowTheOrder() {
        let a = SourceRecord(name: "A", kindRaw: "m3u", sortOrder: 2)
        let b = SourceRecord(name: "B", kindRaw: "stalker", sortOrder: 0)
        let removed = SourceRecord(name: "Removed", kindRaw: "xtream", sortOrder: 1, isRemoved: true)
        let unknown = SourceRecord(name: "Unknown", kindRaw: "hologram", sortOrder: 1)
        let c = SourceRecord(name: "C", kindRaw: "xtream", sortOrder: 1)
        #expect(SourceMapping.configurations(from: [a, b, removed, unknown, c]).map(\.name) == ["B", "C", "A"])
        #expect(SourceMapping.configurations(from: []).isEmpty)
    }

    @Test func recordToConfigurationAndBackIsLossless() {
        let record = stalkerRecord
        let configuration = SourceMapping.configuration(from: record)
        #expect(SourceMapping.record(from: configuration, base: record) == record)
        // And the other way round.
        #expect(SourceMapping.configuration(from: SourceMapping.record(from: configuration)) == configuration)
    }

    @Test func roundTripsForEveryKind() {
        let configurations = [
            SourceConfiguration(id: UUID(), name: "Xtream", kind: .xtream, serverURL: "http://xtream.example.com:8080", username: "u", password: "p", guideURL: "https://guide.example.com/epg.xml"),
            SourceConfiguration(id: UUID(), name: "Playlist", kind: .m3u, playlistURL: "https://lists.example.com/list.m3u", guideURL: "https://guide.example.com/epg.xml"),
            SourceConfiguration(id: UUID(), name: "Portal", kind: .stalker, serverURL: "portal.example.com/c/", macAddress: "00:1A:79:AB:CD:EF"),
        ]
        for configuration in configurations {
            let record = SourceMapping.record(from: configuration)
            #expect(record.kindRaw == configuration.kind.rawValue)
            #expect(SourceMapping.configuration(from: record) == configuration)
        }
    }

    @Test func aNewRecordTakesTheKindsDefaultsAndAnEditKeepsTheHouseholdsFields() {
        let configuration = SourceMapping.configuration(from: stalkerRecord)

        let fresh = SourceMapping.record(from: SourceConfiguration(name: "New", kind: .m3u, playlistURL: "https://lists.example.com/list.m3u"))
        #expect(fresh.sortOrder == 0)
        #expect(!fresh.isRemoved)
        #expect(fresh.maxStreams == 0)
        #expect(fresh.expiresAt == nil)
        #expect(SourceMapping.record(from: configuration).maxStreams == 1)

        // Order, removal, limit and expiry are the household's, kept from the base.
        var base = stalkerRecord
        base.isRemoved = true
        let edited = SourceMapping.record(from: configuration, base: base)
        #expect(edited.sortOrder == 3)
        #expect(edited.isRemoved)
        #expect(edited.maxStreams == 2)
        #expect(edited.expiresAt == utc(2027, 3, 12))

        // Explicit values beat the base.
        let overridden = SourceMapping.record(from: configuration, base: base, maxStreams: 4, expiresAt: utc(2028, 1, 1))
        #expect(overridden.maxStreams == 4)
        #expect(overridden.expiresAt == utc(2028, 1, 1))
    }

    @Test func onlyAConnectionChangeNeedsAFreshCatalog() {
        let old = SourceMapping.configuration(from: stalkerRecord)
        #expect(SourceMapping.connectionChanged(nil, old))
        #expect(!SourceMapping.connectionChanged(old, old))

        var renamed = old
        renamed.name = "Living Room"
        #expect(!SourceMapping.connectionChanged(old, renamed))

        var newMAC = old
        newMAC.macAddress = "00:1A:79:65:43:21"
        #expect(SourceMapping.connectionChanged(old, newMAC))

        var newServer = renamed
        newServer.serverURL = "http://other.example.com/c/"
        #expect(SourceMapping.connectionChanged(old, newServer))
    }
}

/// `StreamLimit` and `SourceStreamRow`: how many streams a source allows and
/// how many are taken (HH-5, HH-6).
@Suite struct StreamLimitTests {
    func record(_ kind: String, maxStreams: Int) -> SourceRecord {
        SourceRecord(name: kind, kindRaw: kind, maxStreams: maxStreams)
    }

    @Test func defaults() {
        #expect(StreamLimit.defaultMaxStreams(for: .stalker) == 1)
        #expect(StreamLimit.defaultMaxStreams(for: .xtream) == 1)
        #expect(StreamLimit.defaultMaxStreams(for: .m3u) == 0)
    }

    @Test func theOwnersSettingForPortalsAndPlaylists() {
        #expect(StreamLimit.limit(for: record("stalker", maxStreams: 2), account: nil) == 2)
        #expect(StreamLimit.limit(for: record("m3u", maxStreams: 0), account: nil) == nil) // unlimited
        // A portal's account never says (maxConnections is Xtream's).
        #expect(StreamLimit.limit(for: record("stalker", maxStreams: 1), account: AccountInfo(maxConnections: 5)) == 1)
    }

    @Test func xtreamReportsItsOwn() {
        let xtream = record("xtream", maxStreams: 3)
        #expect(StreamLimit.limit(for: xtream, account: AccountInfo(maxConnections: 2)) == 2)
        // Not known yet, or nonsense: no limit shown, whatever the record says.
        #expect(StreamLimit.limit(for: xtream, account: nil) == nil)
        #expect(StreamLimit.limit(for: xtream, account: AccountInfo(maxConnections: 0)) == nil)
    }

    @Test func inUseNeverFallsBelowTheHouseholdsOwnRows() {
        let xtream = record("xtream", maxStreams: 1)
        #expect(StreamLimit.inUse(for: xtream, account: AccountInfo(activeConnections: 3), playbacks: 1) == 3)
        #expect(StreamLimit.inUse(for: xtream, account: AccountInfo(activeConnections: 0), playbacks: 2) == 2)
        #expect(StreamLimit.inUse(for: xtream, account: nil, playbacks: 1) == 1)
        #expect(StreamLimit.inUse(for: record("stalker", maxStreams: 1), account: AccountInfo(activeConnections: 4), playbacks: 1) == 1)
    }

    @Test func rowsKeepFreshPlaybacksOfTheirOwnSourceOldestFirst() {
        let portal = SourceRecord(name: "Portal", kindRaw: "stalker", maxStreams: 2)
        let xtream = SourceRecord(name: "Xtream", kindRaw: "xtream")
        let profile = UUID()
        func playback(_ title: String, on source: SourceRecord, startedAgo: TimeInterval, seenAgo: TimeInterval) -> PlaybackRecord {
            PlaybackRecord(deviceName: "iPad", profileID: profile, sourceID: source.id, itemKey: title, title: title,
                           startedAt: referenceNow - startedAgo, lastSeenAt: referenceNow - seenAgo)
        }
        let playbacks = [
            playback("Later", on: portal, startedAgo: 5 * minute, seenAgo: minute),
            playback("Earlier", on: portal, startedAgo: hour, seenAgo: 2 * minute),
            // Unseen for longer than 15 minutes: the device went quiet.
            playback("Stale", on: portal, startedAgo: 2 * hour, seenAgo: 16 * minute),
            playback("Elsewhere", on: xtream, startedAgo: minute, seenAgo: 0),
        ]
        let rows = SourceStreamRow.rows(
            sources: [portal, xtream], playbacks: playbacks,
            account: { $0 == xtream.id ? AccountInfo(maxConnections: 4, activeConnections: 3) : nil },
            now: referenceNow
        )
        #expect(rows.map(\.name) == ["Portal", "Xtream"])
        #expect(rows[0].playbacks.map(\.title) == ["Earlier", "Later"])
        #expect(rows[0].usage == StreamBarUsage(inUse: 2, limit: 2))
        #expect(rows[1].playbacks.map(\.title) == ["Elsewhere"])
        #expect(rows[1].usage == StreamBarUsage(inUse: 3, limit: 4))
    }
}
