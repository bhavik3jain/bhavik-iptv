import Foundation
import Synchronization
@testable import SourceKit

/// Fakes the network for one test at a time. Each test registers a handler
/// under a host of its own (`StubURLProtocol.makeHost()`) and gets a
/// `URLSession` routed here, so tests run in parallel without seeing each
/// other's requests. Every request is recorded for assertions.
final class StubURLProtocol: URLProtocol {
    struct Reply: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data

        static func json(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
        }

        static func text(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, headers: ["Content-Type": "text/html"], body: Data(text.utf8))
        }

        static func fixture(_ path: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Fixture.data(path))
        }
    }

    /// Thrown by a handler to fail the request at the transport level.
    struct TransportFailure: Error {
        let code: URLError.Code
    }

    typealias Handler = @Sendable (URLRequest) throws -> Reply

    private struct State {
        var handlers: [String: Handler] = [:]
        var requests: [String: [URLRequest]] = [:]
    }

    private static let state = Mutex(State())

    /// A host no other test uses.
    static func makeHost(_ prefix: String = "portal") -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8).lowercased()).test"
    }

    /// A session whose requests to `host` go to `handler`.
    static func session(host: String, handler: @escaping Handler) -> URLSession {
        state.withLock { $0.handlers[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func requests(for host: String) -> [URLRequest] {
        state.withLock { $0.requests[host] ?? [] }
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            recorded.httpBody = Self.read(stream)
        }
        let host = request.url?.host() ?? ""
        let handler = Self.state.withLock { state -> Handler? in
            state.requests[host, default: []].append(recorded)
            return state.handlers[host]
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        do {
            let reply = try handler(recorded)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch let failure as TransportFailure {
            client?.urlProtocol(self, didFailWithError: URLError(failure.code))
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension URLRequest {
    /// Query items by name (the last wins), for routing and assertions.
    var query: [String: String] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    /// A form body's fields.
    var form: [String: String] {
        guard let body = httpBody, let text = String(data: body, encoding: .utf8) else { return [:] }
        var components = URLComponents()
        components.percentEncodedQuery = text
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }
}

/// Fixtures under `Tests/SourceKitTests/Fixtures`: scrubbed shapes of real
/// provider answers, never real logins (PRIV-2).
enum Fixture {
    static func url(_ path: String) -> URL {
        guard let base = Bundle.module.resourceURL else { fatalError("Test bundle has no resources") }
        return base.appending(path: "Fixtures").appending(path: path)
    }

    static func data(_ path: String) -> Data {
        guard let data = try? Data(contentsOf: url(path)) else { fatalError("Missing fixture \(path)") }
        return data
    }

    static func json(_ path: String) -> JSONValue {
        guard let value = JSONValue(data: data(path)) else { fatalError("Fixture \(path) isn't JSON") }
        return value
    }

    static func text(_ path: String) -> String {
        String(decoding: data(path), as: UTF8.self)
    }
}

/// The `SourceError` an operation throws, nil when it succeeds or throws
/// something else.
func sourceError<T>(_ work: () async throws -> T) async -> SourceError? {
    do {
        _ = try await work()
        return nil
    } catch let error as SourceError {
        return error
    } catch {
        return nil
    }
}

/// `2026-10-24 20:00` in UTC, for expectations.
func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}
