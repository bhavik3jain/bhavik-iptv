import CoreGraphics
import Foundation
import Testing
@testable import LiveTVFeature

@Suite struct GuideTimelineTests {
    let calendar = Fixture.london
    let now = Fixture.now
    let today = Fixture.date(2026, 10, 28)

    private func timeline(_ range: ClosedRange<Date>?, now: Date? = nil, pointsPerMinute: CGFloat = 2.5, calendar: Calendar? = nil) -> GuideTimeline {
        GuideTimeline.make(guideRange: range, now: now ?? self.now, pointsPerMinute: pointsPerMinute, calendar: calendar ?? self.calendar)
    }

    // MARK: Range

    @Test func withoutAGuideTheTimelineIsToday() {
        let t = timeline(nil)
        #expect(t.origin == today)
        #expect(t.end == Fixture.date(2026, 10, 29))
        #expect(t.duration == 86_400)
        #expect(t.totalWidth == 1440 * 2.5)
    }

    @Test func coversEveryDayTheGuideTouchesFromMidnightToMidnight() {
        let t = timeline(Fixture.date(2026, 10, 27, 18)...Fixture.date(2026, 10, 30, 6))
        #expect(t.origin == Fixture.date(2026, 10, 27))
        #expect(t.end == Fixture.date(2026, 10, 31))
    }

    @Test func aGuideEndingExactlyAtMidnightAddsNoEmptyDay() {
        let t = timeline(Fixture.date(2026, 10, 28, 6)...Fixture.date(2026, 10, 30))
        #expect(t.end == Fixture.date(2026, 10, 30))
    }

    @Test func aGuideThatHasEndedStillReachesTheEndOfToday() {
        let t = timeline(Fixture.date(2026, 10, 20, 6)...Fixture.date(2026, 10, 22, 6))
        #expect(t.origin == Fixture.date(2026, 10, 20))
        #expect(t.end == Fixture.date(2026, 10, 29))
        #expect(t.contains(now))
    }

    @Test func aGuideStartingTomorrowStillStartsToday() {
        let t = timeline(Fixture.date(2026, 10, 29, 6)...Fixture.date(2026, 10, 30, 6))
        #expect(t.origin == today)
        #expect(t.end == Fixture.date(2026, 10, 31))
    }

    @Test func reachIsCappedAtFourteenDaysBackAndFifteenAhead() {
        let t = timeline(Fixture.date(2026, 8, 1)...Fixture.date(2027, 1, 31))
        #expect(t.origin == Fixture.date(2026, 10, 14))
        // Today plus 15 days ahead, up to the midnight after the last.
        #expect(t.end == Fixture.date(2026, 11, 13))
    }

    @Test func pointsPerMinuteHasAFloor() {
        #expect(timeline(nil, pointsPerMinute: 0).pointsPerMinute == 0.1)
        #expect(timeline(nil, pointsPerMinute: -4).pointsPerMinute == 0.1)
        #expect(timeline(nil, pointsPerMinute: 3).pointsPerMinute == 3)
    }

    @Test func theDayTheClocksGoBackIsTwentyFiveHoursWide() {
        let t = timeline(nil, now: Fixture.date(2026, 10, 25, 12))
        #expect(t.duration == 25 * 3600)
        #expect(t.totalWidth == 25 * 60 * 2.5)
    }

    @Test func theDayTheClocksGoForwardIsTwentyThreeHoursWide() {
        let t = timeline(nil, now: Fixture.date(2026, 3, 29, 12))
        #expect(t.duration == 23 * 3600)
    }

    @Test func dayBoundariesAreLocalMidnightInTheCalendarsZone() {
        // 20:42 in London is 02:27 the next morning in Kathmandu.
        let t = timeline(nil, calendar: Fixture.kathmandu)
        #expect(t.origin == Fixture.date(2026, 10, 29, in: Fixture.kathmandu))
        #expect(t.origin != today)
    }

    // MARK: Positions

    @Test func xIsMinutesSinceTheOriginTimesTheScale() {
        let t = timeline(nil)
        #expect(t.x(for: today) == 0)
        #expect(t.x(for: today.adding(minutes: 90)) == 225)
        #expect(t.x(for: now) == (20 * 60 + 42) * 2.5)
        #expect(t.x(for: today.adding(hours: -1)) == -150)
    }

    @Test func dateAtXInvertsXAndIsClampedToTheTimeline() {
        let t = timeline(nil)
        #expect(t.date(atX: t.x(for: now)) == now)
        #expect(t.date(atX: 0) == t.origin)
        #expect(t.date(atX: -500) == t.origin)
        #expect(t.date(atX: t.totalWidth + 500) == t.end)
    }

    @Test func containsIncludesTheOriginButNotTheEnd() {
        let t = timeline(nil)
        #expect(t.contains(t.origin))
        #expect(t.contains(t.end.addingTimeInterval(-1)))
        #expect(!t.contains(t.end))
        #expect(!t.contains(t.origin.addingTimeInterval(-1)))
    }

    @Test func sideSaysWhichWayADateWentOffScreen() {
        let t = timeline(nil)
        let nowX = t.x(for: now) // 3105
        #expect(t.side(of: now, offsetX: nowX - 100, viewportWidth: 300) == .visible)
        #expect(t.side(of: now, offsetX: nowX + 1, viewportWidth: 300) == .before)
        #expect(t.side(of: now, offsetX: nowX - 301, viewportWidth: 300) == .after)
        // Both edges count as on screen.
        #expect(t.side(of: now, offsetX: nowX, viewportWidth: 300) == .visible)
        #expect(t.side(of: now, offsetX: nowX - 300, viewportWidth: 300) == .visible)
    }

    // MARK: Opening scroll

    @Test(arguments: [
        // (now hh:mm, edge hh:mm): the edge is the half hour at or before a
        // quarter of an hour ahead of now.
        (20, 42, 20, 0),
        (20, 44, 20, 0),
        (20, 45, 20, 30),
        (20, 15, 20, 0),
        (20, 14, 19, 30),
    ])
    func leadingEdgeLeavesFifteenToFortyFiveMinutesOfThePast(hour: Int, minute: Int, edgeHour: Int, edgeMinute: Int) {
        let date = Fixture.date(2026, 10, 28, hour, minute)
        let edge = GuideTimeline.leadingEdge(toShow: date, calendar: calendar)
        #expect(edge == Fixture.date(2026, 10, 28, edgeHour, edgeMinute))
        let lead = date.timeIntervalSince(edge)
        #expect(lead >= 15 * 60 && lead < 45 * 60)
    }

    @Test func leadingEdgeJustAfterMidnightIsTheDayBefore() {
        let edge = GuideTimeline.leadingEdge(toShow: Fixture.date(2026, 10, 28, 0, 10), calendar: calendar)
        #expect(edge == Fixture.date(2026, 10, 27, 23, 30))
    }

    @Test func leadingEdgeLandsOnLocalHalfHoursInAQuarterHourZone() {
        let zone = Fixture.kathmandu
        let date = Fixture.date(2026, 10, 28, 20, 42, in: zone)
        let edge = GuideTimeline.leadingEdge(toShow: date, calendar: zone)
        #expect(edge == Fixture.date(2026, 10, 28, 20, 0, in: zone))
        // Not a UTC half hour: counting from 1970 would have missed it.
        #expect(edge.timeIntervalSince1970.truncatingRemainder(dividingBy: 1800) != 0)
    }

    @Test func scrollXPutsTheLeadingEdgeAtTheLeft() {
        let t = timeline(nil)
        #expect(t.scrollX(toShow: now, viewportWidth: 300, calendar: calendar) == t.x(for: Fixture.date(2026, 10, 28, 20)))
    }

    @Test func scrollXIsClampedToTheContent() {
        let t = timeline(nil)
        // Just after midnight the edge would be yesterday, before the origin.
        #expect(t.scrollX(toShow: Fixture.date(2026, 10, 28, 0, 5), viewportWidth: 300, calendar: calendar) == 0)
        // Late in the day it can't scroll past the end.
        #expect(t.scrollX(toShow: Fixture.date(2026, 10, 28, 23, 50), viewportWidth: 1000, calendar: calendar) == t.totalWidth - 1000)
        // A viewport wider than the whole timeline never scrolls.
        #expect(t.scrollX(toShow: now, viewportWidth: t.totalWidth + 100, calendar: calendar) == 0)
    }
}

@Suite struct ProgrammePhaseTests {
    let start = Fixture.date(2026, 10, 28, 20)
    var end: Date { start.adding(hours: 1) }

    @Test func phaseIsHalfOpenAroundTheSlot() {
        #expect(ProgrammePhase.of(start: start, end: end, now: start.addingTimeInterval(-1)) == .upcoming)
        #expect(ProgrammePhase.of(start: start, end: end, now: start) == .onAir)
        #expect(ProgrammePhase.of(start: start, end: end, now: end.addingTimeInterval(-1)) == .onAir)
        #expect(ProgrammePhase.of(start: start, end: end, now: end) == .aired)
    }
}
