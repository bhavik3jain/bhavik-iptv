import Foundation
import Testing
@testable import SourceKit

/// Path discovery past a vanity host: some providers hand out a host that
/// only redirects its root (or the typed page) to the real portal and 404s
/// every API path itself; the client follows the hop as iSTB does.
@Suite struct StalkerRedirectTests {
    static let notFound = StubURLProtocol.Reply.text("<html><body><h1>404 Not Found</h1></body></html>", status: 404)

    /// A host where every path is the 404 page except those `redirects`
    /// sends on (by path, e.g. `/` or `/c/`).
    static func vanityHost(redirects: [String: String]) -> String {
        let host = StubURLProtocol.makeHost("vanity")
        _ = StubURLProtocol.session(host: host) { request in
            if let target = redirects[request.url?.path() ?? ""] { return .redirect(to: target) }
            return notFound
        }
        return host
    }

    static func client(typed: String, session: URLSession) -> StalkerClient {
        StalkerClient(
            configuration: SourceConfiguration(name: "Portal", kind: .stalker, serverURL: typed, macAddress: StalkerClientTests.mac, timeZone: "Europe/London"),
            session: session
        )
    }

    static func handshakes(on host: String) -> [URLRequest] {
        StubURLProtocol.requests(for: host).filter { $0.query["action"] == "handshake" }
    }

    @Test func theStubFollowsRedirectsLikeAWebServer() async throws {
        let target = StalkerClientTests.Portal()
        let vanity = Self.vanityHost(redirects: ["/": "http://\(target.host)/stalker_portal/server/load.php?type=stb&action=handshake&token="])
        let (data, response) = try await target.session.data(from: URL(string: "http://\(vanity)/")!)
        #expect(response.url?.host() == target.host)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("token"))
    }

    @Test func aRootRedirectLeadsToTheRealPortal() async throws {
        let portal = StalkerClientTests.Portal()
        let vanity = Self.vanityHost(redirects: ["/": "http://\(portal.host)/"])
        let client = Self.client(typed: "http://\(vanity)/c/", session: portal.session)

        let account = try await client.signIn()
        #expect(account.status == .active)
        // Every API path on the typed host was tried, and none answered.
        #expect(Self.handshakes(on: vanity).count == 5)
        #expect(portal.count("handshake") == 1)
        // The real portal is called with its own origin in the headers.
        let profile = try #require(portal.requests("get_profile").first)
        #expect(profile.url?.path() == "/stalker_portal/server/load.php")
        #expect(profile.value(forHTTPHeaderField: "Referer") == "http://\(portal.host)/")

        // Later calls go straight to the redirected origin.
        let before = StubURLProtocol.requests(for: vanity).count
        _ = try await client.channels()
        #expect(portal.count("get_all_channels") == 1)
        #expect(StubURLProtocol.requests(for: vanity).count == before)
    }

    @Test func theTypedPagesRedirectKeepsItsPath() async throws {
        let portal = StalkerClientTests.Portal()
        let vanity = Self.vanityHost(redirects: ["/c/": "http://\(portal.host)/stalker_portal/c/"])
        let client = Self.client(typed: "http://\(vanity)/c/", session: portal.session)

        _ = try await client.signIn()
        // The landed page's own path is the first candidate there.
        let handshakes = Self.handshakes(on: portal.host)
        #expect(handshakes.count == 1)
        #expect(handshakes.first?.url?.path() == "/stalker_portal/server/load.php")
    }

    @Test func anUnreachableTargetIsSkippedForTheNext() async throws {
        let portal = StalkerClientTests.Portal()
        // The typed page lands on a host whose API can't be reached; the
        // root lands on the real portal.
        let flaky = StubURLProtocol.makeHost("flaky")
        _ = StubURLProtocol.session(host: flaky) { request in
            if request.url?.path() == "/c/" { return .text("<html>player</html>") }
            throw StubURLProtocol.TransportFailure(code: .cannotConnectToHost)
        }
        let vanity = Self.vanityHost(redirects: ["/c/": "http://\(flaky)/c/", "/": "http://\(portal.host)/"])
        let client = Self.client(typed: "http://\(vanity)/c/", session: portal.session)

        let account = try await client.signIn()
        #expect(account.status == .active)
        #expect(Self.handshakes(on: flaky).count == 1) // one failure ends that host
        #expect(portal.count("handshake") == 1)
    }

    // MARK: Nothing to follow

    @Test func noRedirectAndEveryPath404IsABadResponse() async {
        let vanity = Self.vanityHost(redirects: [:])
        let client = Self.client(typed: "http://\(vanity)/c/", session: StubURLProtocol.session(host: StubURLProtocol.makeHost()) { _ in Self.notFound })
        let error = await sourceError { try await client.signIn() }
        #expect(error?.code == .badResponse)
        #expect(error?.providerMessage == "404 Not Found")
        #expect(Self.handshakes(on: vanity).count == 5)
    }

    @Test func aRedirectWithinTheSameOriginIsNotFollowed() async {
        // The root sends to the host's own player page: nothing new to try.
        let vanity = Self.vanityHost(redirects: ["/": "/c/index.html"])
        let client = Self.client(typed: "http://\(vanity)/c/", session: StubURLProtocol.session(host: StubURLProtocol.makeHost()) { _ in Self.notFound })
        let error = await sourceError { try await client.signIn() }
        #expect(error?.code == .badResponse)
        #expect(Self.handshakes(on: vanity).count == 5)
        // The hop was followed, and led nowhere new.
        #expect(StubURLProtocol.requests(for: vanity).contains { $0.url?.path() == "/c/index.html" })
    }

    @Test func aRedirectToSomethingElseThatIsNotAPortalIsABadResponse() async {
        let elsewhere = StalkerClientTests.Portal(apiPath: "/nowhere.php")
        let vanity = Self.vanityHost(redirects: ["/": "http://\(elsewhere.host)/"])
        let client = Self.client(typed: "http://\(vanity)/c/", session: elsewhere.session)
        let error = await sourceError { try await client.signIn() }
        #expect(error?.code == .badResponse)
        #expect(error?.providerMessage == "404 Not Found")
        #expect(Self.handshakes(on: elsewhere.host).count == 5)
    }

    @Test func aRedirectToADeadHostIsStillABadResponse() async {
        // The typed host answered (404s), so the portal isn't "unreachable".
        let vanity = Self.vanityHost(redirects: ["/": "http://\(StubURLProtocol.makeHost("dead"))/"])
        let client = Self.client(typed: "http://\(vanity)/c/", session: StubURLProtocol.session(host: StubURLProtocol.makeHost()) { _ in Self.notFound })
        let error = await sourceError { try await client.signIn() }
        #expect(error?.code == .badResponse)
    }
}
