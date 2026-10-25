import Foundation

/// Times and durations as the mockups write them.
public enum HearthFormat {
    /// "20:00", in the device's time zone and 24- or 12-hour per locale.
    public static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "20:00 – 21:00".
    public static func timeRange(_ start: Date, _ end: Date) -> String {
        "\(clock(start)) – \(clock(end))"
    }

    /// "31 min left", "1 h 5 min left".
    public static func remaining(_ seconds: TimeInterval) -> String {
        "\(duration(seconds)) left"
    }

    /// "48 min", "1 h 5 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// "-4:12" for a position behind live, "1:02:03" for a long one.
    public static func timecode(_ seconds: TimeInterval, signed: Bool = false) -> String {
        let total = Int(abs(seconds).rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let body = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        return signed && seconds < 0 ? "-" + body : body
    }

    /// "S2 · E5".
    public static func episodeCode(season: Int, episode: Int) -> String {
        "S\(season) · E\(episode)"
    }

    /// "20:00–21:00", without spaces, for the guide's narrow programme cells.
    public static func compactTimeRange(_ start: Date, _ end: Date) -> String {
        "\(clock(start))–\(clock(end))"
    }

    /// `timecode` set for display: a true minus sign ("−4:12") rather than a
    /// hyphen, as in the player mockup.
    public static func displayTimecode(_ seconds: TimeInterval, signed: Bool = false) -> String {
        let code = timecode(seconds, signed: signed)
        return code.hasPrefix("-") ? "\u{2212}" + code.dropFirst() : code
    }

    /// "4 minutes, 12 seconds": a duration as VoiceOver should say it, where
    /// "4:12" would be read as a time of day.
    public static func spokenDuration(_ seconds: TimeInterval) -> String {
        let whole = Int(abs(seconds).rounded())
        let units: Set<Duration.UnitsFormatStyle.Unit> = whole >= 3600 ? [.hours, .minutes] : [.minutes, .seconds]
        return Duration.seconds(whole).formatted(.units(allowed: units, width: .wide))
    }
}
