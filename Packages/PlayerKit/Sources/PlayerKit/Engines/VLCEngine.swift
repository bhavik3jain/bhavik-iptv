#if canImport(VLCKit)
import SwiftUI
import VLCKit

/// Raw MPEG-TS, MKV and everything AVPlayer refuses, through VLCKit 4
/// (PLY-1). The only file that imports VLCKit: if the dependency is ever
/// removed this compiles away, `VLCKitInfo.isLinked` turns false and the
/// model falls back to AVPlayer with a message.
///
/// VLCKit delivers its delegate callbacks synchronously on libvlc's own
/// threads (VLCKit 4's default events configuration), so a small proxy
/// forwards each one to the main actor and the engine re-reads the player
/// there. Calling back into the player from the libvlc thread would deadlock.
@MainActor
final class VLCEngine: PlaybackEngine {
    let kind: EngineKind = .vlc
    private(set) var state: PlaybackState = .idle
    var onChange: (() -> Void)?

    private let player: VLCMediaPlayer
    private let drawable: PlatformView
    private let events: VLCEventProxy

    private var stream: StreamDescriptor?
    private var wantsToPlay = false
    private var hasStarted = false
    /// A stop we asked for; any other stop is the stream ending or dying.
    private var stopRequested = false
    /// Set by `load` until the new media reports opening or playing: swapping
    /// the media on a playing player makes libvlc stop the old one first, and
    /// that stop arrives (on its own thread, then here) after `load` returned.
    /// Without this a channel change would read as the new stream dying.
    private var awaitingOpen = false
    /// libvlc's buffering progress, 0…1 (1 is "enough to play").
    private var bufferingProgress: Float = 1

    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var selectedAudioTrackID: String?
    private(set) var selectedSubtitleTrackID: String?

    init() {
        player = VLCMediaPlayer()
        #if os(macOS)
        let videoView = VLCVideoView()
        videoView.backColor = .black
        drawable = videoView
        #else
        let view = UIView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        drawable = view
        #endif
        events = VLCEventProxy()
        events.engine = self
        player.drawable = drawable
        player.delegate = events
        applyGravity()
    }

    // MARK: Properties

    var currentTime: TimeInterval {
        guard let milliseconds = player.time.value?.doubleValue, milliseconds.isFinite else { return 0 }
        return max(0, milliseconds / 1000)
    }

    var duration: TimeInterval? {
        guard let milliseconds = player.media?.length.value?.doubleValue, milliseconds > 0 else { return nil }
        return milliseconds / 1000
    }

    var isMuted = false {
        didSet { applyAudio() }
    }

    /// 0…1 here; VLC counts 0…200 with 100 as unity.
    var volume: Float = 1 {
        didSet { applyAudio() }
    }

    var gravity: VideoGravity = .fit {
        didSet { applyGravity() }
    }

    /// VLCKit's own picture in picture is Phase 4 (PLY-8).
    var supportsPictureInPicture: Bool { false }

    // MARK: Control

    func load(_ stream: StreamDescriptor) {
        self.stream = stream
        hasStarted = false
        stopRequested = false
        awaitingOpen = true
        bufferingProgress = 1
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil

        guard let media = VLCMedia(url: stream.url) else {
            state = .failed(PlayerMessage.genericFailure)
            onChange?()
            return
        }
        for option in Self.mediaOptions(for: stream) {
            media.addOption(option)
        }
        player.media = media
        state = .loading
        onChange?()
    }

    func play() {
        wantsToPlay = true
        stopRequested = false
        player.play()
        refresh()
    }

    func pause() {
        wantsToPlay = false
        if player.canPause { player.pause() }
        refresh()
    }

    func seek(to seconds: TimeInterval) {
        guard player.isSeekable else { return }
        let upper = duration ?? .greatestFiniteMagnitude
        let milliseconds = Int64((min(max(seconds, 0), upper) * 1000).rounded())
        player.time = VLCTime(number: NSNumber(value: milliseconds))
    }

    func stop() {
        wantsToPlay = false
        stopRequested = true
        player.stop()
        player.media = nil
        stream = nil
        state = .idle
    }

    func selectAudioTrack(id: String) {
        guard let track = player.audioTracks.first(where: { $0.trackId == id }) else { return }
        track.isSelectedExclusively = true
        readTracks()
        onChange?()
    }

    func selectSubtitleTrack(id: String?) {
        if let id, let track = player.textTracks.first(where: { $0.trackId == id }) {
            track.isSelectedExclusively = true
        } else if id == nil {
            player.deselectAllTextTracks()
        }
        readTracks()
        onChange?()
    }

    func startPictureInPicture() {}

    func makeVideoView() -> AnyView {
        AnyView(EngineVideoSurface(content: drawable))
    }

    // MARK: Events (main actor)

    func playerStateChanged() {
        refresh()
    }

    func bufferingChanged(_ progress: Float) {
        bufferingProgress = progress
        refresh()
    }

    func tracksChanged() {
        readTracks()
        onChange?()
    }

    func lengthChanged() {
        onChange?()
    }

    private func refresh() {
        let newState = computeState()
        if newState != state {
            // libvlc makes its audio output when playback starts and forgets a
            // mute set before then, so a muted multi-view tile re-applies it.
            if newState == .playing { applyAudio() }
            state = newState
            onChange?()
        }
    }

    private func applyAudio() {
        guard let audio = player.audio else { return }
        audio.isMuted = isMuted
        audio.volume = Int32((min(max(volume, 0), 1) * 100).rounded())
    }

    private func computeState() -> PlaybackState {
        guard stream != nil else { return .idle }
        switch player.state {
        case .opening:
            awaitingOpen = false
            return hasStarted ? .buffering : .loading
        case .playing:
            awaitingOpen = false
            if bufferingProgress < 1 { return hasStarted ? .buffering : .loading }
            hasStarted = true
            return .playing
        case .paused:
            return .paused
        case .stopped, .stopping:
            if stopRequested { return .idle }
            // The previous media's stop, still on its way in.
            if awaitingOpen { return .loading }
            // The stream ran out (a movie's end) or the server closed it
            // before a frame arrived.
            return hasStarted ? .ended : .failed(PlayerMessage.stoppedBeforeStart)
        case .error:
            // libvlc 4 keeps no error text; its log has the detail.
            return .failed(PlayerMessage.vlcCouldNotOpen)
        case .nothingSpecial:
            return wantsToPlay ? .loading : .idle
        @unknown default:
            return state
        }
    }

    private func readTracks() {
        let audio = player.audioTracks
        let text = player.textTracks
        audioTracks = audio.map { MediaTrack(id: $0.trackId, kind: .audio, name: $0.trackName, language: $0.language) }
        subtitleTracks = text.map { MediaTrack(id: $0.trackId, kind: .subtitle, name: $0.trackName, language: $0.language) }
        selectedAudioTrackID = audio.first(where: \.isSelected)?.trackId
        selectedSubtitleTrackID = text.first(where: \.isSelected)?.trackId
    }

    /// Fit is VLC's "smaller dimension" fit, fill its "larger", and zoom is
    /// fill over a 4:3 crop — the same third of magnification as AVPlayer's.
    private func applyGravity() {
        switch gravity {
        case .fit:
            player.setCropRatioWithNumerator(0, denominator: 0)
            player.videoFitMode = .smaller
        case .fill:
            player.setCropRatioWithNumerator(0, denominator: 0)
            player.videoFitMode = .larger
        case .zoom:
            player.setCropRatioWithNumerator(4, denominator: 3)
            player.videoFitMode = .larger
        }
    }

    /// Request headers become VLC's per-media options. VLC's HTTP module
    /// only takes a user agent and a referrer; any other header is dropped
    /// (Stalker's play links carry their token in the URL, not a cookie).
    static func mediaOptions(for stream: StreamDescriptor) -> [String] {
        var options: [String] = []
        for (name, value) in stream.headers.sorted(by: { $0.key < $1.key }) {
            switch name.lowercased() {
            case "user-agent": options.append(":http-user-agent=\(value)")
            case "referer", "referrer": options.append(":http-referrer=\(value)")
            default: continue
            }
        }
        // Live gets a short cache for a quick start (quality bar: 3 s for
        // MPEG-TS); files a longer one to ride out Wi-Fi dips.
        options.append(":network-caching=\(stream.isLive ? 1500 : 3000)")
        if let start = stream.startPosition, start > 0 {
            options.append(":start-time=\(Int(start))")
        }
        return options
    }
}

/// VLCKit's delegate. Nonisolated because libvlc calls it on its own
/// threads; it only ever forwards to the main actor.
///
/// `@unchecked Sendable`: `engine` is written once, on the main actor,
/// before the proxy becomes the player's delegate, and only read afterwards;
/// the engine it points at is main-actor isolated and so Sendable itself.
private final class VLCEventProxy: NSObject, VLCMediaPlayerDelegate, @unchecked Sendable {
    weak var engine: VLCEngine?

    func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        forward { $0.playerStateChanged() }
    }

    func mediaPlayerBufferingChanged(_ progress: Float) {
        forward { $0.bufferingChanged(progress) }
    }

    func mediaPlayerLengthChanged(_ length: Int64) {
        forward { $0.lengthChanged() }
    }

    func mediaPlayerTrackAdded(_ trackId: String, with trackType: VLCMedia.TrackType) {
        forward { $0.tracksChanged() }
    }

    func mediaPlayerTrackRemoved(_ trackId: String, with trackType: VLCMedia.TrackType) {
        forward { $0.tracksChanged() }
    }

    func mediaPlayerTrackSelected(_ trackType: VLCMedia.TrackType, selectedId: String, unselectedId: String) {
        forward { $0.tracksChanged() }
    }

    private func forward(_ body: @escaping @MainActor @Sendable (VLCEngine) -> Void) {
        let engine = self.engine
        Task { @MainActor in
            if let engine { body(engine) }
        }
    }
}
#endif
