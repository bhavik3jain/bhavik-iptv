import Foundation
import Testing
@testable import SourceKit

/// Device ids in `get_profile`: blank by default, stalkerhek's 64-"f"
/// placeholder tried once (on a fresh handshake) when a portal refuses blank
/// ones, and an owner's own ids sent as given with no second guess (SRC-1).
@Suite struct StalkerDeviceIDTests {
    typealias Portal = StalkerClientTests.Portal

    static let placeholder = String(repeating: "f", count: 64)
    /// `get_profile` refusing the box: no account `id`.
    static let refused = StubURLProtocol.Reply.json(#"{"js":{"id":null,"name":null,"status":1},"text":"generated in: 0.004s"}"#)
    static let conflict = StubURLProtocol.Reply.json(#"{"js":{"id":null,"status":1,"msg":"Device conflict - device_id mismatch"}}"#)

    static func client(_ portal: Portal, deviceID: String = "", deviceID2: String = "", signature: String = "", username: String = "", password: String = "") -> StalkerClient {
        StalkerClient(
            configuration: SourceConfiguration(
                name: "Portal", kind: .stalker, serverURL: "http://\(portal.host)/stalker_portal/c/", macAddress: StalkerClientTests.mac,
                username: username, password: password, deviceID: deviceID, deviceID2: deviceID2, signature: signature, timeZone: "Europe/London"
            ),
            session: portal.session
        )
    }

    static func deviceFields(_ request: URLRequest?) -> [String?] {
        let query = request?.query ?? [:]
        return [query["device_id"], query["device_id2"], query["signature"]]
    }

    static func mentionsPlaceholder(_ portal: Portal) -> Bool {
        portal.requests.contains { request in
            (request.url?.absoluteString.contains(placeholder) ?? false)
                || String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains(placeholder)
        }
    }

    /// A handshake whose token names its attempt, so a test can tell which
    /// session a later call carries.
    static func numberedHandshake(_ attempt: Int) -> StubURLProtocol.Reply {
        .json(#"{"js":{"token":"TOKEN-\#(attempt)","random":"0"}}"#)
    }

    @Test func blankIDsGoFirstAndAPortalThatRefusesThePlaceholderSignsInAtOnce() async throws {
        let portal = Portal { action, request, _ in
            guard action == "get_profile" else { return nil }
            return request.query["device_id"] == Self.placeholder ? Self.conflict : nil
        }
        let account = try await Self.client(portal).signIn()
        #expect(account.status == .active)
        #expect(portal.count("handshake") == 1)
        #expect(portal.count("get_profile") == 1)
        #expect(Self.deviceFields(portal.requests("get_profile").first) == ["", "", ""])
        #expect(!Self.mentionsPlaceholder(portal))
    }

    @Test func aPortalThatRefusesBlankIDsTakesThePlaceholderOnAFreshHandshake() async throws {
        let portal = Portal { action, request, attempt in
            switch action {
            case "handshake": return Self.numberedHandshake(attempt)
            case "get_profile": return request.query["device_id"] == Self.placeholder ? nil : Self.refused
            default: return nil
            }
        }
        let client = Self.client(portal)
        let account = try await client.signIn()
        #expect(account.status == .active)
        #expect(portal.count("handshake") == 2)

        let profiles = portal.requests("get_profile")
        #expect(profiles.count == 2)
        #expect(Self.deviceFields(profiles.first) == ["", "", ""])
        #expect(profiles.first?.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN-1")
        #expect(Self.deviceFields(profiles.last) == [Self.placeholder, Self.placeholder, Self.placeholder])
        #expect(profiles.last?.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN-2")

        // The session that signed in is the one later calls carry.
        _ = try await client.channels()
        #expect(portal.requests("get_all_channels").first?.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN-2")

        // Later sign-ins go straight to the placeholder.
        _ = try await client.signIn()
        #expect(portal.count("handshake") == 3)
        #expect(portal.count("get_profile") == 3)
        #expect(Self.deviceFields(portal.requests("get_profile").last) == [Self.placeholder, Self.placeholder, Self.placeholder])
    }

    @Test func doAuthCarriesThePlaceholderOnceItSignedIn() async throws {
        let portal = Portal { action, request, _ in
            switch action {
            case "get_profile": return request.query["device_id"] == Self.placeholder ? nil : Self.refused
            case "do_auth": return .json(#"{"js":true}"#)
            default: return nil
            }
        }
        _ = try await Self.client(portal, username: "demo-user", password: "demo-pass").signIn()
        let auth = try #require(portal.requests("do_auth").first)
        #expect(auth.form["device_id"] == Self.placeholder)
        #expect(auth.form["device_id2"] == Self.placeholder)
    }

    @Test func refusedBothWaysFailsWithThePortalsWordsForTheBox() async {
        let portal = Portal { action, request, _ in
            guard action == "get_profile" else { return nil }
            return request.query["device_id"] == Self.placeholder ? Self.conflict : .fixture("stalker/profile_unknown_mac.json")
        }
        let error = await sourceError { try await Self.client(portal).signIn() }
        #expect(error?.code == .authenticationFailed)
        #expect(error?.providerMessage == "Your STB is not registered. Please contact your provider.")
        // One placeholder try, no more.
        #expect(portal.count("get_profile") == 2)
        #expect(portal.count("handshake") == 2)
    }

    @Test func theOwnersIDsAreSentAsGiven() async throws {
        let portal = Portal()
        _ = try await Self.client(portal, deviceID: " DEV-ID-1 ", deviceID2: "DEV-ID-2", signature: "SIG-1").signIn()
        #expect(portal.count("get_profile") == 1)
        #expect(Self.deviceFields(portal.requests("get_profile").first) == ["DEV-ID-1", "DEV-ID-2", "SIG-1"])
    }

    @Test(arguments: [
        ("DEV-ID-1", "", ""),
        ("", "DEV-ID-2", ""),
        ("", "", "SIG-1"),
    ])
    func anyOwnerIDMeansNoPlaceholderRetry(deviceID: String, deviceID2: String, signature: String) async {
        let portal = Portal { action, _, _ in action == "get_profile" ? Self.refused : nil }
        let error = await sourceError { try await Self.client(portal, deviceID: deviceID, deviceID2: deviceID2, signature: signature).signIn() }
        #expect(error?.code == .authenticationFailed)
        #expect(portal.count("handshake") == 1)
        #expect(portal.count("get_profile") == 1)
        // What the owner left blank stays blank.
        #expect(Self.deviceFields(portal.requests("get_profile").first) == [deviceID, deviceID2, signature])
        #expect(!Self.mentionsPlaceholder(portal))
    }
}
