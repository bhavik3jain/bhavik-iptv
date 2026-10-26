import Foundation
import HouseholdKit
import SourceKit

/// What the source editor holds while someone types (SRC-1…SRC-3): every
/// field as text, the checks that decide whether Test and Save are possible,
/// and the configuration they produce. A value type so the rules are
/// testable without the form.
struct SourceDraft: Hashable {
    enum Field: Hashable {
        case serverURL, macAddress, username, password, playlistURL, guideURL, timeZone
    }

    var kind: SourceKind
    var name = ""
    /// Stalker: the portal. Xtream: the server.
    var serverURL = ""
    var macAddress = ""
    var username = ""
    var password = ""
    var playlistURL = ""
    var guideURL = ""
    var serialNumber = ""
    var deviceID = ""
    var deviceID2 = ""
    var signature = ""
    var model = ""
    var timeZone = ""
    /// Stalker and M3U: the owner's setting, 0 = unlimited.
    var maxStreams: Int

    init(kind: SourceKind = .stalker) {
        self.kind = kind
        self.maxStreams = StreamLimit.defaultMaxStreams(for: kind)
    }

    init(record: SourceRecord) {
        let login = record.credentials
        kind = SourceMapping.kind(of: record) ?? .m3u
        name = record.name
        serverURL = record.serverURL
        macAddress = MACAddress.normalized(login.macAddress) ?? login.macAddress
        username = login.username
        password = login.password
        // Today's path to a playlist file: saving heals a stale one.
        playlistURL = PlaylistFile.resolved(login.playlistURL)
        guideURL = login.guideURL
        serialNumber = login.serialNumber
        deviceID = login.deviceID
        deviceID2 = login.deviceID2
        signature = login.signature
        model = login.model
        timeZone = login.timeZone
        maxStreams = max(0, record.maxStreams)
    }

    /// A new source switching kind takes that kind's default limit.
    mutating func changeKind(to newKind: SourceKind) {
        guard newKind != kind else { return }
        kind = newKind
        maxStreams = StreamLimit.defaultMaxStreams(for: newKind)
    }

    /// The Stalker fields under Advanced; any set opens the section.
    var hasAdvancedValues: Bool {
        [serialNumber, deviceID, deviceID2, signature, model, timeZone, username, password]
            .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: Checks

    /// Required fields for this kind that are still empty.
    var missingFields: [Field] {
        let required: [(Field, String)] = switch kind {
        case .stalker: [(.serverURL, serverURL), (.macAddress, macAddress)]
        case .xtream: [(.serverURL, serverURL), (.username, username), (.password, password)]
        case .m3u: [(.playlistURL, playlistURL)]
        }
        return required.filter { $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.0)
    }

    /// What is wrong with a field that has something in it, in a sentence
    /// for under the field; nil when it is fine or empty.
    func problem(with field: Field) -> String? {
        switch field {
        case .serverURL:
            guard kind != .m3u, !serverURL.isBlank else { return nil }
            return SourceURLCheck.isWebAddress(serverURL, allowingSchemeless: true)
                ? nil : String(localized: "That doesn't look like a web address, like http://portal.example.com/c/.")
        case .macAddress:
            guard kind == .stalker, !macAddress.isBlank else { return nil }
            return MACAddress.isValid(macAddress)
                ? nil : String(localized: "A MAC address has 12 hex digits, like 00:1A:79:12:34:56.")
        case .playlistURL:
            guard kind == .m3u, !playlistURL.isBlank else { return nil }
            return SourceURLCheck.isPlaylistAddress(playlistURL)
                ? nil : String(localized: "Use a link starting with http:// or https://, or choose a file.")
        case .guideURL:
            guard kind != .stalker, !guideURL.isBlank else { return nil }
            return SourceURLCheck.isWebAddress(guideURL, allowingSchemeless: false)
                ? nil : String(localized: "Use a link starting with http:// or https://.")
        case .timeZone:
            guard kind == .stalker, !timeZone.isBlank else { return nil }
            return TimeZone(identifier: timeZone.trimmingCharacters(in: .whitespaces)) != nil
                ? nil : String(localized: "Use a time zone name, like Europe/London.")
        case .username, .password:
            return nil
        }
    }

    /// Everything required is there and nothing typed is malformed: Test
    /// and Save are possible.
    var isComplete: Bool {
        let checked: [Field] = [.serverURL, .macAddress, .playlistURL, .guideURL, .timeZone]
        return missingFields.isEmpty && checked.allSatisfy { problem(with: $0) == nil }
    }

    // MARK: Output

    /// The name to save: what was typed, else the portal's or playlist's
    /// host ("portal.example.com"), else the kind.
    var resolvedName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? suggestedName : typed
    }

    var suggestedName: String {
        let address = kind == .m3u ? playlistURL : serverURL
        if let url = SourceURLCheck.url(from: address, allowingSchemeless: true) {
            if url.isFileURL { return url.deletingPathExtension().lastPathComponent }
            if let host = url.host(), !host.isEmpty { return host }
        }
        return SourceRowText.kindTitle(kind)
    }

    /// The configuration Test signs in with and Save stores. Only this
    /// kind's fields go in: switching kind leaves no stray login behind.
    func configuration(id: UUID) -> SourceConfiguration {
        var configuration = SourceConfiguration(id: id, name: resolvedName, kind: kind)
        switch kind {
        case .stalker:
            configuration.serverURL = serverURL.trimmed
            configuration.macAddress = MACAddress.normalized(macAddress) ?? macAddress.trimmed
            configuration.username = username.trimmed
            configuration.password = password
            configuration.serialNumber = serialNumber.trimmed
            configuration.deviceID = deviceID.trimmed
            configuration.deviceID2 = deviceID2.trimmed
            configuration.signature = signature.trimmed
            configuration.model = model.trimmed
            configuration.timeZone = timeZone.trimmed
        case .xtream:
            configuration.serverURL = serverURL.trimmed
            configuration.username = username.trimmed
            configuration.password = password
            configuration.guideURL = guideURL.trimmed
        case .m3u:
            configuration.playlistURL = playlistURL.trimmed
            configuration.guideURL = guideURL.trimmed
        }
        return configuration
    }
}

/// Loose checks on what people type as addresses: enough to catch a typo
/// before Test, not to second-guess the provider.
enum SourceURLCheck {
    /// The URL a typed address means: "portal.example.com/c/" is taken as
    /// http when `allowingSchemeless`, as Stalker portals usually are.
    static func url(from text: String, allowingSchemeless: Bool) -> URL? {
        var trimmed = text.trimmed
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if allowingSchemeless, !trimmed.contains("://") { trimmed = "http://" + trimmed }
        return URL(string: trimmed)
    }

    static func isWebAddress(_ text: String, allowingSchemeless: Bool) -> Bool {
        guard let url = url(from: text, allowingSchemeless: allowingSchemeless),
              let scheme = url.scheme?.lowercased(), let host = url.host(), !host.isEmpty else { return false }
        // `stub://` is the demo provider's (`-StubProvider YES`).
        return ["http", "https", "stub"].contains(scheme)
    }

    static func isPlaylistAddress(_ text: String) -> Bool {
        guard let url = url(from: text, allowingSchemeless: false) else { return false }
        if url.isFileURL { return true }
        return isWebAddress(text, allowingSchemeless: false)
    }
}

/// Where a playlist file chosen with "Choose File…" is kept (SRC-3): a copy
/// in Application Support, so it outlives the picker's access to the
/// original.
enum PlaylistFile {
    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Playlists", directoryHint: .isDirectory)
    }

    /// Copies the picked file next to the app's data as `<source id>.m3u`
    /// (replacing an earlier copy) and returns the copy's `file://` URL.
    static func importCopy(of picked: URL, sourceID: UUID) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let scoped = picked.startAccessingSecurityScopedResource()
            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = picked.pathExtension.isEmpty ? "m3u" : picked.pathExtension.lowercased()
            let destination = directory.appending(path: "\(sourceID.uuidString).\(ext)")
            if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(at: picked, to: destination)
            return destination
        }.value
    }

    /// A saved playlist link as it reads on this device now. iOS moves an
    /// app's container when the app is updated or reinstalled, so the
    /// absolute `file://` URL saved with the source goes stale while the copy
    /// itself stays in Application Support/Playlists under the same name: a
    /// file URL in a folder of that name is re-rooted at today's folder.
    /// Web links, and files anywhere else, come back as they are.
    static func resolved(_ stored: String) -> String {
        guard let url = URL(string: stored.trimmingCharacters(in: .whitespacesAndNewlines)), url.isFileURL,
              !url.lastPathComponent.isEmpty,
              url.deletingLastPathComponent().lastPathComponent == directory.lastPathComponent else { return stored }
        return directory.appending(path: url.lastPathComponent).absoluteString
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    fileprivate var isBlank: Bool { trimmed.isEmpty }
}
