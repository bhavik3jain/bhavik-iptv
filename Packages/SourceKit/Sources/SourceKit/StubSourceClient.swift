import Foundation

// PLACEHOLDER — replaced by the SourceKit implementation (see docs/TRACKING.md).
// The real stub serves a believable catalog (channels named like the mockups,
// a generated guide around "now", movies and shows) whose streams are Apple's
// public HLS samples, so a simulator shows everything with no login.
public actor StubSourceClient: SourceClient {
    /// A source whose server URL is this is served by the stub.
    public static let serverURL = "stub://hearth.demo"

    public nonisolated let configuration: SourceConfiguration

    public init(configuration: SourceConfiguration) {
        self.configuration = configuration
    }

    public nonisolated var capabilities: SourceCapabilities {
        SourceCapabilities(hasMovies: true, hasSeries: true, hasFullGuide: true, hasCatchup: true, reportsStreamCount: false)
    }

    public func signIn() async throws -> AccountInfo { AccountInfo(status: .active) }
    public func accountInfo() async throws -> AccountInfo { AccountInfo(status: .active) }
    public func categories(_ kind: ContentKind) async throws -> [RemoteCategory] { [] }
    public func channels() async throws -> [RemoteChannel] { [] }
    public func movies(categoryID: String?, page: Int) async throws -> Page<RemoteMovie> { Page(items: [], page: page, hasMore: false) }
    public func series(categoryID: String?, page: Int) async throws -> Page<RemoteSeries> { Page(items: [], page: page, hasMore: false) }
    public func seriesDetail(_ series: RemoteSeries) async throws -> SeriesDetail { SeriesDetail(series: series, seasons: [], episodes: []) }
    public func shortGuide(for channel: RemoteChannel, limit: Int) async throws -> [RemoteProgramme] { [] }
    public nonisolated func fullGuide() -> AsyncThrowingStream<RemoteProgramme, Error>? { nil }
    public func streamLink(for request: StreamRequest) async throws -> StreamLink { throw SourceError(.noLink) }
    public func keepAlive() async {}
}
