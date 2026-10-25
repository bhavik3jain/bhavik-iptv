import Foundation

/// The provider behind `-StubProvider YES`: a believable catalog (channels
/// named like the mockups, a guide from a week back to a week ahead, movies
/// and shows) whose streams are Apple's public HLS samples, so a simulator
/// shows everything with no login and no real provider (technical spec,
/// Debug launch arguments).
///
/// Everything is deterministic: the same day gives the same catalog, and any
/// window of the guide agrees with any other. A short artificial delay makes
/// loading states visible without slowing anything down.
public actor StubSourceClient: SourceClient {
    /// A source whose server URL is this is served by the stub.
    public static let serverURL = "stub://hearth.demo"

    /// Movies per page, small enough that the library pages at least once.
    static let moviePageSize = 20

    public nonisolated let configuration: SourceConfiguration
    private let latency: Duration

    public init(configuration: SourceConfiguration) {
        self.init(configuration: configuration, latency: .milliseconds(80))
    }

    /// Tests pass zero latency.
    init(configuration: SourceConfiguration, latency: Duration) {
        self.configuration = configuration
        self.latency = latency
    }

    public nonisolated var capabilities: SourceCapabilities {
        SourceCapabilities(hasMovies: true, hasSeries: true, hasFullGuide: true, hasCatchup: true, reportsStreamCount: false)
    }

    // MARK: Account

    public func signIn() async throws -> AccountInfo {
        await pause()
        return Self.account(now: Date())
    }

    public func accountInfo() async throws -> AccountInfo {
        await pause()
        return Self.account(now: Date())
    }

    public func keepAlive() async {}

    static func account(now: Date) -> AccountInfo {
        let today = floor(now.timeIntervalSince1970 / 86_400) * 86_400
        return AccountInfo(status: .active, expiresAt: Date(timeIntervalSince1970: today + 180 * 86_400), message: "Demo provider — sample streams only")
    }

    // MARK: Catalog

    public func categories(_ kind: ContentKind) async throws -> [RemoteCategory] {
        await pause()
        switch kind {
        case .live: return StubCatalog.liveCategories
        case .vod: return StubCatalog.movieCategories
        case .series: return StubCatalog.seriesCategories
        }
    }

    public func channels() async throws -> [RemoteChannel] {
        await pause()
        return StubCatalog.channels
    }

    public func movies(categoryID: String?, page: Int) async throws -> Page<RemoteMovie> {
        await pause()
        let all = StubCatalog.movies(now: Date()).filter { categoryID == nil || $0.categoryID == categoryID }
        let start = max(page, 0) * Self.moviePageSize
        let items = start < all.count ? Array(all[start..<min(start + Self.moviePageSize, all.count)]) : []
        return Page(items: items, page: page, totalItems: all.count, hasMore: start + Self.moviePageSize < all.count)
    }

    public func series(categoryID: String?, page: Int) async throws -> Page<RemoteSeries> {
        await pause()
        guard page == 0 else { return Page(items: [], page: page, totalItems: nil, hasMore: false) }
        let all = StubCatalog.series(now: Date()).filter { categoryID == nil || $0.categoryID == categoryID }
        return Page(items: all, page: 0, totalItems: all.count, hasMore: false)
    }

    public func seriesDetail(_ series: RemoteSeries) async throws -> SeriesDetail {
        await pause()
        return StubCatalog.detail(for: series)
    }

    // MARK: Guide

    public func shortGuide(for channel: RemoteChannel, limit: Int) async throws -> [RemoteProgramme] {
        await pause()
        let now = Date()
        let programmes = StubCatalog.programmes(for: channel, from: now, to: now.addingTimeInterval(12 * 3600), now: now)
        return Array(programmes.prefix(max(limit, 1)))
    }

    /// Every channel's guide from 7 days back to 7 days ahead, generated as
    /// it's read.
    public nonisolated func fullGuide() -> AsyncThrowingStream<RemoteProgramme, Error>? {
        let now = Date()
        let from = now.addingTimeInterval(-7 * 86_400)
        let to = now.addingTimeInterval(7 * 86_400)
        // About 8,000 small values: buffering them all is fine for a demo.
        return AsyncThrowingStream { continuation in
            let task = Task {
                for channel in StubCatalog.channels {
                    if Task.isCancelled { break }
                    for programme in StubCatalog.programmes(for: channel, from: from, to: to, now: now) {
                        continuation.yield(programme)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Links

    public func streamLink(for request: StreamRequest) async throws -> StreamLink {
        await pause()
        switch request {
        case .live(let channel):
            guard let url = URL(string: channel.command) else { throw SourceError(.noLink) }
            return StreamLink(url: url, formatHint: channel.formatHint, isLive: true)
        case .catchup(let channel, _, _):
            guard channel.hasArchive else {
                throw SourceError(.notSupported, providerMessage: "This channel has no archive.")
            }
            guard let url = URL(string: channel.command) else { throw SourceError(.noLink) }
            return StreamLink(url: url, formatHint: channel.formatHint)
        case .movie(let movie):
            guard let url = URL(string: movie.command ?? StubCatalog.hlsSample(StubCatalog.stableSeed(movie.id))) else { throw SourceError(.noLink) }
            return StreamLink(url: url, formatHint: .hls)
        case .episode(let episode, _):
            guard let url = URL(string: episode.command ?? StubCatalog.hlsSample(episode.number)) else { throw SourceError(.noLink) }
            return StreamLink(url: url, formatHint: .hls)
        }
    }

    private func pause() async {
        guard latency > .zero else { return }
        try? await Task.sleep(for: latency)
    }
}
