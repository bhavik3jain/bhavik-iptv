import Foundation
import Synchronization
import Testing
@testable import SourceKit

/// `-SourceProbe`: every step reported with its timing, and nothing printed
/// that carries a login, a MAC or a token (SRC-4, PRIV-2).
@Suite struct SourceProbeTests {
    final class Lines: Sendable {
        private let lines = Mutex<[String]>([])
        func append(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    @Test func walksTheStubThroughEveryStep() async {
        let lines = Lines()
        await SourceProbe.run(client: StubSourceClient(configuration: .stub(), latency: .zero)) { lines.append($0) }
        let text = lines.all.joined(separator: "\n")
        for step in ["Sign in", "Account", "Categories (live)", "Categories (vod)", "Categories (series)", "Channels", "Movies (page 0)", "Series (page 0)", "Live link", "Short guide"] {
            #expect(text.contains("✓ \(step) — "), "missing step \(step)")
        }
        #expect(text.contains(" ms"))
        #expect(text.contains("Done in"))
        #expect(!text.contains("00:1A:79:00:00:01"))
        #expect(text.contains("00:1A:79:••:••:01"))
    }

    @Test func aStalkerProbeMasksTheMACAndTheToken() async {
        let portal = StalkerClientTests.Portal { action, _, _ in
            switch action {
            case "get_genres": return .fixture("stalker/genres.json")
            case "get_all_channels": return .fixture("stalker/channels_data.json")
            case "create_link": return .fixture("stalker/create_link_ffmpeg.json")
            case "get_short_epg": return .fixture("stalker/short_epg_timestamps.json")
            default: return nil
            }
        }
        let configuration = SourceConfiguration(
            name: "Portal", kind: .stalker, serverURL: "http://\(portal.host)/stalker_portal/c/",
            macAddress: StalkerClientTests.mac, username: "demo-user", password: "demo-pass", timeZone: "Europe/London"
        )
        let lines = Lines()
        await SourceProbe.run(configuration, session: portal.session) { lines.append($0) }
        let text = lines.all.joined(separator: "\n")
        // do_auth answers `{"js":[]}` here, which isn't a yes.
        #expect(text.contains("✗ Sign in"))
        #expect(text.contains("Stopped: sign-in failed."))
        #expect(!text.contains(StalkerClientTests.mac))
        #expect(!text.contains("demo-pass"))
        #expect(!text.contains("demo-user"))
    }

    @Test func aStalkerProbeThatSignsIn() async {
        let portal = StalkerClientTests.Portal { action, _, _ in
            switch action {
            case "get_all_channels": return .fixture("stalker/channels_data.json")
            case "create_link": return .fixture("stalker/create_link_ffmpeg.json")
            case "get_short_epg": return .fixture("stalker/short_epg_timestamps.json")
            default: return nil
            }
        }
        let lines = Lines()
        await SourceProbe.run(
            SourceConfiguration(name: "Portal", kind: .stalker, serverURL: "http://\(portal.host)/stalker_portal/c/", macAddress: StalkerClientTests.mac),
            session: portal.session
        ) { lines.append($0) }
        let text = lines.all.joined(separator: "\n")
        #expect(text.contains("✓ Sign in"))
        #expect(text.contains("3 channels, 2 with archive"))
        #expect(text.contains("✓ Live link"))
        #expect(text.contains("2 programmes"))
        // The live link's query holds the MAC and a play token: only the host is printed.
        #expect(text.contains("http://cdn.portal.test/•••"))
        #expect(!text.contains("Zq81Lm"))
        #expect(!text.contains(StalkerClientTests.token))
        #expect(!text.contains(StalkerClientTests.mac))
    }
}

/// PRIV-2's masking helpers.
@Suite struct RedactionScrubTests {
    let configuration = SourceConfiguration(
        name: "P", kind: .xtream, serverURL: "http://x.test", macAddress: "00:1A:79:AB:CD:41",
        username: "demo-user", password: "demo-user-pass", playlistURL: "http://p.test/get.php?username=demo-user&password=demo-user-pass",
        serialNumber: "SN0001", deviceID: "DEVICEIDVALUE"
    )

    @Test func macInEverySpelling() {
        for spelling in ["00:1A:79:AB:CD:41", "00-1a-79-ab-cd-41", "001A79ABCD41", "00%3A1A%3A79%3AAB%3ACD%3A41"] {
            let scrubbed = Redaction.scrub("mac=\(spelling);", for: configuration)
            #expect(scrubbed == "mac=00:1A:79:••:••:41;", "\(spelling) → \(scrubbed)")
        }
    }

    @Test func secretsAndPlaylistURL() {
        let text = "user demo-user pass demo-user-pass serial SN0001 device DEVICEIDVALUE at http://p.test/get.php?username=demo-user&password=demo-user-pass"
        let scrubbed = Redaction.scrub(text, for: configuration)
        #expect(!scrubbed.contains("demo-user"))
        #expect(!scrubbed.contains("SN0001"))
        #expect(!scrubbed.contains("DEVICEIDVALUE"))
        #expect(scrubbed.contains("http://p.test/•••"))
    }

    @Test func redactedConfigurationMasksEverything() {
        let safe = configuration.redacted
        #expect(safe.macAddress == "00:1A:79:••:••:41")
        #expect(safe.serialNumber == "•••")
        #expect(safe.deviceID == "•••")
        #expect(safe.deviceID2 == "")
        #expect(safe.playlistURL == "http://p.test/•••")
        #expect(Redaction.mac("garbage") == "•••")
        #expect(Redaction.secret("") == "")
    }
}

/// Which engine a link picks: from the extension or the provider's query.
@Suite struct FormatHintTests {
    @Test func guessesFromURLs() {
        #expect(StreamFormatHint.guess(fromURL: "http://a.test/live/1.m3u8?token=x") == .hls)
        #expect(StreamFormatHint.guess(fromURL: "http://a.test/play/live.php?stream=1&extension=ts") == .mpegts)
        #expect(StreamFormatHint.guess(fromURL: "http://a.test/live/u/p/1.ts") == .mpegts)
        #expect(StreamFormatHint.guess(fromURL: "http://a.test/movie/u/p/1.mp4") == .mp4)
        #expect(StreamFormatHint.guess(fromURL: "http://a.test/movie/u/p/1.mkv") == .mkv)
        #expect(StreamFormatHint.guess(fromURL: "http://a.test/ch/1001_") == .unknown)
        #expect(StreamFormatHint.guess(fromURL: "http://a.test/flussonic/mpegts") == .mpegts)
        #expect(StreamFormatHint.fromExtension(".MKV") == .mkv)
        #expect(StreamFormatHint.fromExtension(nil) == .unknown)
    }
}
