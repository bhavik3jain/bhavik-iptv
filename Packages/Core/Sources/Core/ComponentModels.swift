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
