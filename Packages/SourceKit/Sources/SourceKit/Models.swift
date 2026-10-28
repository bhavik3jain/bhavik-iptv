import Foundation

// SourceKit's public vocabulary. Every type here is a plain Sendable value, so
// CatalogKit can import them on a background context and tests can build them
// by hand. Changes to this file are additive only: CatalogKit, the household
// feature and the app all compile against it.

public enum SourceKind: String, Sendable, Codable, CaseIterable, Hashable {
    case stalker
    case xtream
    case m3u
}

/// One provider login, as the app hands it to SourceKit. Built from the
/// household's encrypted Source record; never logged, printed or written to a
/// fixture (PRIV-2) — use `redacted` for anything that leaves memory.
public struct SourceConfiguration: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: SourceKind
    /// Stalker: the portal URL as typed (often ending `/c/`). Xtream: the
    /// server URL. M3U: unused.
    public var serverURL: String
    /// Stalker: `00:1A:79:XX:XX:XX`.
    public var macAddress: String
    /// Xtream, and Stalker portals that need `do_auth`.
    public var username: String
    public var password: String
    /// M3U: the playlist URL, or a `file://` URL to a copy in the app's container.
    public var playlistURL: String
    /// M3U and Xtream: an XMLTV guide URL that overrides the playlist header.
    public var guideURL: String
    // Stalker advanced fields (SRC-1). Empty means "use the default".
    public var serialNumber: String
    public var deviceID: String
    public var deviceID2: String
    public var signature: String
    /// Box model sent as `stb_type` and in X-User-Agent; MAG254 by default.
    public var model: String
    /// IANA zone the portal reads guide times in, e.g. `Europe/London`.
    public var timeZone: String

    public init(
        id: UUID = UUID(),
        name: String,
        kind: SourceKind,
        serverURL: String = "",
        macAddress: String = "",
        username: String = "",
        password: String = "",
        playlistURL: String = "",
        guideURL: String = "",
        serialNumber: String = "",
        deviceID: String = "",
        deviceID2: String = "",
        signature: String = "",
        model: String = "",
        timeZone: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.serverURL = serverURL
        self.macAddress = macAddress
        self.username = username
        self.password = password
        self.playlistURL = playlistURL
        self.guideURL = guideURL
        self.serialNumber = serialNumber
        self.deviceID = deviceID
        self.deviceID2 = deviceID2
        self.signature = signature
        self.model = model
        self.timeZone = timeZone
    }
}

/// What a category holds.
public enum ContentKind: String, Sendable, Codable, CaseIterable, Hashable {
    case live
    case vod
    case series
}

/// What the stream probably is, which picks the player engine (PlayerKit).
public enum StreamFormatHint: String, Sendable, Codable, Hashable {
    case hls
    case mpegts
    case mp4
    case mkv
    case unknown
}

public struct RemoteCategory: Sendable, Hashable, Codable, Identifiable {
    /// The provider's own id, unique within the source and kind.
    public var id: String
    public var name: String
    public var kind: ContentKind
    public var sortOrder: Int

    public init(id: String, name: String, kind: ContentKind, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sortOrder = sortOrder
    }
}

public struct RemoteChannel: Sendable, Hashable, Codable, Identifiable {
    /// The stable id the item key is built from (Source protocols, Stable ids):
    /// Stalker channel `id`, Xtream `stream_id`, M3U `tvg-id` or a hash of the
    /// normalised name and group.
    public var id: String
    public var number: Int?
    public var name: String
    public var logoURL: URL?
    public var categoryID: String?
    /// The id the guide knows the channel by: Stalker `ch_id` (or `id`),
    /// Xtream `epg_channel_id`, M3U `tvg-id`.
    public var guideChannelID: String?
    public var hasArchive: Bool
    public var archiveDays: Int
    /// What a stream link is made from: Stalker `cmd`, Xtream stream id, M3U URL.
    public var command: String
    public var formatHint: StreamFormatHint
    /// Request headers the stream needs (M3U `#EXTVLCOPT` user agent, referrer).
    public var headers: [String: String]
    /// M3U catch-up: the `catchup` mode and `catchup-source` template.
    public var catchupMode: String?
    public var catchupSource: String?

    public init(
        id: String,
        number: Int? = nil,
        name: String,
        logoURL: URL? = nil,
        categoryID: String? = nil,
        guideChannelID: String? = nil,
        hasArchive: Bool = false,
        archiveDays: Int = 0,
        command: String,
        formatHint: StreamFormatHint = .unknown,
        headers: [String: String] = [:],
        catchupMode: String? = nil,
        catchupSource: String? = nil
    ) {
        self.id = id
        self.number = number
        self.name = name
        self.logoURL = logoURL
        self.categoryID = categoryID
        self.guideChannelID = guideChannelID
        self.hasArchive = hasArchive
        self.archiveDays = archiveDays
        self.command = command
        self.formatHint = formatHint
        self.headers = headers
        self.catchupMode = catchupMode
        self.catchupSource = catchupSource
    }
}

public struct RemoteProgramme: Sendable, Hashable, Codable {
    public var guideChannelID: String
    public var start: Date
    public var end: Date
    public var title: String
    public var summary: String?
    public var category: String?
    /// The provider says this programme can be played from its archive.
    public var hasArchive: Bool

    public init(guideChannelID: String, start: Date, end: Date, title: String, summary: String? = nil, category: String? = nil, hasArchive: Bool = false) {
        self.guideChannelID = guideChannelID
        self.start = start
        self.end = end
        self.title = title
        self.summary = summary
        self.category = category
        self.hasArchive = hasArchive
    }
}

public struct RemoteMovie: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var categoryID: String?
    public var posterURL: URL?
    public var year: Int?
    public var plot: String?
    public var rating: Double?
    public var durationSeconds: Int?
    public var containerExtension: String?
    public var addedAt: Date?
    public var genre: String?
    public var cast: String?
    public var director: String?
    /// Stalker `cmd`; nil for Xtream (built from the id) and M3U (the URL is
    /// in `command` of the channel the movie came from).
    public var command: String?

    public init(
        id: String,
        name: String,
        categoryID: String? = nil,
        posterURL: URL? = nil,
        year: Int? = nil,
        plot: String? = nil,
        rating: Double? = nil,
        durationSeconds: Int? = nil,
        containerExtension: String? = nil,
        addedAt: Date? = nil,
        genre: String? = nil,
        cast: String? = nil,
        director: String? = nil,
        command: String? = nil
    ) {
        self.id = id
        self.name = name
        self.categoryID = categoryID
        self.posterURL = posterURL
        self.year = year
        self.plot = plot
        self.rating = rating
        self.durationSeconds = durationSeconds
        self.containerExtension = containerExtension
        self.addedAt = addedAt
        self.genre = genre
        self.cast = cast
        self.director = director
        self.command = command
    }
}

public struct RemoteSeries: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var categoryID: String?
    public var posterURL: URL?
    public var plot: String?
    public var year: Int?
    public var rating: Double?
    public var addedAt: Date?
    public var genre: String?
    public var cast: String?
    /// Stalker `cmd` of the series item, when the portal gives one.
    public var command: String?

    public init(
        id: String,
        name: String,
        categoryID: String? = nil,
        posterURL: URL? = nil,
        plot: String? = nil,
        year: Int? = nil,
        rating: Double? = nil,
        addedAt: Date? = nil,
        genre: String? = nil,
        cast: String? = nil,
        command: String? = nil
    ) {
        self.id = id
        self.name = name
        self.categoryID = categoryID
        self.posterURL = posterURL
        self.plot = plot
        self.year = year
        self.rating = rating
        self.addedAt = addedAt
        self.genre = genre
        self.cast = cast
        self.command = command
    }
}

public struct RemoteSeason: Sendable, Hashable, Codable {
    public var number: Int
    public var name: String?
    /// Stalker `season_id`; Xtream doesn't need one.
    public var remoteID: String?

    public init(number: Int, name: String? = nil, remoteID: String? = nil) {
        self.number = number
        self.name = name
        self.remoteID = remoteID
    }
}

public struct RemoteEpisode: Sendable, Hashable, Codable, Identifiable {
    /// The provider's episode id. Never used in an item key: some providers
    /// reissue it (keys use season and number).
    public var id: String
    public var seriesID: String
    public var season: Int
    public var number: Int
    public var title: String
    public var plot: String?
    public var durationSeconds: Int?
    public var containerExtension: String?
    public var posterURL: URL?
    /// Stalker `cmd`, M3U URL; nil for Xtream (built from the id).
    public var command: String?

    public init(
        id: String,
        seriesID: String,
        season: Int,
        number: Int,
        title: String,
        plot: String? = nil,
        durationSeconds: Int? = nil,
        containerExtension: String? = nil,
        posterURL: URL? = nil,
        command: String? = nil
    ) {
        self.id = id
        self.seriesID = seriesID
        self.season = season
        self.number = number
        self.title = title
        self.plot = plot
        self.durationSeconds = durationSeconds
        self.containerExtension = containerExtension
        self.posterURL = posterURL
        self.command = command
    }
}

public struct SeriesDetail: Sendable, Hashable {
    public var series: RemoteSeries
    public var seasons: [RemoteSeason]
    public var episodes: [RemoteEpisode]

    public init(series: RemoteSeries, seasons: [RemoteSeason], episodes: [RemoteEpisode]) {
        self.series = series
        self.seasons = seasons
        self.episodes = episodes
    }
}

/// One page of a paged list. Stalker pages count from 0 in this API (the
/// client translates to whatever the portal wants); Xtream and M3U answer
/// everything as page 0 with `hasMore == false`.
/// One page of a provider's own search: the movies and the shows in it.
public struct RemoteSearchPage: Sendable, Hashable {
    public var movies: [RemoteMovie]
    public var series: [RemoteSeries]
    public var page: Int
    public var hasMore: Bool

    public init(movies: [RemoteMovie] = [], series: [RemoteSeries] = [], page: Int, hasMore: Bool) {
        self.movies = movies
        self.series = series
        self.page = page
        self.hasMore = hasMore
    }
}

public struct Page<Item: Sendable & Hashable>: Sendable, Hashable {
    public var items: [Item]
    public var page: Int
    public var totalItems: Int?
    public var hasMore: Bool

    public init(items: [Item], page: Int, totalItems: Int? = nil, hasMore: Bool) {
        self.items = items
        self.page = page
        self.totalItems = totalItems
        self.hasMore = hasMore
    }
}

public enum AccountStatus: String, Sendable, Codable, Hashable {
    case active
    case expired
    case disabled
    case unknown
}

/// What the provider says about the login (SRC-5).
public struct AccountInfo: Sendable, Hashable, Codable {
    public var status: AccountStatus
    public var expiresAt: Date?
    /// Xtream `max_connections`; nil when the provider doesn't say (Stalker, M3U).
    public var maxConnections: Int?
    /// Xtream `active_cons`.
    public var activeConnections: Int?
    public var isTrial: Bool
    /// Xtream `allowed_output_formats` ("m3u8", "ts").
    public var allowedOutputFormats: [String]
    /// The provider's own words, shown as they are (SRC-4).
    public var message: String?

    public init(
        status: AccountStatus = .unknown,
        expiresAt: Date? = nil,
        maxConnections: Int? = nil,
        activeConnections: Int? = nil,
        isTrial: Bool = false,
        allowedOutputFormats: [String] = [],
        message: String? = nil
    ) {
        self.status = status
        self.expiresAt = expiresAt
        self.maxConnections = maxConnections
        self.activeConnections = activeConnections
        self.isTrial = isTrial
        self.allowedOutputFormats = allowedOutputFormats
        self.message = message
    }
}

/// What to fetch a stream link for. Links are asked for at every play and
/// never stored: they expire.
public enum StreamRequest: Sendable, Hashable {
    case live(RemoteChannel)
    /// An aired programme from its archive, or a live one from its start.
    case catchup(RemoteChannel, start: Date, duration: TimeInterval)
    case movie(RemoteMovie)
    case episode(RemoteEpisode, series: RemoteSeries?)
}

public struct StreamLink: Sendable, Hashable {
    public var url: URL
    /// Headers the player must send (User-Agent, Referer, Cookie).
    public var headers: [String: String]
    public var formatHint: StreamFormatHint
    public var isLive: Bool

    public init(url: URL, headers: [String: String] = [:], formatHint: StreamFormatHint = .unknown, isLive: Bool = false) {
        self.url = url
        self.headers = headers
        self.formatHint = formatHint
        self.isLive = isLive
    }
}

/// What a source type can do, so screens hide what it can't.
public struct SourceCapabilities: Sendable, Hashable {
    public var hasMovies: Bool
    public var hasSeries: Bool
    /// One call returns the whole guide (Xtream `xmltv.php`, an XMLTV file).
    public var hasFullGuide: Bool
    public var hasCatchup: Bool
    /// The provider reports its stream limit and use (Xtream only).
    public var reportsStreamCount: Bool
    /// The provider searches its own movies and shows (`search(_:page:)`):
    /// a Stalker portal, whose catalog can be too big to keep on a device.
    public var searchesCatalog: Bool

    public init(hasMovies: Bool, hasSeries: Bool, hasFullGuide: Bool, hasCatchup: Bool, reportsStreamCount: Bool, searchesCatalog: Bool = false) {
        self.hasMovies = hasMovies
        self.hasSeries = hasSeries
        self.hasFullGuide = hasFullGuide
        self.hasCatchup = hasCatchup
        self.reportsStreamCount = reportsStreamCount
        self.searchesCatalog = searchesCatalog
    }
}

/// Every failure a client reports. `providerMessage` carries the provider's
/// own text when it sent any, shown verbatim (SRC-4, PLY-4).
public struct SourceError: Error, Sendable, Hashable, LocalizedError {
    public enum Code: String, Sendable, Hashable {
        case invalidConfiguration
        case unreachable
        case authenticationFailed
        case accountExpired
        case notSupported
        case badResponse
        case noLink
        case cancelled
    }

    public var code: Code
    public var providerMessage: String?
    /// A developer-facing detail (HTTP status, decoding path). Never contains
    /// a login or a MAC.
    public var detail: String?

    public init(_ code: Code, providerMessage: String? = nil, detail: String? = nil) {
        self.code = code
        self.providerMessage = providerMessage
        self.detail = detail
    }

    public var errorDescription: String? {
        if let providerMessage, !providerMessage.isEmpty { return providerMessage }
        switch code {
        case .invalidConfiguration: return String(localized: "Some of this source's details are missing or malformed.")
        case .unreachable: return String(localized: "The provider can't be reached.")
        case .authenticationFailed: return String(localized: "The provider refused this login.")
        case .accountExpired: return String(localized: "This subscription has expired.")
        case .notSupported: return String(localized: "This provider doesn't offer that.")
        case .badResponse: return String(localized: "The provider sent an answer Hearth doesn't understand.")
        case .noLink: return String(localized: "The provider didn't give a link for this stream.")
        case .cancelled: return String(localized: "Cancelled.")
        }
    }
}
