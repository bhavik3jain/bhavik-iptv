import AVFoundation
import Foundation
import MediaPlayer

#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The lock screen, Control Center, the Mac's Now Playing menu and the
/// headphone/remote buttons (PLY-3), for both engines: AVPlayer's automatic
/// Now Playing doesn't cover VLCKit, so the app sets it itself for both.
///
/// One player at a time owns this: the full-screen player does, multi-view
/// tiles don't (`PlayerConfiguration.publishesNowPlaying`).
@MainActor
final class NowPlayingCenter {
    struct Handlers {
        var play: @MainActor () -> Void
        var pause: @MainActor () -> Void
        var toggle: @MainActor () -> Void
        var skip: @MainActor (TimeInterval) -> Void
        var next: @MainActor () -> Void
        var previous: @MainActor () -> Void
        var seek: @MainActor (TimeInterval) -> Void
    }

    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?

    func activate(_ handlers: Handlers) {
        deactivateCommands()
        let center = MPRemoteCommandCenter.shared()
        // Handlers arrive on the main thread in practice, but nothing promises
        // it, so each one hops rather than assuming.
        add(center.playCommand) { handlers.play() }
        add(center.pauseCommand) { handlers.pause() }
        add(center.togglePlayPauseCommand) { handlers.toggle() }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { handlers.skip(10) }
        add(center.skipBackwardCommand) { handlers.skip(-10) }
        add(center.nextTrackCommand) { handlers.next() }
        add(center.previousTrackCommand) { handlers.previous() }
        let seek = center.changePlaybackPositionCommand
        // `@Sendable` keeps the handler nonisolated: a closure formed here
        // would otherwise inherit the main actor, and Swift 6 traps when
        // MediaPlayer calls it from one of its own queues.
        let token = seek.addTarget { @Sendable event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in handlers.seek(position) }
            return .success
        }
        targets.append((seek, token))
    }

    /// Writes what's playing. Elapsed time and rate are enough for the system
    /// to run the clock itself, so this is called on state changes and seeks,
    /// not every tick.
    func update(item: PlayerItem, isPlaying: Bool, position: TimeInterval, duration: TimeInterval?, canGoNext: Bool, canGoPrevious: Bool, canSeek: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = canGoNext
        center.previousTrackCommand.isEnabled = canGoPrevious
        center.changePlaybackPositionCommand.isEnabled = canSeek && !item.isLive
        center.skipForwardCommand.isEnabled = canSeek
        center.skipBackwardCommand.isEnabled = canSeek

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyIsLiveStream: item.isLive,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
        ]
        if let subtitle = item.subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if let duration, !item.isLive { info[MPMediaItemPropertyPlaybackDuration] = duration }
        loadArtwork(item.artworkURL ?? item.logoURL)
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = info
        #if os(macOS)
        // The Mac shows Now Playing from playbackState, not the rate.
        infoCenter.playbackState = isPlaying ? .playing : .paused
        #endif
    }

    func deactivate() {
        deactivateCommands()
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        artworkURL = nil
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = nil
        #if os(macOS)
        infoCenter.playbackState = .stopped
        #endif
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
        command.isEnabled = true
        let token = command.addTarget { @Sendable _ in
            Task { @MainActor in action() }
            return .success
        }
        targets.append((command, token))
    }

    private func deactivateCommands() {
        for (command, token) in targets {
            command.removeTarget(token)
        }
        targets = []
    }

    /// Fetches the poster or logo once per item; Now Playing shows text until
    /// it arrives. Goes through URLCache like every other image.
    private func loadArtwork(_ url: URL?) {
        guard url != artworkURL else { return }
        artworkURL = url
        artwork = nil
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled,
                  let artwork = Self.makeArtwork(data) else { return }
            guard let self, self.artworkURL == url else { return }
            self.artwork = artwork
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    private nonisolated static func makeArtwork(_ data: Data) -> MPMediaItemArtwork? {
        #if os(iOS) || os(tvOS)
        guard let image = UIImage(data: data) else { return nil }
        #else
        guard let image = NSImage(data: data) else { return nil }
        #endif
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

/// Audio keeps playing with the screen locked or the app in the background,
/// and drives picture in picture (PLY-3; the app declares the `audio`
/// background mode).
enum PlaybackAudioSession {
    @MainActor
    static func activate() {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        do {
            #if os(tvOS)
            // The TV routes long-form video itself; there is no policy to ask for.
            try session.setCategory(.playback, mode: .moviePlayback)
            #else
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            #endif
            try session.setActive(true)
        } catch {
            // Playback still works in the foreground; only background audio
            // is lost. Nothing sensitive in the error, but nothing to show either.
        }
        #endif
    }
}
