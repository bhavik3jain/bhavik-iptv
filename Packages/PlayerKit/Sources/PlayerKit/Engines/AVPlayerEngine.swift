import AVFoundation
import AVKit
import SwiftUI

/// HLS, MP4 and MOV through AVPlayer (PLY-1): picture in picture, AirPlay
/// and the system's caption settings come with it (PLY-3).
///
/// AVFoundation reports through KVO and notifications on threads of its
/// choosing, so every observer hops to the main actor before touching state
/// and the engine re-reads AVPlayer there rather than trusting the payload.
@MainActor
final class AVPlayerEngine: PlaybackEngine {
    let kind: EngineKind = .avPlayer
    private(set) var state: PlaybackState = .idle
    var onChange: (() -> Void)?

    /// For the Mac's AirPlay picker, which picks a route for one player.
    let player = AVPlayer()
    private let surface = PlayerLayerView()
    private var pictureInPicture: AVPictureInPictureController?

    private var stream: StreamDescriptor?
    private var playerObservations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var itemNotifications: [any NSObjectProtocol] = []
    private var tracksTask: Task<Void, Never>?

    /// The user (or the model) asked to play; before the first frame a
    /// paused AVPlayer is then still loading, not paused.
    private var wantsToPlay = false
    private var hasStarted = false
    private var didReachEnd = false
    private var failureMessage: String?
    private var pendingStartPosition: TimeInterval?

    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var selectedAudioTrackID: String?
    private(set) var selectedSubtitleTrackID: String?

    init() {
        surface.playerLayer.player = player
        // AirPlay video (PLY-3): the stream goes to the Apple TV, not a mirror.
        player.allowsExternalPlayback = true
        #if os(iOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let controller = AVPictureInPictureController(playerLayer: surface.playerLayer)
            #if os(iOS)
            // Swiping home while a stream plays continues it in a floating window.
            controller?.canStartPictureInPictureAutomaticallyFromInline = true
            #endif
            pictureInPicture = controller
        }
        playerObservations = [
            player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
        ]
    }

    // MARK: Properties

    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return 0 }
        if isLiveStream, let window = seekableWindow {
            return max(0, seconds - window.start.seconds)
        }
        return max(0, seconds)
    }

    var duration: TimeInterval? {
        if isLiveStream {
            guard let window = seekableWindow else { return nil }
            let length = window.duration.seconds
            return length.isFinite && length > 0 ? length : nil
        }
        guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = min(max(newValue, 0), 1) }
    }

    var gravity: VideoGravity = .fit {
        didSet { surface.gravity = gravity }
    }

    var supportsPictureInPicture: Bool { pictureInPicture != nil }

    /// iOS starts picture in picture by itself when the app leaves mid-stream
    /// (PLY-3); a multi-view tile turns this off.
    var startsPictureInPictureAutomatically = true {
        didSet {
            #if os(iOS)
            pictureInPicture?.canStartPictureInPictureAutomaticallyFromInline = startsPictureInPictureAutomatically
            #endif
        }
    }

    private var isLiveStream: Bool {
        stream?.isLive == true || player.currentItem?.duration.isIndefinite == true
    }

    /// The live window: the last seekable range.
    private var seekableWindow: CMTimeRange? {
        guard let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue,
              range.duration.seconds.isFinite else { return nil }
        return range
    }

    // MARK: Control

    func load(_ stream: StreamDescriptor) {
        tearDownItem()
        self.stream = stream
        hasStarted = false
        didReachEnd = false
        failureMessage = nil
        pendingStartPosition = stream.startPosition.flatMap { $0 > 0 ? $0 : nil }

        var options: [String: Any] = [:]
        if !stream.headers.isEmpty {
            // The documented-but-private key every IPTV player uses: AVFoundation
            // has no public API for request headers (User-Agent, Referer, Cookie).
            options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers
        }
        if let agent = stream.headers.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value {
            options[AVURLAssetHTTPUserAgentKey] = agent
        }
        let asset = AVURLAsset(url: stream.url, options: options)
        let item = AVPlayerItem(asset: asset)
        observe(item)
        player.replaceCurrentItem(with: item)
        state = .loading
        onChange?()
    }

    func play() {
        wantsToPlay = true
        if didReachEnd {
            didReachEnd = false
            player.seek(to: .zero)
        }
        player.play()
        refresh()
    }

    func pause() {
        wantsToPlay = false
        player.pause()
        refresh()
    }

    func seek(to seconds: TimeInterval) {
        guard let item = player.currentItem else { return }
        didReachEnd = false
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        if isLiveStream, let window = seekableWindow {
            // At (or past) the end of the window, go to where AVPlayer would
            // sit at the live edge rather than the very last frame, which stalls.
            let length = window.duration.seconds
            var target = window.start.seconds + min(max(seconds, 0), length)
            if seconds >= length - 1 {
                let offset = item.recommendedTimeOffsetFromLive.seconds
                target = window.end.seconds - (offset.isFinite ? offset : 0)
            }
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        } else {
            let upper = duration ?? .greatestFiniteMagnitude
            let target = min(max(seconds, 0), upper)
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
    }

    func stop() {
        wantsToPlay = false
        player.pause()
        tearDownItem()
        player.replaceCurrentItem(with: nil)
        stream = nil
        state = .idle
    }

    func selectAudioTrack(id: String) {
        guard let item = player.currentItem, let group = audibleGroup,
              let option = option(for: id, prefix: "audio", in: group) else { return }
        item.select(option, in: group)
        readSelection()
        onChange?()
    }

    func selectSubtitleTrack(id: String?) {
        guard let item = player.currentItem, let group = legibleGroup else { return }
        if let id {
            guard let option = option(for: id, prefix: "text", in: group) else { return }
            item.select(option, in: group)
        } else if group.allowsEmptySelection {
            item.select(nil, in: group)
        }
        readSelection()
        onChange?()
    }

    func startPictureInPicture() {
        guard let pictureInPicture, pictureInPicture.isPictureInPicturePossible else { return }
        pictureInPicture.startPictureInPicture()
    }

    func makeVideoView() -> AnyView {
        AnyView(EngineVideoSurface(content: surface))
    }

    // MARK: State

    private func refresh() {
        let newState = computeState()
        if newState != state {
            state = newState
            onChange?()
        }
    }

    private func computeState() -> PlaybackState {
        if let failureMessage { return .failed(failureMessage) }
        guard let item = player.currentItem, stream != nil else { return .idle }
        if item.status == .failed {
            return .failed(Self.message(for: item, error: item.error))
        }
        if didReachEnd { return .ended }
        switch player.timeControlStatus {
        case .playing:
            hasStarted = true
            return .playing
        case .waitingToPlayAtSpecifiedRate:
            return hasStarted ? .buffering : .loading
        case .paused:
            return (!wantsToPlay || hasStarted) ? .paused : .loading
        @unknown default:
            return state
        }
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservations = [
            item.observe(\.status, options: [.new]) { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.itemStatusChanged() }
            },
            item.observe(\.duration, options: [.new]) { @Sendable [weak self] _, _ in
                Task { @MainActor in self?.onChange?() }
            },
        ]
        let center = NotificationCenter.default
        itemNotifications = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { @Sendable [weak self] _ in
                MainActor.assumeIsolated {
                    self?.didReachEnd = true
                    self?.refresh()
                }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { @Sendable [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                MainActor.assumeIsolated {
                    guard let self, let item = self.player.currentItem else { return }
                    self.failureMessage = Self.message(for: item, error: error)
                    self.refresh()
                }
            },
        ]
    }

    private func itemStatusChanged() {
        guard let item = player.currentItem else { return }
        if item.status == .readyToPlay {
            if let position = pendingStartPosition {
                pendingStartPosition = nil
                let time = CMTime(seconds: position, preferredTimescale: 600)
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
            }
            loadTracks(for: item)
        }
        refresh()
        onChange?()
    }

    private func tearDownItem() {
        tracksTask?.cancel()
        tracksTask = nil
        itemObservations.forEach { $0.invalidate() }
        itemObservations = []
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        itemNotifications = []
        audibleGroup = nil
        legibleGroup = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil
    }

    // MARK: Tracks

    /// Audio and subtitle choices come from the asset's media selection groups.
    private func loadTracks(for item: AVPlayerItem) {
        guard tracksTask == nil, let asset = item.asset as? AVURLAsset else { return }
        tracksTask = Task { [weak self] in
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled, let self, self.player.currentItem === item else { return }
            self.audibleGroup = audible
            self.legibleGroup = legible
            self.audioTracks = audible.map { Self.tracks(in: $0, kind: .audio, prefix: "audio") } ?? []
            self.subtitleTracks = legible.map { Self.tracks(in: $0, kind: .subtitle, prefix: "text") } ?? []
            self.readSelection()
            self.onChange?()
        }
    }

    private func readSelection() {
        guard let item = player.currentItem else { return }
        let selection = item.currentMediaSelection
        selectedAudioTrackID = audibleGroup.flatMap { group in
            selection.selectedMediaOption(in: group).flatMap { group.options.firstIndex(of: $0) }.map { "audio-\($0)" }
        }
        selectedSubtitleTrackID = legibleGroup.flatMap { group in
            selection.selectedMediaOption(in: group).flatMap { group.options.firstIndex(of: $0) }.map { "text-\($0)" }
        }
    }

    private func option(for id: String, prefix: String, in group: AVMediaSelectionGroup) -> AVMediaSelectionOption? {
        guard id.hasPrefix(prefix + "-"), let index = Int(id.dropFirst(prefix.count + 1)),
              group.options.indices.contains(index) else { return nil }
        return group.options[index]
    }

    private static func tracks(in group: AVMediaSelectionGroup, kind: MediaTrack.Kind, prefix: String) -> [MediaTrack] {
        group.options.enumerated().map { index, option in
            MediaTrack(
                id: "\(prefix)-\(index)",
                kind: kind,
                name: option.displayName,
                language: option.extendedLanguageTag ?? option.locale?.language.languageCode?.identifier
            )
        }
    }

    // MARK: Messages

    /// The provider's own words where AVFoundation kept them: the access
    /// log's last error ("HTTP 403: Forbidden") beats a generic NSError.
    private static func message(for item: AVPlayerItem, error: (any Error)?) -> String {
        if let event = item.errorLog()?.events.last, let comment = event.errorComment, !comment.isEmpty {
            return PlayerMessage.scrub(comment)
        }
        if let error { return PlayerMessage.describe(error) }
        return PlayerMessage.genericFailure
    }
}

/// A view whose only content is an AVPlayerLayer, laid out by hand so zoom
/// can magnify the layer past the view's bounds (which clip).
final class PlayerLayerView: PlatformView {
    let playerLayer = AVPlayerLayer()

    /// Fit letterboxes, fill crops to the screen, zoom fills and then
    /// magnifies by a third — for 4:3 pictures broadcast inside a 16:9 frame
    /// with bars on every side, common on SD channels (PLY-7).
    var gravity: VideoGravity = .fit {
        didSet { applyGravity() }
    }

    #if os(iOS)
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        layer.addSublayer(playerLayer)
        applyGravity()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPlayerLayer()
    }
    #elseif os(macOS)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(playerLayer)
        applyGravity()
    }

    override func layout() {
        super.layout()
        layoutPlayerLayer()
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func layoutPlayerLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.bounds = bounds
        playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    private func applyGravity() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch gravity {
        case .fit:
            playerLayer.videoGravity = .resizeAspect
            playerLayer.setAffineTransform(.identity)
        case .fill:
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.setAffineTransform(.identity)
        case .zoom:
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.setAffineTransform(CGAffineTransform(scaleX: 4.0 / 3.0, y: 4.0 / 3.0))
        }
        CATransaction.commit()
    }
}
