import CatalogKit
import Foundation
import HouseholdKit
import SourceKit

/// Values the library tests build on. Every date is fixed: nothing reads the
/// clock, and `ProgressRecord.updatedAt` is always passed in.
enum Fixture {
    static let sourceA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let sourceB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    static let profile = UUID(uuidString: "00000000-0000-0000-0000-00000000F00D")!

    /// Wednesday 28 October 2026, 20:42 UTC.
    static let now = Date(timeIntervalSince1970: 1_793_220_120)

    static let seriesKey = ItemKey.series(source: sourceA, id: "lighthouse")

    static func episode(_ season: Int, _ number: Int, title: String = "") -> CatalogEpisode {
        CatalogEpisode(
            key: .episode(source: sourceA, seriesID: "lighthouse", season: season, number: number),
            seriesKey: seriesKey,
            sourceID: sourceA,
            remoteID: "\(season)-\(number)",
            season: season,
            number: number,
            title: title,
            plot: nil,
            duration: 2_700,
            posterURL: nil
        )
    }

    /// A progress row for an episode, `minutesAgo` before `now`.
    static func progress(_ episode: CatalogEpisode, position: TimeInterval, duration: TimeInterval = 2_700, watched: Bool = false, minutesAgo: Double) -> ProgressRecord {
        ProgressRecord(
            profileID: profile,
            itemKey: episode.key.rawValue,
            kind: .episode,
            position: position,
            duration: duration,
            watched: watched,
            updatedAt: now.addingTimeInterval(-minutesAgo * 60),
            seriesKey: seriesKey.rawValue,
            season: episode.season,
            episode: episode.number
        )
    }

    /// A row with only a season and episode (for "In this household" and
    /// poster badges), or none (`season: nil`).
    static func row(season: Int?, episode: Int?, position: TimeInterval = 600, duration: TimeInterval = 2_460, watched: Bool = false) -> ProgressRecord {
        ProgressRecord(
            profileID: profile,
            itemKey: "row",
            kind: .episode,
            position: position,
            duration: duration,
            watched: watched,
            updatedAt: now,
            seriesKey: seriesKey.rawValue,
            season: season,
            episode: episode
        )
    }

    static func movieRow(position: TimeInterval, duration: TimeInterval, watched: Bool = false) -> ProgressRecord {
        ProgressRecord(profileID: profile, itemKey: "movie", kind: .movie, position: position, duration: duration, watched: watched, updatedAt: now)
    }

    static func movie(_ id: String = "m1", name: String = "The Long Night", year: Int? = 2024, genre: String? = "Drama", duration: TimeInterval? = 6_720, rating: Double? = 7.4, sourceName: String = "Provider B", addedAt: Date? = nil) -> CatalogMovie {
        CatalogMovie(
            key: .movie(source: sourceA, id: id),
            sourceID: sourceA,
            sourceName: sourceName,
            remoteID: id,
            name: name,
            categoryID: nil,
            posterURL: URL(string: "https://example.com/poster/\(id).jpg"),
            year: year,
            plot: nil,
            rating: rating,
            duration: duration,
            addedAt: addedAt,
            genre: genre,
            cast: nil
        )
    }

    static func series(_ id: String = "s1", name: String = "Lighthouse", year: Int? = 2024, genre: String? = "Drama", rating: Double? = nil, sourceName: String = "Provider B") -> CatalogSeries {
        CatalogSeries(
            key: .series(source: sourceA, id: id),
            sourceID: sourceA,
            sourceName: sourceName,
            remoteID: id,
            name: name,
            categoryID: nil,
            posterURL: nil,
            plot: nil,
            year: year,
            rating: rating,
            addedAt: nil,
            genre: genre
        )
    }

    static func category(_ remoteID: String, name: String, source: UUID = sourceA, sortOrder: Int = 0) -> CatalogCategory {
        CatalogCategory(
            id: CategoryKey.make(source: source, kind: "vod", remoteID: remoteID),
            sourceID: source,
            remoteID: remoteID,
            kind: .vod,
            name: name,
            sortOrder: sortOrder,
            isAdult: false
        )
    }
}
