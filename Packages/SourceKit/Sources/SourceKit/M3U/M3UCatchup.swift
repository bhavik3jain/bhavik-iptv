import Foundation

/// Archive URLs for M3U channels, following Kodi IPTV Simple's `catchup`
/// modes and placeholders (Source protocols, M3U playlists).
enum M3UCatchup {
    /// The archive URL for a programme of `channel`, nil when the channel
    /// has no catch-up or its mode can't build one.
    ///
    /// - `default`: `catchup-source` is the whole URL.
    /// - `append`: `catchup-source` is added to the channel URL.
    /// - `shift` / `timeshift`: `?utc={utc}&lutc={lutc}` added to the channel URL.
    /// - `flussonic` (`fs`, `flussonic-hls`, `flussonic-ts`): Flussonic's
    ///   `index-{utc}-{duration}.m3u8` and `timeshift_abs-{utc}.ts`.
    /// - `xc`: an Xtream live URL turned into its `/timeshift/` form.
    static func url(for channel: RemoteChannel, start: Date, duration: TimeInterval, now: Date = Date()) -> URL? {
        guard let mode = channel.catchupMode?.lowercased() else { return nil }
        let channelURL = channel.command
        let template: String?
        switch mode {
        case "default":
            guard let source = channel.catchupSource else { return nil }
            // A relative source (`?start=…`) only makes sense appended.
            template = source.contains("://") ? source : channelURL + source
        case "append":
            guard let source = channel.catchupSource else { return nil }
            template = channelURL + source
        case "shift", "timeshift":
            template = channelURL + (channelURL.contains("?") ? "&" : "?") + "utc={utc}&lutc={lutc}"
        case "flussonic", "flussonic-hls", "flussonic-ts", "fs":
            template = flussonic(channelURL, forceTS: mode == "flussonic-ts")
        case "xc":
            template = xtream(channelURL)
        default:
            template = channel.catchupSource.map { $0.contains("://") ? $0 : channelURL + $0 }
        }
        guard let template else { return nil }
        return URL(string: fill(template, start: start, duration: duration, now: now))
    }

    /// Replaces the placeholders: `{utc}` / `${start}` (programme start),
    /// `{utcend}` / `${end}`, `{lutc}` / `${now}` / `${timestamp}` (now),
    /// `{duration}` / `${duration}` (seconds), `{duration:X}` and
    /// `{offset:X}` (divided by X), `{Y}` `{m}` `{d}` `{H}` `{M}` `{S}` (the
    /// start in UTC), and `{utc:YmdHMS}`-style formats of start, end or now.
    static func fill(_ template: String, start: Date, duration: TimeInterval, now: Date) -> String {
        let startSeconds = Int(start.timeIntervalSince1970)
        let endSeconds = startSeconds + Int(duration)
        let nowSeconds = Int(now.timeIntervalSince1970)
        var result = template

        // Formatted times first: `{utc:Y-m-d}` would otherwise lose its `{utc`.
        let formattedPattern = #"\{(utc|utcend|lutc|start|end|now):([^}]+)\}|\$\{(start|end|now|timestamp):([^}]+)\}"#
        if let expression = try? NSRegularExpression(pattern: formattedPattern) {
            let matches = expression.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let whole = Range(match.range, in: result) else { continue }
                let keyRange = Range(match.range(at: 1), in: result) ?? Range(match.range(at: 3), in: result)
                let formatRange = Range(match.range(at: 2), in: result) ?? Range(match.range(at: 4), in: result)
                guard let keyRange, let formatRange else { continue }
                let key = String(result[keyRange])
                let layout = String(result[formatRange])
                let seconds: Int
                switch key {
                case "utcend", "end": seconds = endSeconds
                case "lutc", "now", "timestamp": seconds = nowSeconds
                default: seconds = startSeconds
                }
                result.replaceSubrange(whole, with: formatted(seconds, layout))
            }
        }
        let divided = #"\{(duration|offset):(\d+)\}"#
        if let expression = try? NSRegularExpression(pattern: divided) {
            let matches = expression.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let whole = Range(match.range, in: result),
                      let keyRange = Range(match.range(at: 1), in: result),
                      let divisorRange = Range(match.range(at: 2), in: result),
                      let divisor = Int(result[divisorRange]), divisor > 0
                else { continue }
                let value = result[keyRange] == "duration" ? Int(duration) : nowSeconds - startSeconds
                result.replaceSubrange(whole, with: String(value / divisor))
            }
        }

        let parts = utcParts(startSeconds)
        let replacements: [(String, String)] = [
            ("{utcend}", String(endSeconds)), ("${end}", String(endSeconds)),
            ("{utc}", String(startSeconds)), ("${start}", String(startSeconds)),
            ("{lutc}", String(nowSeconds)), ("${now}", String(nowSeconds)), ("${timestamp}", String(nowSeconds)),
            ("{duration}", String(Int(duration))), ("${duration}", String(Int(duration))),
            ("{offset}", String(nowSeconds - startSeconds)), ("${offset}", String(nowSeconds - startSeconds)),
            ("{Y}", parts.year), ("{m}", parts.month), ("{d}", parts.day),
            ("{H}", parts.hour), ("{M}", parts.minute), ("{S}", parts.second),
        ]
        for (placeholder, value) in replacements {
            result = result.replacingOccurrences(of: placeholder, with: value)
        }
        return result
    }

    // MARK: Modes that rewrite the channel URL

    /// `…/channel/index.m3u8?token=x` → `…/channel/index-{utc}-{duration}.m3u8?token=x`;
    /// `…/channel/mpegts?token=x` → `…/channel/timeshift_abs-{utc}.ts?token=x`.
    static func flussonic(_ channelURL: String, forceTS: Bool) -> String? {
        // By hand rather than URLComponents, which would encode the braces.
        let queryStart = channelURL.firstIndex(of: "?") ?? channelURL.endIndex
        let address = channelURL[..<queryStart]
        let query = channelURL[queryStart...]
        guard address.contains("://"), let slash = address.lastIndex(of: "/") else { return nil }
        let directory = address[..<slash]
        let file = address[address.index(after: slash)...]
        if forceTS || file == "mpegts" || file.hasSuffix(".ts") {
            return directory + "/timeshift_abs-{utc}.ts" + query
        }
        if file.hasSuffix(".m3u8") {
            return directory + "/\(file.dropLast(".m3u8".count))-{utc}-{duration}.m3u8" + query
        }
        return nil
    }

    /// `http://host/live/U/P/123.ts` (or without `live/`) →
    /// `http://host/timeshift/U/P/{duration:60}/{Y}-{m}-{d}:{H}-{M}/123.ts`.
    static func xtream(_ channelURL: String) -> String? {
        let pattern = #"^(https?://[^/]+)/(?:live/)?([^/]+)/([^/]+)/([^/.?]+)(?:\.(?:m3u8|ts))?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: channelURL, range: NSRange(channelURL.startIndex..., in: channelURL)),
              match.numberOfRanges == 5
        else { return nil }
        let groups = (1...4).compactMap { Range(match.range(at: $0), in: channelURL).map { String(channelURL[$0]) } }
        guard groups.count == 4 else { return nil }
        return "\(groups[0])/timeshift/\(groups[1])/\(groups[2])/{duration:60}/{Y}-{m}-{d}:{H}-{M}/\(groups[3]).ts"
    }

    // MARK: Time pieces

    private static func utcParts(_ seconds: Int) -> (year: String, month: String, day: String, hour: String, minute: String, second: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return (String(format: "%04d", parts.year ?? 1970), two(parts.month), two(parts.day), two(parts.hour), two(parts.minute), two(parts.second))
    }

    /// `YmdHMS`-style format of a UTC time; other characters are kept.
    private static func formatted(_ seconds: Int, _ layout: String) -> String {
        let parts = utcParts(seconds)
        var result = ""
        for character in layout {
            switch character {
            case "Y": result += parts.year
            case "m": result += parts.month
            case "d": result += parts.day
            case "H": result += parts.hour
            case "M": result += parts.minute
            case "S": result += parts.second
            default: result.append(character)
            }
        }
        return result
    }
}
