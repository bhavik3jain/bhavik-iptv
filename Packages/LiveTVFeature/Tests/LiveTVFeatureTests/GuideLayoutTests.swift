import CatalogKit
import CoreGraphics
import Foundation
import Testing
@testable import LiveTVFeature

/// A three-day timeline (27–29 October, London) at the phone's 2.5 pt a
/// minute. London is on GMT then, so the window's whole-hour snapping (from
/// 1970) lands on local hours and the expectations read as clock times.
private let timeline = GuideTimeline.make(
    guideRange: Fixture.date(2026, 10, 27, 6)...Fixture.date(2026, 10, 29, 18),
    now: Fixture.now,
    pointsPerMinute: 2.5,
    calendar: Fixture.london
)

private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    Fixture.date(2026, 10, day, hour, minute)
}

@Suite struct GuideWindowTests {
    @Test func theTimelineUnderTestSpansThreeDays() {
        #expect(timeline.origin == at(27, 0))
        #expect(timeline.end == at(30, 0))
    }

    @Test func aroundAddsTwoHoursEitherSideSnappedToWholeHours() {
        let window = GuideWindow.around(visibleStart: at(28, 20, 42), visibleEnd: at(28, 22, 42), in: timeline)
        #expect(window.start == at(28, 18))
        #expect(window.end == at(29, 1))
    }

    @Test func aroundOnAWholeHourDoesNotWiden() {
        let window = GuideWindow.around(visibleStart: at(28, 20), visibleEnd: at(28, 22), in: timeline)
        #expect(window.start == at(28, 18))
        #expect(window.end == at(29, 0))
    }

    @Test func scrollingWithinAnHourKeepsTheSameWindow() {
        // The point of snapping: rows rebuild only when the screen crosses
        // an hour, not on every frame.
        let a = GuideWindow.at(offsetX: timeline.x(for: at(28, 20, 1)), timelineViewport: 300, in: timeline)
        let b = GuideWindow.at(offsetX: timeline.x(for: at(28, 20, 59)), timelineViewport: 300, in: timeline)
        #expect(a == b)
        let c = GuideWindow.at(offsetX: timeline.x(for: at(28, 21, 1)), timelineViewport: 300, in: timeline)
        #expect(c != a)
    }

    @Test func theWindowIsClampedToTheTimeline() {
        let first = GuideWindow.around(visibleStart: at(27, 0, 30), visibleEnd: at(27, 2), in: timeline)
        #expect(first.start == timeline.origin)
        let last = GuideWindow.around(visibleStart: at(29, 22), visibleEnd: at(29, 23, 30), in: timeline)
        #expect(last.end == timeline.end)
    }

    @Test func aVisibleEndBeforeTheStartIsIgnored() {
        let window = GuideWindow.around(visibleStart: at(28, 20, 42), visibleEnd: at(28, 19), in: timeline)
        #expect(window.start == at(28, 18))
        #expect(window.end == at(28, 23))
    }

    @Test func atTheLeftEdgeTheWindowStartsAtTheOrigin() {
        // 300 pt is two hours at 2.5 pt a minute.
        let window = GuideWindow.at(offsetX: 0, timelineViewport: 300, in: timeline)
        #expect(window.start == timeline.origin)
        #expect(window.end == at(27, 4))
    }

    @Test func aZeroWidthViewportStillGetsAWindow() {
        let window = GuideWindow.at(offsetX: timeline.x(for: at(28, 20)), timelineViewport: 0, in: timeline)
        #expect(window.start == at(28, 18))
        #expect(window.end == at(28, 23))
    }

    @Test func theInitialWindowIsAFewHoursAroundNow() {
        let window = GuideWindow.initial(now: Fixture.now, in: timeline)
        // 19:42…23:42 visible, plus the margin, snapped out.
        #expect(window.start == at(28, 17))
        #expect(window.end == at(29, 2))
        #expect(window.interval.contains(Fixture.now))
    }

    @Test func overlapsIsHalfOpenAtBothEnds() {
        let window = GuideWindow(start: at(28, 18), end: at(28, 22))
        #expect(!window.overlaps(start: at(28, 16), end: at(28, 18)))
        #expect(window.overlaps(start: at(28, 16), end: at(28, 18, 1)))
        #expect(window.overlaps(start: at(28, 19), end: at(28, 20)))
        #expect(window.overlaps(start: at(28, 17), end: at(28, 23)))
        #expect(window.overlaps(start: at(28, 21, 59), end: at(28, 23)))
        #expect(!window.overlaps(start: at(28, 22), end: at(28, 23)))
    }

    @Test func anInvertedWindowHasAnEmptyInterval() {
        let window = GuideWindow(start: at(28, 20), end: at(28, 19))
        #expect(window.interval.duration == 0)
        #expect(window.interval.start == at(28, 20))
    }
}

@Suite struct GuideTickTests {
    let window = GuideWindow(start: at(28, 18), end: at(28, 21))

    @Test func ticksEveryHalfHourUpToButNotIncludingTheEnd() {
        let ticks = GuideTick.ticks(in: window, timeline: timeline, now: nil, calendar: Fixture.london)
        #expect(ticks.map(\.date) == [at(28, 18), at(28, 18, 30), at(28, 19), at(28, 19, 30), at(28, 20), at(28, 20, 30)])
        #expect(ticks.map(\.x) == ticks.map { timeline.x(for: $0.date) })
        #expect(ticks.allSatisfy { !$0.isDayStart })
    }

    @Test func aWindowStartingOffTheHalfHourStartsAtTheNextOne() {
        let ticks = GuideTick.ticks(in: GuideWindow(start: at(28, 18, 10), end: at(28, 19, 30)), timeline: timeline, now: nil, calendar: Fixture.london)
        #expect(ticks.map(\.date) == [at(28, 18, 30), at(28, 19)])
    }

    @Test func midnightIsMarkedAsTheStartOfADay() {
        let ticks = GuideTick.ticks(in: GuideWindow(start: at(28, 23), end: at(29, 1)), timeline: timeline, now: nil, calendar: Fixture.london)
        #expect(ticks.map(\.date) == [at(28, 23), at(28, 23, 30), at(29, 0), at(29, 0, 30)])
        #expect(ticks.map(\.isDayStart) == [false, false, true, false])
    }

    @Test func theTickUnderTheNowMarkerIsLeftOut() {
        // Now is 20:42: 20:30 sits 30 pt from it, 21:00 45 pt (mockup 03).
        let wide = GuideWindow(start: at(28, 18), end: at(28, 22))
        let ticks = GuideTick.ticks(in: wide, timeline: timeline, now: Fixture.now, calendar: Fixture.london)
        #expect(!ticks.contains { $0.date == at(28, 20, 30) })
        #expect(ticks.contains { $0.date == at(28, 21) })
        #expect(ticks.contains { $0.date == at(28, 20) })
    }

    @Test func clearanceIsInclusiveAtItsEdge() {
        let wide = GuideWindow(start: at(28, 18), end: at(28, 22))
        let kept = GuideTick.ticks(in: wide, timeline: timeline, now: Fixture.now, clearance: 30, calendar: Fixture.london)
        #expect(kept.contains { $0.date == at(28, 20, 30) })
        let dropped = GuideTick.ticks(in: wide, timeline: timeline, now: Fixture.now, clearance: 30.5, calendar: Fixture.london)
        #expect(!dropped.contains { $0.date == at(28, 20, 30) })
    }

    @Test func theStepHasAFiveMinuteFloor() {
        let hour = GuideWindow(start: at(28, 18), end: at(28, 19))
        #expect(GuideTick.ticks(in: hour, timeline: timeline, every: 1, now: nil, calendar: Fixture.london).count == 12)
        #expect(GuideTick.ticks(in: hour, timeline: timeline, every: 0, now: nil, calendar: Fixture.london).count == 12)
        #expect(GuideTick.ticks(in: window, timeline: timeline, every: 60, now: nil, calendar: Fixture.london).map(\.date) == [at(28, 18), at(28, 19), at(28, 20)])
    }

    @Test func ticksFallOnLocalHalfHoursInAQuarterHourZone() {
        let zone = Fixture.kathmandu
        let t = GuideTimeline.make(guideRange: nil, now: Fixture.now, pointsPerMinute: 2.5, calendar: zone)
        // A window snapped to UTC hours, which are :45 past in Kathmandu.
        let w = GuideWindow.around(visibleStart: t.origin.adding(hours: 8), visibleEnd: t.origin.adding(hours: 10), in: t)
        #expect(zone.component(.minute, from: w.start) == 45)
        let ticks = GuideTick.ticks(in: w, timeline: t, now: nil, calendar: zone)
        #expect(!ticks.isEmpty)
        #expect(ticks.allSatisfy { [0, 30].contains(zone.component(.minute, from: $0.date)) })
        #expect(ticks.allSatisfy { $0.date >= w.start && $0.date < w.end })
        #expect(ticks.first?.date == w.start.adding(minutes: 15))
    }
}

@Suite struct GuideCellFrameTests {
    let window = GuideWindow(start: at(28, 18), end: at(28, 22))

    private func frame(_ start: Date, _ end: Date, gap: CGFloat = 3) -> GuideCellFrame? {
        GuideCellFrame.make(start: start, end: end, window: window, timeline: timeline, gap: gap)
    }

    @Test func anHourIsA147PointCellInA150PointSlot() {
        let cell = frame(at(28, 20), at(28, 21))
        #expect(cell == GuideCellFrame(x: timeline.x(for: at(28, 20)), width: 147))
    }

    @Test func aCellStartingBeforeTheWindowIsClippedToItsStartAndKeepsItsGap() {
        let cell = frame(at(28, 17), at(28, 19))
        #expect(cell == GuideCellFrame(x: timeline.x(for: at(28, 18)), width: 147))
    }

    @Test func aCellRunningPastTheWindowIsClippedWithoutAGap() {
        let cell = frame(at(28, 21, 30), at(28, 23))
        #expect(cell == GuideCellFrame(x: timeline.x(for: at(28, 21, 30)), width: 75))
    }

    @Test func aCellCoveringTheWholeWindowFillsIt() {
        let cell = frame(at(28, 12), at(29, 6))
        #expect(cell == GuideCellFrame(x: timeline.x(for: at(28, 18)), width: 600))
    }

    @Test func programmesOutsideTheWindowHaveNoCell() {
        #expect(frame(at(28, 16), at(28, 18)) == nil)
        #expect(frame(at(28, 22), at(28, 23)) == nil)
    }

    @Test func aSliverNarrowerThanAPointHasNoCell() {
        // One minute is 2.5 pt, less the 3 pt gap.
        #expect(frame(at(28, 20), at(28, 20, 1)) == nil)
        #expect(frame(at(28, 20), at(28, 20, 2)) == GuideCellFrame(x: timeline.x(for: at(28, 20)), width: 2))
        #expect(frame(at(28, 20), at(28, 20, 1), gap: 0) != nil)
    }
}

@Suite struct GuideMetricsTests {
    @Test func aPhoneShowsTwoHoursBesideANarrowColumn() {
        let m = GuideMetrics.make(width: 390)
        #expect(m.channelColumnWidth == 90)
        #expect(!m.showsChannelNames)
        #expect(m.pointsPerMinute == 2.5)
        #expect(m.rowHeight == 60)
        #expect(m.cellHeight == 50)
        #expect(m.headerHeight == 34)
        #expect(m.cellGap == 3)
    }

    @Test func namesAndTheWideColumnStartAt640Points() {
        let narrow = GuideMetrics.make(width: 639)
        #expect(!narrow.showsChannelNames && narrow.channelColumnWidth == 90)
        #expect(narrow.pointsPerMinute == 3)
        let wide = GuideMetrics.make(width: 640)
        #expect(wide.showsChannelNames && wide.channelColumnWidth == 196)
        #expect(wide.pointsPerMinute == 3.5)
    }

    @Test func widerScreensShowThreeHours() {
        // 1194 − 196 = 998 pt for 180 minutes, quantised down to 5.5.
        #expect(GuideMetrics.make(width: 1194).pointsPerMinute == 5.5)
    }

    @Test func theScaleIsClampedBothWays() {
        #expect(GuideMetrics.make(width: 3000).pointsPerMinute == GuideMetrics.maximumPointsPerMinute)
        #expect(GuideMetrics.make(width: 100).pointsPerMinute == GuideMetrics.minimumPointsPerMinute)
        #expect(GuideMetrics.make(width: 0).pointsPerMinute == GuideMetrics.minimumPointsPerMinute)
    }

    @Test func theScaleMovesInHalfPointSteps() {
        #expect(GuideMetrics.make(width: 1030).pointsPerMinute == GuideMetrics.make(width: 1040).pointsPerMinute)
        for width in stride(from: CGFloat(300), through: 2400, by: 7) {
            let ppm = GuideMetrics.make(width: width).pointsPerMinute
            #expect((ppm * 2).rounded() == ppm * 2, "width \(width) gave \(ppm)")
        }
    }

    @Test func rowsGrowWithTextSizeButNeverShrinkBelow52() {
        let small = GuideMetrics.make(width: 390, rowHeight: 40)
        #expect(small.rowHeight == 52 && small.cellHeight == 42)
        let large = GuideMetrics.make(width: 390, rowHeight: 80)
        #expect(large.rowHeight == 80 && large.cellHeight == 70)
    }
}

@Suite struct GuideSelectionTests {
    let channel = Fixture.channel("101", number: 101)
    let other = Fixture.channel("102", number: 102)
    let bulletin = Fixture.programme(start: at(28, 20), end: at(28, 21))
    let film = Fixture.programme("Film", start: at(28, 21), end: at(28, 23))

    @Test func aProgrammeIsSelectedOnlyOnItsOwnChannel() {
        let selection = GuideSelection(channel: channel, programme: bulletin)
        #expect(selection.isSelected(bulletin, on: channel))
        #expect(!selection.isSelected(film, on: channel))
        #expect(!selection.isSelected(bulletin, on: other))
        #expect(!selection.isSelected(nil, on: channel))
    }

    @Test func theNoGuideCellIsSelectedAsNil() {
        let selection = GuideSelection(channel: channel, programme: nil)
        #expect(selection.isSelected(nil, on: channel))
        #expect(!selection.isSelected(bulletin, on: channel))
        #expect(!selection.isSelected(nil, on: other))
    }
}
