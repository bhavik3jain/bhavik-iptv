import Foundation
import Observation
import SwiftUI

/// Picks the engine for a stream (PLY-1). Pure, so its table is tested.
public enum EngineChooser {
    public static func choose(for stream: StreamDescriptor) -> EngineKind {
        switch stream.format {
        case .hls, .mp4: return .avPlayer
        case .mpegts, .mkv: return .vlc
        case .unknown:
            let ext = stream.url.pathExtension.lowercased()
            if ["m3u8", "mp4", "m4v", "mov"].contains(ext) { return .avPlayer }
            return .vlc
        }
    }
}

/// Drives one player screen: the current item, its engine, the controls'
/// state, retries (PLY-4) and channel up/down (LIV-5).
///
/// PUBLIC API IS A CONTRACT. Add to it; don't change or remove.
@MainActor
@Observable
public final class PlayerModel: Identifiable {
    public nonisolated let id = UUID()

    /// Moves through a queue: channel up/down for live, next episode for VOD.
    /// Return nil at either end.
    public typealias Navigator = @MainActor (_ current: PlayerItem, _ offset: Int) -> PlayerItem?

    public init(item: PlayerItem, navigator: Navigator? = nil) {
        self.item = item
        self.navigator = navigator
    }

    public private(set) var item: PlayerItem
    let navigator: Navigator?

    /// Called for every event the owner records (progress, who's watching).
    public var onEvent: ((PlayerEvent) -> Void)?
    /// Called when the user closes the player.
    public var onClose: (() -> Void)?

    public private(set) var state: PlaybackState = .idle
    public private(set) var engineKind: EngineKind?
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval?
    /// Seconds behind live when paused or rewound in a live stream.
    public private(set) var liveOffset: TimeInterval = 0
    public private(set) var audioTracks: [MediaTrack] = []
    public private(set) var subtitleTracks: [MediaTrack] = []
    public private(set) var selectedAudioTrackID: String?
    public private(set) var selectedSubtitleTrackID: String?
    public var gravity: VideoGravity = .fit
    public var isMuted = false
    /// Whether the controls overlay is showing.
    public var controlsVisible = true

    public var isPlaying: Bool { state == .playing || state == .buffering }
    public var canGoToPreviousItem: Bool { false }
    public var canGoToNextItem: Bool { false }
    /// The neighbouring items' titles for the "‹ 101 Cityline News" pills.
    public var previousItemTitle: String? { nil }
    public var nextItemTitle: String? { nil }
    public var supportsPictureInPicture: Bool { false }

    /// Opens the item (resolving a fresh link) and plays.
    public func start() async {}
    public func play() {}
    public func pause() {}
    public func togglePlayPause() {}
    public func skip(by seconds: TimeInterval) {}
    public func seek(to seconds: TimeInterval) {}
    /// Back to the live edge (PLY-2).
    public func jumpToLive() async {}
    /// Plays the current programme from its start (catch-up channels).
    public func playFromStart() async {}
    public func goToNextItem() async {}
    public func goToPreviousItem() async {}
    /// The last channel watched before this one (LIV-5).
    public func goToLastItem() async {}
    public func selectAudioTrack(id: String) {}
    public func selectSubtitleTrack(id: String?) {}
    /// Picks tracks matching the profile's languages when they load (PLY-6).
    public func setPreferredLanguages(audio: String?, subtitle: String?) {}
    public func startPictureInPicture() {}
    public func close() {}

    /// The engine's video surface.
    public func videoView() -> AnyView { AnyView(Color.black) }
}

/// The full-screen player (mockup 06): video edge to edge, controls in the
/// safe area, catch-up timeline, channel pills, PiP, AirPlay, tracks.
public struct PlayerView: View {
    let model: PlayerModel

    public init(model: PlayerModel) {
        self.model = model
    }

    public var body: some View {
        model.videoView()
            .ignoresSafeArea()
            .task { await model.start() }
    }
}
