import Foundation

/// One protocol over the three provider types. CatalogKit drives it; nothing
/// else talks to a provider. Implementations are actors or otherwise
/// Sendable, keep any session (Stalker's token) in memory, and re-authenticate
/// once on an auth error before failing.
public protocol SourceClient: Sendable {
    var configuration: SourceConfiguration { get }
    var capabilities: SourceCapabilities { get }

    /// Signs in (Stalker handshake + profile, optional `do_auth`; Xtream
    /// account call; M3U fetches the playlist header) and reports the account.
    /// Throws `SourceError` with the provider's text on refusal.
    func signIn() async throws -> AccountInfo

    /// The account as of now: expiry, and for Xtream the stream limit and use.
    func accountInfo() async throws -> AccountInfo

    func categories(_ kind: ContentKind) async throws -> [RemoteCategory]

    /// Every live channel across categories.
    func channels() async throws -> [RemoteChannel]

    /// One page of movies; `categoryID == nil` asks for all where the provider allows.
    func movies(categoryID: String?, page: Int) async throws -> Page<RemoteMovie>

    func series(categoryID: String?, page: Int) async throws -> Page<RemoteSeries>

    /// Seasons and episodes, fetched when a show is opened.
    func seriesDetail(_ series: RemoteSeries) async throws -> SeriesDetail

    /// The next few programmes for one channel (Stalker short guide, Xtream
    /// `get_short_epg`).
    func shortGuide(for channel: RemoteChannel, limit: Int) async throws -> [RemoteProgramme]

    /// The whole guide as a stream (XMLTV parsed incrementally), or nil when
    /// the source has none and the short guide is all there is.
    func fullGuide() -> AsyncThrowingStream<RemoteProgramme, Error>?

    /// A fresh link to play. Never cached by callers.
    func streamLink(for request: StreamRequest) async throws -> StreamLink

    /// Keeps a session alive while something plays (Stalker watchdog every
    /// few minutes). A no-op for sessionless sources.
    func keepAlive() async
}

/// Makes the right client for a configuration. `URLSession` is injectable so
/// tests can route everything through a `URLProtocol` stub.
public enum SourceClientFactory {
    public static func make(_ configuration: SourceConfiguration, session: URLSession = .shared) -> any SourceClient {
        if configuration.serverURL == StubSourceClient.serverURL || configuration.playlistURL == StubSourceClient.serverURL {
            return StubSourceClient(configuration: configuration)
        }
        switch configuration.kind {
        case .stalker:
            return StalkerClient(configuration: configuration, session: session)
        case .xtream:
            return XtreamClient(configuration: configuration, session: session)
        case .m3u:
            return M3UClient(configuration: configuration, session: session)
        }
    }
}

extension SourceConfiguration {
    /// A copy safe to print: MAC, logins and device ids masked (PRIV-2).
    /// `00:1A:79:AA:BB:41` → `00:1A:79:••:••:41`.
    public var redacted: SourceConfiguration {
        var copy = self
        copy.macAddress = Redaction.mac(macAddress)
        copy.username = Redaction.secret(username)
        copy.password = Redaction.secret(password)
        copy.serialNumber = Redaction.secret(serialNumber)
        copy.deviceID = Redaction.secret(deviceID)
        copy.deviceID2 = Redaction.secret(deviceID2)
        copy.signature = Redaction.secret(signature)
        copy.playlistURL = Redaction.url(playlistURL)
        copy.guideURL = Redaction.url(guideURL)
        return copy
    }

    /// The stub provider used by `-StubProvider YES`: channels, a guide,
    /// movies and shows built from Apple's public HLS samples, no login.
    public static func stub(id: UUID = UUID(uuidString: "5A1E5A1E-0000-4000-8000-000000000001")!, name: String = "Demo Provider") -> SourceConfiguration {
        SourceConfiguration(id: id, name: name, kind: .stalker, serverURL: StubSourceClient.serverURL, macAddress: "00:1A:79:00:00:01")
    }
}

/// Masking for anything that might reach a log, the probe's output or a fixture.
public enum Redaction {
    public static func mac(_ mac: String) -> String {
        let parts = mac.split(separator: ":")
        guard parts.count == 6 else { return secret(mac) }
        return (parts.prefix(3) + ["••", "••"] + [parts[5]]).joined(separator: ":")
    }

    public static func secret(_ value: String) -> String {
        value.isEmpty ? "" : "•••"
    }

    /// Keeps scheme and host, drops path and query (which often carry logins).
    public static func url(_ value: String) -> String {
        guard let url = URL(string: value), let host = url.host() else { return secret(value) }
        return "\(url.scheme ?? "http")://\(host)/•••"
    }
}
