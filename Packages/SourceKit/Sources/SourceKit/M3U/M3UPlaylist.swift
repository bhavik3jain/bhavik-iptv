import Foundation

/// One stream of a playlist: the `#EXTINF` line's attributes and name, the
/// URL that follows, and the headers `#EXTVLCOPT` / `#EXTHTTP` / a Kodi `|`
/// suffix asked for.
struct M3UEntry: Sendable, Hashable {
    var name: String
    var url: String
    /// Attribute names lowercased (`tvg-id`, `group-title`, `catchup-source`).
    var attributes: [String: String]
    var headers: [String: String]

    subscript(attribute: String) -> String? {
        guard let value = attributes[attribute]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}

struct M3UPlaylist: Sendable, Hashable {
    /// Whether the file opened with `#EXTM3U`.
    var sawHeader = false
    /// Attributes of the `#EXTM3U` line (guide URL, playlist-wide catch-up).
    var headerAttributes: [String: String] = [:]
    var entries: [M3UEntry] = []

    /// The guide URLs from `x-tvg-url` or `url-tvg` (Kodi IPTV Simple reads
    /// both); either may hold a comma-separated list.
    var guideURLs: [URL] {
        let raw = [headerAttributes["x-tvg-url"], headerAttributes["url-tvg"], headerAttributes["tvg-url"]].compactMap { $0 }
        var seen: Set<String> = []
        return raw.flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { seen.insert($0).inserted }
            .compactMap { text in
                guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
                return url
            }
    }
}

/// Reads a playlist one line at a time, so a file with a hundred thousand
/// entries never sits in memory as text (technical spec, Big files).
struct M3UParser: Sendable {
    private(set) var playlist = M3UPlaylist()
    private var pending: (name: String, attributes: [String: String])?
    private var pendingHeaders: [String: String] = [:]
    private var pendingGroup: String?
    private var isFirstLine = true

    mutating func consume(_ rawLine: some StringProtocol) {
        var line = Substring(rawLine)
        if isFirstLine {
            isFirstLine = false
            if line.hasPrefix("\u{FEFF}") { line = line.dropFirst() }
        }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        guard !line.isEmpty else { return }

        if line.hasPrefix("#") {
            let upper = line.prefix(12).uppercased()
            if upper.hasPrefix("#EXTM3U") {
                playlist.sawHeader = true
                let (_, attributes, _) = Self.parseAttributes(line.dropFirst("#EXTM3U".count))
                playlist.headerAttributes.merge(attributes) { _, new in new }
            } else if upper.hasPrefix("#EXTINF:") {
                let (_, attributes, name) = Self.parseAttributes(line.dropFirst("#EXTINF:".count))
                pending = (name, attributes)
            } else if upper.hasPrefix("#EXTVLCOPT:") {
                let option = line.dropFirst("#EXTVLCOPT:".count)
                guard let equals = option.firstIndex(of: "=") else { return }
                let key = option[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let value = option[option.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "http-user-agent": pendingHeaders["User-Agent"] = value
                case "http-referrer", "http-referer": pendingHeaders["Referer"] = value
                case "http-origin": pendingHeaders["Origin"] = value
                case "http-cookie": pendingHeaders["Cookie"] = value
                default: break
                }
            } else if upper.hasPrefix("#EXTHTTP:") {
                // `#EXTHTTP:{"User-Agent":"…","cookie":"…"}` (TiviMate, OTT Navigator).
                let json = line.dropFirst("#EXTHTTP:".count)
                if let value = JSONValue(data: Data(json.utf8)), let object = value.object {
                    for (key, value) in object { if let text = value.string { pendingHeaders[Self.headerName(key)] = text } }
                }
            } else if upper.hasPrefix("#EXTGRP:") {
                pendingGroup = line.dropFirst("#EXTGRP:".count).trimmingCharacters(in: .whitespaces)
            }
            return
        }

        // A stream URL, perhaps with Kodi's `|User-Agent=…&Referer=…` suffix.
        var url = String(line)
        var headers = pendingHeaders
        if let pipe = url.firstIndex(of: "|") {
            let suffix = url[url.index(after: pipe)...]
            url = String(url[..<pipe])
            for pair in suffix.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                headers[Self.headerName(key)] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            }
        }
        var attributes = pending?.attributes ?? [:]
        if attributes["group-title"] == nil, let pendingGroup, !pendingGroup.isEmpty { attributes["group-title"] = pendingGroup }
        let name = pending?.name.nilIfBlank ?? attributes["tvg-name"]?.nilIfBlank ?? Self.fallbackName(url)
        playlist.entries.append(M3UEntry(name: name, url: url, attributes: attributes, headers: headers))
        pending = nil
        pendingHeaders = [:]
        pendingGroup = nil
    }

    /// Parses `-1 tvg-id="a" group-title="News, Weather",Display Name`:
    /// the duration, the attributes, and the name after the first comma that
    /// isn't inside quotes.
    static func parseAttributes(_ text: Substring) -> (duration: String?, attributes: [String: String], name: String) {
        var attributes: [String: String] = [:]
        var index = text.startIndex
        func skipSpaces() { while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) } }

        skipSpaces()
        // The duration: up to the first space or comma.
        var duration: String?
        let durationStart = index
        while index < text.endIndex, !text[index].isWhitespace, text[index] != "," { index = text.index(after: index) }
        if index > durationStart {
            let word = text[durationStart..<index]
            if word.contains("=") {
                index = durationStart // No duration (the #EXTM3U line): it's an attribute.
            } else {
                duration = String(word)
            }
        }

        while index < text.endIndex {
            skipSpaces()
            guard index < text.endIndex else { break }
            if text[index] == "," {
                index = text.index(after: index)
                break
            }
            // key
            let keyStart = index
            while index < text.endIndex, text[index] != "=", text[index] != ",", !text[index].isWhitespace { index = text.index(after: index) }
            let key = text[keyStart..<index].lowercased()
            guard index < text.endIndex, text[index] == "=" else {
                // A bare word: skip it.
                if index < text.endIndex, text[index] == "," { continue }
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            index = text.index(after: index)
            // value: quoted with " or ', or bare up to a space or comma.
            var value = ""
            if index < text.endIndex, text[index] == "\"" || text[index] == "'" {
                let quote = text[index]
                index = text.index(after: index)
                let valueStart = index
                while index < text.endIndex, text[index] != quote { index = text.index(after: index) }
                value = String(text[valueStart..<index])
                if index < text.endIndex { index = text.index(after: index) }
            } else {
                let valueStart = index
                while index < text.endIndex, !text[index].isWhitespace, text[index] != "," { index = text.index(after: index) }
                value = String(text[valueStart..<index])
            }
            if !key.isEmpty { attributes[key] = value }
        }
        let name = index < text.endIndex ? text[index...].trimmingCharacters(in: .whitespaces) : ""
        return (duration, attributes, name)
    }

    /// `user-agent` → `User-Agent`; `referrer` → `Referer`.
    static func headerName(_ key: String) -> String {
        switch key.lowercased() {
        case "user-agent", "useragent", "http-user-agent": return "User-Agent"
        case "referer", "referrer", "http-referrer", "http-referer": return "Referer"
        case "origin": return "Origin"
        case "cookie": return "Cookie"
        default: return key
        }
    }

    private static func fallbackName(_ url: String) -> String {
        URL(string: url)?.deletingPathExtension().lastPathComponent.nilIfBlank ?? url
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Turning playlist entries into the catalog's channels and categories.
enum M3UCatalog {
    static func categories(_ playlist: M3UPlaylist) -> [RemoteCategory] {
        var seen: Set<String> = []
        var categories: [RemoteCategory] = []
        for entry in playlist.entries {
            guard let group = entry["group-title"], seen.insert(group).inserted else { continue }
            categories.append(RemoteCategory(id: group, name: group, kind: .live, sortOrder: categories.count))
        }
        return categories
    }

    /// Channels with stable ids: `tvg-id`, else a hash of the normalised
    /// name and group (Source protocols, Stable ids). A repeated id (one
    /// channel listed in HD and SD under one `tvg-id`) gets the name's hash,
    /// then a counter, so every id stays unique and survives a refresh.
    static func channels(_ playlist: M3UPlaylist) -> [RemoteChannel] {
        let header = playlist.headerAttributes
        var used: Set<String> = []
        var channels: [RemoteChannel] = []
        channels.reserveCapacity(playlist.entries.count)
        for entry in playlist.entries {
            let group = entry["group-title"]
            let tvgID = entry["tvg-id"]
            var id = tvgID ?? "m3u-" + stableHash(normalised(entry.name) + "|" + normalised(group ?? ""))
            if used.contains(id) { id += "~" + stableHash(normalised(entry.name)).prefix(8) }
            var counter = 2
            let base = id
            while used.contains(id) {
                id = "\(base)~\(counter)"
                counter += 1
            }
            used.insert(id)

            var mode = (entry["catchup"] ?? entry["catchup-type"] ?? header["catchup"] ?? header["catchup-type"])?.lowercased()
            let source = entry["catchup-source"] ?? header["catchup-source"]
            // SIPTV's legacy `timeshift="3"` means shift mode with three days;
            // `catchup-days` alone only sets the window. IPTV Simple needs a
            // `catchup` tag (or a source template) before it offers an archive,
            // so a playlist-wide `catchup-days` doesn't switch every channel on.
            let timeshift = entry["timeshift"] ?? header["timeshift"]
            let days = Int(entry["catchup-days"] ?? timeshift ?? header["catchup-days"] ?? "")
            if mode == nil, source != nil { mode = "default" }
            if mode == nil, timeshift != nil { mode = "shift" }
            if mode == "disabled" || mode == "none" { mode = nil }
            let hasArchive = mode != nil && (source != nil || !["default", "append"].contains(mode!))

            channels.append(RemoteChannel(
                id: id,
                number: entry["tvg-chno"].flatMap { Int($0) },
                name: entry.name,
                logoURL: entry["tvg-logo"].flatMap { URL(string: $0) },
                categoryID: group,
                guideChannelID: tvgID ?? entry["tvg-name"] ?? entry.name,
                hasArchive: hasArchive,
                archiveDays: hasArchive ? (days ?? 7) : 0,
                command: entry.url,
                formatHint: StreamFormatHint.guess(fromURL: entry.url),
                headers: entry.headers,
                catchupMode: hasArchive ? mode : nil,
                catchupSource: hasArchive ? source : nil
            ))
        }
        return channels
    }

    /// Lowercased letters and digits, accents folded, runs of anything else
    /// as one space: "Cityline  News (HD)" → "cityline news hd".
    static func normalised(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return result
    }

    /// 64-bit FNV-1a as 16 hex digits: stable across launches and platforms,
    /// unlike `Hasher`.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
