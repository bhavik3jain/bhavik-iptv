import AVFoundation
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
/// Every (re)open asks the item's resolver for a fresh link, because provider
/// links expire and Stalker's are single-use. An attempt that fails, or an
/// AVPlayer attempt that hasn't started within `startTimeout`, is retried once
/// with another fresh link, on VLCKit when AVPlayer was the one that failed
/// (`EnginePlan`); a second failure shows the provider's or engine's message
/// with Retry.
///
/// Events go to `onEvent` at the moments the household store wants them
/// (technical spec, Sync and sharing rules): started, paused, a checkpoint
/// every 5 minutes of actual playback, finished, stopped, failed, switched —
/// never per second.
///
/// PUBLIC API IS A CONTRACT. Add to it; don't change or remove.
@MainActor
@Observable
public final class PlayerModel: Identifiable {
    public nonisolated let id = UUID()

    /// Moves through a queue: channel up/down for live, next episode for VOD.
    /// Return nil at either end.
    public typealias Navigator = @MainActor (_ current: PlayerItem, _ offset: Int) -> PlayerItem?

    public convenience init(item: PlayerItem, navigator: Navigator? = nil) {
        self.init(item: item, navigator: navigator, configuration: .standard, engineFactory: .standard)
    }

    /// A player with its own timings and engines: multi-view tiles pass
    /// `.multiViewTile`; tests pass short timeouts and a factory of fakes.
    public init(
        item: PlayerItem,
        navigator: Navigator? = nil,
        configuration: PlayerConfiguration,
        engineFactory: PlaybackEngineFactory = .standard
    ) {
        self.item = item
        self.navigator = navigator
        self.configuration = configuration
        self.engineFactory = engineFactory
        self.isMuted = configuration.startsMuted
        self.checkpoints = CheckpointClock(
            interval: configuration.checkpointInterval,
            maximumStep: max(2, configuration.tickInterval * 2)
        )
        self.now = configuration.now()
        refreshNeighbours()
    }

    public private(set) var item: PlayerItem
    let navigator: Navigator?
    public let configuration: PlayerConfiguration
    @ObservationIgnored let engineFactory: PlaybackEngineFactory

    /// Called for every event the owner records (progress, who's watching).
    public var onEvent: ((PlayerEvent) -> Void)?
    /// Called when the user closes the player.
    public var onClose: (() -> Void)?
    /// Shows the multi-view button in the top bar; the owner opens it.
    public var onShowMultiView: (() -> Void)?
    /// After a final failure, offers the same channel from another source
    /// (PLY-4's last step). The owner knows whether one exists; nil hides it.
    public var onTryAnotherSource: (() -> Void)?

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
    public var gravity: VideoGravity = .fit {
        didSet { engine?.gravity = gravity }
    }
    public var isMuted = false {
        didSet { engine?.isMuted = isMuted }
    }
    /// Whether the controls overlay is showing.
    public var controlsVisible = true
    /// False while VoiceOver runs: controls that vanish can't be reached.
    public var autoHidesControls = true {
        didSet { autoHidesControls ? scheduleControlsHide() : showControls() }
    }
    /// The model's clock, advanced every tick, so the live timeline moves.
    public private(set) var now: Date
    public private(set) var preferredAudioLanguage: String?
    public private(set) var preferredSubtitleLanguage: String?

    public var isPlaying: Bool { state == .playing || state == .buffering }
    public var canGoToPreviousItem: Bool { previousNeighbour != nil }
    public var canGoToNextItem: Bool { nextNeighbour != nil }
    /// The neighbouring items' titles for the "‹ 101 Cityline News" pills.
    public var previousItemTitle: String? { previousNeighbour.map(PlayerFormat.itemLabel) }
    public var nextItemTitle: String? { nextNeighbour.map(PlayerFormat.itemLabel) }
    public var supportsPictureInPicture: Bool {
        configuration.allowsPictureInPicture && (engine?.supportsPictureInPicture ?? false)
    }

    /// A channel watched before this one, for "previous channel" (LIV-5).
    public var canGoToLastItem: Bool { lastItem != nil }
    public var lastItemTitle: String? { lastItem.map(PlayerFormat.itemLabel) }

    /// The live programme can be replayed from its start (catch-up channels).
    public var canPlayFromStart: Bool { item.isLive && item.hasArchive && item.programmeStart != nil }
    /// Playing the channel's archive rather than live ("From the start", or
    /// rewound past what the live link holds).
    public var isPlayingArchive: Bool {
        if case .archive = liveClock.anchor { return true }
        return false
    }
    /// At the live edge: the scrub bar's knob sits on now and the badge reads LIVE.
    public var isAtLiveEdge: Bool {
        item.isLive && !isPlayingArchive && liveOffset < LiveSeekPlan.liveTolerance && state != .paused
    }
    /// Skipping and scrubbing do something: a movie, an HLS live window, or a
    /// channel with an archive to rewind into.
    public var canSeek: Bool {
        if item.isLive { return item.hasArchive || isPlayingArchive || (duration ?? 0) > 0 }
        return (duration ?? 0) > 0
    }

    /// What the scrub bar draws (mockup 06).
    public var timeline: PlaybackTimeline {
        PlaybackTimeline.make(
            isLive: item.isLive,
            programmeStart: item.programmeStart,
            programmeEnd: item.programmeEnd,
            now: now,
            liveOffset: liveOffset,
            currentTime: currentTime,
            duration: duration
        )
    }

    // MARK: Private state

    private var engine: (any PlaybackEngine)?
    @ObservationIgnored private var nowPlaying: NowPlayingCenter?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var startTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var hideControlsTask: Task<Void, Never>?
    @ObservationIgnored private var lastActivity: Date = .distantPast

    /// Bumped by every open, switch and close; an async step that finds it
    /// changed has been overtaken and does nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var isClosed = false
    /// What the current link was resolved for, so Retry asks for the same.
    @ObservationIgnored private var request: PlayerResolveRequest = .standard
    /// One retry per open (PLY-4).
    @ObservationIgnored private var retryAvailable = true
    /// The current attempt has reached `.playing` at least once.
    @ObservationIgnored private var attemptStarted = false
    /// Seconds the current attempt has actually played. Past
    /// `retryRestoredAfter` the stream has proved itself, so a drop an hour
    /// into a match gets its own retry rather than the error screen.
    @ObservationIgnored private var attemptPlayedSeconds: TimeInterval = 0
    static let retryRestoredAfter: TimeInterval = 60
    /// `.started` went out for this item and `.stopped` hasn't yet.
    @ObservationIgnored private var startedEventSent = false
    @ObservationIgnored private var firstFailureMessage: String?
    /// The chooser wanted VLCKit and this build has none.
    @ObservationIgnored private var vlcWanted = false
    @ObservationIgnored private var preferredKind: EngineKind?
    /// Where a VOD retry resumes.
    @ObservationIgnored private var pendingResume: TimeInterval?
    @ObservationIgnored private var userPickedAudio = false
    @ObservationIgnored private var userPickedSubtitle = false
    @ObservationIgnored private var autoSelectedAudioID: String?
    @ObservationIgnored private var autoSelectedSubtitleID: String?
    @ObservationIgnored private var checkpoints: CheckpointClock
    private var liveClock = LiveClock()
    private var lastItem: PlayerItem?
    private var previousNeighbour: PlayerItem?
    private var nextNeighbour: PlayerItem?

    // MARK: Opening

    /// Opens the item (resolving a fresh link) and plays.
    public func start() async {
        guard !didStart, !isClosed else { return }
        didStart = true
        PlaybackAudioSession.activate()
        if configuration.publishesNowPlaying { activateNowPlaying() }
        startTicking()
        let token = beginOpen(.standard, isRetry: false)
        // The open belongs to the model, not to the view that asked for it:
        // SwiftUI cancels a view's `.task` when the view goes (the player
        // moving into a multi-view tile), and a resolve cancelled that way
        // would read as a dead link and spend the one retry.
        await Task { await self.runOpen(token: token, engine: nil) }.value
    }

    /// Opens the item again with a fresh link, after a failure or on demand.
    public func retry() async {
        guard didStart, !isClosed else { return }
        if !item.isLive, currentTime > 5 { pendingResume = currentTime }
        let token = beginOpen(request, isRetry: false)
        await runOpen(token: token, engine: nil)
    }

    /// Everything an open does before its first suspension, so a later call
    /// (a switch, a close) can overtake it cleanly.
    private func beginOpen(_ request: PlayerResolveRequest, isRetry: Bool) -> Int {
        generation += 1
        startTimeoutTask?.cancel()
        if !isRetry {
            retryAvailable = true
            firstFailureMessage = nil
            vlcWanted = false
        }
        // Every link starts at its own edge, so the live clock starts afresh:
        // a retried live link is at live again, and its window's edge gap is
        // measured anew when it plays.
        if case .fromStart(let start, _) = request {
            liveClock = LiveClock(anchor: .archive(start: start))
        } else {
            liveClock = LiveClock(anchor: .live)
        }
        self.request = request
        attemptStarted = false
        attemptPlayedSeconds = 0
        // Stop what's playing now: a channel change mustn't hold two of the
        // provider's streams while the new link resolves (Stalker allows one).
        engine?.onChange = nil
        engine?.stop()
        state = .loading
        liveOffset = 0
        controlsVisible = true
        return generation
    }

    /// Resolves the link, picks the engine and starts it.
    private func runOpen(token: Int, engine requested: EngineKind?) async {
        let item = self.item
        let request = self.request
        let descriptor: StreamDescriptor
        do {
            descriptor = try await item.resolve(request)
        } catch {
            guard token == generation else { return }
            attemptFailed(PlayerMessage.describe(error), failedKind: nil)
            return
        }
        guard token == generation else { return }

        let available = engineFactory.availableKinds
        let preferred = EngineChooser.choose(for: descriptor)
        preferredKind = preferred
        if preferred == .vlc, !available.contains(.vlc) { vlcWanted = true }
        let kind: EngineKind
        if let requested, available.contains(requested) {
            kind = requested
        } else if let first = EnginePlan.first(preferred: preferred, available: available) {
            kind = first
        } else {
            finalFailure(PlayerMessage.genericFailure)
            return
        }
        guard let engine = prepareEngine(kind) else {
            attemptFailed(PlayerMessage.genericFailure, failedKind: kind)
            return
        }

        var stream = descriptor
        switch request {
        case .fromStart:
            // An archive link starts at the programme's start by itself.
            stream.startPosition = nil
        case .standard where !item.isLive:
            stream.startPosition = pendingResume ?? descriptor.startPosition ?? item.startPosition
        case .standard:
            break
        }
        pendingResume = nil
        currentTime = 0
        duration = nil
        engine.load(stream)
        engine.play()
        scheduleStartTimeout(token: token, kind: kind)
    }

    /// Reuses the running engine when the kind matches (AVPlayer keeps its
    /// picture-in-picture window across a channel change), otherwise swaps.
    private func prepareEngine(_ kind: EngineKind) -> (any PlaybackEngine)? {
        if let engine, engine.kind == kind {
            engine.onChange = { [weak self] in self?.engineDidChange() }
            return engine
        }
        tearDownEngine()
        guard let new = engineFactory.makeEngine(kind) else { return nil }
        new.gravity = gravity
        new.isMuted = isMuted
        (new as? AVPlayerEngine)?.startsPictureInPictureAutomatically = configuration.allowsPictureInPicture
        new.onChange = { [weak self] in self?.engineDidChange() }
        engine = new
        engineKind = kind
        return new
    }

    private func tearDownEngine() {
        engine?.onChange = nil
        engine?.stop()
        engine = nil
        engineKind = nil
    }

    private func scheduleStartTimeout(token: Int, kind: EngineKind) {
        let seconds = kind == .avPlayer ? configuration.startTimeout : configuration.slowStartTimeout
        startTimeoutTask?.cancel()
        startTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, token == self.generation, !self.attemptStarted else { return }
            // Paused before the first frame: the user's wait, not the stream's.
            guard self.state == .loading || self.state == .buffering else { return }
            self.attemptFailed(PlayerMessage.didNotStart, failedKind: kind)
        }
    }

    // MARK: Engine events

    private func engineDidChange() {
        guard let engine, !isClosed else { return }
        let old = state
        let new = engine.state
        syncTime()
        syncTracks()

        switch new {
        case .failed(let message):
            attemptFailed(message, failedKind: engine.kind)
            return
        case .ended where item.isLive && !isPlayingArchive:
            // Live streams don't end; the server dropped it.
            attemptFailed(PlayerMessage.liveStopped, failedKind: engine.kind)
            return
        case .playing where !attemptStarted:
            state = new
            attemptDidStart()
        default:
            state = new
        }
        handleTransition(from: old, to: new)
    }

    private func attemptDidStart() {
        attemptStarted = true
        startTimeoutTask?.cancel()
        if !startedEventSent {
            startedEventSent = true
            checkpoints.reset()
            emit(.started(itemID: item.id))
        }
        liveClock.captureEdge(currentTime: currentTime, duration: duration)
        applyPreferredTracks()
        scheduleControlsHide()
        updateNowPlaying()
    }

    private func handleTransition(from old: PlaybackState, to new: PlaybackState) {
        guard old != new else { return }
        let wasPlaying = old == .playing || old == .buffering
        switch new {
        case .paused where wasPlaying:
            liveClock.paused(at: configuration.now())
            checkpoints.reset()
            emit(.paused(itemID: item.id, position: currentTime, duration: duration))
            showControls()
        case .playing, .buffering:
            if old == .paused { liveClock.resumed(at: configuration.now()) }
            if new == .playing, old != .buffering { scheduleControlsHide() }
            if new == .playing, !startedEventSent {
                // Played again after it finished: a new viewing as far as the
                // household's progress and who's-watching rows go.
                startedEventSent = true
                checkpoints.reset()
                emit(.started(itemID: item.id))
            }
        case .ended:
            checkpoints.reset()
            emit(.finished(itemID: item.id, duration: duration))
            startedEventSent = false
            showControls()
        default:
            break
        }
        liveOffset = computeLiveOffset()
        updateNowPlaying()
    }

    private func attemptFailed(_ message: String, failedKind: EngineKind?) {
        startTimeoutTask?.cancel()
        if firstFailureMessage == nil { firstFailureMessage = message }
        guard retryAvailable else {
            finalFailure(message)
            return
        }
        retryAvailable = false
        // A stream that played and then died gets the engine that worked; one
        // that never started moves AVPlayer → VLCKit (PLY-4).
        let next: EngineKind? = failedKind.map { failed in
            attemptStarted ? failed : (EnginePlan.retry(after: failed, preferred: preferredKind ?? failed, available: engineFactory.availableKinds) ?? failed)
        }
        if !item.isLive, attemptStarted, currentTime > 5 { pendingResume = currentTime }
        let token = beginOpen(request, isRetry: true)
        Task { [weak self] in
            await self?.runOpen(token: token, engine: next)
        }
    }

    private func finalFailure(_ message: String) {
        startTimeoutTask?.cancel()
        let shown = PlayerMessage.final(first: firstFailureMessage, last: message, vlcMissing: vlcWanted)
        engine?.onChange = nil
        engine?.stop()
        if startedEventSent {
            startedEventSent = false
            emit(.stopped(itemID: item.id, position: currentTime, duration: duration))
        }
        state = .failed(shown)
        showControls()
        emit(.failed(itemID: item.id, message: shown))
        updateNowPlaying()
    }

    private func syncTime() {
        guard let engine else { return }
        currentTime = engine.currentTime
        duration = engine.duration
    }

    private func syncTracks() {
        guard let engine else { return }
        let changed = engine.audioTracks != audioTracks || engine.subtitleTracks != subtitleTracks
        audioTracks = engine.audioTracks
        subtitleTracks = engine.subtitleTracks
        selectedAudioTrackID = engine.selectedAudioTrackID
        selectedSubtitleTrackID = engine.selectedSubtitleTrackID
        if changed, attemptStarted { applyPreferredTracks() }
    }

    // MARK: Ticking

    private func startTicking() {
        let interval = configuration.tickInterval
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                let current = clock.now
                guard let self else { return }
                self.tick(elapsed: (current - last).timeInterval)
                last = current
            }
        }
    }

    /// One tick of the model's clock: the scrub bar's time, the live offset
    /// and the checkpoint count. Internal so tests can drive it.
    func tick(elapsed: TimeInterval) {
        now = configuration.now()
        syncTime()
        liveOffset = computeLiveOffset()
        if state == .playing, attemptStarted, elapsed > 0 {
            attemptPlayedSeconds += min(elapsed, checkpoints.maximumStep)
            if attemptPlayedSeconds >= Self.retryRestoredAfter, !retryAvailable {
                retryAvailable = true
                firstFailureMessage = nil
            }
        }
        if startedEventSent, checkpoints.advance(by: elapsed, isPlaying: state == .playing) {
            emit(.checkpoint(itemID: item.id, position: currentTime, duration: duration))
        }
    }

    /// Writes progress now, outside the 5-minute rhythm: the app going to
    /// the background (technical spec, Sync and sharing rules).
    public func checkpointNow() {
        guard startedEventSent, state == .playing || state == .paused || state == .buffering else { return }
        checkpoints.reset()
        emit(.checkpoint(itemID: item.id, position: currentTime, duration: duration))
    }

    private func computeLiveOffset() -> TimeInterval {
        guard item.isLive else { return 0 }
        return liveClock.offset(currentTime: currentTime, duration: duration, now: configuration.now())
    }

    // MARK: Controls

    public func play() {
        if case .failed = state {
            Task { await retry() }
            return
        }
        engine?.play()
        showControls()
    }

    public func pause() {
        engine?.pause()
        showControls()
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Back or forward (PLY-2). Live goes through the live-seek plan, so ten
    /// seconds back on a channel with an archive works even with no window.
    public func skip(by seconds: TimeInterval) {
        guard engine != nil else { return }
        showControls()
        if item.isLive {
            Task { await seekBehindLive(max(0, liveOffset - seconds)) }
            return
        }
        seek(to: currentTime + seconds)
    }

    /// Seconds from the start of the stream (or of the live window).
    public func seek(to seconds: TimeInterval) {
        guard let engine else { return }
        let upper = duration ?? .greatestFiniteMagnitude
        let target = min(max(seconds, 0), upper)
        engine.seek(to: target)
        currentTime = target
        liveOffset = computeLiveOffset()
        showControls()
        updateNowPlaying()
    }

    /// A drag on the scrub bar, as a fraction of it.
    public func seek(toFraction fraction: Double) async {
        switch timeline.seekTarget(forFraction: fraction) {
        case .position(let seconds)?: seek(to: seconds)
        case .behindLive(let seconds)?: await seekBehindLive(seconds)
        case nil: break
        }
    }

    /// Plays from `seconds` behind live (PLY-5): a seek when the open link
    /// holds that moment, the archive from it otherwise.
    public func seekBehindLive(_ seconds: TimeInterval) async {
        guard item.isLive, engine != nil else { return }
        let plan = LiveSeekPlan.plan(
            behindLive: seconds,
            anchor: liveClock.anchor,
            currentTime: currentTime,
            duration: duration,
            edgeSlack: liveClock.edgeSlack,
            now: configuration.now(),
            hasArchive: item.hasArchive,
            programmeEnd: item.programmeEnd
        )
        switch plan {
        case .seek(let position):
            seek(to: position)
            if state == .paused { liveClock.resumed(at: configuration.now()) }
        case .live:
            await jumpToLive()
        case .archive(let start, let duration):
            let token = beginOpen(.fromStart(start, duration: duration), isRetry: false)
            await runOpen(token: token, engine: nil)
        case .unavailable:
            break
        }
    }

    /// Back to the live edge (PLY-2): a seek to the end of an HLS window, or
    /// a fresh live link when the stream has none or is the archive.
    public func jumpToLive() async {
        guard item.isLive, didStart, !isClosed else { return }
        showControls()
        if isAtLiveEdge {
            return
        }
        if state == .paused, !isPlayingArchive, liveOffset < LiveSeekPlan.liveTolerance {
            // Paused for a moment: carrying on is live enough.
            play()
            return
        }
        if !isPlayingArchive, let engine, let duration, duration > 0 {
            engine.seek(to: duration)
            liveClock.returnedToLive()
            if !isPlaying { engine.play() }
            liveOffset = 0
            updateNowPlaying()
            return
        }
        let token = beginOpen(.standard, isRetry: false)
        await runOpen(token: token, engine: nil)
    }

    /// Plays the current programme from its start (catch-up channels).
    public func playFromStart() async {
        guard didStart, !isClosed else { return }
        guard item.isLive else {
            seek(to: 0)
            return
        }
        guard item.hasArchive, let start = item.programmeStart else { return }
        let end = item.programmeEnd ?? configuration.now()
        let token = beginOpen(.fromStart(start, duration: max(60, end.timeIntervalSince(start))), isRetry: false)
        await runOpen(token: token, engine: nil)
    }

    // MARK: Moving between items

    public func goToNextItem() async {
        guard let next = nextNeighbour ?? navigator?(item, 1) else { return }
        await switchTo(next)
    }

    public func goToPreviousItem() async {
        guard let previous = previousNeighbour ?? navigator?(item, -1) else { return }
        await switchTo(previous)
    }

    /// The last channel watched before this one (LIV-5).
    public func goToLastItem() async {
        guard let lastItem else { return }
        await switchTo(lastItem)
    }

    private func switchTo(_ newItem: PlayerItem) async {
        guard didStart, !isClosed else { return }
        let old = item
        if startedEventSent {
            startedEventSent = false
            emit(.stopped(itemID: old.id, position: currentTime, duration: duration))
        }
        emit(.switched(fromItemID: old.id, toItemID: newItem.id))
        lastItem = old
        item = newItem
        refreshNeighbours()
        resetItemState()
        let token = beginOpen(.standard, isRetry: false)
        updateNowPlaying()
        await runOpen(token: token, engine: nil)
    }

    private func resetItemState() {
        currentTime = 0
        duration = nil
        liveOffset = 0
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil
        userPickedAudio = false
        userPickedSubtitle = false
        autoSelectedAudioID = nil
        autoSelectedSubtitleID = nil
        pendingResume = nil
        checkpoints.reset()
    }

    private func refreshNeighbours() {
        previousNeighbour = navigator?(item, -1)
        nextNeighbour = navigator?(item, 1)
    }

    // MARK: Tracks

    public func selectAudioTrack(id: String) {
        userPickedAudio = true
        engine?.selectAudioTrack(id: id)
        syncTracks()
        showControls()
    }

    public func selectSubtitleTrack(id: String?) {
        userPickedSubtitle = true
        engine?.selectSubtitleTrack(id: id)
        syncTracks()
        showControls()
    }

    /// Picks tracks matching the profile's languages when they load (PLY-6).
    public func setPreferredLanguages(audio: String?, subtitle: String?) {
        preferredAudioLanguage = audio
        preferredSubtitleLanguage = subtitle
        autoSelectedAudioID = nil
        autoSelectedSubtitleID = nil
        applyPreferredTracks()
    }

    /// Selects the profile's languages once per track, and never over the
    /// user's own pick. A subtitle preference of nil leaves the stream's
    /// default alone rather than forcing subtitles off.
    private func applyPreferredTracks() {
        guard let engine else { return }
        if !userPickedAudio,
           let wanted = LanguageMatch.bestTrack(in: engine.audioTracks, preferred: preferredAudioLanguage),
           wanted.id != engine.selectedAudioTrackID, wanted.id != autoSelectedAudioID {
            autoSelectedAudioID = wanted.id
            engine.selectAudioTrack(id: wanted.id)
        }
        if !userPickedSubtitle,
           let wanted = LanguageMatch.bestTrack(in: engine.subtitleTracks, preferred: preferredSubtitleLanguage),
           wanted.id != engine.selectedSubtitleTrackID, wanted.id != autoSelectedSubtitleID {
            autoSelectedSubtitleID = wanted.id
            engine.selectSubtitleTrack(id: wanted.id)
        }
        selectedAudioTrackID = engine.selectedAudioTrackID
        selectedSubtitleTrackID = engine.selectedSubtitleTrackID
    }

    public func startPictureInPicture() {
        guard supportsPictureInPicture else { return }
        engine?.startPictureInPicture()
    }

    // MARK: Controls overlay

    /// Shows the controls and restarts the fade timer.
    public func showControls() {
        controlsVisible = true
        lastActivity = configuration.now()
        scheduleControlsHide()
    }

    /// A tap on the picture.
    public func toggleControls() {
        if controlsVisible, autoHidesControls, isPlaying {
            hideControlsTask?.cancel()
            controlsVisible = false
        } else {
            showControls()
        }
    }

    /// Pointer movement on the Mac (and iPad): shows the controls, but
    /// restarts the timer at most twice a second rather than on every move.
    public func noteActivity() {
        if !controlsVisible || configuration.now().timeIntervalSince(lastActivity) > 0.5 {
            showControls()
        }
    }

    private func scheduleControlsHide() {
        hideControlsTask?.cancel()
        guard autoHidesControls, state == .playing else { return }
        let delay = configuration.controlsHideDelay
        hideControlsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.state == .playing, self.autoHidesControls else { return }
            self.controlsVisible = false
        }
    }

    // MARK: Closing

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        generation += 1
        tickTask?.cancel()
        startTimeoutTask?.cancel()
        hideControlsTask?.cancel()
        if startedEventSent {
            startedEventSent = false
            emit(.stopped(itemID: item.id, position: currentTime, duration: duration))
        }
        tearDownEngine()
        nowPlaying?.deactivate()
        nowPlaying = nil
        state = .idle
        onClose?()
    }

    /// The engine's video surface.
    public func videoView() -> AnyView {
        engine?.makeVideoView() ?? AnyView(Color.black)
    }

    /// AVPlayer's player, for the Mac's AirPlay picker (which routes one
    /// player); nil on VLCKit, which AirPlays only by mirroring.
    var airPlayPlayer: AVPlayer? {
        (engine as? AVPlayerEngine)?.player
    }

    // MARK: Now Playing (PLY-3)

    private func activateNowPlaying() {
        let center = NowPlayingCenter()
        center.activate(NowPlayingCenter.Handlers(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlayPause() },
            skip: { [weak self] seconds in self?.skip(by: seconds) },
            next: { [weak self] in
                guard let self else { return }
                Task { await self.goToNextItem() }
            },
            previous: { [weak self] in
                guard let self else { return }
                Task { await self.goToPreviousItem() }
            },
            seek: { [weak self] seconds in self?.seek(to: seconds) }
        ))
        nowPlaying = center
    }

    private func updateNowPlaying() {
        nowPlaying?.update(
            item: item,
            isPlaying: isPlaying,
            position: currentTime,
            duration: duration,
            canGoNext: canGoToNextItem,
            canGoPrevious: canGoToPreviousItem,
            canSeek: canSeek
        )
    }

    private func emit(_ event: PlayerEvent) {
        onEvent?(event)
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`.
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
