import Foundation

/// The "now" every test passes in: 15 Jan 2027, 08:00 UTC. Mid-month, so a
/// date a few days either side stays in its month in any time zone.
let referenceNow = Date(timeIntervalSince1970: 1_800_000_000)

let utcZone = TimeZone(identifier: "UTC")!

/// A Gregorian calendar in UTC, whatever the machine running the tests uses.
let gregorianUTC: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcZone
    return calendar
}()

/// `2027-03-12 12:00` in UTC.
func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    gregorianUTC.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

let minute: TimeInterval = 60
let hour: TimeInterval = 3_600
let day: TimeInterval = 86_400
