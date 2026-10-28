import Foundation
import SwiftUI

/// What a download is of.
public enum DownloadKind: String, Codable, Sendable, Hashable {
    case movie
    case episode
}

/// Where a download stands.
public enum DownloadState: String, Codable, Sendable, Hashable {
    /// Running: it takes one of the provider's streams (DL-2).
    case running
    /// Paused by the person, or stopped when the app last quit; it takes no
    /// stream.
    case paused
    case finished
    case failed
}

/// Where a finished download's file is. A file the app downloaded sits in
/// its downloads folder; an HLS package is placed by the system, and its
/// path is kept relative to the home directory, as Apple asks, since the
/// container's absolute path changes across updates.
public enum DownloadLocation: Codable, Sendable, Hashable {
    case downloadsFolder(String)
    case home(String)
}

/// One movie or episode saved on this device (technical spec, Download:
/// itemKey, profileID, fileName, bytes, state, finishedAt). Kept in a file
/// of its own, never synced: downloads belong to the device (DL-1).
public struct DownloadRecord: Codable, Identifiable, Sendable, Hashable {
    /// The catalog's item key.
    public var id: String
    public var kind: DownloadKind
    public var title: String
    /// "S2 E5 · The Lighthouse Keeper" for an episode.
    public var subtitle: String?
    public var artworkURL: URL?
    public var sourceID: UUID
    /// Who asked for it: the who's-watching row while it runs is theirs.
    public var profileID: UUID?
    /// The show an episode belongs to.
    public var seriesKey: String?
    public var state: DownloadState
    public var failureMessage: String?
    /// 0…1, from bytes for a file and from the time loaded for HLS.
    public var fraction: Double
    public var bytesWritten: Int64
    public var bytesExpected: Int64?
    public var isHLS: Bool
    public var location: DownloadLocation?
    public var createdAt: Date
    public var finishedAt: Date?

    public init(request: DownloadRequest, profileID: UUID?, isHLS: Bool, now: Date = .now) {
        id = request.itemKey
        kind = request.kind
        title = request.title
        subtitle = request.subtitle
        artworkURL = request.artworkURL
        sourceID = request.sourceID
        self.profileID = profileID
        seriesKey = request.seriesKey
        state = .running
        fraction = 0
        bytesWritten = 0
        self.isHLS = isHLS
        createdAt = now
    }
}

/// What a screen asks to download: the item, as the catalog names it.
public struct DownloadRequest: Sendable, Hashable, Identifiable {
    public var itemKey: String
    public var kind: DownloadKind
    public var title: String
    public var subtitle: String?
    public var artworkURL: URL?
    public var sourceID: UUID
    public var seriesKey: String?

    public var id: String { itemKey }

    public init(itemKey: String, kind: DownloadKind, title: String, subtitle: String? = nil, artworkURL: URL? = nil, sourceID: UUID, seriesKey: String? = nil) {
        self.itemKey = itemKey
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.sourceID = sourceID
        self.seriesKey = seriesKey
    }
}

/// The link to save, fresh from the provider (links expire, so one is
/// asked for at every start).
public struct DownloadLink: Sendable, Hashable {
    public var url: URL
    /// Sent with every request (User-Agent, Referer).
    public var headers: [String: String]
    /// An HLS playlist, saved as a package by AVFoundation; anything else is
    /// one file.
    public var isHLS: Bool

    public init(url: URL, headers: [String: String] = [:], isHLS: Bool) {
        self.url = url
        self.headers = headers
        self.isHLS = isHLS
    }
}

/// `@Environment(\.download)`: a screen asks for a download; the app checks
/// the stream limit (DL-2), resolves a fresh link and starts it, or restarts
/// one that can't simply resume.
public struct DownloadAction: Sendable {
    private let handler: @MainActor @Sendable (DownloadRequest) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (DownloadRequest) -> Void) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction(_ request: DownloadRequest) {
        handler(request)
    }
}

extension EnvironmentValues {
    @Entry public var download = DownloadAction { _ in }
}
