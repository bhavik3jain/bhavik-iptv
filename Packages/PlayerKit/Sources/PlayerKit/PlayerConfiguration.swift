import Foundation

/// The player's timings and duties, separate from what it plays.
///
/// The full-screen player owns Now Playing and the remote commands; a
/// multi-view tile doesn't, and starts muted (PLY-9). Tests shorten the
/// timeouts and stop the clock so the retry and checkpoint logic runs in
/// milliseconds.
public struct PlayerConfiguration: Sendable {
    /// Sets the lock screen / Control Center / Mac Now Playing info and
    /// answers the remote commands (PLY-3). One player at a time should.
    public var publishesNowPlaying: Bool
    /// Multi-view tiles start silent; tapping one gives it the sound.
    public var startsMuted: Bool
    /// How long an AVPlayer stream may sit loading before it is retried on
    /// VLCKit (technical spec, Player engine: "a few seconds").
    public var startTimeout: TimeInterval
    /// The same for VLCKit, which opens raw MPEG-TS more slowly and has no
    /// engine to fall back to, so it gets longer before the retry.
    public var slowStartTimeout: TimeInterval
    /// Controls fade after this long of uninterrupted playing.
    public var controlsHideDelay: TimeInterval
    /// Seconds of actual playback between progress checkpoints (5 minutes:
    /// technical spec, Sync and sharing rules).
    public var checkpointInterval: TimeInterval
    /// How often the model reads the engine's clock for the scrub bar, the
    /// live offset and the checkpoint count. UI only; events are never per tick.
    public var tickInterval: TimeInterval
    /// Wall-clock time, for the live offset and the guide timeline.
    public var now: @Sendable () -> Date

    public init(
        publishesNowPlaying: Bool = true,
        startsMuted: Bool = false,
        startTimeout: TimeInterval = 6,
        slowStartTimeout: TimeInterval = 20,
        controlsHideDelay: TimeInterval = 4,
        checkpointInterval: TimeInterval = 300,
        tickInterval: TimeInterval = 1,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.publishesNowPlaying = publishesNowPlaying
        self.startsMuted = startsMuted
        self.startTimeout = startTimeout
        self.slowStartTimeout = slowStartTimeout
        self.controlsHideDelay = controlsHideDelay
        self.checkpointInterval = checkpointInterval
        self.tickInterval = tickInterval
        self.now = now
    }

    /// The full-screen player.
    public static let standard = PlayerConfiguration()

    /// A multi-view tile: muted, and leaves Now Playing to the full-screen player.
    public static let multiViewTile = PlayerConfiguration(publishesNowPlaying: false, startsMuted: true)
}
