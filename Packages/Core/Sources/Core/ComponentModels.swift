import Foundation

// The logic behind the components, kept in value types so it can be tested
// (views are untested by policy). Each component reads one of these rather
// than computing in its body.

/// A programme's start and end, and where a moment falls inside it: the
/// progress bar and "18 min left" on a channel card, the guide's on-air cell.
public struct ProgrammeTiming: Hashable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// 0 before the start, 1 at or after the end; 0 for a zero-length slot.
    public func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }

    /// Seconds until the end, never negative.
    public func remaining(at date: Date) -> TimeInterval {
        max(0, end.timeIntervalSince(date))
    }

    /// On air from its start up to (not including) its end.
    public func isOnAir(at date: Date) -> Bool {
        start <= date && date < end
    }

    /// "20:00 – 21:00", for cards.
    public var timeRange: String { HearthFormat.timeRange(start, end) }

    /// "20:00–21:00", for the guide's narrow cells.
    public var compactTimeRange: String { HearthFormat.compactTimeRange(start, end) }
}

/// How many of a source's streams are taken (HH-5, HH-6): the segmented bar
/// under "Provider B   1 of 2" and the Mac sidebar's foot.
public struct StreamUsage: Hashable, Sendable {
    /// Streams playing now, from the provider's own count or the household's
    /// who's-watching rows.
    public var inUse: Int
    /// The source's limit; nil when it has none (an M3U playlist by default).
    public var limit: Int?

    /// Above this many streams the bar is drawn as one continuous track:
    /// segments thinner than a finger stop reading as "slots".
    public static let maxSegments = 8

    public init(inUse: Int, limit: Int?) {
        self.inUse = max(0, inUse)
        self.limit = limit.map { max(0, $0) }
    }

    /// Streams still free; nil when unlimited.
    public var free: Int? { limit.map { max(0, $0 - inUse) } }

    /// Every stream is taken: the next play warns (HH-6).
    public var isFull: Bool { limit.map { inUse >= $0 } ?? false }

    /// More streams than the limit ("Watch anyway" was used).
    public var isOverLimit: Bool { limit.map { inUse > $0 } ?? false }

    /// How full, 0…1; 0 when unlimited.
    public var fraction: Double {
        guard let limit else { return 0 }
        guard limit > 0 else { return inUse > 0 ? 1 : 0 }
        return min(Double(inUse) / Double(limit), 1)
    }

    /// One flag per stream slot, `true` where taken; nil when the source is
    /// unlimited or has more slots than `maxSegments`.
    public var segments: [Bool]? {
        guard let limit, limit > 0, limit <= Self.maxSegments else { return nil }
        return (0..<limit).map { $0 < inUse }
    }

    /// "1 of 2", or "3 in use" without a limit.
    public var countText: String {
        if let limit {
            return String(localized: "\(inUse) of \(limit)", bundle: .module, comment: "Streams in use of the limit: 1 of 2")
        }
        return String(localized: "\(inUse) in use", bundle: .module, comment: "Streams in use on a source with no limit")
    }

    /// "1 of 2 streams in use", for VoiceOver.
    public var spokenText: String {
        if let limit {
            return String(localized: "\(inUse) of \(limit) streams in use", bundle: .module)
        }
        return String(localized: "\(inUse) streams in use, no limit", bundle: .module)
    }
}

/// Which avatars an `AvatarStack` draws and what the "+N" circle says.
public struct AvatarStackLayout: Hashable, Sendable {
    public var visible: Int
    public var overflow: Int

    public init(count: Int, maxVisible: Int) {
        let count = max(0, count)
        let maxVisible = max(1, maxVisible)
        visible = min(count, maxVisible)
        overflow = count - visible
    }
}

/// Text for an episode row: "5. The Lighthouse Keeper".
public enum EpisodeText {
    /// The numbered title. A provider that sends no title gets "Episode 5";
    /// a title that already starts with the number is left alone.
    public static func title(number: Int?, title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number else { return trimmed }
        if trimmed.isEmpty {
            return String(localized: "Episode \(number)", bundle: .module)
        }
        if trimmed.hasPrefix("\(number).") || trimmed.hasPrefix("\(number) ") { return trimmed }
        return "\(number). \(trimmed)"
    }
}

extension EpisodeText {
    /// The line under an episode's title: "51 min · 31 min left",
    /// "47 min · Downloaded", "48 min". A started episode shows what is left
    /// rather than "Downloaded", since resuming is the likelier next step; a
    /// finished one shows only its length (the checkmark says the rest).
    public static func detail(duration: TimeInterval?, remaining: TimeInterval? = nil, isDownloaded: Bool = false) -> String? {
        let parts = detailParts(duration: duration, remaining: remaining, isDownloaded: isDownloaded)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The pieces of `detail` before they are joined, so VoiceOver can join
    /// them with commas instead of "·". Under a minute left reads as
    /// finished rather than "0 min left".
    public static func detailParts(duration: TimeInterval?, remaining: TimeInterval? = nil, isDownloaded: Bool = false) -> [String] {
        var parts: [String] = []
        if let duration, duration > 0 { parts.append(HearthFormat.duration(duration)) }
        if let remaining, remaining >= 60, remaining < (duration ?? .infinity) {
            parts.append(HearthFormat.remaining(remaining))
        } else if isDownloaded {
            parts.append(String(localized: "Downloaded", bundle: .module, comment: "An episode saved on this device"))
        }
        return parts
    }
}

extension ProgrammeTiming {
    /// "18 min left", or nil once it has ended or before it starts.
    public func remainingText(at date: Date) -> String? {
        guard isOnAir(at: date) else { return nil }
        return HearthFormat.remaining(remaining(at: date))
    }
}

/// What VoiceOver says for a channel card or row: one sentence instead of
/// six separate fragments ("101", "Cityline News", "LIVE", …).
public enum ChannelText {
    /// "101 Cityline News", or the name alone when the source sends no
    /// number.
    public static func numberedName(number: Int?, name: String) -> String {
        number.map { "\($0) \(name)" } ?? name
    }

    /// "101 Cityline News. Live: Evening Bulletin, 20:00 – 21:00, 18 min
    /// left." Without a programme (no guide for the channel) it is just the
    /// channel.
    public static func spokenNowPlaying(number: Int?, name: String, programme: String?, timing: ProgrammeTiming?, isLive: Bool, at date: Date) -> String {
        var sentence = numberedName(number: number, name: name)
        guard let programme, !programme.isEmpty else { return sentence }
        let prefix = isLive
            ? String(localized: "Live", bundle: .module, comment: "Spoken before the programme on air now")
            : String(localized: "Now", bundle: .module, comment: "Spoken before the current programme on a channel that is not live")
        sentence += ". \(prefix): \(programme)"
        if let timing {
            sentence += ", \(timing.timeRange)"
            if let left = timing.remainingText(at: date) { sentence += ", \(left)" }
        }
        return sentence
    }
}

extension AvatarStackLayout {
    /// Every name, not just the drawn ones: "Bhavik, Anya and Dad". VoiceOver
    /// has room for the people the "+1" stands for.
    public static func spokenNames(_ names: [String]) -> String {
        names.formatted(.list(type: .and))
    }
}

/// How `SegmentedPills` lays out its segments.
public enum SegmentedPillsLayout {
    /// Up to this many segments share the width equally, as the show
    /// screen's three seasons do; more scroll sideways at their own widths
    /// so "Season 12" never truncates.
    public static let maxEqualSegments = 4

    /// Equal widths for a short list at a non-accessibility text size.
    public static func usesEqualWidths(count: Int, isAccessibilitySize: Bool) -> Bool {
        count <= maxEqualSegments && !isAccessibilitySize
    }
}
