import Foundation

/// Everything fixed about one Stalker login: the box it pretends to be, the
/// paths to try, the headers every call sends. Built from a
/// `SourceConfiguration` with the advanced-field defaults filled in (SRC-1).
/// Never printed: it holds the MAC and logins (PRIV-2).
struct StalkerPortal: Sendable {
    /// What stalkerhek sends; portals check for a MAG box.
    static let userAgent = "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 4 rev: 2116 Mobile Safari/533.3"
    static let defaultSerial = "0000000000000"
    static let defaultDeviceID = String(repeating: "f", count: 64)
    static let defaultModel = "MAG254"

    let typedURL: URL
    let mac: String
    let serial: String
    let deviceID: String
    let deviceID2: String
    let signature: String
    let model: String
    /// The zone sent in the cookie, which is also the zone the portal writes
    /// guide times in when it leaves the offset off.
    let timeZone: TimeZone
    let username: String
    let password: String

    init(configuration: SourceConfiguration) throws {
        guard let url = Self.normalisedURL(configuration.serverURL) else {
            throw SourceError(.invalidConfiguration, detail: "The portal URL isn't a web address")
        }
        guard let mac = Self.normalisedMAC(configuration.macAddress) else {
            throw SourceError(.invalidConfiguration, detail: "The MAC address isn't six hex pairs")
        }
        typedURL = url
        self.mac = mac
        serial = Self.value(configuration.serialNumber, or: Self.defaultSerial)
        deviceID = Self.value(configuration.deviceID, or: Self.defaultDeviceID)
        deviceID2 = Self.value(configuration.deviceID2, or: Self.defaultDeviceID)
        signature = Self.value(configuration.signature, or: Self.defaultDeviceID)
        model = Self.value(configuration.model, or: Self.defaultModel)
        timeZone = TimeZone(identifier: configuration.timeZone.trimmingCharacters(in: .whitespaces)) ?? .current
        username = configuration.username.trimmingCharacters(in: .whitespaces)
        password = configuration.password
    }

    // MARK: Where to send calls

    /// API endpoints to try, most likely first, until one answers the
    /// handshake with JSON. The typed URL is often the web player's `/c/`
    /// page; the API sits beside it (Source protocols, Where to send calls).
    var candidateAPIURLs: [URL] {
        guard let origin = Self.origin(of: typedURL) else { return [] }
        var paths: [String] = []
        let typedPath = typedURL.path(percentEncoded: true)
        if typedPath.lowercased().hasSuffix(".php") {
            paths.append(typedPath)
        }
        // The typed path with `/c/` (and a trailing `index.html`) stripped:
        // `/stalker_portal/c/` → `/stalker_portal`.
        var prefix = typedPath
        for suffix in ["index.html", "/"] where prefix.hasSuffix(suffix) { prefix.removeLast(suffix.count) }
        if prefix.lowercased().hasSuffix(".php") { prefix = (prefix as NSString).deletingLastPathComponent }
        if prefix.hasSuffix("/c") { prefix.removeLast(2) }
        while prefix.hasSuffix("/") { prefix.removeLast() }
        if !prefix.isEmpty, prefix != "/server" {
            paths += ["\(prefix)/server/load.php", "\(prefix)/portal.php", "\(prefix)/load.php"]
        }
        paths += [
            "/portal.php",
            "/load.php",
            "/stalker_portal/server/load.php",
            "/stalker_portal/server/portal.php",
            "/stalker_portal/portal.php",
        ]
        var seen: Set<String> = []
        return paths.compactMap { path in
            guard seen.insert(path).inserted else { return nil }
            return URL(string: origin + path)
        }
    }

    // MARK: Requests

    /// A GET to the API with `JsHttpRequest=1-xml` added, as every MAG call has.
    func request(_ api: URL, _ parameters: [(String, String)], token: String?) -> URLRequest {
        let query = QueryEncoding.query(parameters + [("JsHttpRequest", "1-xml")])
        var components = URLComponents(url: api, resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = query
        var request = URLRequest(url: components?.url ?? api, timeoutInterval: HTTP.apiTimeout)
        applyHeaders(to: &request, api: api, token: token)
        return request
    }

    /// A form POST (`do_auth`), so the password never sits in a URL.
    func formRequest(_ api: URL, _ parameters: [(String, String)], token: String?) -> URLRequest {
        var request = URLRequest(url: api, timeoutInterval: HTTP.apiTimeout)
        request.httpMethod = "POST"
        request.httpBody = Data(QueryEncoding.query(parameters + [("JsHttpRequest", "1-xml")]).utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        applyHeaders(to: &request, api: api, token: token)
        return request
    }

    private func applyHeaders(to request: inout URLRequest, api: URL, token: String?) {
        // Our Cookie header must go out exactly as written; the shared cookie
        // store would otherwise merge in whatever the portal set before.
        request.httpShouldHandleCookies = false
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Model: \(model); Link: Ethernet", forHTTPHeaderField: "X-User-Agent")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        if let origin = Self.origin(of: api) {
            request.setValue(origin + "/", forHTTPHeaderField: "Referer")
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// stalkerhek's cookie, `PHPSESSID=null` included: some portals start a
    /// PHP session otherwise and then expect it back.
    var cookie: String {
        "PHPSESSID=null; sn=\(QueryEncoding.encode(serial)); mac=\(QueryEncoding.encode(mac)); stb_lang=en; timezone=\(QueryEncoding.encode(timeZone.identifier))"
    }

    /// Parameters of `get_profile`: the doc's set (hd, sn, stb_type, device
    /// ids, signature, auth_second_step) plus what a MAG254 also sends, which
    /// some portals check.
    var profileParameters: [(String, String)] {
        [
            ("type", "stb"), ("action", "get_profile"),
            ("hd", "1"),
            ("ver", "ImageDescription: 0.2.18-r23-254; ImageDate: Wed Oct 31 15:22:54 EEST 2018; PORTAL version: 5.6.2; API Version: JS API version: 343; STB API version: 146; Player Engine version: 0x58c"),
            ("num_banks", "2"),
            ("sn", serial),
            ("stb_type", model),
            ("client_type", "STB"),
            ("image_version", "218"),
            ("video_out", "hdmi"),
            ("device_id", deviceID),
            ("device_id2", deviceID2),
            ("signature", signature),
            ("auth_second_step", "1"),
            ("hw_version", "1.7-BD-00"),
            ("not_valid_token", "0"),
            ("api_signature", "262"),
            ("prehash", ""),
        ]
    }

    // MARK: Resolving portal-relative paths

    /// `scheme://host[:port]`.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host(percentEncoded: true) else { return nil }
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// Where `play/movie.php` lives: the origin plus whatever comes before
    /// `/stalker_portal` (stalkerhek's `StreamServerBase`).
    static func streamServerBase(for api: URL) -> String? {
        guard let origin = origin(of: api) else { return nil }
        var path = api.path(percentEncoded: true)
        if let range = path.range(of: "/stalker_portal") {
            path = String(path[..<range.lowerBound])
        } else if let range = path.range(of: "/c/") {
            path = String(path[..<range.lowerBound])
        } else {
            path = (path as NSString).deletingLastPathComponent
        }
        if path == "/" || path == "." { path = "" }
        return origin + path
    }

    /// A logo, poster or screenshot the portal names relative to itself.
    static func resolveAsset(_ value: String?, api: URL, logoDirectory: Bool = false) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return URL(string: value) }
        guard let origin = origin(of: api) else { return nil }
        if value.hasPrefix("/") { return URL(string: origin + value) }
        guard logoDirectory else { return URL(string: origin + "/" + value) }
        // A bare file name: logos live in misc/logos/320 beside the portal.
        let path = api.path(percentEncoded: true)
        let base: String
        if let range = path.range(of: "/stalker_portal") {
            base = String(path[..<range.upperBound])
        } else {
            base = (path as NSString).deletingLastPathComponent
        }
        let trimmed = base == "/" ? "" : base
        return URL(string: "\(origin)\(trimmed)/misc/logos/320/\(QueryEncoding.encode(value))")
    }

    // MARK: Normalising what the owner typed

    static func normalisedURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        return url
    }

    /// `00-1a-79-aa-bb-cc` → `00:1A:79:AA:BB:CC`.
    static func normalisedMAC(_ text: String) -> String? {
        let hex = text.uppercased().filter { $0.isHexDigit }
        guard hex.count == 12, text.filter({ $0.isLetter || $0.isNumber }).count == 12 else { return nil }
        var pairs: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            pairs.append(String(hex[index..<next]))
            index = next
        }
        return pairs.joined(separator: ":")
    }

    private static func value(_ text: String, or fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
