import Foundation
import SourceKit

// What the catalog hands to screens: plain values read from the local store.
// Additive changes only — every feature package compiles against these.

public struct CatalogCategory: Identifiable, Hashable, Sendable {
    /// `CategoryKey.make(source:kind:remoteID:)` — also the key profile rules use.
    public var id: String
    public var sourceID: UUID
    public var remoteID: String
    public var kind: ContentKind
    public var name: String
    public var sortOrder: Int
    /// Matched by name ("adult", "xxx", "18+") or marked by the household (PAR-1).
    public var isAdult: Bool

    public init(id: String, sourceID: UUID, remoteID: String, kind: ContentKind, name: String, sortOrder: Int, isAdult: Bool) {
        self.id = id
        self.sourceID = sourceID
        self.remoteID = remoteID
        self.kind = kind
        self.name = name
        self.sortOrder = sortOrder
        self.isAdult = isAdult
    }
}

public struct CatalogChannel: Identifiable, Hashable, Sendable {
    public var key: ItemKey
    public var id: ItemKey { key }
    public var sourceID: UUID
    /// The source's display name, for "from Provider B" labels (SRC-7).
    public var sourceName: String
    public var remoteID: String
    public var number: Int?
    public var name: String
    public var logoURL: URL?
    /// `CatalogCategory.id`, or nil.
    public var categoryID: String?
    public var guideChannelID: String?
    public var hasArchive: Bool
    public var archiveDays: Int

    public init(key: ItemKey, sourceID: UUID, sourceName: String, remoteID: String, number: Int?, name: String, logoURL: URL?, categoryID: String?, guideChannelID: String?, hasArchive: Bool, archiveDays: Int) {
        self.key = key
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.remoteID = remoteID
        self.number = number
        self.name = name
        self.logoURL = logoURL
        self.categoryID = categoryID
        self.guideChannelID = guideChannelID
        self.hasArchive = hasArchive
        self.archiveDays = archiveDays
    }
}

public struct CatalogProgramme: Identifiable, Hashable, Sendable {
    /// Stable for the programme: source, guide channel and start.
    public var id: String
    public var sourceID: UUID
    public var guideChannelID: String
    public var start: Date
    public var end: Date
    public var title: String
    public var summary: String?
    public var category: String?
    /// Can be played from the archive (LIV-4): the channel has one, the
    /// programme has started, and it is inside the archive window.
    public var hasArchive: Bool

    public init(id: String, sourceID: UUID, guideChannelID: String, start: Date, end: Date, title: String, summary: String?, category: String?, hasArchive: Bool) {
        self.id = id
        self.sourceID = sourceID
        self.guideChannelID = guideChannelID
        self.start = start
        self.end = end
        self.title = title
        self.summary = summary
        self.category = category
        self.hasArchive = hasArchive
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public func isOn(at date: Date) -> Bool { start <= date && date < end }

    /// 0…1 through the programme at `date`.
    public func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }
}

public struct CatalogMovie: Identifiable, Hashable, Sendable {
    public var key: ItemKey
    public var id: ItemKey { key }
    public var sourceID: UUID
    public var sourceName: String
    public var remoteID: String
    public var name: String
    public var categoryID: String?
    public var posterURL: URL?
    public var year: Int?
    public var plot: String?
    public var rating: Double?
    public var duration: TimeInterval?
    public var addedAt: Date?
    public var genre: String?
    public var cast: String?

    public init(key: ItemKey, sourceID: UUID, sourceName: String, remoteID: String, name: String, categoryID: String?, posterURL: URL?, year: Int?, plot: String?, rating: Double?, duration: TimeInterval?, addedAt: Date?, genre: String?, cast: String?) {
        self.key = key
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.remoteID = remoteID
        self.name = name
        self.categoryID = categoryID
        self.posterURL = posterURL
        self.year = year
        self.plot = plot
        self.rating = rating
        self.duration = duration
        self.addedAt = addedAt
        self.genre = genre
        self.cast = cast
    }
}

public struct CatalogSeries: Identifiable, Hashable, Sendable {
    public var key: ItemKey
    public var id: ItemKey { key }
    public var sourceID: UUID
    public var sourceName: String
    public var remoteID: String
    public var name: String
    public var categoryID: String?
    public var posterURL: URL?
    public var plot: String?
    public var year: Int?
    public var rating: Double?
    public var addedAt: Date?
    public var genre: String?

    public init(key: ItemKey, sourceID: UUID, sourceName: String, remoteID: String, name: String, categoryID: String?, posterURL: URL?, plot: String?, year: Int?, rating: Double?, addedAt: Date?, genre: String?) {
        self.key = key
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.remoteID = remoteID
        self.name = name
        self.categoryID = categoryID
        self.posterURL = posterURL
        self.plot = plot
        self.year = year
        self.rating = rating
        self.addedAt = addedAt
        self.genre = genre
    }
}

public struct CatalogEpisode: Identifiable, Hashable, Sendable {
    /// `ItemKey.episode(source:seriesID:season:number:)`.
    public var key: ItemKey
    public var id: ItemKey { key }
    public var seriesKey: ItemKey
    public var sourceID: UUID
    public var remoteID: String
    public var season: Int
    public var number: Int
    public var title: String
    public var plot: String?
    public var duration: TimeInterval?
    public var posterURL: URL?

    public init(key: ItemKey, seriesKey: ItemKey, sourceID: UUID, remoteID: String, season: Int, number: Int, title: String, plot: String?, duration: TimeInterval?, posterURL: URL?) {
        self.key = key
        self.seriesKey = seriesKey
        self.sourceID = sourceID
        self.remoteID = remoteID
        self.season = season
        self.number = number
        self.title = title
        self.plot = plot
        self.duration = duration
        self.posterURL = posterURL
    }
}

public enum CatalogSort: String, Sendable, CaseIterable, Hashable {
    case dateAdded
    case name
    case year
}

/// One search across everything on the device (SRCH-1, SRCH-2).
public struct SearchResults: Sendable, Hashable {
    public struct ProgrammeHit: Sendable, Hashable, Identifiable {
        public var programme: CatalogProgramme
        public var channel: CatalogChannel
        public var id: String { programme.id }

        public init(programme: CatalogProgramme, channel: CatalogChannel) {
            self.programme = programme
            self.channel = channel
        }
    }

    public var channels: [CatalogChannel]
    /// The next 24 hours of the guide.
    public var programmes: [ProgrammeHit]
    public var movies: [CatalogMovie]
    public var series: [CatalogSeries]

    public init(channels: [CatalogChannel] = [], programmes: [ProgrammeHit] = [], movies: [CatalogMovie] = [], series: [CatalogSeries] = []) {
        self.channels = channels
        self.programmes = programmes
        self.movies = movies
        self.series = series
    }

    public var isEmpty: Bool { channels.isEmpty && programmes.isEmpty && movies.isEmpty && series.isEmpty }
}

/// What the current profile may see (PRF-4, PRF-6, LIV-8, PAR-1, SRCH-3).
/// The app sets `CatalogService.filter` whenever the profile changes; every
/// query applies it unless told not to.
public struct CatalogFilter: Sendable, Hashable {
    /// Nil shows every source; otherwise only these.
    public var visibleSourceIDs: Set<UUID>?
    /// Nil allows every category; a Kids profile sets only its allowed ones.
    public var allowedCategoryIDs: Set<String>?
    /// Categories this profile hides.
    public var hiddenCategoryIDs: Set<String>
    /// Hide categories matched as adult and those in `adultCategoryIDs`.
    public var hidesAdult: Bool
    /// Categories the household marked adult, beyond the name match.
    public var adultCategoryIDs: Set<String>

    public init(visibleSourceIDs: Set<UUID>? = nil, allowedCategoryIDs: Set<String>? = nil, hiddenCategoryIDs: Set<String> = [], hidesAdult: Bool = true, adultCategoryIDs: Set<String> = []) {
        self.visibleSourceIDs = visibleSourceIDs
        self.allowedCategoryIDs = allowedCategoryIDs
        self.hiddenCategoryIDs = hiddenCategoryIDs
        self.hidesAdult = hidesAdult
        self.adultCategoryIDs = adultCategoryIDs
    }

    /// Shows everything, adult included: the owner's rule editors.
    public static let unrestricted = CatalogFilter(hidesAdult: false)
}

/// Where a source's refresh stands, for the Household screen (SRC-5).
public struct SourceRefreshState: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        case idle
        /// `progress` 0…1 when known.
        case refreshing(progress: Double?, message: String)
        case failed(message: String)
    }

    public var sourceID: UUID
    public var phase: Phase
    public var account: AccountInfo?
    public var catalogRefreshedAt: Date?
    public var guideRefreshedAt: Date?
    public var channelCount: Int
    public var movieCount: Int
    public var seriesCount: Int

    public init(sourceID: UUID, phase: Phase = .idle, account: AccountInfo? = nil, catalogRefreshedAt: Date? = nil, guideRefreshedAt: Date? = nil, channelCount: Int = 0, movieCount: Int = 0, seriesCount: Int = 0) {
        self.sourceID = sourceID
        self.phase = phase
        self.account = account
        self.catalogRefreshedAt = catalogRefreshedAt
        self.guideRefreshedAt = guideRefreshedAt
        self.channelCount = channelCount
        self.movieCount = movieCount
        self.seriesCount = seriesCount
    }
}

/// The outcome of "Test" in the source editor (SRC-4).
public struct SourceTestResult: Sendable, Hashable {
    public var succeeded: Bool
    public var account: AccountInfo?
    public var channelCount: Int?
    public var movieCount: Int?
    public var seriesCount: Int?
    /// The provider's own error text on failure.
    public var message: String?
    /// Each step and how long it took, logins masked.
    public var steps: [String]

    public init(succeeded: Bool, account: AccountInfo? = nil, channelCount: Int? = nil, movieCount: Int? = nil, seriesCount: Int? = nil, message: String? = nil, steps: [String] = []) {
        self.succeeded = succeeded
        self.account = account
        self.channelCount = channelCount
        self.movieCount = movieCount
        self.seriesCount = seriesCount
        self.message = message
        self.steps = steps
    }
}
