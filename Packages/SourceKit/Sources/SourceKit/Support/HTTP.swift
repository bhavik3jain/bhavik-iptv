import Foundation

/// One HTTP answer, read whole. Provider API answers are small enough for
/// that; guides and playlists go through `HTTP.download` instead.
struct HTTPResponse: Sendable {
    var data: Data
    var status: Int
    var headers: [String: String]

    var isSuccess: Bool { (200..<300).contains(status) }

    /// The body as short readable text: HTML tags stripped, whitespace
    /// collapsed, cut to a few hundred characters. What a provider says when
    /// it refuses is often a plain sentence or an HTML page (SRC-4).
    var plainText: String? { HTTP.plainText(from: data) }
}

/// The few things every client does with `URLSession`: send, map failures to
/// `SourceError`, never put a URL (which may carry a login) into an error.
enum HTTP {
    /// API calls answer in seconds or not at all; a portal that hangs should
    /// fail the step rather than the whole refresh.
    static let apiTimeout: TimeInterval = 20
    /// Guides and playlists can be hundreds of megabytes on a slow server.
    static let downloadTimeout: TimeInterval = 300

    static func send(_ request: URLRequest, session: URLSession) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            return HTTPResponse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 200, headers: headers(of: response))
        } catch {
            throw sourceError(for: error, host: request.url?.host())
        }
    }

    /// Downloads to a file this process owns (the caller deletes it). File
    /// URLs are returned as they are, never copied.
    static func download(_ request: URLRequest, session: URLSession) async throws -> (file: URL, status: Int, isTemporary: Bool) {
        if let url = request.url, url.isFileURL {
            guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else {
                throw SourceError(.invalidConfiguration, detail: "The playlist or guide file can't be read")
            }
            return (url, 200, false)
        }
        do {
            let (location, response) = try await session.download(for: request)
            // The system may clean its own download location up; move the file
            // somewhere this process controls before parsing it.
            let owned = FileManager.default.temporaryDirectory.appending(path: "hearth-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: location, to: owned)
            return (owned, (response as? HTTPURLResponse)?.statusCode ?? 200, true)
        } catch let error as SourceError {
            throw error
        } catch {
            throw sourceError(for: error, host: request.url?.host())
        }
    }

    static func sourceError(for error: Error, host: String?) -> SourceError {
        if let sourceError = error as? SourceError { return sourceError }
        if error is CancellationError { return SourceError(.cancelled) }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return SourceError(.cancelled) }
            return SourceError(.unreachable, detail: "URLError \(urlError.code.rawValue) from \(host ?? "server")")
        }
        return SourceError(.unreachable, detail: String(describing: type(of: error)))
    }

    /// True when the host itself can't be reached, so trying another path on
    /// it is pointless.
    static func isHostFailure(_ error: SourceError) -> Bool {
        error.code == .unreachable
    }

    static func headers(of response: URLResponse) -> [String: String] {
        guard let http = response as? HTTPURLResponse else { return [:] }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return headers
    }

    static func plainText(from data: Data, limit: Int = 300) -> String? {
        guard !data.isEmpty, data.count < 64_000,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        var stripped = text
        if stripped.contains("<") {
            stripped = stripped.replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
            stripped = stripped.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }
        let collapsed = stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}

/// Percent-encoding for query values sent to PHP providers. Stricter than
/// `URLComponents`, which leaves `+` alone — and PHP reads a raw `+` in a
/// base64 `cmd` as a space.
enum QueryEncoding {
    private static let allowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "-._~/:*,")
        return set
    }()

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// `key=value&…` in the order given.
    static func query(_ items: [(String, String)]) -> String {
        items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    /// For path segments (Xtream usernames and passwords go in the path).
    static func pathSegment(_ value: String) -> String {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "-._~!$&'()*+,;=:@")
        return value.addingPercentEncoding(withAllowedCharacters: set) ?? value
    }
}
