import CatalogKit
import Foundation
import SourceKit

/// Values the Live TV tests build on. Every date is a wall-clock moment in a
/// named time zone, read through a pinned Gregorian calendar, so nothing
/// depends on the machine's clock or zone.
enum Fixture {
    static let sourceA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let sourceB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    /// London: GMT in late October 2026 (so local hours are UTC hours), with
    /// the clocks going back on 25 October and forward on 29 March.
    static let london = calendar("Europe/London")
    /// Kathmandu is UTC+5:45: local half hours are not UTC half hours.
    static let kathmandu = calendar("Asia/Kathmandu")

    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// A wall-clock moment in `calendar`'s zone.
    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, in calendar: Calendar = london) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Wednesday 28 October 2026, 20:42 in London: the mockup's now line.
    static let now = date(2026, 10, 28, 20, 42)

    static func channel(_ id: String, number: Int? = nil, name: String? = nil, source: UUID = sourceA, hasArchive: Bool = false, archiveDays: Int = 0) -> CatalogChannel {
        CatalogChannel(
            key: .channel(source: source, id: id),
            sourceID: source,
            sourceName: source == sourceA ? "Provider A" : "Provider B",
            remoteID: id,
            number: number,
            name: name ?? "Channel \(id)",
            logoURL: URL(string: "https://example.com/logo/\(id).png"),
            categoryID: nil,
            guideChannelID: id,
            hasArchive: hasArchive,
            archiveDays: archiveDays
        )
    }

    static func programme(_ title: String = "Evening Bulletin", start: Date, end: Date, hasArchive: Bool = false) -> CatalogProgramme {
        CatalogProgramme(
            id: "\(title)@\(start.timeIntervalSince1970)",
            sourceID: sourceA,
            guideChannelID: "101",
            start: start,
            end: end,
            title: title,
            summary: nil,
            category: nil,
            hasArchive: hasArchive
        )
    }

    static func category(_ remoteID: String, name: String, source: UUID = sourceA, sortOrder: Int = 0) -> CatalogCategory {
        CatalogCategory(
            id: CategoryKey.make(source: source, kind: "live", remoteID: remoteID),
            sourceID: source,
            remoteID: remoteID,
            kind: .live,
            name: name,
            sortOrder: sortOrder,
            isAdult: false
        )
    }
}

extension Date {
    func adding(minutes: Double) -> Date { addingTimeInterval(minutes * 60) }
    func adding(hours: Double) -> Date { addingTimeInterval(hours * 3600) }
}
