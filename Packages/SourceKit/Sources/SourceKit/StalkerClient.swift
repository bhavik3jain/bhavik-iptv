import Foundation

/// A Stalker (Ministra) portal, spoken to the way a MAG set-top box does
/// (Source protocols, Stalker portal; SRC-1, SRC-4).
///
/// The session token lives in this actor's memory only. Every call goes
/// through `call(_:what:)`, which signs in when there's no session and, on an
/// auth error, handshakes again once before failing — stalkerhek doesn't, and
/// its sessions die when the token lapses.
public actor StalkerClient: SourceClient {
    public nonisolated let configuration: SourceConfiguration
    private let session: URLSession
    /// The login with the advanced-field defaults filled in, or why it can't be used.
    private let portal: Result<StalkerPortal, SourceError>
    /// The API endpoint path discovery settled on. Kept across re-handshakes:
    /// it's a fact about the portal, not the session.
    private var api: URL?
    /// The session token, memory only (never stored, never logged).
    private var token: String?
    /// The last `get_profile` answer, read for account details.
    private var profile: JSONValue?
    /// A sign-in in flight, shared by every caller that needs a session meanwhile.
    private var authentication: Task<Void, Error>?
    /// Which module answers series: Ministra 5.3+ has `series`; older portals
    /// keep shows inside `vod`, flagged `is_series`.
    private var seriesModule: String?
    /// The portal refused blank device ids and took stalkerhek's placeholder,
    /// so later sign-ins go straight to it.
    private var usesPlaceholderDeviceIDs = false

    public init(configuration: SourceConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        do {
            portal = .success(try StalkerPortal(configuration: configuration))
        } catch let error as SourceError {
            portal = .failure(error)
        } catch {
            portal = .failure(SourceError(.invalidConfiguration))
        }
    }

    public nonisolated var capabilities: SourceCapabilities {
        SourceCapabilities(hasMovies: true, hasSeries: true, hasFullGuide: false, hasCatchup: true, reportsStreamCount: false)
    }

    // MARK: Session

    public func signIn() async throws -> AccountInfo {
        // Always a fresh session: this is also the "Test source" button (SRC-4).
        token = nil
        try await authenticate()
        return await currentAccount()
    }

    public func accountInfo() async throws -> AccountInfo {
        _ = try await sessionEndpoint()
        return await currentAccount()
    }

    /// The watchdog call a MAG box makes every few minutes so the portal keeps
    /// the session (stalkerhek: every 5 minutes). Only while signed in; errors
    /// are ignored — the next real call re-handshakes if the session went.
    public func keepAlive() async {
        guard token != nil, api != nil else { return }
        _ = try? await call(
            [("type", "watchdog"), ("action", "get_events"), ("event_active_id", "0"), ("init", "0"), ("cur_play_type", "1")],
            what: "watchdog"
        )
    }

    // MARK: Catalog

    public func categories(_ kind: ContentKind) async throws -> [RemoteCategory] {
        switch kind {
        case .live:
            let envelope = try await call([("type", "itv"), ("action", "get_genres")], what: "get_genres")
            return StalkerParse.categories(envelope.js, kind: .live)
        case .vod:
            let envelope = try await call([("type", "vod"), ("action", "get_categories")], what: "get_categories")
            return StalkerParse.categories(envelope.js, kind: .vod)
        case .series:
            // The series module first; portals without it keep shows in VOD
            // categories named like "TV Series" (stalkerhek's rule).
            if let envelope = try? await call([("type", "series"), ("action", "get_categories")], what: "get_categories") {
                let categories = StalkerParse.categories(envelope.js, kind: .series)
                if !categories.isEmpty {
                    seriesModule = "series"
                    return categories
                }
            }
            let envelope = try await call([("type", "vod"), ("action", "get_categories")], what: "get_categories")
            seriesModule = "vod"
            return StalkerParse.categories(envelope.js, kind: .series).filter { StalkerParse.isSeriesStyleCategory($0.name) }
        }
    }

    public func channels() async throws -> [RemoteChannel] {
        let api = try await sessionEndpoint().api
        let envelope = try await call([("type", "itv"), ("action", "get_all_channels")], what: "get_all_channels")
        let channels = StalkerParse.channels(envelope.js, api: api)
        if !channels.isEmpty { return channels }
        // Some portals switch get_all_channels off; page through the ordered
        // list instead, as the MAG UI does.
        var all: [RemoteChannel] = []
        var seen: Set<String> = []
        for page in 0..<Self.maxPages {
            let answer = try await call(
                [("type", "itv"), ("action", "get_ordered_list"), ("genre", "*"), ("fav", "0"), ("sortby", "number"), ("p", StalkerParse.portalPage(page))],
                what: "get_ordered_list"
            )
            let list = StalkerParse.listPage(answer.js)
            for channel in list.items.compactMap({ StalkerParse.channel($0, api: api) }) where seen.insert(channel.id).inserted {
                all.append(channel)
            }
            if !list.hasMore(after: page) { break }
        }
        return all
    }

    public func movies(categoryID: String?, page: Int) async throws -> Page<RemoteMovie> {
        let (portal, api) = try await sessionEndpoint()
        let envelope = try await call(
            [("type", "vod"), ("action", "get_ordered_list"), ("category", categoryID ?? "*"), ("sortby", "added"), ("p", StalkerParse.portalPage(page))],
            what: "get_ordered_list"
        )
        let list = StalkerParse.listPage(envelope.js)
        // Shows listed among movies (old portals) belong to series().
        let movies = list.items.filter { !$0.truthy("is_series") }.compactMap { StalkerParse.movie($0, api: api, timeZone: portal.timeZone) }
        return Page(items: movies, page: page, totalItems: list.totalItems, hasMore: list.hasMore(after: page))
    }

    public func series(categoryID: String?, page: Int) async throws -> Page<RemoteSeries> {
        let (portal, api) = try await sessionEndpoint()
        var module = seriesModule ?? "series"
        var list: StalkerListPage
        if seriesModule == nil {
            // stalkerhek's fallback: a portal without the series module
            // answers empty (or not at all), and its shows sit in VOD.
            let fromSeries = try? await seriesList(module: "series", categoryID: categoryID, page: page)
            if let fromSeries, !fromSeries.items.isEmpty {
                list = fromSeries
            } else {
                module = "vod"
                list = try await seriesList(module: "vod", categoryID: categoryID, page: page)
            }
            let settled = module == "series" ? !list.items.isEmpty : list.items.contains { $0.truthy("is_series") }
            if settled { seriesModule = module }
        } else {
            list = try await seriesList(module: module, categoryID: categoryID, page: page)
        }
        let rows = module == "vod" ? list.items.filter { $0.truthy("is_series") } : list.items
        let series = rows.compactMap { StalkerParse.series($0, api: api, timeZone: portal.timeZone) }
        return Page(items: series, page: page, totalItems: list.totalItems, hasMore: list.hasMore(after: page))
    }

    public func seriesDetail(_ series: RemoteSeries) async throws -> SeriesDetail {
        let api = try await sessionEndpoint().api
        let preferred = seriesModule ?? "series"
        var module = preferred
        var seasonRows = try await allRows(
            [("type", module), ("action", "get_ordered_list"), ("movie_id", series.id), ("season_id", "0"), ("episode_id", "0")],
            what: "get_ordered_list (seasons)"
        )
        if seasonRows.isEmpty {
            module = preferred == "series" ? "vod" : "series"
            seasonRows = (try? await allRows(
                [("type", module), ("action", "get_ordered_list"), ("movie_id", series.id), ("season_id", "0"), ("episode_id", "0")],
                what: "get_ordered_list (seasons)"
            )) ?? []
        }
        let flagged = seasonRows.filter { $0.truthy("is_season") }
        let rows = flagged.isEmpty ? seasonRows : flagged

        var seasons: [RemoteSeason] = []
        var episodes: [RemoteEpisode] = []
        for (index, row) in rows.enumerated() {
            guard let seasonID = row.string("id") else { continue }
            let name = row.string("name")
            let number = row.int("season_number") ?? StalkerParse.leadingNumber(in: name) ?? index + 1
            seasons.append(RemoteSeason(number: number, name: name, remoteID: seasonID))

            let episodeRows = try await allRows(
                [("type", module), ("action", "get_ordered_list"), ("movie_id", series.id), ("season_id", seasonID), ("episode_id", "0")],
                what: "get_ordered_list (episodes)"
            )
            var seasonEpisodes = StalkerParse.episodes(episodeRows, seriesID: series.id, season: number, api: api)
            if seasonEpisodes.isEmpty {
                // Older portals list episode numbers on the season and play
                // them as the season's cmd plus `series=<n>`.
                seasonEpisodes = StalkerParse.numberedEpisodes(row, seriesID: series.id, season: number)
            }
            episodes += seasonEpisodes
        }
        return SeriesDetail(series: series, seasons: seasons.sorted { $0.number < $1.number }, episodes: episodes)
    }

    // MARK: Guide

    public func shortGuide(for channel: RemoteChannel, limit: Int) async throws -> [RemoteProgramme] {
        let portal = try await sessionEndpoint().portal
        let guideID = channel.guideChannelID ?? channel.id
        let size = min(max(limit, 1), 20)
        let envelope = try await call(
            [("type", "itv"), ("action", "get_short_epg"), ("ch_id", guideID), ("size", String(size))],
            what: "get_short_epg"
        )
        var programmes = StalkerParse.programmes(envelope.js, guideChannelID: guideID, timeZone: portal.timeZone)
        if programmes.isEmpty {
            // stalkerhek's fallback. Ministra answers get_epg_info for every
            // channel keyed by id, so ask for a short period.
            if let info = try? await call(
                [("type", "itv"), ("action", "get_epg_info"), ("ch_id", guideID), ("period", "5")],
                what: "get_epg_info"
            ) {
                let now = Date()
                programmes = StalkerParse.programmes(info.js, guideChannelID: guideID, timeZone: portal.timeZone)
                    .filter { $0.guideChannelID == guideID && $0.end > now }
            }
        }
        return Array(programmes.prefix(max(limit, 1)))
    }

    /// Stalker has only the per-channel short guide.
    public nonisolated func fullGuide() -> AsyncThrowingStream<RemoteProgramme, Error>? { nil }

    // MARK: Links

    public func streamLink(for request: StreamRequest) async throws -> StreamLink {
        let (portal, api) = try await sessionEndpoint()
        let headers = ["User-Agent": StalkerPortal.userAgent]
        switch request {
        case .live(let channel):
            let envelope = try await call([("type", "itv"), ("action", "create_link"), ("cmd", channel.command)], what: "create_link")
            guard let link = StalkerParse.liveLink(envelope.js) ?? Self.directURL(in: channel.command), let url = URL(string: link) else {
                throw noLink(envelope, what: "create_link")
            }
            return StreamLink(url: url, headers: headers, formatHint: Self.hint(for: url, fallback: channel.formatHint), isLive: true)

        case .catchup(let channel, let start, let duration):
            return try await catchupLink(channel: channel, start: start, duration: duration, portal: portal, headers: headers)

        case .movie(let movie):
            let command = StalkerParse.movieCommand(movie.command ?? movie.id)
            let envelope = try await call([("type", "vod"), ("action", "create_link"), ("cmd", command)], what: "create_link (vod)")
            guard let link = StalkerParse.vodLink(envelope.js, streamServerBase: StalkerPortal.streamServerBase(for: api), mac: portal.mac, linkType: "movie"),
                  let url = URL(string: link)
            else { throw noLink(envelope, what: "create_link (vod)") }
            return StreamLink(url: url, headers: headers, formatHint: Self.hint(for: url, fallback: .fromExtension(movie.containerExtension)))

        case .episode(let episode, _):
            let command = StalkerParse.movieCommand(episode.command ?? episode.id)
            var parameters = [("type", "vod"), ("action", "create_link"), ("cmd", command)]
            if episode.number > 0 { parameters.append(("series", String(episode.number))) }
            let envelope = try await call(parameters, what: "create_link (episode)")
            guard let link = StalkerParse.vodLink(envelope.js, streamServerBase: StalkerPortal.streamServerBase(for: api), mac: portal.mac, linkType: "series"),
                  let url = URL(string: link)
            else { throw noLink(envelope, what: "create_link (episode)") }
            return StreamLink(url: url, headers: headers, formatHint: Self.hint(for: url, fallback: .fromExtension(episode.containerExtension)))
        }
    }

    /// Catch-up (unverified — check with the probe): find the archived
    /// programme's id in the day's guide table, then ask `tv_archive` for a
    /// link to `auto /media/<id>.mpg`, as the MAG portal UI does.
    private func catchupLink(channel: RemoteChannel, start: Date, duration: TimeInterval, portal: StalkerPortal, headers: [String: String]) async throws -> StreamLink {
        let guideID = channel.guideChannelID ?? channel.id
        let day = StalkerParse.dayString(start, timeZone: portal.timeZone)
        var programmeID: String?
        for page in 0..<12 {
            let envelope = try await call(
                [("type", "epg"), ("action", "get_simple_data_table"), ("ch_id", guideID), ("date", day), ("p", StalkerParse.portalPage(page))],
                what: "get_simple_data_table"
            )
            let list = StalkerParse.listPage(envelope.js)
            programmeID = StalkerParse.programmeID(in: list.items, startingAt: start, timeZone: portal.timeZone)
            if programmeID != nil || !list.hasMore(after: page) { break }
        }
        guard let programmeID else {
            throw SourceError(.noLink, detail: "No programme in the portal's guide starts at the requested time")
        }
        let envelope = try await call(
            [("type", "tv_archive"), ("action", "create_link"), ("cmd", "auto /media/\(programmeID).mpg")],
            what: "create_link (tv_archive)"
        )
        guard let link = StalkerParse.liveLink(envelope.js), let url = URL(string: link) else {
            throw noLink(envelope, what: "create_link (tv_archive)")
        }
        return StreamLink(url: url, headers: headers, formatHint: Self.hint(for: url, fallback: channel.formatHint), isLive: false)
    }

    // MARK: Signing in

    /// Signs in, or joins a sign-in already running.
    private func authenticate() async throws {
        if let authentication {
            return try await authentication.value
        }
        let task = Task { try await self.performAuthentication() }
        authentication = task
        defer { authentication = nil }
        try await task.value
    }

    /// Handshake → token, `get_profile` → signed in when `js.id` is set, and
    /// `do_auth` when the login has a username (Source protocols, Stalker).
    private func performAuthentication() async throws {
        let base = try portal.get()
        let (api, handshake) = try await discoverAndHandshake(base)
        self.api = api
        // A portal that accepts the offered (empty) token sends none back;
        // stalkerhek carries on without one, and so do we.
        token = handshake.js.string("token") ?? ""

        var portal = usesPlaceholderDeviceIDs ? base.withPlaceholderDeviceIDs : base
        var profile = try await sessionlessCall(portal.request(api, portal.profileParameters, token: token), what: "get_profile")
        var signedIn = StalkerParse.profileIsSignedIn(profile.js)

        // Blank device ids are refused by some portals that want stalkerhek's
        // placeholder; others refuse the placeholder ("Device conflict -
        // device_id mismatch") and take blank ids. Blank goes first; the
        // placeholder gets one try, on a fresh token, when blank was refused.
        if !signedIn, base.hasBlankDeviceIDs, !usesPlaceholderDeviceIDs {
            let retry = base.withPlaceholderDeviceIDs
            let fresh = try? await sessionlessCall(retry.request(api, [("type", "stb"), ("action", "handshake"), ("token", "")], token: nil), what: "handshake")
            let retryToken = fresh?.js.string("token") ?? token
            if let second = try? await sessionlessCall(retry.request(api, retry.profileParameters, token: retryToken), what: "get_profile"),
               StalkerParse.profileIsSignedIn(second.js) {
                portal = retry
                profile = second
                token = retryToken
                signedIn = true
                usesPlaceholderDeviceIDs = true
            }
        }

        if !portal.username.isEmpty {
            let form = portal.formRequest(api, [
                ("type", "stb"), ("action", "do_auth"),
                ("login", portal.username), ("password", portal.password),
                ("device_id", portal.deviceID), ("device_id2", portal.deviceID2),
            ], token: token)
            let answer = try await sessionlessCall(form, what: "do_auth")
            guard answer.js.truthy else {
                token = nil
                throw SourceError(.authenticationFailed, providerMessage: scrubbed(answer.message), detail: "do_auth refused the username and password")
            }
            if !signedIn {
                profile = try await sessionlessCall(portal.request(api, portal.profileParameters, token: token), what: "get_profile")
                // do_auth said yes; a portal that still leaves `id` out is trusted.
                signedIn = true
            }
        }

        guard signedIn else {
            token = nil
            throw SourceError(.authenticationFailed, providerMessage: scrubbed(profile.message), detail: "get_profile returned no account id for this MAC")
        }
        self.profile = profile.js
    }

    /// Tries the remembered endpoint, then every candidate path, until a
    /// handshake answers with a portal envelope. A host that can't be reached
    /// at all fails at once: other paths on it won't answer either.
    private func discoverAndHandshake(_ portal: StalkerPortal) async throws -> (URL, StalkerEnvelope) {
        var candidates = portal.candidateAPIURLs
        if let api {
            candidates.removeAll { $0 == api }
            candidates.insert(api, at: 0)
        }
        guard !candidates.isEmpty else { throw SourceError(.invalidConfiguration, detail: "The portal URL has no host") }
        var tried: Set<URL> = []
        var lastResponse: HTTPResponse?

        for candidate in candidates where tried.insert(candidate).inserted {
            switch try await handshake(at: candidate, portal: portal) {
            case .answered(let envelope): return (candidate, envelope)
            case .notAPortal(let response): lastResponse = response
            case .noAnswer: break
            }
        }

        // Nothing answered on the typed host. Some providers give out a host
        // that only redirects its root to the real portal and 404s every API
        // path itself (iSTB follows the hop); see where the typed page and the
        // root land, and try the same paths there.
        redirects: for base in await redirectTargets(of: portal) {
            for candidate in portal.candidateAPIURLs(from: base) where tried.insert(candidate).inserted {
                do {
                    switch try await handshake(at: candidate, portal: portal) {
                    case .answered(let envelope): return (candidate, envelope)
                    case .notAPortal(let response): lastResponse = response
                    case .noAnswer: break
                    }
                } catch let error as SourceError where error.code == .unreachable {
                    continue redirects // that host is down; the next target may not be
                }
            }
        }

        let refused = lastResponse.map { $0.status == 401 || $0.status == 403 } ?? false
        throw SourceError(
            refused ? .authenticationFailed : .badResponse,
            providerMessage: scrubbed(lastResponse?.plainText),
            detail: "No Stalker API answered the handshake (tried \(tried.count) paths)"
        )
    }

    private enum HandshakeOutcome {
        case answered(StalkerEnvelope)
        /// It answered, but not as a portal (a 404 page, a login wall).
        case notAPortal(HTTPResponse)
        case noAnswer
    }

    /// One handshake attempt. A host that can't be reached at all throws, so
    /// discovery stops at once; a wrong path is just not a portal.
    private func handshake(at candidate: URL, portal: StalkerPortal) async throws -> HandshakeOutcome {
        try Task.checkCancellation()
        let request = portal.request(candidate, [("type", "stb"), ("action", "handshake"), ("token", "")], token: nil)
        let response: HTTPResponse
        do {
            response = try await HTTP.sendRaw(request, session: session)
        } catch {
            if HTTP.isHostFailure(error) || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw HTTP.sourceError(for: error, host: candidate.host())
            }
            return .noAnswer
        }
        if response.isSuccess, let envelope = StalkerEnvelope(data: response.data), envelope.js.object != nil {
            return .answered(envelope)
        }
        return .notAPortal(response)
    }

    /// Where the typed page and the typed host's root end up after redirects,
    /// when that is another origin.
    private func redirectTargets(of portal: StalkerPortal) async -> [URL] {
        guard let typedOrigin = StalkerPortal.origin(of: portal.typedURL) else { return [] }
        var targets: [URL] = []
        for page in [portal.typedURL, URL(string: typedOrigin + "/")].compactMap({ $0 }) {
            guard let response = try? await HTTP.sendRaw(portal.pageRequest(page), session: session),
                  let landed = response.url,
                  let origin = StalkerPortal.origin(of: landed),
                  origin != typedOrigin,
                  !targets.contains(where: { StalkerPortal.origin(of: $0) == origin })
            else { continue }
            targets.append(landed)
        }
        return targets
    }

    /// A call made while signing in: no retry, since signing in is the retry.
    private func sessionlessCall(_ request: URLRequest, what: String) async throws -> StalkerEnvelope {
        let response = try await HTTP.send(request, session: session)
        switch classify(response, what: what) {
        case .envelope(let envelope):
            return envelope
        case .unauthorised(let message):
            throw SourceError(.authenticationFailed, providerMessage: message, detail: "\(what) was refused")
        case .unreadable(let message):
            throw SourceError(.badResponse, providerMessage: message, detail: "\(what) didn't answer with a portal envelope")
        case .failure(let error):
            throw error
        }
    }

    // MARK: Calls

    /// The portal and endpoint of a live session, signing in first if needed.
    private func sessionEndpoint() async throws -> (portal: StalkerPortal, api: URL) {
        let portal = try portal.get()
        if let api, token != nil { return (portal, api) }
        try await authenticate()
        guard let api else { throw SourceError(.unreachable, detail: "Signed in without an endpoint") }
        return (portal, api)
    }

    /// One API call with the session. On an auth error, or an answer that
    /// isn't an envelope (an expired token often gets plain text), the
    /// session is dropped and the call made once more after a new handshake.
    private func call(_ parameters: [(String, String)], what: String) async throws -> StalkerEnvelope {
        var retried = false
        while true {
            let (portal, api) = try await sessionEndpoint()
            let response = try await HTTP.send(portal.request(api, parameters, token: token), session: session)
            switch classify(response, what: what) {
            case .envelope(let envelope):
                return envelope
            case .unauthorised(let message):
                guard !retried else {
                    throw SourceError(.authenticationFailed, providerMessage: message, detail: "\(what) refused a fresh session")
                }
            case .unreadable(let message):
                guard !retried else {
                    throw SourceError(.badResponse, providerMessage: message, detail: "\(what) didn't answer with a portal envelope")
                }
            case .failure(let error):
                throw error
            }
            retried = true
            token = nil
        }
    }

    private enum Answer {
        case envelope(StalkerEnvelope)
        case unauthorised(String?)
        case unreadable(String?)
        case failure(SourceError)
    }

    private func classify(_ response: HTTPResponse, what: String) -> Answer {
        if response.status == 401 || response.status == 403 {
            return .unauthorised(scrubbed(response.plainText))
        }
        guard response.isSuccess else {
            var error = HTTP.statusError(response, what: what)
            error.providerMessage = scrubbed(error.providerMessage)
            return .failure(error)
        }
        if let envelope = StalkerEnvelope(data: response.data) {
            if envelope.saysUnauthorised, envelope.js.isNull || envelope.js == .bool(false) {
                return .unauthorised(scrubbed(envelope.message ?? envelope.text))
            }
            return .envelope(envelope)
        }
        let text = response.plainText
        if let lowered = text?.lowercased(), lowered.contains("authorization failed") || lowered.contains("unauthorized") {
            return .unauthorised(scrubbed(text))
        }
        return .unreadable(scrubbed(text))
    }

    // MARK: Account

    /// The profile plus `account_info` / `get_main_info` (unverified, read
    /// tolerantly: a portal without it still signs in).
    private func currentAccount() async -> AccountInfo {
        let main = try? await call([("type", "account_info"), ("action", "get_main_info")], what: "get_main_info")
        let zone = (try? portal.get().timeZone) ?? .current
        return StalkerParse.account(profile: profile, mainInfo: main?.js, timeZone: zone, now: Date())
    }

    // MARK: Helpers

    /// Pages `get_ordered_list` to the end, dropping repeats (stalkerhek
    /// de-duplicates by id and cmd: some portals repeat a row across pages).
    private func allRows(_ parameters: [(String, String)], what: String) async throws -> [JSONValue] {
        var rows: [JSONValue] = []
        var seen: Set<String> = []
        for page in 0..<Self.maxPages {
            let envelope = try await call(parameters + [("p", StalkerParse.portalPage(page))], what: what)
            let list = StalkerParse.listPage(envelope.js)
            for row in list.items {
                let key = (row.string("id") ?? "") + "|" + (row.string("cmd") ?? "")
                if seen.insert(key).inserted { rows.append(row) }
            }
            if !list.hasMore(after: page) { break }
        }
        return rows
    }

    private func seriesList(module: String, categoryID: String?, page: Int) async throws -> StalkerListPage {
        let envelope = try await call(
            [("type", module), ("action", "get_ordered_list"), ("category", categoryID ?? "*"), ("sortby", "added"), ("p", StalkerParse.portalPage(page))],
            what: "get_ordered_list"
        )
        return StalkerParse.listPage(envelope.js)
    }

    private func noLink(_ envelope: StalkerEnvelope, what: String) -> SourceError {
        SourceError(.noLink, providerMessage: scrubbed(envelope.message), detail: "\(what) answered without a URL")
    }

    /// Provider text with this login's MAC and secrets masked: error pages
    /// sometimes quote the request back (PRIV-2).
    private func scrubbed(_ text: String?) -> String? {
        text.map { Redaction.scrub($0, for: configuration) }
    }

    /// The URL in a channel's own `cmd` when `create_link` gives none — but
    /// not Ministra's `http://localhost/ch/…` placeholder, which only
    /// create_link can turn into a real address.
    static func directURL(in command: String) -> String? {
        guard let word = StalkerParse.lastWord(of: command), word.contains("://"),
              let host = URL(string: word)?.host(), host != "localhost", host != "127.0.0.1"
        else { return nil }
        return word
    }

    static func hint(for url: URL, fallback: StreamFormatHint) -> StreamFormatHint {
        let guess = StreamFormatHint.guess(fromURL: url)
        return guess == .unknown ? fallback : guess
    }

    /// Enough pages for any catalog a portal pages through (14 rows a page on
    /// Ministra) without looping forever on one that never says it's done.
    static let maxPages = 400
}
