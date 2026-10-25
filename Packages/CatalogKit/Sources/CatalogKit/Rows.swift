import CoreData
import Foundation
import SourceKit

// The two translations every row goes through: SourceKit's remote values
// into batch-insert dictionaries on the way in, and rows back into the
// catalog's public values (or SourceKit requests, for a stream link) on the
// way out. Kept together so a new attribute is added in one file.

// MARK: - Remote values → rows

enum RowWriter {
    static func category(_ category: RemoteCategory, sourceID: UUID, generation: Int64) -> [String: Any] {
        [
            "sourceID": sourceID,
            "generation": generation,
            "remoteID": category.id,
            "kindRaw": category.kind.rawValue,
            "categoryKey": CategoryKey.make(source: sourceID, kind: category.kind.rawValue, remoteID: category.id),
            "name": category.name,
            "sortOrder": Int64(category.sortOrder),
            "isAdult": AdultContent.matches(category.name),
        ]
    }

    static func channel(_ channel: RemoteChannel, position: Int, sourceID: UUID, generation: Int64) -> [String: Any] {
        var row: [String: Any] = [
            "sourceID": sourceID,
            "generation": generation,
            "remoteID": channel.id,
            "stableKey": ItemKey.channel(source: sourceID, id: channel.id).rawValue,
            "sortNumber": channel.number.map { Int64($0) } ?? Int64.max,
            "name": channel.name,
            "searchKey": SearchKey.normalize(channel.name),
            "guideKey": channel.guideChannelID ?? channel.id,
            "hasArchive": channel.hasArchive,
            "archiveDays": Int64(channel.archiveDays),
            "command": channel.command,
            "formatHintRaw": channel.formatHint.rawValue,
            "position": Int64(position),
        ]
        if let number = channel.number {
            row["number"] = Int64(number)
            row["numberText"] = String(number)
        }
        row["logoURL"] = channel.logoURL?.absoluteString
        if let categoryID = channel.categoryID {
            row["remoteCategoryID"] = categoryID
            row["categoryID"] = CategoryKey.make(source: sourceID, kind: ContentKind.live.rawValue, remoteID: categoryID)
        }
        row["guideChannelID"] = channel.guideChannelID
        row["headersJSON"] = encodeHeaders(channel.headers)
        row["catchupMode"] = channel.catchupMode
        row["catchupSource"] = channel.catchupSource
        return row
    }

    static func programme(_ programme: RemoteProgramme, guideKey: String? = nil, sourceID: UUID, generation: Int64) -> [String: Any] {
        var row: [String: Any] = [
            "sourceID": sourceID,
            "generation": generation,
            "guideChannelID": guideKey ?? programme.guideChannelID,
            "start": programme.start,
            "end": programme.end,
            "title": programme.title,
            "searchKey": SearchKey.normalize(programme.title),
            "hasArchive": programme.hasArchive,
        ]
        row["summary"] = programme.summary
        row["category"] = programme.category
        return row
    }

    static func movie(_ movie: RemoteMovie, position: Int, sourceID: UUID, generation: Int64) -> [String: Any] {
        var row: [String: Any] = [
            "sourceID": sourceID,
            "generation": generation,
            "remoteID": movie.id,
            "stableKey": ItemKey.movie(source: sourceID, id: movie.id).rawValue,
            "name": movie.name,
            "searchKey": SearchKey.normalize(movie.name),
            "position": Int64(position),
        ]
        if let categoryID = movie.categoryID {
            row["remoteCategoryID"] = categoryID
            row["categoryID"] = CategoryKey.make(source: sourceID, kind: ContentKind.vod.rawValue, remoteID: categoryID)
        }
        row["posterURL"] = movie.posterURL?.absoluteString
        row["year"] = movie.year.map { Int64($0) }
        row["plot"] = movie.plot
        row["rating"] = movie.rating
        row["duration"] = movie.durationSeconds.map { Double($0) }
        row["containerExtension"] = movie.containerExtension
        row["addedAt"] = movie.addedAt
        row["genre"] = movie.genre
        row["cast"] = movie.cast
        row["director"] = movie.director
        row["command"] = movie.command
        return row
    }

    static func series(_ series: RemoteSeries, position: Int, sourceID: UUID, generation: Int64) -> [String: Any] {
        var row: [String: Any] = [
            "sourceID": sourceID,
            "generation": generation,
            "remoteID": series.id,
            "stableKey": ItemKey.series(source: sourceID, id: series.id).rawValue,
            "name": series.name,
            "searchKey": SearchKey.normalize(series.name),
            "position": Int64(position),
        ]
        if let categoryID = series.categoryID {
            row["remoteCategoryID"] = categoryID
            row["categoryID"] = CategoryKey.make(source: sourceID, kind: ContentKind.series.rawValue, remoteID: categoryID)
        }
        row["posterURL"] = series.posterURL?.absoluteString
        row["plot"] = series.plot
        row["year"] = series.year.map { Int64($0) }
        row["rating"] = series.rating
        row["addedAt"] = series.addedAt
        row["genre"] = series.genre
        row["cast"] = series.cast
        row["command"] = series.command
        return row
    }

    static func episode(_ episode: RemoteEpisode, season: RemoteSeason?, seriesID: String, sourceID: UUID, fetchedAt: Date) -> [String: Any] {
        var row: [String: Any] = [
            "sourceID": sourceID,
            "seriesID": seriesID,
            "remoteID": episode.id,
            "stableKey": ItemKey.episode(source: sourceID, seriesID: seriesID, season: episode.season, number: episode.number).rawValue,
            "season": Int64(episode.season),
            "number": Int64(episode.number),
            "title": episode.title,
            "fetchedAt": fetchedAt,
        ]
        row["plot"] = episode.plot
        row["duration"] = episode.durationSeconds.map { Double($0) }
        row["containerExtension"] = episode.containerExtension
        row["posterURL"] = episode.posterURL?.absoluteString
        row["command"] = episode.command
        row["seasonRemoteID"] = season?.remoteID
        row["seasonName"] = season?.name
        return row
    }

    static func removedItem(stableKey: String, kind: ItemKind, nameKey: String, sourceID: UUID, removedAt: Date) -> [String: Any] {
        [
            "sourceID": sourceID,
            "kindRaw": kind.rawValue,
            "stableKey": stableKey,
            "nameKey": nameKey,
            "removedAt": removedAt,
        ]
    }

    static func encodeHeaders(_ headers: [String: String]) -> String? {
        guard !headers.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(headers)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decodeHeaders(_ json: String?) -> [String: String] {
        guard let data = json?.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

// MARK: - Rows → values

extension NSManagedObject {
    func string(_ key: String) -> String { value(forKey: key) as? String ?? "" }
    func optionalString(_ key: String) -> String? { value(forKey: key) as? String }
    func int(_ key: String) -> Int { (value(forKey: key) as? NSNumber)?.intValue ?? 0 }
    func optionalInt(_ key: String) -> Int? { (value(forKey: key) as? NSNumber)?.intValue }
    func int64(_ key: String) -> Int64 { (value(forKey: key) as? NSNumber)?.int64Value ?? 0 }
    func optionalDouble(_ key: String) -> Double? { (value(forKey: key) as? NSNumber)?.doubleValue }
    func bool(_ key: String) -> Bool { (value(forKey: key) as? NSNumber)?.boolValue ?? false }
    func date(_ key: String) -> Date { value(forKey: key) as? Date ?? .distantPast }
    func optionalDate(_ key: String) -> Date? { value(forKey: key) as? Date }
    func uuid(_ key: String) -> UUID? { value(forKey: key) as? UUID }
    func url(_ key: String) -> URL? { optionalString(key).flatMap { URL(string: $0) } }
}

enum RowReader {
    static func category(_ row: NSManagedObject, householdAdultIDs: Set<String>) -> CatalogCategory? {
        guard let sourceID = row.uuid("sourceID"), let kind = ContentKind(rawValue: row.string("kindRaw")) else { return nil }
        let id = row.string("categoryKey")
        return CatalogCategory(
            id: id,
            sourceID: sourceID,
            remoteID: row.string("remoteID"),
            kind: kind,
            name: row.string("name"),
            sortOrder: row.int("sortOrder"),
            isAdult: row.bool("isAdult") || householdAdultIDs.contains(id)
        )
    }

    static func channel(_ row: NSManagedObject, sourceName: String) -> CatalogChannel? {
        guard let sourceID = row.uuid("sourceID") else { return nil }
        return CatalogChannel(
            key: ItemKey(rawValue: row.string("stableKey")),
            sourceID: sourceID,
            sourceName: sourceName,
            remoteID: row.string("remoteID"),
            number: row.optionalInt("number"),
            name: row.string("name"),
            logoURL: row.url("logoURL"),
            categoryID: row.optionalString("categoryID"),
            guideChannelID: row.optionalString("guideChannelID"),
            hasArchive: row.bool("hasArchive"),
            archiveDays: row.int("archiveDays")
        )
    }

    static func remoteChannel(_ row: NSManagedObject) -> RemoteChannel {
        RemoteChannel(
            id: row.string("remoteID"),
            number: row.optionalInt("number"),
            name: row.string("name"),
            logoURL: row.url("logoURL"),
            categoryID: row.optionalString("remoteCategoryID"),
            guideChannelID: row.optionalString("guideChannelID"),
            hasArchive: row.bool("hasArchive"),
            archiveDays: row.int("archiveDays"),
            command: row.string("command"),
            formatHint: StreamFormatHint(rawValue: row.string("formatHintRaw")) ?? .unknown,
            headers: RowWriter.decodeHeaders(row.optionalString("headersJSON")),
            catchupMode: row.optionalString("catchupMode"),
            catchupSource: row.optionalString("catchupSource")
        )
    }

    static func programme(_ row: NSManagedObject, archive: ArchiveWindow?, now: Date) -> CatalogProgramme? {
        guard let sourceID = row.uuid("sourceID") else { return nil }
        let guideChannelID = row.string("guideChannelID")
        let start = row.date("start")
        let providerFlag = row.bool("hasArchive")
        return CatalogProgramme(
            id: ProgrammeID.make(sourceID: sourceID, guideChannelID: guideChannelID, start: start),
            sourceID: sourceID,
            guideChannelID: guideChannelID,
            start: start,
            end: row.date("end"),
            title: row.string("title"),
            summary: row.optionalString("summary"),
            category: row.optionalString("category"),
            hasArchive: ArchiveRule.isPlayable(start: start, providerFlag: providerFlag, window: archive, now: now)
        )
    }

    static func movie(_ row: NSManagedObject, sourceName: String) -> CatalogMovie? {
        guard let sourceID = row.uuid("sourceID") else { return nil }
        return CatalogMovie(
            key: ItemKey(rawValue: row.string("stableKey")),
            sourceID: sourceID,
            sourceName: sourceName,
            remoteID: row.string("remoteID"),
            name: row.string("name"),
            categoryID: row.optionalString("categoryID"),
            posterURL: row.url("posterURL"),
            year: row.optionalInt("year"),
            plot: row.optionalString("plot"),
            rating: row.optionalDouble("rating"),
            duration: row.optionalDouble("duration"),
            addedAt: row.optionalDate("addedAt"),
            genre: row.optionalString("genre"),
            cast: row.optionalString("cast")
        )
    }

    static func remoteMovie(_ row: NSManagedObject) -> RemoteMovie {
        RemoteMovie(
            id: row.string("remoteID"),
            name: row.string("name"),
            categoryID: row.optionalString("remoteCategoryID"),
            posterURL: row.url("posterURL"),
            year: row.optionalInt("year"),
            plot: row.optionalString("plot"),
            rating: row.optionalDouble("rating"),
            durationSeconds: row.optionalDouble("duration").map { Int($0) },
            containerExtension: row.optionalString("containerExtension"),
            addedAt: row.optionalDate("addedAt"),
            genre: row.optionalString("genre"),
            cast: row.optionalString("cast"),
            director: row.optionalString("director"),
            command: row.optionalString("command")
        )
    }

    static func series(_ row: NSManagedObject, sourceName: String) -> CatalogSeries? {
        guard let sourceID = row.uuid("sourceID") else { return nil }
        return CatalogSeries(
            key: ItemKey(rawValue: row.string("stableKey")),
            sourceID: sourceID,
            sourceName: sourceName,
            remoteID: row.string("remoteID"),
            name: row.string("name"),
            categoryID: row.optionalString("categoryID"),
            posterURL: row.url("posterURL"),
            plot: row.optionalString("plot"),
            year: row.optionalInt("year"),
            rating: row.optionalDouble("rating"),
            addedAt: row.optionalDate("addedAt"),
            genre: row.optionalString("genre")
        )
    }

    static func remoteSeries(_ row: NSManagedObject) -> RemoteSeries {
        RemoteSeries(
            id: row.string("remoteID"),
            name: row.string("name"),
            categoryID: row.optionalString("remoteCategoryID"),
            posterURL: row.url("posterURL"),
            plot: row.optionalString("plot"),
            year: row.optionalInt("year"),
            rating: row.optionalDouble("rating"),
            addedAt: row.optionalDate("addedAt"),
            genre: row.optionalString("genre"),
            cast: row.optionalString("cast"),
            command: row.optionalString("command")
        )
    }

    static func episode(_ row: NSManagedObject) -> CatalogEpisode? {
        guard let sourceID = row.uuid("sourceID") else { return nil }
        let seriesID = row.string("seriesID")
        return CatalogEpisode(
            key: ItemKey(rawValue: row.string("stableKey")),
            seriesKey: .series(source: sourceID, id: seriesID),
            sourceID: sourceID,
            remoteID: row.string("remoteID"),
            season: row.int("season"),
            number: row.int("number"),
            title: row.string("title"),
            plot: row.optionalString("plot"),
            duration: row.optionalDouble("duration"),
            posterURL: row.url("posterURL")
        )
    }

    static func remoteEpisode(_ row: NSManagedObject) -> RemoteEpisode {
        RemoteEpisode(
            id: row.string("remoteID"),
            seriesID: row.string("seriesID"),
            season: row.int("season"),
            number: row.int("number"),
            title: row.string("title"),
            plot: row.optionalString("plot"),
            durationSeconds: row.optionalDouble("duration").map { Int($0) },
            containerExtension: row.optionalString("containerExtension"),
            posterURL: row.url("posterURL"),
            command: row.optionalString("command")
        )
    }
}

// MARK: - Small rules

/// `CatalogProgramme.id`: source, guide channel and start, which a refresh
/// reproduces exactly.
enum ProgrammeID {
    static func make(sourceID: UUID, guideChannelID: String, start: Date) -> String {
        "\(sourceID.uuidString)/\(guideChannelID)/\(Int64(start.timeIntervalSince1970))"
    }
}

/// What a channel says about its archive, for `CatalogProgramme.hasArchive`.
struct ArchiveWindow: Sendable, Hashable {
    var hasArchive: Bool
    var days: Int

    init(hasArchive: Bool, days: Int) {
        self.hasArchive = hasArchive
        self.days = days
    }

    init(_ channel: CatalogChannel) {
        self.init(hasArchive: channel.hasArchive, days: channel.archiveDays)
    }
}

/// LIV-4: a programme can be played from the archive when the channel (or
/// the provider, per programme) says so, it has started, and it began inside
/// the archive window.
enum ArchiveRule {
    /// Stalker flags an archive without saying how deep; the guide itself
    /// is only kept 7 days back, so that is the most it could offer.
    static let assumedDays = 7

    static func isPlayable(start: Date, providerFlag: Bool, window: ArchiveWindow?, now: Date) -> Bool {
        guard start <= now else { return false }
        let channelHasArchive = window?.hasArchive ?? false
        guard channelHasArchive || providerFlag else { return false }
        let days = window.map(\.days).flatMap { $0 > 0 ? $0 : nil } ?? assumedDays
        return start >= now.addingTimeInterval(-Double(days) * 86_400)
    }
}

/// `SourceState` as the main actor keeps it: the live generations every
/// query is scoped to, plus what the Household screen shows at launch.
struct PersistedSourceState: Sendable, Hashable {
    var generation: Int64 = 0
    var guideGeneration: Int64 = 0
    var catalogRefreshedAt: Date?
    var guideRefreshedAt: Date?
    var account: AccountInfo?
    var channelCount = 0
    var movieCount = 0
    var seriesCount = 0

    init() {}

    init(row: NSManagedObject) {
        generation = row.int64("generation")
        guideGeneration = row.int64("guideGeneration")
        catalogRefreshedAt = row.optionalDate("catalogRefreshedAt")
        guideRefreshedAt = row.optionalDate("guideRefreshedAt")
        account = (row.value(forKey: "accountJSON") as? Data).flatMap { try? JSONDecoder().decode(AccountInfo.self, from: $0) }
        channelCount = row.int("channelCount")
        movieCount = row.int("movieCount")
        seriesCount = row.int("seriesCount")
    }

    var hasCatalog: Bool { generation > 0 }
    var totalItems: Int { channelCount + movieCount + seriesCount }
}
