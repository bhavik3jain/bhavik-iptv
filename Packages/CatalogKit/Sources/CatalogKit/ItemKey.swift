import Foundation

/// The stable key a favorite, a My List entry or a progress row points at
/// (FAV-2, Source protocols → Stable ids). Every key starts with the source's
/// UUID; stream URLs never go in a key.
///
/// Format: `<sourceUUID>/<kind>/<id>` and, for episodes,
/// `<sourceUUID>/episode/<seriesID>/<season>/<number>` — keyed by season and
/// number, never the provider's episode id, which some reissue.
public struct ItemKey: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible, Identifiable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }
    public var description: String { rawValue }

    public static func channel(source: UUID, id: String) -> ItemKey {
        ItemKey(rawValue: "\(source.uuidString)/\(ItemKind.channel.rawValue)/\(escape(id))")
    }

    public static func movie(source: UUID, id: String) -> ItemKey {
        ItemKey(rawValue: "\(source.uuidString)/\(ItemKind.movie.rawValue)/\(escape(id))")
    }

    public static func series(source: UUID, id: String) -> ItemKey {
        ItemKey(rawValue: "\(source.uuidString)/\(ItemKind.series.rawValue)/\(escape(id))")
    }

    public static func episode(source: UUID, seriesID: String, season: Int, number: Int) -> ItemKey {
        ItemKey(rawValue: "\(source.uuidString)/\(ItemKind.episode.rawValue)/\(escape(seriesID))/\(season)/\(number)")
    }

    private var parts: [Substring] { rawValue.split(separator: "/", omittingEmptySubsequences: false) }

    public var sourceID: UUID? { parts.first.flatMap { UUID(uuidString: String($0)) } }

    public var kind: ItemKind? { parts.count > 1 ? ItemKind(rawValue: String(parts[1])) : nil }

    /// The provider id (for an episode, the series id).
    public var remoteID: String? { parts.count > 2 ? ItemKey.unescape(String(parts[2])) : nil }

    /// For an episode: its series' key.
    public var seriesKey: ItemKey? {
        guard kind == .episode, let sourceID, let remoteID else { return nil }
        return .series(source: sourceID, id: remoteID)
    }

    /// For an episode: season and number.
    public var seasonAndEpisode: (season: Int, number: Int)? {
        guard kind == .episode, parts.count == 5, let season = Int(parts[3]), let number = Int(parts[4]) else { return nil }
        return (season, number)
    }

    /// Ids can hold "/" (M3U names, some Stalker ids); escape it so the
    /// key still splits cleanly.
    private static func escape(_ id: String) -> String {
        id.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "/", with: "%2F")
    }

    private static func unescape(_ id: String) -> String {
        id.replacingOccurrences(of: "%2F", with: "/").replacingOccurrences(of: "%25", with: "%")
    }
}

public enum ItemKind: String, Sendable, Codable, Hashable, CaseIterable {
    case channel
    case movie
    case series
    case episode
}

/// The key a category's allow and hide rules use (PRF-6, PAR-1):
/// `<sourceUUID>/<live|vod|series>/<remoteID>`. Also `CatalogCategory.id`.
public enum CategoryKey {
    public static func make(source: UUID, kind: String, remoteID: String) -> String {
        "\(source.uuidString)/\(kind)/\(remoteID)"
    }
}
