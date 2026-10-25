import Foundation

/// An M3U playlist (by URL or a `file://` copy in the app's container) with
/// an XMLTV guide from the playlist header or typed in (SRC-3).
///
/// The playlist is the catalog: one download, read line by line. It's kept
/// for a couple of minutes so a refresh's `signIn`, `categories` and
/// `channels` read one copy rather than three.
public actor M3UClient: SourceClient {
    public nonisolated let configuration: SourceConfiguration
    private let session: URLSession
    private var playlist: M3UPlaylist?
    private var loadedAt: Date?
    private static let reuseInterval: TimeInterval = 120

    public init(configuration: SourceConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public nonisolated var capabilities: SourceCapabilities {
        SourceCapabilities(hasMovies: false, hasSeries: false, hasFullGuide: true, hasCatchup: true, reportsStreamCount: false)
    }

    // MARK: Account

    /// Fetches the playlist and checks it is one: there's no login to test.
    public func signIn() async throws -> AccountInfo {
        let playlist = try await load(force: true)
        guard playlist.sawHeader || !playlist.entries.isEmpty else {
            throw SourceError(.badResponse, detail: "The file isn't an M3U playlist (no #EXTM3U header and no streams)")
        }
        return AccountInfo(status: .active)
    }

    /// A playlist has no account; it's active while it downloads.
    public func accountInfo() async throws -> AccountInfo {
        AccountInfo(status: .active)
    }

    public func keepAlive() async {}

    // MARK: Catalog

    public func categories(_ kind: ContentKind) async throws -> [RemoteCategory] {
        guard kind == .live else { return [] }
        return M3UCatalog.categories(try await load(force: false))
    }

    public func channels() async throws -> [RemoteChannel] {
        M3UCatalog.channels(try await load(force: false))
    }

    public func movies(categoryID: String?, page: Int) async throws -> Page<RemoteMovie> {
        Page(items: [], page: page, totalItems: 0, hasMore: false)
    }

    public func series(categoryID: String?, page: Int) async throws -> Page<RemoteSeries> {
        Page(items: [], page: page, totalItems: 0, hasMore: false)
    }

    public func seriesDetail(_ series: RemoteSeries) async throws -> SeriesDetail {
        throw SourceError(.notSupported, detail: "M3U playlists carry no series detail")
    }

    // MARK: Guide

    /// A playlist has no per-channel guide call; the XMLTV guide is it.
    public func shortGuide(for channel: RemoteChannel, limit: Int) async throws -> [RemoteProgramme] {
        []
    }

    /// The typed guide URL, else every guide the playlist header names, read
    /// one after another into one stream. When the header names none the
    /// stream simply ends empty — that's only known once the playlist is read.
    public nonisolated func fullGuide() -> AsyncThrowingStream<RemoteProgramme, Error>? {
        let session = self.session
        if let typed = URL(string: configuration.guideURL.trimmingCharacters(in: .whitespaces)), typed.scheme != nil {
            return XMLTVGuide.programmes(from: typed, session: session)
        }
        return ProgrammeStream.make { channel in
            let urls = try await self.headerGuideURLs()
            for url in urls {
                try Task.checkCancellation()
                try await XMLTVGuide.fetch(url, session: session, headers: [:], into: channel)
            }
        }
    }

    // MARK: Links

    public func streamLink(for request: StreamRequest) async throws -> StreamLink {
        switch request {
        case .live(let channel):
            guard let url = URL(string: channel.command) else { throw SourceError(.noLink, detail: "The playlist's URL for this channel is malformed") }
            return StreamLink(url: url, headers: channel.headers, formatHint: channel.formatHint == .unknown ? .guess(fromURL: url) : channel.formatHint, isLive: true)
        case .catchup(let channel, let start, let duration):
            guard let url = M3UCatchup.url(for: channel, start: start, duration: duration) else {
                throw SourceError(.notSupported, detail: "This channel's playlist entry has no usable catch-up")
            }
            return StreamLink(url: url, headers: channel.headers, formatHint: .guess(fromURL: url))
        case .movie(let movie):
            guard let command = movie.command, let url = URL(string: command) else { throw SourceError(.noLink) }
            return StreamLink(url: url, formatHint: .guess(fromURL: url))
        case .episode(let episode, _):
            guard let command = episode.command, let url = URL(string: command) else { throw SourceError(.noLink) }
            return StreamLink(url: url, formatHint: .guess(fromURL: url))
        }
    }

    // MARK: Loading

    private func headerGuideURLs() async throws -> [URL] {
        try await load(force: false).guideURLs
    }

    private func load(force: Bool) async throws -> M3UPlaylist {
        if !force, let playlist, let loadedAt, Date().timeIntervalSince(loadedAt) < Self.reuseInterval {
            return playlist
        }
        let text = configuration.playlistURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else {
            throw SourceError(.invalidConfiguration, detail: "The playlist address isn't a web or file URL")
        }
        let parsed = try await M3UClient.read(url, session: session, configuration: configuration)
        playlist = parsed
        loadedAt = Date()
        return parsed
    }

    /// Downloads (or opens) the playlist and parses it a line at a time.
    static func read(_ url: URL, session: URLSession, configuration: SourceConfiguration) async throws -> M3UPlaylist {
        let request = URLRequest(url: url, timeoutInterval: HTTP.downloadTimeout)
        let download = try await HTTP.download(request, session: session)
        defer { if download.isTemporary { try? FileManager.default.removeItem(at: download.file) } }
        guard (200..<300).contains(download.status) else {
            let text = (try? Data(contentsOf: download.file)).flatMap { HTTP.plainText(from: $0) }.map { Redaction.scrub($0, for: configuration) }
            let code: SourceError.Code = download.status == 401 || download.status == 403 ? .authenticationFailed : .badResponse
            throw SourceError(code, providerMessage: text, detail: "The playlist answered HTTP \(download.status)")
        }
        var parser = M3UParser()
        do {
            for try await line in download.file.lines {
                parser.consume(line)
            }
        } catch is CancellationError {
            throw SourceError(.cancelled)
        } catch {
            throw SourceError(.badResponse, detail: "The playlist couldn't be read as text")
        }
        return parser.playlist
    }
}
