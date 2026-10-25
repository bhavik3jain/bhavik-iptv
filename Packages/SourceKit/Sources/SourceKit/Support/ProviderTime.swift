import Foundation

/// Every way a provider writes a time. Parsed by hand rather than with
/// `DateFormatter`: an XMLTV guide holds a million of them, and a formatter is
/// both slow and easy to get wrong around daylight-saving changes.
enum ProviderTime {
    /// Unix seconds from a number or numeric text (Xtream's `"1798761600"`).
    /// Values that only make sense as milliseconds are scaled down.
    static func unix(_ value: JSONValue?) -> Date? {
        guard let value else { return nil }
        let seconds: Double
        switch value {
        case .int(let int): seconds = Double(int)
        case .double(let double): seconds = double
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber || $0 == "." }), let parsed = Double(trimmed) else { return nil }
            seconds = parsed
        default: return nil
        }
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
    }

    /// A number as Unix time, else text as a wall-clock date. Text without an
    /// offset is read in `timeZone` — the portal's, for Stalker guides.
    static func date(_ value: JSONValue?, timeZone: TimeZone) -> Date? {
        if let date = unix(value) { return date }
        guard let text = value?.string else { return nil }
        return date(text, timeZone: timeZone)
    }

    /// `2026-10-24 20:00:00`, `2026-10-24 20:00`, `2026-10-24`,
    /// `2026-10-24T20:00:00+01:00`, `2026-10-24T20:00:00Z`. Nil for anything
    /// else, including MySQL's `0000-00-00 00:00:00`.
    static func date(_ text: String, timeZone: TimeZone) -> Date? {
        var scanner = DigitScanner(text)
        guard let year = scanner.number(digits: 4), scanner.skip("-"),
              let month = scanner.number(digits: 2), scanner.skip("-"),
              let day = scanner.number(digits: 2),
              (1...12).contains(month), (1...31).contains(day), year > 1900
        else { return nil }
        var hour = 0, minute = 0, second = 0
        if scanner.skip(" ") || scanner.skip("T") {
            guard let h = scanner.number(digits: 2), scanner.skip(":"), let m = scanner.number(digits: 2) else { return nil }
            hour = h
            minute = m
            if scanner.skip(":"), let s = scanner.number(digits: 2) { second = s }
            if scanner.skip(".") { _ = scanner.digits() }
        }
        let offset = scanner.offsetSeconds()
        return makeDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second, offset: offset, timeZone: timeZone)
    }

    /// XMLTV's `YYYYMMDDhhmmss ±zzzz`; seconds and the offset may be missing
    /// (no offset means UTC, as the XMLTV DTD says).
    static func xmltv(_ text: String) -> Date? {
        let utf8 = Array(text.utf8)
        var index = 0
        func take(_ count: Int) -> Int? {
            guard index + count <= utf8.count else { return nil }
            var value = 0
            for byte in utf8[index..<(index + count)] {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            index += count
            return value
        }
        guard let year = take(4), let month = take(2), let day = take(2), let hour = take(2), let minute = take(2) else { return nil }
        let second = take(2) ?? 0
        while index < utf8.count, utf8[index] == 32 { index += 1 }
        var offset = 0
        if index < utf8.count, utf8[index] == 43 || utf8[index] == 45 {
            let sign = utf8[index] == 45 ? -1 : 1
            index += 1
            if let hours = take(2) {
                if index < utf8.count, utf8[index] == 58 { index += 1 }
                let minutes = take(2) ?? 0
                offset = sign * (hours * 3600 + minutes * 60)
            }
        }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let seconds = daysFromCivil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// A year written anywhere in `text`: `"2019"`, `"2019-05-01"`, `"Dune (2021)"`.
    static func year(in text: String?) -> Int? {
        guard let text else { return nil }
        var digits = ""
        var candidates: [Int] = []
        for character in text + " " {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else {
                if digits.count == 4, let year = Int(digits), (1888...2100).contains(year) { candidates.append(year) }
                digits = ""
            }
        }
        return candidates.first
    }

    // MARK: Arithmetic

    static func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, offset: Int?, timeZone: TimeZone) -> Date {
        let wallClock = daysFromCivil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second
        if let offset {
            return Date(timeIntervalSince1970: TimeInterval(wallClock - offset))
        }
        // The zone's offset depends on the instant; settle it in two steps so a
        // time just after a daylight-saving change lands on the right side.
        let first = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(wallClock)))
        var instant = wallClock - first
        let second = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(instant)))
        if second != first { instant = wallClock - second }
        return Date(timeIntervalSince1970: TimeInterval(instant))
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
    /// `days_from_civil`).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthIndex = (month + 9) % 12
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

/// A tiny cursor over ASCII digits and separators.
private struct DigitScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(_ text: String) {
        bytes = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }

    mutating func number(digits count: Int) -> Int? {
        guard index + count <= bytes.count else { return nil }
        var value = 0
        for byte in bytes[index..<(index + count)] {
            guard byte >= 48, byte <= 57 else { return nil }
            value = value * 10 + Int(byte - 48)
        }
        index += count
        return value
    }

    mutating func digits() -> Int? {
        var value: Int?
        while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
            value = (value ?? 0) * 10 + Int(bytes[index] - 48)
            index += 1
        }
        return value
    }

    mutating func skip(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue, index < bytes.count, bytes[index] == ascii else { return false }
        index += 1
        return true
    }

    /// `Z`, `+01:00`, `-0500`, ` +0000`; nil when there's no offset.
    mutating func offsetSeconds() -> Int? {
        while index < bytes.count, bytes[index] == 32 { index += 1 }
        guard index < bytes.count else { return nil }
        if bytes[index] == 90 || bytes[index] == 122 { // Z, z
            index += 1
            return 0
        }
        guard bytes[index] == 43 || bytes[index] == 45 else { return nil }
        let sign = bytes[index] == 45 ? -1 : 1
        index += 1
        guard let hours = number(digits: 2) else { return nil }
        _ = skip(":")
        let minutes = number(digits: 2) ?? 0
        return sign * (hours * 3600 + minutes * 60)
    }
}
