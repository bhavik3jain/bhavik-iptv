import CatalogKit
import Core
import Foundation
import HouseholdKit
import PlayerKit
import SourceKit
import Testing
@testable import Hearth

// The player's queue, resume points, link mapping and text (AppLogic.swift).

@Suite struct PlaybackQueueTests {
    @Test func channelUpAndDownWalkTheQueue() {
        let queue = PlaybackQueue(current: "b", queue: ["a", "b", "c"])
        #expect(queue.keys == ["a", "b", "c"])
        #expect(queue.key(from: "b", offset: 1) == "c")
        #expect(queue.key(from: "b", offset: -1) == "a")
        #expect(queue.key(from: "a", offset: 2) == "c")
        #expect(queue.key(from: "b", offset: 0) == "b")
    }

    /// The ends stop rather than wrap, as the pills show.
    @Test func theEndsStopRatherThanWrap() {
        let queue = PlaybackQueue(current: "a", queue: ["a", "b", "c"])
        #expect(queue.key(from: "a", offset: -1) == nil)
        #expect(queue.key(from: "c", offset: 1) == nil)
        #expect(queue.key(from: "a", offset: 3) == nil)
    }

    /// A queue without the item played (up next after an episode) gets it first.
    @Test func theCurrentItemGoesFirstWhenTheQueueLacksIt() {
        let queue = PlaybackQueue(current: "e1", queue: ["e2", "e3"])
        #expect(queue.keys == ["e1", "e2", "e3"])
        #expect(queue.key(from: "e1", offset: 1) == "e2")
        #expect(queue.key(from: "e1", offset: -1) == nil)
    }

    @Test func duplicatesKeepTheirFirstPlace() {
        let queue = PlaybackQueue(current: "b", queue: ["a", "b", "a", "c", "b"])
        #expect(queue.keys == ["a", "b", "c"])
    }

    @Test func anEmptyQueueHoldsOnlyTheCurrentItem() {
        let queue = PlaybackQueue(current: "only", queue: [])
        #expect(queue.keys == ["only"])
        #expect(queue.key(from: "only", offset: 1) == nil)
        #expect(queue.key(from: "only", offset: -1) == nil)
    }

    @Test func aKeyNotInTheQueueHasNoNeighbours() {
        let queue = PlaybackQueue(current: "a", queue: ["a", "b"])
        #expect(queue.key(from: "z", offset: 1) == nil)
    }
}

@Suite struct EpisodeOrderTests {
    let episodes = [
        makeEpisode(season: 2, number: 1),
        makeEpisode(season: 1, number: 10),
        makeEpisode(season: 1, number: 2),
        makeEpisode(season: 1, number: 1),
        makeEpisode(season: 2, number: 2),
    ]

    /// Season then number, numerically (E10 after E2, S2E1 after S1E10).
    @Test func followsInSeasonAndNumberOrder() {
        let start = ItemKey.episode(source: TestIDs.sourceA, seriesID: "office", season: 1, number: 2)
        let following = EpisodeOrder.following(start, in: episodes)
        #expect(following.map { $0.seasonAndEpisode?.season } == [1, 2, 2])
        #expect(following.map { $0.seasonAndEpisode?.number } == [10, 1, 2])
    }

    @Test func theLastEpisodeHasNothingAfterIt() {
        let last = ItemKey.episode(source: TestIDs.sourceA, seriesID: "office", season: 2, number: 2)
        #expect(EpisodeOrder.following(last, in: episodes).isEmpty)
    }

    @Test func anEpisodeNotInTheListHasNothingAfterIt() {
        let missing = ItemKey.episode(source: TestIDs.sourceA, seriesID: "office", season: 9, number: 9)
        #expect(EpisodeOrder.following(missing, in: episodes).isEmpty)
        #expect(EpisodeOrder.following(missing, in: []).isEmpty)
    }
}

@Suite struct ResumePointTests {
    @Test func theRequestedPositionWins() {
        #expect(ResumePoint.position(requested: 120, saved: makeProgress(position: 900, duration: 3600)) == 120)
    }

    /// Zero (or less) asks for the beginning, even with saved progress.
    @Test(arguments: [0.0, -5.0])
    func aRequestedStartOfZeroOrLessMeansTheBeginning(requested: TimeInterval) {
        #expect(ResumePoint.position(requested: requested, saved: makeProgress(position: 900, duration: 3600)) == nil)
    }

    @Test func theSavedPositionResumes() {
        #expect(ResumePoint.position(requested: nil, saved: makeProgress(position: 900, duration: 3600)) == 900)
        #expect(ResumePoint.position(requested: nil, saved: nil) == nil)
    }

    @Test func aFinishedItemStartsOver() {
        #expect(ResumePoint.position(requested: nil, saved: makeProgress(position: 900, duration: 3600, watched: true)) == nil)
    }

    /// Barely begun (10 s or less) or all but over (30 s or less left).
    @Test func theEdgesStartFromTheBeginning() {
        #expect(ResumePoint.position(requested: nil, saved: makeProgress(position: 10, duration: 3600)) == nil)
        #expect(ResumePoint.position(requested: nil, saved: makeProgress(position: 11, duration: 3600)) == 11)
        #expect(ResumePoint.position(requested: nil, saved: makeProgress(position: 3570, duration: 3600)) == nil)
        #expect(ResumePoint.position(requested: nil, saved: makeProgress(position: 3569, duration: 3600)) == 3569)
    }
}

@Suite struct StreamMappingTests {
    let url = URL(string: "https://stream.invalid/live.m3u8")!

    @Test(arguments: [
        (StreamFormatHint.hls, StreamFormat.hls),
        (.mpegts, .mpegts),
        (.mp4, .mp4),
        (.mkv, .mkv),
        (.unknown, .unknown),
    ])
    func everyHintHasItsFormat(hint: StreamFormatHint, format: StreamFormat) {
        let descriptor = StreamMapping.descriptor(from: StreamLink(url: url, formatHint: hint))
        #expect(descriptor.format == format)
        // The two enums share raw values: neither kit imports the other.
        #expect(hint.rawValue == format.rawValue)
    }

    @Test func carriesTheURLHeadersLiveFlagAndStart() {
        let link = StreamLink(url: url, headers: ["User-Agent": "MAG254", "Referer": "http://portal.invalid/"], formatHint: .mpegts, isLive: true)
        let descriptor = StreamMapping.descriptor(from: link, startPosition: 42)
        #expect(descriptor == StreamDescriptor(url: url, headers: ["User-Agent": "MAG254", "Referer": "http://portal.invalid/"], format: .mpegts, isLive: true, startPosition: 42))
        #expect(StreamMapping.descriptor(from: link).startPosition == nil)
    }
}

@Suite struct PlaybackTextTests {
    @Test func liveSubtitleIsTheNumberedNameAlone() {
        #expect(PlaybackText.liveSubtitle(channel: makeChannel("Fieldhouse Sports", number: 102), programme: nil) == "102 Fieldhouse Sports")
        #expect(PlaybackText.liveSubtitle(channel: makeChannel("Fieldhouse Sports"), programme: nil) == "Fieldhouse Sports")
    }

    /// The time range is formatted for the device's clock, so the expected
    /// value is built with the same formatter.
    @Test func liveSubtitleAddsTheProgrammesTimes() {
        let start = referenceDate
        let end = referenceDate.addingTimeInterval(3 * 3600)
        let programme = CatalogProgramme(id: "p", sourceID: TestIDs.sourceA, guideChannelID: "g", start: start, end: end, title: "Match", summary: nil, category: nil, hasArchive: false)
        let subtitle = PlaybackText.liveSubtitle(channel: makeChannel("Fieldhouse Sports", number: 102), programme: programme)
        #expect(subtitle == "102 Fieldhouse Sports · \(HearthFormat.timeRange(start, end))")
    }

    @Test func episodeSubtitle() {
        #expect(PlaybackText.episodeSubtitle(season: 2, number: 5, title: "The Lighthouse Keeper") == "S2 · E5 — The Lighthouse Keeper")
        #expect(PlaybackText.episodeSubtitle(season: 2, number: 5, title: "  The Lighthouse Keeper ") == "S2 · E5 — The Lighthouse Keeper")
    }

    @Test(arguments: ["", "   "])
    func anUntitledEpisodeIsJustItsCode(title: String) {
        #expect(PlaybackText.episodeSubtitle(season: 1, number: 12, title: title) == "S1 · E12")
    }
}

@MainActor
@Suite struct LiveIntentTests {
    @Test func aChannelBecomesALivePlayWithItsQueue() {
        let logo = URL(string: "https://logo.invalid/102.png")!
        let channel = makeChannel("Fieldhouse Sports", id: "102", number: 102, logo: logo)
        let intent = PlaybackCoordinator.liveIntent(for: channel, queue: ["q1", "q2"])
        #expect(intent.itemKey == channel.key.rawValue)
        #expect(intent.kind == .live)
        #expect(intent.title == "Fieldhouse Sports")
        #expect(intent.artworkURL == logo)
        #expect(intent.queue == ["q1", "q2"])
        #expect(intent.startPosition == nil)
        #expect(intent.catchupStart == nil)
    }
}
