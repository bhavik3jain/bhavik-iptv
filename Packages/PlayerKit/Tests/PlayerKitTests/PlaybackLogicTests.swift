import Core
import Foundation
import Testing
@testable import PlayerKit

// The player's arithmetic as plain values: checkpoints, live offset, the
// scrub bar, wording, messages, seeking behind live, engine plans, languages.

@Suite("CheckpointClock")
struct CheckpointClockTests {
    @Test func dueEveryFiveMinutesOfPlaying() {
        var clock = CheckpointClock(interval: 300, maximumStep: 2)
        for _ in 0..<299 {
            let due = clock.advance(by: 1, isPlaying: true)
            #expect(!due)
        }
        let fiveMinutes = clock.advance(by: 1, isPlaying: true)
        #expect(fiveMinutes)
        #expect(clock.accumulated == 0)
        let oneMore = clock.advance(by: 1, isPlaying: true)
        #expect(!oneMore)
    }

    @Test func pausedAndBufferingTimeDoesNotCount() {
        var clock = CheckpointClock(interval: 300, maximumStep: 2)
        for _ in 0..<1000 {
            let due = clock.advance(by: 1, isPlaying: false)
            #expect(!due)
        }
        #expect(clock.accumulated == 0)
    }

    @Test func aLateTickCountsAsOneStepNotMinutes() {
        var clock = CheckpointClock(interval: 300, maximumStep: 2)
        let due = clock.advance(by: 3600, isPlaying: true)
        #expect(!due, "a suspended process doesn't fake an hour of watching")
        #expect(clock.accumulated == 2)
    }

    @Test func resetStartsAgain() {
        var clock = CheckpointClock(interval: 300, maximumStep: 2)
        for _ in 0..<200 { _ = clock.advance(by: 1, isPlaying: true) }
        clock.reset()
        #expect(clock.accumulated == 0)
        for _ in 0..<299 {
            let due = clock.advance(by: 1, isPlaying: true)
            #expect(!due)
        }
    }
}

@Suite("LiveClock")
struct LiveClockTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func windowedLiveReadsZeroAtTheEdgeAvPlayerKeeps() {
        var clock = LiveClock()
        clock.captureEdge(currentTime: 50, duration: 60)
        #expect(clock.edgeSlack == 10)
        #expect(clock.offset(currentTime: 50, duration: 60, now: now) == 0)
        #expect(clock.offset(currentTime: 20, duration: 60, now: now) == 30)
        // The window slides; the edge stays ten seconds before its end.
        #expect(clock.offset(currentTime: 55, duration: 65, now: now) == 0)
    }

    @Test func edgeIsCapturedOnce() {
        var clock = LiveClock()
        clock.captureEdge(currentTime: 50, duration: 60)
        clock.captureEdge(currentTime: 10, duration: 60)
        #expect(clock.edgeSlack == 10)
    }

    @Test func windowlessLiveFallsBehindOnlyByPausing() {
        var clock = LiveClock()
        #expect(clock.offset(currentTime: 900, duration: nil, now: now) == 0)
        clock.paused(at: now)
        #expect(clock.offset(currentTime: 900, duration: nil, now: now.addingTimeInterval(252)) == 252)
        clock.resumed(at: now.addingTimeInterval(252))
        #expect(clock.offset(currentTime: 900, duration: nil, now: now.addingTimeInterval(400)) == 252)
        clock.paused(at: now.addingTimeInterval(400))
        #expect(clock.offset(currentTime: 900, duration: nil, now: now.addingTimeInterval(410)) == 262)
        clock.returnedToLive()
        #expect(clock.offset(currentTime: 900, duration: nil, now: now.addingTimeInterval(420)) == 0)
    }

    @Test func archiveIsMeasuredFromItsStart() {
        let clock = LiveClock(anchor: .archive(start: now.addingTimeInterval(-600)))
        #expect(clock.offset(currentTime: 100, duration: 3600, now: now) == 500)
        #expect(clock.offset(currentTime: 700, duration: 3600, now: now) == 0, "never negative")
    }
}

@Suite("PlaybackTimeline")
struct PlaybackTimelineTests {
    // 19:30 – 22:30 in UTC terms; labels are compared through HearthFormat so
    // the test doesn't depend on the machine's time zone or locale.
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var end: Date { start.addingTimeInterval(3 * 3600) }
    var now: Date { start.addingTimeInterval(7920) }

    @Test func liveSpansTheProgrammeWithTheEdgeAtNow() {
        let timeline = PlaybackTimeline.make(isLive: true, programmeStart: start, programmeEnd: end, now: now, liveOffset: 252, currentTime: 0, duration: nil)
        #expect(timeline.kind == .live(start: start, end: end))
        #expect(abs((timeline.liveEdge ?? 0) - 7920.0 / 10800) < 1e-9)
        #expect(abs(timeline.position - (7920.0 - 252) / 10800) < 1e-9)
        #expect(timeline.leadingLabel == HearthFormat.clock(start))
        #expect(timeline.trailingLabel == HearthFormat.clock(end))
        #expect(timeline.positionLabel == HearthFormat.clock(now.addingTimeInterval(-252)))
        #expect(timeline.showsBar)
    }

    @Test func liveDragsBecomeSecondsBehindLiveAndStopAtNow() {
        let timeline = PlaybackTimeline.make(isLive: true, programmeStart: start, programmeEnd: end, now: now, liveOffset: 0, currentTime: 0, duration: nil)
        #expect(timeline.seekTarget(forFraction: 0.5) == .behindLive(7920 - 5400))
        #expect(timeline.seekTarget(forFraction: 0) == .behindLive(7920))
        #expect(timeline.seekTarget(forFraction: 0.95) == .behindLive(0))
    }

    @Test func liveWithoutAGuideHasNoBar() {
        let timeline = PlaybackTimeline.make(isLive: true, programmeStart: nil, programmeEnd: nil, now: now, liveOffset: 0, currentTime: 0, duration: nil)
        #expect(!timeline.showsBar)
        #expect(timeline.seekTarget(forFraction: 0.5) == nil)
    }

    @Test func onDemandIsPositionOverDuration() {
        let timeline = PlaybackTimeline.make(isLive: false, programmeStart: nil, programmeEnd: nil, now: now, liveOffset: 0, currentTime: 600, duration: 3600)
        #expect(timeline.kind == .onDemand(duration: 3600))
        #expect(abs(timeline.position - 1.0 / 6) < 1e-9)
        #expect(timeline.liveEdge == nil)
        #expect(timeline.leadingLabel == "10:00")
        #expect(timeline.trailingLabel == "1:00:00")
        #expect(timeline.seekTarget(forFraction: 0.25) == .position(900))
        #expect(timeline.seekTarget(forFraction: 2) == .position(3600), "clamped")
    }

    @Test func onDemandBeforeTheDurationIsKnown() {
        let timeline = PlaybackTimeline.make(isLive: false, programmeStart: nil, programmeEnd: nil, now: now, liveOffset: 0, currentTime: 12, duration: nil)
        #expect(timeline.kind == .unknown)
        #expect(!timeline.showsBar)
        #expect(timeline.leadingLabel == "0:12")
    }
}

@Suite("Wording")
struct PlayerFormatTests {
    @Test func offsetBadgeUsesATrueMinus() {
        #expect(PlayerFormat.behindLive(252) == "\u{2212}4:12")
        #expect(PlayerFormat.behindLive(3725) == "\u{2212}1:02:05")
        #expect(PlayerFormat.behindLive(0) == "\u{2212}0:00")
    }

    @Test func liveCaption() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PlayerFormat.liveCaption(isPaused: true, catchUpFrom: start) == "Paused live · catch-up from \(HearthFormat.clock(start))")
        #expect(PlayerFormat.liveCaption(isPaused: false, catchUpFrom: nil) == "Behind live")
    }

    @Test func itemLabels() {
        let resolver = ScriptedResolver(Streams.hls)
        #expect(PlayerFormat.itemLabel(channel(101, "Cityline News", resolver: resolver)) == "101 Cityline News")
        #expect(PlayerFormat.itemLabel(movie(resolver: resolver)) == "The Lighthouse")
    }
}

@Suite("PlayerMessage")
struct PlayerMessageTests {
    @Test func streamAddressesNeverReachTheMessage() {
        let message = PlayerMessage.scrub("Failed to open http://portal.test/play/live.php?mac=00:1A:79:12:34:56&stream=102&token=abc (403)")
        #expect(!message.contains("mac="))
        #expect(!message.contains("token"))
        #expect(!message.contains("http"))
        #expect(message.contains("(403)"))
    }

    @Test func describeUsesTheProvidersWords() {
        #expect(PlayerMessage.describe(ProviderError(message: "Your subscription has expired.")) == "Your subscription has expired.")
        #expect(PlayerMessage.scrub("   ") == PlayerMessage.genericFailure)
    }

    @Test func finalMessagePrefersTheProvidersWords() {
        #expect(PlayerMessage.final(first: "HTTP 403: Forbidden", last: PlayerMessage.vlcCouldNotOpen, vlcMissing: false) == "HTTP 403: Forbidden")
        #expect(PlayerMessage.final(first: PlayerMessage.didNotStart, last: "Stream not found", vlcMissing: false) == "Stream not found")
        #expect(PlayerMessage.final(first: PlayerMessage.didNotStart, last: PlayerMessage.vlcCouldNotOpen, vlcMissing: false) == PlayerMessage.vlcCouldNotOpen)
        #expect(PlayerMessage.final(first: "HTTP 403", last: "Cannot Open", vlcMissing: true) == PlayerMessage.vlcMissing)
    }
}

@Suite("LiveSeekPlan")
struct LiveSeekPlanTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func nearLiveIsLive() {
        #expect(LiveSeekPlan.plan(behindLive: 2, anchor: .live, currentTime: 0, duration: 60, edgeSlack: 10, now: now, hasArchive: true, programmeEnd: nil) == .live)
    }

    @Test func withinTheWindowIsASeek() {
        #expect(LiveSeekPlan.plan(behindLive: 30, anchor: .live, currentTime: 50, duration: 60, edgeSlack: 10, now: now, hasArchive: false, programmeEnd: nil) == .seek(20))
    }

    @Test func pastTheWindowOpensTheArchiveOrCannot() {
        let end = now.addingTimeInterval(1200)
        #expect(LiveSeekPlan.plan(behindLive: 600, anchor: .live, currentTime: 50, duration: 60, edgeSlack: 10, now: now, hasArchive: false, programmeEnd: end) == .unavailable)
        #expect(LiveSeekPlan.plan(behindLive: 600, anchor: .live, currentTime: 50, duration: 60, edgeSlack: 10, now: now, hasArchive: true, programmeEnd: end)
            == .archive(start: now.addingTimeInterval(-600), duration: 1800))
    }

    @Test func insideAnOpenArchiveIsASeek() {
        let anchor = LiveClock.Anchor.archive(start: now.addingTimeInterval(-1800))
        #expect(LiveSeekPlan.plan(behindLive: 600, anchor: anchor, currentTime: 0, duration: 3600, edgeSlack: nil, now: now, hasArchive: true, programmeEnd: nil) == .seek(1200))
    }
}

@Suite("EnginePlan")
struct EnginePlanTests {
    @Test func firstAttemptUsesTheChoiceWhenAvailable() {
        #expect(EnginePlan.first(preferred: .vlc, available: [.avPlayer, .vlc]) == .vlc)
        #expect(EnginePlan.first(preferred: .vlc, available: [.avPlayer]) == .avPlayer)
        #expect(EnginePlan.first(preferred: .avPlayer, available: []) == nil)
    }

    @Test func retryMovesAVPlayerToVLC() {
        #expect(EnginePlan.retry(after: .avPlayer, preferred: .avPlayer, available: [.avPlayer, .vlc]) == .vlc)
        #expect(EnginePlan.retry(after: .vlc, preferred: .vlc, available: [.avPlayer, .vlc]) == .vlc)
        #expect(EnginePlan.retry(after: .avPlayer, preferred: .vlc, available: [.avPlayer]) == .avPlayer)
        #expect(EnginePlan.retry(after: nil, preferred: .vlc, available: [.avPlayer, .vlc]) == .vlc)
    }
}

@Suite("LanguageMatch")
struct LanguageMatchTests {
    @Test(arguments: [
        ("en", "en"), ("eng", "en"), ("en-GB", "en"), ("English", "en"),
        ("deu", "de"), ("Deutsch", "de"), ("fr_CA", "fr"), ("hin", "hi"),
    ])
    func normalisesCodesAndNames(input: String, expected: String) {
        #expect(LanguageMatch.normalized(input) == expected)
    }

    @Test func emptyIsNoPreference() {
        #expect(LanguageMatch.normalized(nil) == nil)
        #expect(LanguageMatch.normalized("  ") == nil)
        #expect(LanguageMatch.bestTrack(in: [MediaTrack(id: "a", kind: .audio, name: "English", language: "en")], preferred: nil) == nil)
    }

    @Test func tagBeatsName() {
        let tracks = [
            MediaTrack(id: "a0", kind: .audio, name: "French", language: nil),
            MediaTrack(id: "a1", kind: .audio, name: "Stereo", language: "fra"),
        ]
        #expect(LanguageMatch.bestTrack(in: tracks, preferred: "fr")?.id == "a1")
    }

    @Test func nameMatchesWhenUntagged() {
        let tracks = [
            MediaTrack(id: "a0", kind: .audio, name: "Track 1", language: nil),
            MediaTrack(id: "a1", kind: .audio, name: "Deutsch (AC3)", language: nil),
        ]
        #expect(LanguageMatch.bestTrack(in: tracks, preferred: "de")?.id == "a1")
        #expect(LanguageMatch.bestTrack(in: tracks, preferred: "es") == nil)
    }
}

#if canImport(VLCKit)
@Suite("VLC media options")
struct VLCMediaOptionsTests {
    @Test func headersBecomeOptionsAndOthersAreDropped() {
        let stream = StreamDescriptor(
            url: URL(string: "http://provider.test/play/live.php?stream=102&extension=ts")!,
            headers: ["User-Agent": "Mozilla/5.0 (QtEmbedded; MAG250)", "Referer": "http://portal.test/c/", "Cookie": "mac=redacted"],
            format: .mpegts,
            isLive: true
        )
        #expect(VLCEngine.mediaOptions(for: stream) == [
            ":http-referrer=http://portal.test/c/",
            ":http-user-agent=Mozilla/5.0 (QtEmbedded; MAG250)",
            ":network-caching=1500",
        ])
    }

    @Test func filesCacheLongerAndResume() {
        let stream = StreamDescriptor(url: URL(string: "http://provider.test/movie/7.mkv")!, format: .mkv, startPosition: 90.6)
        #expect(VLCEngine.mediaOptions(for: stream) == [":network-caching=3000", ":start-time=90"])
    }
}
#endif

@Suite("VLCKit acknowledgement")
struct VLCKitInfoTests {
    @Test func noticeNamesVersionLicenceAndSource() {
        #expect(VLCKitInfo.notice.contains(VLCKitInfo.version))
        #expect(VLCKitInfo.notice.contains("Lesser General Public License"))
        #expect(VLCKitInfo.notice.contains("code.videolan.org/videolan/VLCKit"))
    }

    @Test func standardFactoryOffersVLCWhenLinked() {
        let kinds = PlaybackEngineFactory.standard.availableKinds
        #expect(kinds.contains(.avPlayer))
        #expect(kinds.contains(.vlc) == VLCKitInfo.isLinked)
    }
}
