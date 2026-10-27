import Foundation
import Testing
@testable import LiveTVFeature

@Suite struct GuideDayTests {
    let calendar = Fixture.london
    let now = Fixture.now

    private func midnight(_ month: Int, _ day: Int) -> Date { Fixture.date(2026, month, day) }

    @Test func everyDayOfTheTimelineInOrderWithItsOffset() {
        let timeline = GuideTimeline.make(guideRange: Fixture.date(2026, 10, 27, 18)...Fixture.date(2026, 10, 30, 6), now: now, pointsPerMinute: 2.5, calendar: calendar)
        let days = GuideDay.days(in: timeline, now: now, calendar: calendar)
        #expect(days.map(\.start) == [midnight(10, 27), midnight(10, 28), midnight(10, 29), midnight(10, 30)])
        #expect(days.map(\.offsetFromToday) == [-1, 0, 1, 2])
        #expect(days.map(\.isToday) == [false, true, false, false])
        // Each day ends where the next begins, and the last at the timeline's end.
        #expect(zip(days, days.dropFirst()).allSatisfy { $0.end == $1.start })
        #expect(days.last?.end == timeline.end)
        #expect(days.map(\.id) == days.map(\.start))
    }

    @Test func theFirstThreeDaysHaveNames() {
        let days = GuideDay.days(from: midnight(10, 26), to: midnight(10, 31), now: now, calendar: calendar)
        let titles = days.map(\.title)
        #expect(titles[1...3] == ["Yesterday", "Today", "Tomorrow"])
        #expect(!["Yesterday", "Today", "Tomorrow"].contains(titles[0]))
        #expect(!["Yesterday", "Today", "Tomorrow"].contains(titles[4]))
        // VoiceOver hears the named days as they are.
        #expect(days[2].spokenTitle == "Today")
    }

    @Test func aStartPartWayThroughADayIncludesThatDay() {
        let days = GuideDay.days(from: Fixture.date(2026, 10, 28, 15), to: Fixture.date(2026, 10, 29, 0, 1), now: now, calendar: calendar)
        #expect(days.map(\.start) == [midnight(10, 28), midnight(10, 29)])
    }

    @Test func anEmptyRangeHasNoDays() {
        #expect(GuideDay.days(from: midnight(10, 28), to: midnight(10, 28), now: now, calendar: calendar).isEmpty)
        #expect(GuideDay.days(from: midnight(10, 29), to: midnight(10, 28), now: now, calendar: calendar).isEmpty)
    }

    @Test func theListIsCappedAt62Days() {
        let days = GuideDay.days(from: Fixture.date(2026, 1, 1), to: Fixture.date(2026, 12, 31), now: now, calendar: calendar)
        #expect(days.count == 62)
    }

    @Test func daysFollowTheClocksAcrossDaylightSavingChanges() {
        let autumn = GuideDay.days(from: midnight(10, 24), to: midnight(10, 27), now: Fixture.date(2026, 10, 26, 12), calendar: calendar)
        #expect(autumn.map { $0.end.timeIntervalSince($0.start) / 3600 } == [24, 25, 24])
        // Offsets count calendar days, not 24-hour blocks: 24 October is two
        // days back although 61 hours have passed since its midnight.
        #expect(autumn.map(\.offsetFromToday) == [-2, -1, 0])

        let spring = GuideDay.days(from: midnight(3, 28), to: midnight(3, 31), now: Fixture.date(2026, 3, 29, 12), calendar: calendar)
        #expect(spring.map { $0.end.timeIntervalSince($0.start) / 3600 } == [24, 23, 24])
        #expect(spring.map(\.offsetFromToday) == [-1, 0, 1])
    }

    @Test func containingPutsMidnightInTheNewDay() {
        let lateYesterday = GuideDay.containing(Fixture.date(2026, 10, 27, 23, 59), now: now, calendar: calendar)
        #expect(lateYesterday.start == midnight(10, 27) && lateYesterday.offsetFromToday == -1)
        let midnightToday = GuideDay.containing(midnight(10, 28), now: now, calendar: calendar)
        #expect(midnightToday.start == midnight(10, 28) && midnightToday.end == midnight(10, 29) && midnightToday.isToday)
        let farAhead = GuideDay.containing(Fixture.date(2026, 11, 4, 9), now: now, calendar: calendar)
        #expect(farAhead.offsetFromToday == 7)
    }

    @Test func containingUsesTheCalendarsZoneNotUTC() {
        // 20:42 in London is already tomorrow in Kathmandu.
        let day = GuideDay.containing(now, now: Fixture.date(2026, 10, 28, 12, in: Fixture.kathmandu), calendar: Fixture.kathmandu)
        #expect(day.start == Fixture.date(2026, 10, 29, in: Fixture.kathmandu))
        #expect(day.offsetFromToday == 1)
    }

    @Test func jumpingToTodayGoesToNow() {
        let today = GuideDay.containing(now, now: now, calendar: calendar)
        #expect(today.jumpTarget(now: now, calendar: calendar) == now)
    }

    @Test func jumpingToAnotherDayKeepsTheTimeOfDay() {
        let yesterday = GuideDay.containing(midnight(10, 27), now: now, calendar: calendar)
        #expect(yesterday.jumpTarget(now: now, calendar: calendar) == Fixture.date(2026, 10, 27, 20, 42))
        let tomorrow = GuideDay.containing(midnight(10, 29), now: now, calendar: calendar)
        #expect(tomorrow.jumpTarget(now: now, calendar: calendar) == Fixture.date(2026, 10, 29, 20, 42))
    }

    @Test func jumpingLateInTheEveningToAShortDayStaysOnThatDay() {
        // 29 March 2026 has 23 hours: 23:30 the next evening is past its end,
        // so the jump stops a minute before its midnight.
        let now = Fixture.date(2026, 3, 30, 23, 30)
        let short = GuideDay.containing(Fixture.date(2026, 3, 29, 12), now: now, calendar: calendar)
        let target = short.jumpTarget(now: now, calendar: calendar)
        #expect(target == short.end.addingTimeInterval(-60))
        #expect(target >= short.start && target < short.end)
    }
}
