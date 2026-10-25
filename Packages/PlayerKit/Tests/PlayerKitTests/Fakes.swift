import Foundation
import SwiftUI
import Synchronization
@testable import PlayerKit

/// An engine with no player behind it: the test moves its state by hand and
/// reads back what the model asked of it.
@MainActor
final class FakeEngine: PlaybackEngine {
    let kind: EngineKind
    private(set) var state: PlaybackState = .idle
    var currentTime: TimeInterval = 0
    var duration: TimeInterval?
    var isMuted = false
    var volume: Float = 1
    var gravity: VideoGravity = .fit
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var selectedAudioTrackID: String?
    private(set) var selectedSubtitleTrackID: String?
    var supportsPictureInPicture = false
    var onChange: (() -> Void)?

    private(set) var loaded: [StreamDescriptor] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var stopCount = 0
    private(set) var seeks: [TimeInterval] = []

    init(kind: EngineKind) {
        self.kind = kind
    }

    func load(_ stream: StreamDescriptor) {
        loaded.append(stream)
        state = .loading
        onChange?()
    }

    func play() {
        playCount += 1
        if state == .paused || state == .ended {
            state = .playing
            onChange?()
        }
    }

    func pause() {
        pauseCount += 1
        if state == .playing || state == .buffering {
            state = .paused
            onChange?()
        }
    }

    func seek(to seconds: TimeInterval) {
        seeks.append(seconds)
        currentTime = seconds
    }

    func stop() {
        stopCount += 1
        state = .idle
    }

    func selectAudioTrack(id: String) {
        selectedAudioTrackID = id
        onChange?()
    }

    func selectSubtitleTrack(id: String?) {
        selectedSubtitleTrackID = id
        onChange?()
    }

    func startPictureInPicture() {}

    func makeVideoView() -> AnyView {
        AnyView(EmptyView())
    }

    // MARK: Driving it

    func simulate(_ newState: PlaybackState) {
        state = newState
        onChange?()
    }

    func simulateTracks(audio: [MediaTrack], subtitles: [MediaTrack], selectedAudio: String? = nil) {
        audioTracks = audio
        subtitleTracks = subtitles
        selectedAudioTrackID = selectedAudio ?? audio.first?.id
        onChange?()
    }
}

/// Makes fakes and keeps them, newest last.
@MainActor
final class FakeEngines {
    private(set) var made: [FakeEngine] = []

    var last: FakeEngine? { made.last }

    func factory(_ kinds: Set<EngineKind> = [.avPlayer, .vlc]) -> PlaybackEngineFactory {
        PlaybackEngineFactory(availableKinds: kinds) { [self] kind in
            let engine = FakeEngine(kind: kind)
            made.append(engine)
            return engine
        }
    }
}

/// A provider error with its own words, as SourceKit's errors carry.
struct ProviderError: LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}

/// The item's resolver: answers each call with the next scripted step (the
/// last one repeats) and records what it was asked for.
final class ScriptedResolver: Sendable {
    enum Step: Sendable {
        case stream(StreamDescriptor)
        case failure(String)
    }

    private struct State {
        var steps: [Step]
        var requests: [PlayerResolveRequest] = []
    }

    private let state: Mutex<State>

    init(_ steps: [Step]) {
        precondition(!steps.isEmpty)
        state = Mutex(State(steps: steps))
    }

    convenience init(_ stream: StreamDescriptor) {
        self.init([.stream(stream)])
    }

    var requests: [PlayerResolveRequest] {
        state.withLock { $0.requests }
    }

    func resolve(_ request: PlayerResolveRequest) throws -> StreamDescriptor {
        let step = state.withLock { state -> Step in
            state.requests.append(request)
            return state.steps.count > 1 ? state.steps.removeFirst() : state.steps[0]
        }
        switch step {
        case .stream(let stream): return stream
        case .failure(let message): throw ProviderError(message: message)
        }
    }
}

/// Wall-clock time the test moves by hand.
final class TestClock: Sendable {
    private let date: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        date = Mutex(start)
    }

    var now: Date { date.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

@MainActor
final class EventLog {
    private(set) var events: [PlayerEvent] = []

    func record(_ event: PlayerEvent) {
        events.append(event)
    }
}

enum Streams {
    static let hls = StreamDescriptor(url: URL(string: "http://provider.test/live/102.m3u8")!, format: .hls, isLive: true)
    static let liveTS = StreamDescriptor(url: URL(string: "http://provider.test/play/live.php?stream=102&extension=ts")!, format: .mpegts, isLive: true)
    static let movie = StreamDescriptor(url: URL(string: "http://provider.test/movie/7.mp4")!, format: .mp4)
}

extension PlayerConfiguration {
    /// No Now Playing, no ticking of its own (tests call `tick`), and
    /// timeouts long enough not to fire unless a test shortens them.
    static func test(clock: TestClock = TestClock(), startTimeout: TimeInterval = 30, slowStartTimeout: TimeInterval = 30) -> PlayerConfiguration {
        PlayerConfiguration(
            publishesNowPlaying: false,
            startTimeout: startTimeout,
            slowStartTimeout: slowStartTimeout,
            controlsHideDelay: 3600,
            checkpointInterval: 300,
            tickInterval: 3600,
            now: { clock.now }
        )
    }
}

func channel(
    _ number: Int,
    _ name: String,
    resolver: ScriptedResolver,
    hasArchive: Bool = false,
    programmeStart: Date? = nil,
    programmeEnd: Date? = nil
) -> PlayerItem {
    PlayerItem(
        id: "ch-\(number)",
        title: "Programme on \(name)",
        channelNumber: number,
        channelName: name,
        isLive: true,
        programmeStart: programmeStart,
        programmeEnd: programmeEnd,
        hasArchive: hasArchive,
        resolve: { try resolver.resolve($0) }
    )
}

func movie(resolver: ScriptedResolver, startPosition: TimeInterval? = nil) -> PlayerItem {
    PlayerItem(
        id: "movie-7",
        title: "The Lighthouse",
        isLive: false,
        startPosition: startPosition,
        resolve: { try resolver.resolve($0) }
    )
}

/// Polls until `condition` holds (async steps in the model run on later
/// main-actor turns), up to two seconds.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while !condition() {
        if clock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
