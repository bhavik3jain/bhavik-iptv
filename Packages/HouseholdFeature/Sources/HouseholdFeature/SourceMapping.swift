import Foundation
import HouseholdKit
import SourceKit

// The household's source records and SourceKit's configurations are two
// shapes of the same login: HouseholdKit never imports SourceKit, so the
// feature that edits sources (and the app, which hands them to the catalog)
// maps between them here. Public so the app shell's `catalog.setSources`
// uses the very same mapping as the editor's Test button.

/// `SourceRecord` ↔ `SourceConfiguration` (SRC-1…SRC-3).
public enum SourceMapping {
    /// The record's kind, or nil for a kind this build doesn't know (a
    /// record written by a newer build).
    public static func kind(of record: SourceRecord) -> SourceKind? {
        SourceKind(rawValue: record.kindRaw)
    }

    /// The configuration CatalogKit and SourceKit sign in with. A kind this
    /// build doesn't know maps to an M3U playlist with no URL, which fails
    /// at once with a clear message instead of sending someone else's login
    /// to the wrong kind of server; `configurations(from:)` skips such
    /// records altogether.
    public static func configuration(from record: SourceRecord) -> SourceConfiguration {
        let login = record.credentials
        let kind = kind(of: record) ?? .m3u
        let known = Self.kind(of: record) != nil
        return SourceConfiguration(
            id: record.id,
            name: record.name,
            kind: kind,
            serverURL: known ? trimmed(record.serverURL) : "",
            macAddress: MACAddress.normalized(login.macAddress) ?? trimmed(login.macAddress),
            username: trimmed(login.username),
            // Passwords keep their spaces: a provider may really use one.
            password: login.password,
            playlistURL: known ? trimmed(login.playlistURL) : "",
            guideURL: trimmed(login.guideURL),
            serialNumber: trimmed(login.serialNumber),
            deviceID: trimmed(login.deviceID),
            deviceID2: trimmed(login.deviceID2),
            signature: trimmed(login.signature),
            model: trimmed(login.model),
            timeZone: trimmed(login.timeZone)
        )
    }

    /// The configurations to hand `CatalogService.setSources`: the sources
    /// still in the household (not removed, SRC-9), in their order, minus
    /// any of a kind this build can't read.
    public static func configurations(from records: [SourceRecord]) -> [SourceConfiguration] {
        records
            .filter { !$0.isRemoved && kind(of: $0) != nil }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(configuration(from:))
    }

    /// A record carrying `configuration`'s login, keeping what only the
    /// household knows (order, removal, stream limit, expiry) from `base`.
    public static func record(from configuration: SourceConfiguration, base: SourceRecord? = nil, maxStreams: Int? = nil, expiresAt: Date? = nil) -> SourceRecord {
        SourceRecord(
            id: configuration.id,
            name: configuration.name,
            kindRaw: configuration.kind.rawValue,
            serverURL: configuration.serverURL,
            sortOrder: base?.sortOrder ?? 0,
            isRemoved: base?.isRemoved ?? false,
            maxStreams: maxStreams ?? base?.maxStreams ?? StreamLimit.defaultMaxStreams(for: configuration.kind),
            expiresAt: expiresAt ?? base?.expiresAt,
            credentials: SourceCredentials(
                macAddress: configuration.macAddress,
                username: configuration.username,
                password: configuration.password,
                playlistURL: configuration.playlistURL,
                guideURL: configuration.guideURL,
                serialNumber: configuration.serialNumber,
                deviceID: configuration.deviceID,
                deviceID2: configuration.deviceID2,
                signature: configuration.signature,
                model: configuration.model,
                timeZone: configuration.timeZone
            )
        )
    }

    /// Whether two configurations sign in differently: anything but the name
    /// changed. A rename needs no fresh catalog; a new MAC or URL does.
    public static func connectionChanged(_ old: SourceConfiguration?, _ new: SourceConfiguration) -> Bool {
        guard var old else { return true }
        old.name = new.name
        return old != new
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A Stalker MAC address as people type it and as portals want it (SRC-1).
enum MACAddress {
    /// The prefix MAG boxes use, offered as the placeholder.
    static let example = "00:1A:79:XX:XX:XX"

    /// `00-1a-79-aa-bb-cc` or `001a79aabbcc` → `00:1A:79:AA:BB:CC`; nil
    /// unless there are exactly twelve hex digits and nothing else but
    /// separators (`:`, `-`, `.`, spaces).
    static func normalized(_ text: String) -> String? {
        let separators: Set<Character> = [":", "-", ".", " "]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isHexDigit || separators.contains($0) }) else { return nil }
        let hex = trimmed.filter(\.isHexDigit).uppercased()
        guard hex.count == 12 else { return nil }
        return pairs(hex).joined(separator: ":")
    }

    static func isValid(_ text: String) -> Bool { normalized(text) != nil }

    /// What the field shows while typing: hex digits only, upper case, a
    /// colon between each pair, at most twelve digits. Never a trailing
    /// colon, so deleting backwards works as people expect.
    static func formattedWhileTyping(_ text: String) -> String {
        let hex = String(text.filter(\.isHexDigit).uppercased().prefix(12))
        return pairs(hex).joined(separator: ":")
    }

    /// `00:1A:79:••:••:41`, as Household shows it (PRIV-2).
    static func masked(_ text: String) -> String {
        Redaction.mac(normalized(text) ?? text)
    }

    private static func pairs(_ hex: String) -> [String] {
        var result: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            result.append(String(hex[index..<next]))
            index = next
        }
        return result
    }
}

/// How many streams a source allows and how many are taken (HH-5, HH-6;
/// technical spec, Stream limits). Public so the app's playback coordinator
/// passes `HouseholdStore.streamUsage(sourceID:limit:)` the same limit the
/// Household bars show.
public enum StreamLimit {
    /// A new source's setting: one stream per MAC for a portal, unlimited
    /// for a playlist. Xtream reports its own.
    public static func defaultMaxStreams(for kind: SourceKind) -> Int {
        switch kind {
        case .stalker: 1
        case .xtream: 1
        case .m3u: 0
        }
    }

    /// The limit, or nil when there is none or it isn't known yet: Xtream's
    /// `max_connections` from the account call, else the owner's setting
    /// (0 = unlimited).
    public static func limit(for record: SourceRecord, account: AccountInfo?) -> Int? {
        if SourceMapping.kind(of: record) == .xtream {
            guard let max = account?.maxConnections, max > 0 else { return nil }
            return max
        }
        return record.maxStreams > 0 ? record.maxStreams : nil
    }

    /// Streams in use. The provider's own count wins where it gives one
    /// (Xtream `active_cons`), but never below the household's own rows: the
    /// count is only as fresh as the last account read, the rows are a
    /// minute old at most.
    public static func inUse(for record: SourceRecord, account: AccountInfo?, playbacks: Int) -> Int {
        if SourceMapping.kind(of: record) == .xtream, let active = account?.activeConnections {
            return max(active, playbacks)
        }
        return playbacks
    }
}
