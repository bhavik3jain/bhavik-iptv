import Foundation

extension StreamFormatHint {
    /// What a stream URL probably carries, from its extension and the query
    /// parameters providers use to say so (`extension=ts`, `output=hls`). The
    /// guess picks the player engine: AVPlayer for HLS and MP4, VLCKit for raw
    /// MPEG-TS and MKV (Source protocols, verification checklist).
    public static func guess(fromURL url: URL) -> StreamFormatHint {
        guess(fromURL: url.absoluteString)
    }

    public static func guess(fromURL text: String) -> StreamFormatHint {
        let lowered = text.lowercased()
        let (path, query): (Substring, Substring) = {
            guard let mark = lowered.firstIndex(of: "?") else { return (lowered[...], "") }
            return (lowered[..<mark], lowered[lowered.index(after: mark)...])
        }()
        let parameters = Dictionary(
            query.split(separator: "&").compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            },
            uniquingKeysWith: { first, _ in first }
        )
        for key in ["extension", "output", "type", "format", "container"] {
            switch parameters[key] {
            case "m3u8", "hls": return .hls
            case "ts", "mpegts", "mpeg-ts": return .mpegts
            case "mp4", "m4v", "mov": return .mp4
            case "mkv": return .mkv
            default: continue
            }
        }
        let fileName = path.split(separator: "/").last.map(String.init) ?? ""
        if path.hasSuffix(".m3u8") || path.hasSuffix(".m3u") || path.contains(".m3u8") { return .hls }
        if fileName.hasSuffix(".ts") || fileName.hasSuffix(".mpegts") || path.hasSuffix("/mpegts") { return .mpegts }
        if fileName.hasSuffix(".mp4") || fileName.hasSuffix(".m4v") || fileName.hasSuffix(".mov") { return .mp4 }
        if fileName.hasSuffix(".mkv") { return .mkv }
        return .unknown
    }

    /// The hint for a container extension (`mkv`, `mp4`, `m3u8`).
    static func fromExtension(_ fileExtension: String?) -> StreamFormatHint {
        switch fileExtension?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) {
        case "m3u8", "m3u", "hls": return .hls
        case "ts", "mpegts": return .mpegts
        case "mp4", "m4v", "mov": return .mp4
        case "mkv": return .mkv
        default: return .unknown
        }
    }
}
