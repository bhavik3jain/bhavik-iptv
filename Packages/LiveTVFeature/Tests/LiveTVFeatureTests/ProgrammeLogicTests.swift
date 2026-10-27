import CatalogKit
import Core
import Foundation
import Testing
@testable import LiveTVFeature

@Suite struct CatchupRulesTests {
    let now = Fixture.now
    let archive = Fixture.channel("101", number: 101, hasArchive: true, archiveDays: 3)

    private func aired(daysAgo: Double, hasArchive: Bool = false) -> CatalogProgramme {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return Fixture.programme(start: start, end: start.adding(hours: 1), hasArchive: hasArchive)
    }

    @Test func aChannelWithoutAnArchivePlaysNothingFromTheStart() {
        let plain = Fixture.channel("102", hasArchive: false, archiveDays: 7)
        #expect(!CatchupRules.isPlayable(aired(daysAgo: 0.1, hasArchive: true), on: plain, now: now))
    }

    @Test func anUpcomingProgrammeIsNotPlayableEvenIfFlagged() {
        let upcoming = Fixture.programme(start: now.adding(minutes: 1), end: now.adding(hours: 1), hasArchive: true)
        #expect(!CatchupRules.isPlayable(upcoming, on: archive, now: now))
    }

    @Test func theProgrammeOnNowIsPlayableFromItsStart() {
        let onNow = Fixture.programme(start: now, end: now.adding(hours: 1))
        #expect(CatchupRules.isPlayable(onNow, on: archive, now: now))
    }

    @Test func theCatalogsFlagIsTrustedWhenSet() {
        #expect(CatchupRules.isPlayable(aired(daysAgo: 30, hasArchive: true), on: archive, now: now))
    }

    @Test func anUnflaggedProgrammeIsCheckedAgainstTheArchiveWindow() {
        #expect(CatchupRules.isPlayable(aired(daysAgo: 2.9), on: archive, now: now))
        #expect(CatchupRules.isPlayable(aired(daysAgo: 3), on: archive, now: now))
        #expect(!CatchupRules.isPlayable(aired(daysAgo: 3.01), on: archive, now: now))
    }

    @Test func anArchiveOfZeroDaysCountsAsOne() {
        let unknownDepth = Fixture.channel("103", hasArchive: true, archiveDays: 0)
        #expect(CatchupRules.isPlayable(aired(daysAgo: 0.5), on: unknownDepth, now: now))
        #expect(!CatchupRules.isPlayable(aired(daysAgo: 1.1), on: unknownDepth, now: now))
    }
}

@Suite struct ProgrammeActionsTests {
    @Test func onNowWatchLiveAndFromTheStartWithAnArchive() {
        #expect(ProgrammeActions.make(phase: .onAir, channelHasArchive: true, isPlayable: true) == ProgrammeActions(primary: .watchLive, secondary: .fromTheStart))
        #expect(ProgrammeActions.make(phase: .onAir, channelHasArchive: true, isPlayable: false) == ProgrammeActions(primary: .watchLive, secondary: nil))
        #expect(ProgrammeActions.make(phase: .onAir, channelHasArchive: false, isPlayable: true) == ProgrammeActions(primary: .watchLive, secondary: nil))
    }

    @Test func airedPlaysFromTheStartOnlyWhileInTheArchive() {
        #expect(ProgrammeActions.make(phase: .aired, channelHasArchive: true, isPlayable: true) == ProgrammeActions(primary: .playFromStart, secondary: nil))
        let gone = ProgrammeActions.make(phase: .aired, channelHasArchive: true, isPlayable: false)
        #expect(gone.isEmpty)
    }

    @Test func upcomingOffersNothing() {
        #expect(ProgrammeActions.make(phase: .upcoming, channelHasArchive: true, isPlayable: true).isEmpty)
    }

    @Test func withoutAGuideTheChannelPlaysLive() {
        let actions = ProgrammeActions.make(phase: nil, channelHasArchive: true, isPlayable: true)
        #expect(actions == ProgrammeActions(primary: .watchLive, secondary: nil))
        #expect(!actions.isEmpty)
    }

    @Test func onlyWatchLiveIsNotCatchup() {
        #expect(!ProgrammeAction.watchLive.isCatchup)
        #expect(ProgrammeAction.fromTheStart.isCatchup)
        #expect(ProgrammeAction.playFromStart.isCatchup)
        #expect(ProgrammeAction.watchLive.title == "Watch live")
        #expect(ProgrammeAction.fromTheStart.title == "From the start")
        #expect(ProgrammeAction.playFromStart.title == "Play from the start")
    }
}

@Suite struct ProgrammeTextTests {
    let calendar = Fixture.london
    let now = Fixture.now
    let start = Fixture.date(2026, 10, 28, 20)
    var end: Date { start.adding(hours: 1) }

    // The clock text itself follows the machine's locale and zone, so these
    // compare against Core's formatter and pin what Live TV adds around it.

    @Test func todaysRangeHasNoDay() {
        #expect(ProgrammeText.timeRange(start: start, end: end, now: now, calendar: calendar) == HearthFormat.compactTimeRange(start, end))
    }

    @Test func otherDaysAreNamedInFront() {
        let yesterday = start.adding(hours: -24)
        #expect(ProgrammeText.timeRange(start: yesterday, end: yesterday.adding(hours: 1), now: now, calendar: calendar)
            == "Yesterday " + HearthFormat.compactTimeRange(yesterday, yesterday.adding(hours: 1)))
        let tomorrow = start.adding(hours: 24)
        #expect(ProgrammeText.timeRange(start: tomorrow, end: tomorrow.adding(hours: 1), now: now, calendar: calendar)
            == "Tomorrow " + HearthFormat.compactTimeRange(tomorrow, tomorrow.adding(hours: 1)))
        let later = start.adding(hours: 72)
        let text = ProgrammeText.timeRange(start: later, end: later.adding(hours: 1), now: now, calendar: calendar)
        #expect(text.hasSuffix(" " + HearthFormat.compactTimeRange(later, later.adding(hours: 1))))
        #expect(!text.hasPrefix("Today") && !text.hasPrefix("Tomorrow"))
    }

    @Test func theDayIsTheStartsDayInTheCalendarsZone() {
        // 23:30–00:30 started today, so it carries no day even though it ends
        // tomorrow.
        let lateStart = Fixture.date(2026, 10, 28, 23, 30)
        #expect(ProgrammeText.timeRange(start: lateStart, end: lateStart.adding(hours: 1), now: now, calendar: calendar)
            == HearthFormat.compactTimeRange(lateStart, lateStart.adding(hours: 1)))
    }

    @Test func subtitleWithoutAProgrammeIsTheChannel() {
        #expect(ProgrammeText.cardSubtitle(channelNumber: 101, channelName: "Cityline News", start: nil, end: nil, now: now, calendar: calendar) == "101 Cityline News")
        #expect(ProgrammeText.cardSubtitle(channelNumber: nil, channelName: "Cityline News", start: start, end: nil, now: now, calendar: calendar) == "Cityline News")
    }

    @Test func subtitleOnNowSaysTimeLeft() {
        let subtitle = ProgrammeText.cardSubtitle(channelNumber: 101, channelName: "Cityline News", start: start, end: end, now: now, calendar: calendar)
        #expect(subtitle == "101 Cityline News · \(HearthFormat.compactTimeRange(start, end)) · 18 min left")
    }

    @Test func subtitleSoonSaysWhenItStarts() {
        let soon = now.adding(minutes: 49)
        let subtitle = ProgrammeText.cardSubtitle(channelNumber: 101, channelName: "Cityline News", start: soon, end: soon.adding(hours: 1), now: now, calendar: calendar)
        #expect(subtitle.hasPrefix("101 Cityline News · "))
        #expect(subtitle.hasSuffix(" · Starts in 49 min"))
    }

    @Test func subtitleSixHoursOrMoreAheadSaysNoCountdown() {
        let far = now.adding(hours: 6)
        let subtitle = ProgrammeText.cardSubtitle(channelNumber: 101, channelName: "Cityline News", start: far, end: far.adding(hours: 1), now: now, calendar: calendar)
        #expect(subtitle.components(separatedBy: " · ").count == 2)
        #expect(!subtitle.contains("Starts in"))
    }

    @Test func spokenCellOnNow() {
        let text = ProgrammeText.spokenCell(title: "Evening Bulletin", start: start, end: end, now: now, isPlayable: true)
        let range = ProgrammeText.timeRange(start: start, end: end, now: now)
        #expect(text == "Evening Bulletin, \(range), On now, 18 min left, Can be played from the start")
    }

    @Test func spokenCellAiredAndUpcoming() {
        let earlier = start.adding(hours: -2)
        let aired = ProgrammeText.spokenCell(title: "Quiz", start: earlier, end: earlier.adding(hours: 1), now: now, isPlayable: false)
        #expect(aired == "Quiz, \(ProgrammeText.timeRange(start: earlier, end: earlier.adding(hours: 1), now: now)), Aired")
        let later = start.adding(hours: 2)
        let upcoming = ProgrammeText.spokenCell(title: "Film", start: later, end: later.adding(hours: 2), now: now, isPlayable: false)
        #expect(upcoming == "Film, \(ProgrammeText.timeRange(start: later, end: later.adding(hours: 2), now: now))")
    }
}

@Suite struct LiveIntentsTests {
    let now = Fixture.now
    let channel = Fixture.channel("101", number: 101, name: "Cityline News", hasArchive: true, archiveDays: 3)
    let queue = ["a", "b", "c"]
    var onNow: CatalogProgramme { Fixture.programme(start: now.adding(minutes: -42), end: now.adding(minutes: 18)) }
    var aired: CatalogProgramme { Fixture.programme("Quiz", start: now.adding(hours: -3), end: now.adding(hours: -2)) }

    @Test func liveCarriesTheChannelAndTheQueue() {
        let intent = LiveIntents.live(channel, programme: onNow, queue: queue)
        #expect(intent.itemKey == channel.key.rawValue)
        #expect(intent.kind == .live)
        #expect(intent.title == "Evening Bulletin")
        #expect(intent.subtitle == "101 Cityline News")
        #expect(intent.artworkURL == channel.logoURL)
        #expect(intent.queue == queue)
        #expect(intent.catchupStart == nil && intent.catchupEnd == nil)
    }

    @Test func liveWithoutAProgrammeIsTitledByTheChannel() {
        #expect(LiveIntents.live(channel, programme: nil, queue: []).title == "Cityline News")
    }

    @Test func catchupCarriesTheProgrammesSlot() {
        let programme = aired
        let intent = LiveIntents.catchup(channel, programme: programme, now: now, queue: queue)
        #expect(intent.kind == .catchup)
        #expect(intent.itemKey == channel.key.rawValue)
        #expect(intent.title == "Quiz")
        #expect(intent.catchupStart == programme.start)
        #expect(intent.catchupEnd == programme.end)
        #expect(intent.subtitle == "101 Cityline News · " + ProgrammeText.timeRange(start: programme.start, end: programme.end, now: now))
        #expect(intent.queue == queue)
    }

    @Test func watchLiveOnAnAiredProgrammeShowsWhatIsOnNotWhatWasSelected() {
        let intent = LiveIntents.intent(for: .watchLive, channel: channel, programme: aired, now: now, queue: queue)
        #expect(intent.kind == .live)
        #expect(intent.title == "Cityline News")
        let current = LiveIntents.intent(for: .watchLive, channel: channel, programme: onNow, now: now, queue: queue)
        #expect(current.title == "Evening Bulletin")
    }

    @Test func catchupActionsPlayTheProgrammeFromItsStart() {
        let fromTheStart = LiveIntents.intent(for: .fromTheStart, channel: channel, programme: onNow, now: now, queue: queue)
        #expect(fromTheStart.kind == .catchup && fromTheStart.catchupStart == onNow.start)
        let archived = LiveIntents.intent(for: .playFromStart, channel: channel, programme: aired, now: now, queue: queue)
        #expect(archived.kind == .catchup && archived.catchupEnd == aired.end)
    }

    @Test func aCatchupActionWithoutAProgrammeFallsBackToLive() {
        let intent = LiveIntents.intent(for: .playFromStart, channel: channel, programme: nil, now: now, queue: queue)
        #expect(intent.kind == .live)
        #expect(intent.title == "Cityline News")
    }
}
