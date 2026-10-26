import CoreGraphics
import Foundation

// The guide's time maths (LIV-2), kept out of the views so it can be tested
// without a screen: where a moment sits across the timeline, how wide a
// programme is, which slice of the timeline is worth drawing, the header's
// ticks and the days the jump menu offers. Every day boundary is midnight in
// the device's time zone, read from the calendar passed in.

/// The whole scrollable time axis: midnight of the first day the guide holds
/// up to midnight after the last, at a fixed number of points per minute.
struct GuideTimeline: Hashable, Sendable {
    /// The left edge of the timeline (x = 0).
    var origin: Date
    /// The right edge.
    var end: Date
    var pointsPerMinute: CGFloat

    /// How far back and ahead the timeline may reach, whatever the guide
    /// holds: a provider that keeps a month of old programmes would otherwise
    /// make a row tens of thousands of points wide for nothing.
    static let maxDaysBack = 14
    static let maxDaysAhead = 15

    /// The timeline for a guide range. Always covers today, so a source with
    /// no guide yet still gets a timeline with a now line.
    static func make(guideRange: ClosedRange<Date>?, now: Date, pointsPerMinute: CGFloat, calendar: Calendar = .current) -> GuideTimeline {
        let today = calendar.startOfDay(for: now)
        let earliest = calendar.date(byAdding: .day, value: -maxDaysBack, to: today) ?? today
        let latest = calendar.date(byAdding: .day, value: maxDaysAhead + 1, to: today) ?? today.addingTimeInterval(86_400)

        let first = min(guideRange?.lowerBound ?? now, now)
        let last = max(guideRange?.upperBound ?? now, now)
        let origin = max(calendar.startOfDay(for: first), earliest)
        let lastDay = calendar.startOfDay(for: last)
        // Midnight after the last programme ends; a programme ending exactly
        // at midnight doesn't add an empty day.
        var end = last == lastDay ? lastDay : (calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay)
        end = min(max(end, calendar.date(byAdding: .day, value: 1, to: today) ?? end), latest)
        return GuideTimeline(origin: origin, end: end, pointsPerMinute: max(pointsPerMinute, 0.1))
    }

    var duration: TimeInterval { end.timeIntervalSince(origin) }

    /// The timeline's width in points.
    var totalWidth: CGFloat { x(for: end) }

    /// The x of a moment, from the timeline's left edge (negative before it).
    func x(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(origin) / 60) * pointsPerMinute
    }

    /// The moment at an x, clamped to the timeline.
    func date(atX x: CGFloat) -> Date {
        let minutes = TimeInterval(max(0, min(x, totalWidth)) / pointsPerMinute)
        return origin.addingTimeInterval(minutes * 60)
    }

    /// The x a scroll should go to so `date` is on screen with the edge on
    /// a half hour before it (`leadingEdge(toShow:)`): the guide opens on now
    /// the way the mockup does, "20:00" at the edge and the now line at
    /// 20:42, with the programme already running in view.
    func scrollX(toShow date: Date, viewportWidth: CGFloat, calendar: Calendar = .current) -> CGFloat {
        let target = x(for: Self.leadingEdge(toShow: date, calendar: calendar))
        let maxX = max(0, totalWidth - viewportWidth)
        return min(max(0, target), maxX)
    }

    /// The half hour on the device's clock at or before a quarter of an
    /// hour ahead of `date`, so between 15 and 45 minutes of what came
    /// before `date` stay in view. Counted from local midnight, as the
    /// header's ticks are, so it lands on a tick in zones with :30 and :45
    /// offsets too.
    static func leadingEdge(toShow date: Date, calendar: Calendar = .current) -> Date {
        let step: TimeInterval = 30 * 60
        let target = date.addingTimeInterval(-15 * 60)
        let midnight = calendar.startOfDay(for: target)
        let index = (target.timeIntervalSince(midnight) / step).rounded(.down)
        return midnight.addingTimeInterval(index * step)
    }

    /// Where `date` is relative to a visible span of the timeline starting
    /// at `offsetX` and `viewportWidth` wide: before it, in it, or after.
    func side(of date: Date, offsetX: CGFloat, viewportWidth: CGFloat) -> GuideSide {
        let dateX = x(for: date)
        if dateX < offsetX { return .before }
        if dateX > offsetX + viewportWidth { return .after }
        return .visible
    }

    func contains(_ date: Date) -> Bool { origin <= date && date < end }
}

/// Where a moment sits relative to what's on screen.
enum GuideSide: Hashable, Sendable {
    case before
    case visible
    case after
}

/// The slice of the timeline the rows draw: what's on screen plus a margin
/// either side, snapped to whole hours. Scrolling changes it only when the
/// screen crosses an hour, so rows rebuild their cells rarely instead of on
/// every frame, and the margin keeps the edges of the drawn cells off screen.
struct GuideWindow: Hashable, Sendable {
    var start: Date
    var end: Date

    static let margin: TimeInterval = 2 * 3600
    static let step: TimeInterval = 3600

    /// The window around a visible span, clamped to the timeline.
    static func around(visibleStart: Date, visibleEnd: Date, in timeline: GuideTimeline) -> GuideWindow {
        let start = snapDown(visibleStart.addingTimeInterval(-margin))
        let end = snapUp(max(visibleEnd, visibleStart).addingTimeInterval(margin))
        return GuideWindow(start: max(start, timeline.origin), end: min(max(end, start.addingTimeInterval(step)), timeline.end))
    }

    /// The window for a scroll offset: `offsetX` is the content offset and
    /// `timelineViewport` the width the timeline gets beside the channel
    /// column.
    static func at(offsetX: CGFloat, timelineViewport: CGFloat, in timeline: GuideTimeline) -> GuideWindow {
        around(
            visibleStart: timeline.date(atX: offsetX),
            visibleEnd: timeline.date(atX: offsetX + max(timelineViewport, 1)),
            in: timeline
        )
    }

    /// Before the first scroll: a few hours around now.
    static func initial(now: Date, in timeline: GuideTimeline) -> GuideWindow {
        around(visibleStart: now.addingTimeInterval(-3600), visibleEnd: now.addingTimeInterval(3 * 3600), in: timeline)
    }

    var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }

    /// Whether a programme from `start` to `end` shows in the window.
    func overlaps(start programmeStart: Date, end programmeEnd: Date) -> Bool {
        programmeEnd > start && programmeStart < end
    }

    private static func snapDown(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / step).rounded(.down) * step)
    }

    private static func snapUp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / step).rounded(.up) * step)
    }
}

/// A labelled tick in the guide's header: "20:00", "20:30", or the day's name
/// at midnight.
struct GuideTick: Hashable, Sendable, Identifiable {
    var date: Date
    var x: CGFloat
    /// Midnight: the label names the day instead of "00:00".
    var isDayStart: Bool
    var id: Date { date }

    /// Ticks every `minutes` across `window`, leaving out any that would sit
    /// under the now marker (`clearance` points either side of it), as the
    /// mockup drops 20:30 under "20:42".
    static func ticks(in window: GuideWindow, timeline: GuideTimeline, every minutes: Int = 30, now: Date?, clearance: CGFloat = 34, calendar: Calendar = .current) -> [GuideTick] {
        let step = TimeInterval(max(minutes, 5) * 60)
        // Ticks fall on whole half hours of the device's clock, which isn't
        // always a multiple of the step from 1970 (time zones with :30 and
        // :45 offsets), so they are counted from the window's local midnight.
        let midnight = calendar.startOfDay(for: window.start)
        let firstIndex = (window.start.timeIntervalSince(midnight) / step).rounded(.up)
        var date = midnight.addingTimeInterval(firstIndex * step)
        let nowX = now.map { timeline.x(for: $0) }
        var ticks: [GuideTick] = []
        while date < window.end {
            let x = timeline.x(for: date)
            if nowX.map({ abs($0 - x) >= clearance }) ?? true {
                ticks.append(GuideTick(date: date, x: x, isDayStart: calendar.startOfDay(for: date) == date))
            }
            date = date.addingTimeInterval(step)
        }
        return ticks
    }
}

/// One day of the guide, for the header's jump menu and a channel's day
/// picker.
struct GuideDay: Hashable, Sendable, Identifiable {
    /// Midnight in the device's time zone.
    var start: Date
    var end: Date
    /// 0 for today, -1 yesterday, 1 tomorrow.
    var offsetFromToday: Int
    var id: Date { start }

    var isToday: Bool { offsetFromToday == 0 }

    /// "Yesterday", "Today", "Tomorrow", then "Wed 28".
    var title: String {
        switch offsetFromToday {
        case -1: String(localized: "Yesterday")
        case 0: String(localized: "Today")
        case 1: String(localized: "Tomorrow")
        default: start.formatted(.dateTime.weekday(.abbreviated).day())
        }
    }

    /// For VoiceOver: "Wednesday, 28 October" rather than "Wed 28".
    var spokenTitle: String {
        abs(offsetFromToday) <= 1 ? title : start.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// Every day the timeline covers, in order.
    static func days(in timeline: GuideTimeline, now: Date, calendar: Calendar = .current) -> [GuideDay] {
        days(from: timeline.origin, to: timeline.end, now: now, calendar: calendar)
    }

    /// Every day from `start`'s up to (not including) the day `end` falls in
    /// at midnight.
    static func days(from start: Date, to end: Date, now: Date, calendar: Calendar = .current) -> [GuideDay] {
        let today = calendar.startOfDay(for: now)
        var day = calendar.startOfDay(for: start)
        var result: [GuideDay] = []
        while day < end, result.count < 62 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
            result.append(GuideDay(start: day, end: next, offsetFromToday: offset))
            day = next
        }
        return result
    }

    /// The day `date` falls in.
    static func containing(_ date: Date, now: Date, calendar: Calendar = .current) -> GuideDay {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: start).day ?? 0
        return GuideDay(start: start, end: end, offsetFromToday: offset)
    }

    /// Where the jump menu lands on this day: now for today; the same time
    /// of day as now on any other day, so "Yesterday" shows what was on at
    /// this hour.
    func jumpTarget(now: Date, calendar: Calendar = .current) -> Date {
        if isToday { return now }
        let sinceMidnight = now.timeIntervalSince(calendar.startOfDay(for: now))
        return min(start.addingTimeInterval(sinceMidnight), end.addingTimeInterval(-60))
    }
}

/// The guide's sizes for a width: how wide the channel column is and how
/// many points a minute gets. About two hours of guide fit on a phone (the
/// mockup's 150 pt an hour beside a 90 pt column); wider screens show up to
/// three hours at a larger scale and name each channel beside its logo.
struct GuideMetrics: Hashable, Sendable {
    var channelColumnWidth: CGFloat
    var showsChannelNames: Bool
    var pointsPerMinute: CGFloat
    var rowHeight: CGFloat
    var cellHeight: CGFloat
    var headerHeight: CGFloat
    /// The gap between neighbouring programme cells.
    var cellGap: CGFloat

    static let minimumPointsPerMinute: CGFloat = 2.5
    static let maximumPointsPerMinute: CGFloat = 6

    /// - Parameters:
    ///   - width: The guide's width, channel column included.
    ///   - rowHeight: The row height at the current text size (60 at the
    ///     default size).
    static func make(width: CGFloat, rowHeight: CGFloat = 60) -> GuideMetrics {
        let names = width >= 640
        let column: CGFloat = names ? 196 : 90
        let timelineWidth = max(width - column, 200)
        let targetMinutes: CGFloat = timelineWidth < 500 ? 120 : 180
        // Quantised to half points so resizing a Mac window doesn't rescale
        // the guide on every pixel.
        let raw = (timelineWidth / targetMinutes * 2).rounded(.down) / 2
        let ppm = min(max(raw, minimumPointsPerMinute), maximumPointsPerMinute)
        let row = max(rowHeight, 52)
        return GuideMetrics(
            channelColumnWidth: column,
            showsChannelNames: names,
            pointsPerMinute: ppm,
            rowHeight: row,
            cellHeight: row - 10,
            headerHeight: 34,
            cellGap: 3
        )
    }
}

/// Where a programme sits in time relative to now.
enum ProgrammePhase: Hashable, Sendable {
    case aired
    case onAir
    case upcoming

    static func of(start: Date, end: Date, now: Date) -> ProgrammePhase {
        if end <= now { return .aired }
        if start <= now { return .onAir }
        return .upcoming
    }
}

/// One programme cell's frame in a row, clipped to the drawn window.
struct GuideCellFrame: Hashable, Sendable {
    var x: CGFloat
    var width: CGFloat

    /// The frame of a programme from `start` to `end`, or nil when it falls
    /// outside the window. Cells are clipped to the window (their hidden ends
    /// stay off screen thanks to the window's margin) and keep a gap on the
    /// right, as in the mockup's 147 pt cells in 150 pt slots.
    static func make(start: Date, end: Date, window: GuideWindow, timeline: GuideTimeline, gap: CGFloat) -> GuideCellFrame? {
        guard window.overlaps(start: start, end: end) else { return nil }
        let clippedStart = max(start, window.start)
        let clippedEnd = min(end, window.end)
        let x = timeline.x(for: clippedStart)
        let width = timeline.x(for: clippedEnd) - x - (clippedEnd == end ? gap : 0)
        guard width >= 1 else { return nil }
        return GuideCellFrame(x: x, width: width)
    }
}
