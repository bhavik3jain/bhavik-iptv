import Foundation
import Testing
@testable import Core

@Suite struct ProgrammeTimingTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var timing: ProgrammeTiming { ProgrammeTiming(start: start, end: start + 3600) }

    @Test func progressIsClampedToTheSlot() {
        #expect(timing.progress(at: start - 60) == 0)
        #expect(timing.progress(at: start + 900) == 0.25)
        #expect(timing.progress(at: start + 7200) == 1)
        #expect(ProgrammeTiming(start: start, end: start).progress(at: start) == 0)
        #expect(ProgrammeTiming(start: start, end: start - 60).duration == 0)
    }

    @Test func onAirIncludesTheStartButNotTheEnd() {
        #expect(timing.isOnAir(at: start))
        #expect(timing.isOnAir(at: start + 3599))
        #expect(!timing.isOnAir(at: start + 3600))
        #expect(!timing.isOnAir(at: start - 1))
    }

    @Test func remainingTextOnlyWhileOnAir() {
        #expect(timing.remainingText(at: start + 42 * 60) == "18 min left")
        #expect(timing.remainingText(at: start + 3600) == nil)
        #expect(timing.remainingText(at: start - 60) == nil)
        #expect(timing.remaining(at: start + 7200) == 0)
    }

    @Test func timeRangesUseAnEnDash() {
        #expect(timing.timeRange.contains(" – "))
        // No spaces around the dash for the guide's narrow cells (a 12-hour
        // locale still has its own space before AM/PM).
        #expect(timing.compactTimeRange.contains("–"))
        #expect(!timing.compactTimeRange.contains(" – "))
    }
}

@Suite struct StreamUsageTests {
    @Test func segmentsMarkTheTakenSlots() {
        #expect(StreamUsage(inUse: 1, limit: 2).segments == [true, false])
        #expect(StreamUsage(inUse: 0, limit: 1).segments == [false])
        #expect(StreamUsage(inUse: 3, limit: 2).segments == [true, true])
    }

    @Test func manySlotsOrNoLimitDrawNoSegments() {
        #expect(StreamUsage(inUse: 2, limit: 9).segments == nil)
        #expect(StreamUsage(inUse: 2, limit: nil).segments == nil)
        #expect(StreamUsage(inUse: 0, limit: 0).segments == nil)
    }

    @Test func fullnessAndOverLimit() {
        let half = StreamUsage(inUse: 1, limit: 2)
        #expect(!half.isFull && !half.isOverLimit && half.free == 1 && half.fraction == 0.5)

        let full = StreamUsage(inUse: 2, limit: 2)
        #expect(full.isFull && !full.isOverLimit && full.free == 0)

        let over = StreamUsage(inUse: 3, limit: 2)
        #expect(over.isFull && over.isOverLimit && over.free == 0 && over.fraction == 1)

        let unlimited = StreamUsage(inUse: 5, limit: nil)
        #expect(!unlimited.isFull && unlimited.free == nil && unlimited.fraction == 0)
    }

    @Test func negativeCountsAreClamped() {
        let usage = StreamUsage(inUse: -1, limit: -3)
        #expect(usage.inUse == 0 && usage.limit == 0)
    }

    @Test func textReadsLikeTheMockup() {
        #expect(StreamUsage(inUse: 1, limit: 2).countText == "1 of 2")
        #expect(StreamUsage(inUse: 3, limit: nil).countText == "3 in use")
        #expect(StreamUsage(inUse: 1, limit: 2).spokenText == "1 of 2 streams in use")
    }
}

@Suite struct AvatarStackLayoutTests {
    @Test func overflowBecomesPlusN() {
        let layout = AvatarStackLayout(count: 3, maxVisible: 2)
        #expect(layout.visible == 2 && layout.overflow == 1)
    }

    @Test func fewerMembersThanSlots() {
        let layout = AvatarStackLayout(count: 1, maxVisible: 2)
        #expect(layout.visible == 1 && layout.overflow == 0)
        #expect(AvatarStackLayout(count: 0, maxVisible: 2).visible == 0)
    }

    @Test func atLeastOneFaceIsDrawn() {
        let layout = AvatarStackLayout(count: 4, maxVisible: 0)
        #expect(layout.visible == 1 && layout.overflow == 3)
    }

    @Test func spokenNamesIncludeEveryone() {
        let spoken = AvatarStackLayout.spokenNames(["Bhavik", "Anya", "Dad"])
        #expect(spoken.contains("Bhavik") && spoken.contains("Anya") && spoken.contains("Dad"))
    }
}

@Suite struct EpisodeTextTests {
    @Test func titlesAreNumbered() {
        #expect(EpisodeText.title(number: 5, title: "The Lighthouse Keeper") == "5. The Lighthouse Keeper")
        #expect(EpisodeText.title(number: 5, title: "5. The Lighthouse Keeper") == "5. The Lighthouse Keeper")
        #expect(EpisodeText.title(number: 5, title: "  ") == "Episode 5")
        #expect(EpisodeText.title(number: nil, title: " Pilot ") == "Pilot")
    }

    @Test func detailLinesMatchTheShowScreen() {
        #expect(EpisodeText.detail(duration: 48 * 60) == "48 min")
        #expect(EpisodeText.detail(duration: 51 * 60, remaining: 31 * 60) == "51 min · 31 min left")
        #expect(EpisodeText.detail(duration: 47 * 60, isDownloaded: true) == "47 min · Downloaded")
        // A started download says what is left: resuming is likelier.
        #expect(EpisodeText.detail(duration: 47 * 60, remaining: 10 * 60, isDownloaded: true) == "47 min · 10 min left")
        #expect(EpisodeText.detail(duration: nil) == nil)
    }

    @Test func remainingThatIsNotProgressIsIgnored() {
        // Under a minute left, or "remaining" the whole length (unstarted).
        #expect(EpisodeText.detail(duration: 51 * 60, remaining: 30) == "51 min")
        #expect(EpisodeText.detail(duration: 51 * 60, remaining: 51 * 60) == "51 min")
        #expect(EpisodeText.detailParts(duration: 51 * 60, remaining: 31 * 60) == ["51 min", "31 min left"])
    }
}

@Suite struct ChannelTextTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func numberedName() {
        #expect(ChannelText.numberedName(number: 101, name: "Cityline News") == "101 Cityline News")
        #expect(ChannelText.numberedName(number: nil, name: "Cityline News") == "Cityline News")
    }

    @Test func spokenSentenceCarriesTheProgramme() {
        let timing = ProgrammeTiming(start: start, end: start + 3600)
        let sentence = ChannelText.spokenNowPlaying(number: 101, name: "Cityline News", programme: "Evening Bulletin",
                                                    timing: timing, isLive: true, at: start + 42 * 60)
        #expect(sentence.hasPrefix("101 Cityline News. Live: Evening Bulletin, "))
        #expect(sentence.hasSuffix(", 18 min left"))
    }

    @Test func noGuideIsJustTheChannel() {
        #expect(ChannelText.spokenNowPlaying(number: 7, name: "Kids", programme: nil, timing: nil, isLive: true, at: start) == "7 Kids")
        #expect(ChannelText.spokenNowPlaying(number: 7, name: "Kids", programme: "", timing: nil, isLive: true, at: start) == "7 Kids")
    }
}

@Suite struct LayoutRuleTests {
    @Test func segmentedPillsShareWidthOnlyWhenShort() {
        #expect(SegmentedPillsLayout.usesEqualWidths(count: 3, isAccessibilitySize: false))
        #expect(!SegmentedPillsLayout.usesEqualWidths(count: 5, isAccessibilitySize: false))
        #expect(!SegmentedPillsLayout.usesEqualWidths(count: 2, isAccessibilitySize: true))
    }

    /// FNV-1a over the name: a channel's tile colour must not change between
    /// launches, devices or Swift versions.
    @Test func tileColoursAreStable() {
        #expect(TilePalette.index(for: "Cityline News") == TilePalette.index(for: "Cityline News"))
        #expect(TilePalette.index(for: "") == Int(0xcbf2_9ce4_8422_2325 as UInt64 % UInt64(TilePalette.colors.count)))
        let indices = Set(["Cityline News", "Fieldhouse Sports", "Lantern Drama", "Northwind Docs", "Kitchen Corner", "Little Owl Kids"]
            .map(TilePalette.index(for:)))
        #expect(indices.count > 1)
        #expect(indices.allSatisfy { (0..<TilePalette.colors.count).contains($0) })
    }
}

@Suite struct FormattingTests {
    @Test func displayTimecodeUsesATrueMinus() {
        #expect(HearthFormat.displayTimecode(-252, signed: true) == "\u{2212}4:12")
        #expect(HearthFormat.displayTimecode(252, signed: true) == "4:12")
        #expect(HearthFormat.displayTimecode(3723) == "1:02:03")
    }

    @Test func spokenDurationNamesTheUnits() {
        let spoken = HearthFormat.spokenDuration(252)
        #expect(spoken.contains("4") && spoken.contains("12"))
        #expect(!spoken.contains(":"))
    }

    @Test func remainingAndEpisodeCodes() {
        #expect(HearthFormat.remaining(31 * 60) == "31 min left")
        #expect(HearthFormat.duration(60 * 60) == "1 h")
        #expect(HearthFormat.episodeCode(season: 2, episode: 5) == "S2 · E5")
    }
}
