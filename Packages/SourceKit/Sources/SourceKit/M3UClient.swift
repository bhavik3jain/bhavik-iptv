import Foundation

// PLACEHOLDER — replaced by the SourceKit implementation (see docs/TRACKING.md).
// Every call fails with .notSupported so the rest of the app compiles against
// the protocol before the client exists.
public actor M3UClient: SourceClient {
    public nonisolated let configuration: SourceConfiguration
    private let session: URLSession

    public init(configuration: SourceConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public nonisolated var capabilities: SourceCapabilities {
        SourceCapabilities(hasMovies: false, hasSeries: false, hasFullGuide: true, hasCatchup: true, reportsStreamCount: false)
    }

    public func signIn() async throws -> AccountInfo { throw SourceError(.notSupported) }
    public func accountInfo() async throws -> AccountInfo { throw SourceError(.notSupported) }
    public func categories(_ kind: ContentKind) async throws -> [RemoteCategory] { throw SourceError(.notSupported) }
    public func channels() async throws -> [RemoteChannel] { throw SourceError(.notSupported) }
    public func movies(categoryID: String?, page: Int) async throws -> Page<RemoteMovie> { throw SourceError(.notSupported) }
    public func series(categoryID: String?, page: Int) async throws -> Page<RemoteSeries> { throw SourceError(.notSupported) }
    public func seriesDetail(_ series: RemoteSeries) async throws -> SeriesDetail { throw SourceError(.notSupported) }
    public func shortGuide(for channel: RemoteChannel, limit: Int) async throws -> [RemoteProgramme] { throw SourceError(.notSupported) }
    public nonisolated func fullGuide() -> AsyncThrowingStream<RemoteProgramme, Error>? { nil }
    public func streamLink(for request: StreamRequest) async throws -> StreamLink { throw SourceError(.notSupported) }
    public func keepAlive() async {}
}
