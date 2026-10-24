import Foundation
import SwiftUI

// PlayerKit's public contract. The app's playback coordinator builds a
// `PlayerItem` (with a resolver that asks CatalogKit for a fresh link),
// makes a `PlayerModel`, and shows `PlayerView`. Additive changes only.

public enum StreamFormat: String, Sendable, Hashable, Codable {
    case hls
    case mpegts
    case mp4
    case mkv
    case unknown
}

/// Everything an engine needs to open a stream.
public struct StreamDescriptor: Sendable, Hashable {
    public var url: URL
    /// Sent with every request (User-Agent, Referer, Cookie).
    public var headers: [String: String]
    public var format: StreamFormat
    public var isLive: Bool
    /// Seconds to start at (resume), or nil.
    public var startPosition: TimeInterval?

    public init(url: URL, headers: [String: String] = [:], format: StreamFormat = .unknown, isLive: Bool = false, startPosition: TimeInterval? = nil) {
        self.url = url
        self.headers = headers
        self.format = format
        self.isLive = isLive
        self.startPosition = startPosition
    }
}

public enum EngineKind: String, Sendable, Hashable, CaseIterable {
    /// HLS, MP4, MOV: picture in picture, AirPlay and Now Playing for free.
    case avPlayer
    /// Raw MPEG-TS, MKV and everything else.
    case vlc
}

public enum PlaybackState: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case ended
    /// The provider's or engine's message, shown as it is (PLY-4).
    case failed(String)
}

public struct MediaTrack: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case audio, subtitle }

    public var id: String
    public var kind: Kind
    public var name: String
    /// ISO 639 code when the stream says.
    public var language: String?

    public init(id: String, kind: Kind, name: String, language: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.language = language
    }
}

/// Fit, fill and zoom (PLY-7).
public enum VideoGravity: String, Sendable, Hashable, CaseIterable {
    case fit
    case fill
    case zoom
}

/// One engine behind the player. The player screen and multi-view never ask
/// which one is running.
@MainActor
public protocol PlaybackEngine: AnyObject {
    var kind: EngineKind { get }
    var state: PlaybackState { get }
    /// Seconds from the start of the stream (or of the live window).
    var currentTime: TimeInterval { get }
    /// Nil for live streams without a seekable window.
    var duration: TimeInterval? { get }
    var isMuted: Bool { get set }
    var volume: Float { get set }
    var gravity: VideoGravity { get set }
    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    var selectedAudioTrackID: String? { get }
    var selectedSubtitleTrackID: String? { get }
    var supportsPictureInPicture: Bool { get }
    /// Called on the main actor whenever `state`, tracks or duration change.
    var onChange: (() -> Void)? { get set }

    func load(_ stream: StreamDescriptor)
    func play()
    func pause()
    func seek(to seconds: TimeInterval)
    func stop()
    func selectAudioTrack(id: String)
    /// Nil turns subtitles off.
    func selectSubtitleTrack(id: String?)
    func startPictureInPicture()

    /// The engine's video surface for SwiftUI.
    func makeVideoView() -> AnyView
}

/// What to fetch a link for when (re)opening an item.
public enum PlayerResolveRequest: Sendable, Hashable {
    /// Live now, or a movie/episode from `startPosition`.
    case standard
    /// From the start of the programme on now, or an aired one (catch-up).
    case fromStart(Date, duration: TimeInterval)
}

/// One thing the player can show: a channel, a catch-up programme, a movie or
/// an episode. The resolver asks for a fresh link every time it is called.
public struct PlayerItem: Identifiable, Sendable {
    public var id: String
    public var title: String
    /// "102 Fieldhouse Sports · 19:30–22:30" or "S2 · E5 — The Lighthouse Keeper".
    public var subtitle: String?
    public var channelNumber: Int?
    public var logoURL: URL?
    public var artworkURL: URL?
    public var isLive: Bool
    /// The live programme's bounds, for the catch-up timeline (PLY-5).
    public var programmeStart: Date?
    public var programmeEnd: Date?
    /// The channel has an archive, so "From the start" and rewinding live work.
    public var hasArchive: Bool
    /// Seconds to resume at.
    public var startPosition: TimeInterval?
    public var resolve: @Sendable (PlayerResolveRequest) async throws -> StreamDescriptor

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        channelNumber: Int? = nil,
        logoURL: URL? = nil,
        artworkURL: URL? = nil,
        isLive: Bool,
        programmeStart: Date? = nil,
        programmeEnd: Date? = nil,
        hasArchive: Bool = false,
        startPosition: TimeInterval? = nil,
        resolve: @escaping @Sendable (PlayerResolveRequest) async throws -> StreamDescriptor
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.channelNumber = channelNumber
        self.logoURL = logoURL
        self.artworkURL = artworkURL
        self.isLive = isLive
        self.programmeStart = programmeStart
        self.programmeEnd = programmeEnd
        self.hasArchive = hasArchive
        self.startPosition = startPosition
        self.resolve = resolve
    }
}

/// What the player tells its owner, so the app can save progress and
/// who's-watching rows at the right moments (never per second).
public enum PlayerEvent: Sendable, Equatable {
    case started(itemID: String)
    case paused(itemID: String, position: TimeInterval, duration: TimeInterval?)
    /// Every 5 minutes of playback.
    case checkpoint(itemID: String, position: TimeInterval, duration: TimeInterval?)
    case finished(itemID: String, duration: TimeInterval?)
    /// The user closed the player or switched item.
    case stopped(itemID: String, position: TimeInterval, duration: TimeInterval?)
    case failed(itemID: String, message: String)
    /// Channel up/down or next episode moved to another item.
    case switched(fromItemID: String, toItemID: String)
}
