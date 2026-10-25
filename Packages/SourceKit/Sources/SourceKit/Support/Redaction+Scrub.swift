import Foundation

extension Redaction {
    /// `text` with every login of `configuration` masked wherever it
    /// appears: the MAC in any spelling (`00:1A:79:…`, `00-1a-79-…`,
    /// `001A79…`, `00%3A1A%3A…`), the username, password, serial, device ids,
    /// signature and playlist URL. For anything a provider wrote that is about
    /// to be printed — an error page can quote the MAC back (PRIV-2).
    public static func scrub(_ text: String, for configuration: SourceConfiguration) -> String {
        var result = text
        let hex = configuration.macAddress.uppercased().filter(\.isHexDigit)
        if hex.count == 12 {
            let pairs = stride(from: 0, to: 12, by: 2).map { offset -> String in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return String(hex[start..<hex.index(start, offsetBy: 2)])
            }
            let pattern = pairs.joined(separator: "(?::|-|%3A|\\.)?")
            if let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: mac(pairs.joined(separator: ":"))))
            }
        }
        if !configuration.playlistURL.isEmpty {
            result = result.replacingOccurrences(of: configuration.playlistURL, with: url(configuration.playlistURL))
        }
        if !configuration.guideURL.isEmpty {
            result = result.replacingOccurrences(of: configuration.guideURL, with: url(configuration.guideURL))
        }
        // Longest first, so a password that contains the username is masked whole.
        let secrets = [configuration.password, configuration.username, configuration.serialNumber, configuration.deviceID, configuration.deviceID2, configuration.signature]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
            .sorted { $0.count > $1.count }
        for value in secrets {
            result = result.replacingOccurrences(of: value, with: "•••")
            if let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics), encoded != value {
                result = result.replacingOccurrences(of: encoded, with: "•••")
            }
        }
        return result
    }
}
