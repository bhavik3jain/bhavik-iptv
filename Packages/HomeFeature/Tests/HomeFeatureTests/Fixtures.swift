import CatalogKit
import Foundation
import HouseholdKit

/// Small builders for the catalog and household values Home's logic reads.
/// Every date is fixed, so nothing here depends on the clock.
enum Fixture {
    static let source = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let profile = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    static let reference = Date(timeIntervalSince1970: 1_800_000_000)

    static let seriesPoster = URL(string: "https://example.com/show.jpg")!
    static let stillA = URL(string: "https://example.com/still-a.jpg")!

    static func seriesKey(_ id: String = "show") -> ItemKey {
        .series(source: source, id: id)
    }

    static func series(_ id: String = "show", name: String = "The Lighthouse", poster: URL? = seriesPoster, addedAt: Date? = nil) -> CatalogSeries {
        CatalogSeries(
            key: seriesKey(id), sourceID: source, sourceName: "Provider A", remoteID: id, name: name,
            categoryID: nil, posterURL: poster, plot: nil, year: 2021, rating: nil, addedAt: addedAt, genre: nil
        )
    }

    static func episodeKey(series: String = "show", _ season: Int, _ number: Int) -> ItemKey {
        .episode(source: source, seriesID: series, season: season, number: number)
    }

    static func episode(series: String = "show", _ season: Int, _ number: Int, title: String = "", duration: TimeInterval? = nil, poster: URL? = nil) -> CatalogEpisode {
        CatalogEpisode(
            key: episodeKey(series: series, season, number), seriesKey: seriesKey(series), sourceID: source,
            remoteID: "\(series)-\(season)-\(number)", season: season, number: number, title: title,
            plot: nil, duration: duration, posterURL: poster
        )
    }

    static func movie(_ id: String = "film", name: String = "Harbour Lights", year: Int? = 2019, genre: String? = "Drama", duration: TimeInterval? = nil, poster: URL? = nil) -> CatalogMovie {
        CatalogMovie(
            key: .movie(source: source, id: id), sourceID: source, sourceName: "Provider A", remoteID: id, name: name,
            categoryID: nil, posterURL: poster, year: year, plot: nil, rating: nil, duration: duration,
            addedAt: nil, genre: genre, cast: nil
        )
    }

    static func movieProgress(_ id: String = "film", position: TimeInterval, duration: TimeInterval, watched: Bool = false) -> ProgressRecord {
        ProgressRecord(
            profileID: profile, itemKey: ItemKey.movie(source: source, id: id).rawValue, kind: .movie,
            position: position, duration: duration, watched: watched, updatedAt: reference
        )
    }

    /// A progress row for an episode, with the season and number on the row
    /// (as the app writes them) unless `codeOnRow` is false.
    static func episodeProgress(series: String = "show", _ season: Int, _ number: Int, position: TimeInterval = 600, duration: TimeInterval = 2400, watched: Bool = false, updatedAt: Date = reference, codeOnRow: Bool = true) -> ProgressRecord {
        ProgressRecord(
            profileID: profile, itemKey: episodeKey(series: series, season, number).rawValue, kind: .episode,
            position: position, duration: duration, watched: watched, updatedAt: updatedAt,
            seriesKey: seriesKey(series).rawValue,
            season: codeOnRow ? season : nil, episode: codeOnRow ? number : nil
        )
    }
}
