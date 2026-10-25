import Foundation

/// An Xtream Codes login: plain `player_api.php` calls with the username and
/// password on each, no session (Source protocols, Xtream Codes; SRC-2).
///
/// Stream links are built from URL patterns, not asked for. The account
/// call's `allowed_output_formats` decides whether live links ask for HLS
/// (playable by AVPlayer) or raw MPEG-TS, so it's remembered after sign-in.
public actor XtreamClient: SourceClient {
    public nonisolated let configuration: SourceConfiguration
    private let session: URLSession
    /// `scheme://host[:port][/prefix]`, no trailing slash.
    private let base: Result<String, SourceError>
    private var allowedOutputFormats: [String]?
    /// `server_info.timezone`: the zone wall-clock guide times and catch-up
    /// paths are written in.
    private var serverTimeZone: TimeZone?

    public init(configuration: SourceConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        if let base = XtreamParse.baseURL(configuration.serverURL) {
            self.base = .success(base)
        } else {
            self.base = .failure(SourceError(.invalidConfiguration, detail: "The server URL isn't a web address"))
        }
    }

    public nonisolated var capabilities: SourceCapabilities {
        SourceCapabilities(hasMovies: true, hasSeries: true, hasFullGuide: true, hasCatchup: true, reportsStreamCount: true)
    }

    // MARK: Account

    public func signIn() async throws -> AccountInfo {
        guard !configuration.username.isEmpty, !configuration.password.isEmpty else {
            throw SourceError(.invalidConfiguration, detail: "An Xtream login needs a username and a password")
        }
        return try await accountInfo()
    }

    public func accountInfo() async throws -> AccountInfo {
        let answer = try await call(action: nil)
        let account = try XtreamParse.account(answer)
        allowedOutputFormats = account.allowedOutputFormats
        serverTimeZone = answer["server_info"]?.string("timezone").flatMap(TimeZone.init(identifier:))
        return account
    }

    public func keepAlive() async {}

    // MARK: Catalog

    public func categories(_ kind: ContentKind) async throws -> [RemoteCategory] {
        let action: String
        switch kind {
        case .live: action = "get_live_categories"
        case .vod: action = "get_vod_categories"
        case .series: action = "get_series_categories"
        }
        return XtreamParse.categories(try await call(action: action), kind: kind)
    }

    public func channels() async throws -> [RemoteChannel] {
        let formats = try await outputFormats()
        return XtreamParse.channels(try await call(action: "get_live_streams"), prefersHLS: XtreamParse.prefersHLS(formats))
    }

    /// Xtream answers every movie in one call: page 0 holds them all.
    public func movies(categoryID: String?, page: Int) async throws -> Page<RemoteMovie> {
        guard page == 0 else { return Page(items: [], page: page, hasMore: false) }
        let answer = try await call(action: "get_vod_streams", categoryID.map { [("category_id", $0)] } ?? [])
        let movies = XtreamParse.movies(answer)
        return Page(items: movies, page: 0, totalItems: movies.count, hasMore: false)
    }

    public func series(categoryID: String?, page: Int) async throws -> Page<RemoteSeries> {
        guard page == 0 else { return Page(items: [], page: page, hasMore: false) }
        let answer = try await call(action: "get_series", categoryID.map { [("category_id", $0)] } ?? [])
        let series = XtreamParse.series(answer)
        return Page(items: series, page: 0, totalItems: series.count, hasMore: false)
    }

    public func seriesDetail(_ series: RemoteSeries) async throws -> SeriesDetail {
        // `series_id`, not `series` (the community thread's correction).
        let answer = try await call(action: "get_series_info", [("series_id", series.id)])
        return XtreamParse.seriesDetail(answer, series: series)
    }

    // MARK: Guide

    public func shortGuide(for channel: RemoteChannel, limit: Int) async throws -> [RemoteProgramme] {
        let answer = try await call(action: "get_short_epg", [("stream_id", channel.command), ("limit", String(max(limit, 1)))])
        let zone = serverTimeZone ?? TimeZone(identifier: configuration.timeZone) ?? TimeZone(secondsFromGMT: 0)!
        let programmes = XtreamParse.shortGuide(answer, guideChannelID: channel.guideChannelID ?? channel.id, timeZone: zone)
        return Array(programmes.prefix(max(limit, 1)))
    }

    /// `xmltv.php` (or a typed guide URL that overrides it), streamed through
    /// the XMLTV parser. Not every provider offers it; one that doesn't fails
    /// the stream with its own words.
    public nonisolated func fullGuide() -> AsyncThrowingStream<RemoteProgramme, Error>? {
        if let typed = URL(string: configuration.guideURL.trimmingCharacters(in: .whitespaces)), typed.scheme != nil {
            return XMLTVGuide.programmes(from: typed, session: session)
        }
        guard case .success(let base) = base,
              let url = URL(string: base + "/xmltv.php?" + QueryEncoding.query([("username", configuration.username), ("password", configuration.password)]))
        else { return nil }
        return XMLTVGuide.programmes(from: url, session: session)
    }

    // MARK: Links

    public func streamLink(for request: StreamRequest) async throws -> StreamLink {
        let base = try base.get()
        let builder = XtreamURLBuilder(base: base, username: configuration.username, password: configuration.password)
        switch request {
        case .live(let channel):
            let hls = XtreamParse.prefersHLS(try await outputFormats())
            guard let url = builder.live(streamID: channel.command, hls: hls) else { throw SourceError(.noLink, detail: "Live URL couldn't be built") }
            return StreamLink(url: url, formatHint: hls ? .hls : .mpegts, isLive: true)
        case .catchup(let channel, let start, let duration):
            if allowedOutputFormats == nil { _ = try? await accountInfo() }
            let zone = serverTimeZone ?? TimeZone(identifier: configuration.timeZone) ?? TimeZone(secondsFromGMT: 0)!
            guard let url = builder.timeshift(streamID: channel.command, start: start, duration: duration, timeZone: zone) else {
                throw SourceError(.noLink, detail: "Catch-up URL couldn't be built")
            }
            return StreamLink(url: url, formatHint: .mpegts)
        case .movie(let movie):
            let fileExtension = movie.containerExtension ?? "mp4"
            guard let url = builder.movie(streamID: movie.id, fileExtension: fileExtension) else { throw SourceError(.noLink) }
            return StreamLink(url: url, formatHint: .fromExtension(fileExtension))
        case .episode(let episode, _):
            let fileExtension = episode.containerExtension ?? "mp4"
            guard let url = builder.episode(episodeID: episode.id, fileExtension: fileExtension) else { throw SourceError(.noLink) }
            return StreamLink(url: url, formatHint: .fromExtension(fileExtension))
        }
    }

    // MARK: Calls

    private func outputFormats() async throws -> [String] {
        if let allowedOutputFormats { return allowedOutputFormats }
        return try await accountInfo().allowedOutputFormats
    }

    /// One `player_api.php` call. A refusal carries the provider's own text
    /// (SRC-4); the URL, which holds the password, never reaches an error.
    private func call(action: String?, _ parameters: [(String, String)] = []) async throws -> JSONValue {
        let base = try base.get()
        var query = [("username", configuration.username), ("password", configuration.password)]
        if let action { query.append(("action", action)) }
        query += parameters
        guard let url = URL(string: base + "/player_api.php?" + QueryEncoding.query(query)) else {
            throw SourceError(.invalidConfiguration, detail: "The server URL isn't a web address")
        }
        var request = URLRequest(url: url, timeoutInterval: HTTP.apiTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await HTTP.send(request, session: session)
        guard response.isSuccess else {
            var error = HTTP.statusError(response, what: action ?? "player_api.php")
            error.providerMessage = error.providerMessage.map { Redaction.scrub($0, for: configuration) }
            throw error
        }
        guard let value = JSONValue(data: response.data) else {
            // Some panels answer a wrong login with an empty body or a page of text.
            let text = response.plainText.map { Redaction.scrub($0, for: configuration) }
            throw SourceError(action == nil ? .authenticationFailed : .badResponse, providerMessage: text,
                              detail: "\(action ?? "player_api.php") didn't answer JSON")
        }
        return value
    }
}

/// Xtream stream URLs (Source protocols, Xtream Codes, Stream).
struct XtreamURLBuilder: Sendable {
    let base: String
    let username: String
    let password: String

    private var credentials: String {
        QueryEncoding.pathSegment(username) + "/" + QueryEncoding.pathSegment(password)
    }

    /// `/live/U/P/<id>.m3u8` when the account allows HLS, else `.ts`.
    func live(streamID: String, hls: Bool) -> URL? {
        URL(string: "\(base)/live/\(credentials)/\(QueryEncoding.pathSegment(streamID)).\(hls ? "m3u8" : "ts")")
    }

    /// `/movie/U/P/<id>.<container_extension>` (common convention; check with the probe).
    func movie(streamID: String, fileExtension: String) -> URL? {
        URL(string: "\(base)/movie/\(credentials)/\(QueryEncoding.pathSegment(streamID)).\(fileExtension)")
    }

    /// `/series/U/P/<episode_id>.<container_extension>` (common convention).
    func episode(episodeID: String, fileExtension: String) -> URL? {
        URL(string: "\(base)/series/\(credentials)/\(QueryEncoding.pathSegment(episodeID)).\(fileExtension)")
    }

    /// `/timeshift/U/P/<minutes>/<YYYY-MM-DD:HH-MM>/<id>.ts`, the start
    /// written in the server's zone (common convention, unconfirmed).
    func timeshift(streamID: String, start: Date, duration: TimeInterval, timeZone: TimeZone) -> URL? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        let stamp = String(format: "%04d-%02d-%02d:%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1, parts.hour ?? 0, parts.minute ?? 0)
        let minutes = max(Int((duration / 60).rounded(.up)), 1)
        return URL(string: "\(base)/timeshift/\(credentials)/\(minutes)/\(stamp)/\(QueryEncoding.pathSegment(streamID)).ts")
    }
}

/// Pure readers for Xtream answers, shared by the client and the tests.
/// Numbers often arrive as strings, an empty object as `[]`.
enum XtreamParse {
    /// The server URL without `player_api.php` or a trailing slash.
    static func baseURL(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), components.host?.isEmpty == false
        else { return nil }
        components.query = nil
        components.fragment = nil
        var path = components.path
        for suffix in ["player_api.php", "get.php", "xmltv.php", "panel_api.php"] where path.lowercased().hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.string
    }

    static func prefersHLS(_ formats: [String]) -> Bool {
        formats.contains { $0.lowercased() == "m3u8" }
    }

    /// `user_info` and `server_info` (SRC-2, SRC-5). `auth` 0 is a refusal.
    static func account(_ answer: JSONValue) throws -> AccountInfo {
        guard let info = answer["user_info"], info.object != nil else {
            throw SourceError(.authenticationFailed, providerMessage: answer.string("message", "error"),
                              detail: "The account call returned no user_info")
        }
        let message = info.string("message") ?? answer.string("message")
        if let auth = info["auth"], !auth.truthy {
            throw SourceError(.authenticationFailed, providerMessage: message, detail: "user_info.auth is 0")
        }
        let expiresAt = ProviderTime.unix(info["exp_date"])
        let status: AccountStatus
        switch info.string("status")?.lowercased() {
        case "active": status = (expiresAt.map { $0 < Date() } ?? false) ? .expired : .active
        case "expired": status = .expired
        case "banned", "disabled": status = .disabled
        case nil: status = .unknown
        default: status = .unknown
        }
        let formats = info["allowed_output_formats"]?.elements.compactMap(\.string) ?? []
        return AccountInfo(
            status: status,
            expiresAt: expiresAt,
            maxConnections: info.int("max_connections"),
            activeConnections: info.int("active_cons"),
            isTrial: info.truthy("is_trial"),
            allowedOutputFormats: formats,
            message: message
        )
    }

    static func categories(_ answer: JSONValue, kind: ContentKind) -> [RemoteCategory] {
        answer.elements.enumerated().compactMap { index, row in
            guard let id = row.string("category_id") else { return nil }
            return RemoteCategory(id: id, name: row.string("category_name") ?? id, kind: kind, sortOrder: index)
        }
    }

    static func channels(_ answer: JSONValue, prefersHLS: Bool) -> [RemoteChannel] {
        answer.elements.compactMap { row in
            guard let id = row.string("stream_id"), let name = row.string("name") else { return nil }
            let hasArchive = row.truthy("tv_archive")
            return RemoteChannel(
                id: id,
                number: row.int("num"),
                name: name,
                logoURL: url(row.string("stream_icon")),
                categoryID: row.string("category_id"),
                guideChannelID: row.string("epg_channel_id") ?? id,
                hasArchive: hasArchive,
                archiveDays: hasArchive ? (row.int("tv_archive_duration") ?? 0) : 0,
                command: id,
                formatHint: prefersHLS ? .hls : .mpegts
            )
        }
    }

    static func movies(_ answer: JSONValue) -> [RemoteMovie] {
        answer.elements.compactMap { row in
            guard let id = row.string("stream_id"), let name = row.string("name") else { return nil }
            return RemoteMovie(
                id: id,
                name: name,
                categoryID: row.string("category_id"),
                posterURL: url(row.string("stream_icon", "cover")),
                year: row.int("year") ?? ProviderTime.year(in: row.string("releasedate", "releaseDate")) ?? ProviderTime.year(in: name),
                plot: row.string("plot", "description"),
                rating: rating(row),
                durationSeconds: ProviderTime.duration(row["duration_secs"], minutesWhenBare: false) ?? ProviderTime.duration(row["duration"], minutesWhenBare: false),
                containerExtension: row.string("container_extension"),
                addedAt: ProviderTime.unix(row["added"]),
                genre: row.string("genre"),
                cast: row.string("cast", "actors"),
                director: row.string("director")
            )
        }
    }

    static func series(_ answer: JSONValue) -> [RemoteSeries] {
        answer.elements.compactMap { row in
            guard let id = row.string("series_id"), let name = row.string("name") else { return nil }
            return RemoteSeries(
                id: id,
                name: name,
                categoryID: row.string("category_id"),
                posterURL: url(row.string("cover", "stream_icon")),
                plot: row.string("plot", "description"),
                year: row.int("year") ?? ProviderTime.year(in: row.string("releaseDate", "releasedate", "release_date")),
                rating: rating(row),
                addedAt: ProviderTime.unix(row["last_modified"]),
                genre: row.string("genre"),
                cast: row.string("cast")
            )
        }
    }

    /// `get_series_info`: `seasons` (may be `[]` while episodes exist) and
    /// `episodes` keyed by season number — as an object, or as an array of
    /// arrays on some panels.
    static func seriesDetail(_ answer: JSONValue, series: RemoteSeries) -> SeriesDetail {
        var episodes: [RemoteEpisode] = []
        let groups: [(key: Int?, rows: [JSONValue])]
        switch answer["episodes"] {
        case .object(let object)?:
            groups = object.map { (Int($0.key), $0.value.elements) }
        case .array(let array)?:
            groups = array.map { (nil, $0.elements) }
        default:
            groups = []
        }
        for group in groups {
            for row in group.rows {
                guard let id = row.string("id") else { continue }
                let season = row.int("season") ?? group.key ?? 1
                let number = row.int("episode_num", "episode_number") ?? (episodes.filter { $0.season == season }.count + 1)
                let info = row["info"]
                episodes.append(RemoteEpisode(
                    id: id,
                    seriesID: series.id,
                    season: season,
                    number: number,
                    title: cleanEpisodeTitle(row.string("title"), series: series.name, number: number),
                    plot: info?.string("plot"),
                    durationSeconds: ProviderTime.duration(info?["duration_secs"], minutesWhenBare: false)
                        ?? ProviderTime.duration(info?["duration"], minutesWhenBare: false),
                    containerExtension: row.string("container_extension"),
                    posterURL: url(info?.string("movie_image", "cover_big")),
                    command: nil
                ))
            }
        }
        episodes.sort { ($0.season, $0.number) < ($1.season, $1.number) }

        var seasons: [RemoteSeason] = answer["seasons"]?.elements.compactMap { row in
            guard let number = row.int("season_number") else { return nil }
            return RemoteSeason(number: number, name: row.string("name"))
        } ?? []
        let known = Set(seasons.map(\.number))
        for number in Set(episodes.map(\.season)).subtracting(known) {
            seasons.append(RemoteSeason(number: number, name: "Season \(number)"))
        }
        // A "Season 0" of specials with no episodes is noise.
        let withEpisodes = Set(episodes.map(\.season))
        seasons = seasons.filter { $0.number != 0 || withEpisodes.contains(0) }.sorted { $0.number < $1.number }

        var detailed = series
        if let info = answer["info"], info.object != nil {
            detailed.plot = detailed.plot ?? info.string("plot")
            detailed.cast = detailed.cast ?? info.string("cast")
            detailed.genre = detailed.genre ?? info.string("genre")
            detailed.posterURL = detailed.posterURL ?? url(info.string("cover"))
            detailed.year = detailed.year ?? ProviderTime.year(in: info.string("releaseDate", "releasedate"))
        }
        return SeriesDetail(series: detailed, seasons: seasons, episodes: episodes)
    }

    /// `get_short_epg`: `epg_listings[]` with base64 titles and descriptions
    /// on many panels; decoded when they decode cleanly.
    static func shortGuide(_ answer: JSONValue, guideChannelID: String, timeZone: TimeZone) -> [RemoteProgramme] {
        let rows = answer["epg_listings"]?.elements ?? answer.array ?? []
        return rows.compactMap { row -> RemoteProgramme? in
            guard let start = ProviderTime.unix(row["start_timestamp"]) ?? ProviderTime.date(row["start"], timeZone: timeZone),
                  let end = ProviderTime.unix(row["stop_timestamp"]) ?? ProviderTime.date(row["end"] ?? row["stop"], timeZone: timeZone),
                  end > start
            else { return nil }
            let title = row.string("title").map { Base64.decodedText($0) ?? $0 } ?? "—"
            let summary = row.string("description").map { Base64.decodedText($0) ?? $0 }
            return RemoteProgramme(
                guideChannelID: guideChannelID,
                start: start,
                end: end,
                title: title,
                summary: summary,
                hasArchive: row.truthy("has_archive")
            )
        }
        .sorted { $0.start < $1.start }
    }

    /// "Salt & Signal - S03E04 - Fog Bell" → "Fog Bell"; a bare series name
    /// becomes "Episode 4".
    static func cleanEpisodeTitle(_ title: String?, series: String, number: Int) -> String {
        guard var text = title?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return "Episode \(number)" }
        if let range = text.range(of: #"^.*?\bS\d{1,2}\s*E\d{1,3}\b\s*[-–:.]?\s*"#, options: [.regularExpression, .caseInsensitive]) {
            let rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            text = rest.isEmpty ? "Episode \(number)" : rest
        }
        if text.caseInsensitiveCompare(series) == .orderedSame { return "Episode \(number)" }
        return text
    }

    /// `rating` out of 10, else `rating_5based` doubled.
    static func rating(_ row: JSONValue) -> Double? {
        if let value = row.double("rating"), value > 0, value <= 10 { return value }
        if let value = row.double("rating_5based"), value > 0, value <= 5 { return value * 2 }
        return nil
    }

    static func url(_ text: String?) -> URL? {
        guard let text, text.hasPrefix("http://") || text.hasPrefix("https://") else { return nil }
        return URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
    }
}
