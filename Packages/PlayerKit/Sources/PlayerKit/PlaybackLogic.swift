import Core
import Foundation

// The player's arithmetic, kept in value types so it is tested without an
// engine, a clock or a screen: when progress is due, how far behind live the
// picture is, what the scrub bar shows, which engine a retry uses and which
// track matches a profile's language.

// MARK: - Checkpoints

/// Counts actual playback time and says when a progress checkpoint is due:
/// every 5 minutes of playing, never per second, never while paused or
/// buffering (technical spec, Sync and sharing rules: Progress).
public struct CheckpointClock: Sendable, Equatable {
    /// Seconds of playback between checkpoints.
    public var interval: TimeInterval
    /// The most one tick may add. A tick that arrives late (the process was
    /// suspended, the main thread was busy) counts as at most this much, so a
    /// sleep never fakes minutes of watching.
    public var maximumStep: TimeInterval
    /// Playback counted since the last checkpoint.
    public private(set) var accumulated: TimeInterval = 0

    public init(interval: TimeInterval = 300, maximumStep: TimeInterval = 2) {
        self.interval = interval
        self.maximumStep = maximumStep
    }

    /// Adds `elapsed` wall-clock seconds; returns true when a checkpoint is due
    /// (and starts counting towards the next one).
    public mutating func advance(by elapsed: TimeInterval, isPlaying: Bool) -> Bool {
        guard isPlaying, elapsed > 0 else { return false }
        accumulated += min(elapsed, maximumStep)
        guard accumulated >= interval else { return false }
        accumulated -= interval
        return true
    }

    /// Starts counting from zero (a new item, or a progress write that just
    /// happened for another reason such as a pause).
    public mutating func reset() {
        accumulated = 0
    }
}

// MARK: - Live offset

/// How far behind live the picture is (PLY-2, PLY-5).
///
/// Three kinds of stream need three answers:
/// - live with a seekable window (HLS): the gap between the window's end and
///   the playhead, less the gap AVPlayer keeps at the live edge on its own
///   (measured once when playback first starts), so "live" reads as 0:00;
/// - live with no window (raw MPEG-TS on VLC): only pausing puts it behind,
///   so the paused wall-clock time is the offset;
/// - an archive opened at a programme's start ("From the start", catch-up):
///   the programme's start plus the playhead, against now.
public struct LiveClock: Sendable, Equatable {
    public enum Anchor: Sendable, Equatable {
        /// The stream is the channel live now.
        case live
        /// The stream is the channel's archive, starting at this moment.
        case archive(start: Date)
    }

    public var anchor: Anchor
    /// The window gap at the live edge, captured when playback first starts.
    public private(set) var edgeSlack: TimeInterval?
    /// Pause time already behind us, for windowless live streams.
    public private(set) var accumulatedPause: TimeInterval = 0
    public private(set) var pausedAt: Date?

    public init(anchor: Anchor = .live) {
        self.anchor = anchor
    }

    /// Called when playback first reaches `.playing` on a new link.
    public mutating func captureEdge(currentTime: TimeInterval, duration: TimeInterval?) {
        guard anchor == .live, edgeSlack == nil, let duration else { return }
        edgeSlack = max(0, duration - currentTime)
    }

    public mutating func paused(at date: Date) {
        if pausedAt == nil { pausedAt = date }
    }

    public mutating func resumed(at date: Date) {
        if let pausedAt { accumulatedPause += max(0, date.timeIntervalSince(pausedAt)) }
        pausedAt = nil
    }

    /// Back at the live edge on the same link (a seek to the window's end).
    public mutating func returnedToLive() {
        accumulatedPause = 0
        pausedAt = nil
    }

    /// Seconds behind live, never negative.
    public func offset(currentTime: TimeInterval, duration: TimeInterval?, now: Date) -> TimeInterval {
        switch anchor {
        case .archive(let start):
            return max(0, now.timeIntervalSince(start) - currentTime)
        case .live:
            if let duration, duration > 0 {
                let gap = max(0, duration - currentTime)
                return max(0, gap - (edgeSlack ?? gap))
            }
            let pausedNow = pausedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
            return accumulatedPause + pausedNow
        }
    }
}

/// How far behind a live HLS stream's edge AVPlayer starts. Left alone it
/// sits where the stream recommends, three target durations back: 18–21 s with
/// the owner's provider's 6–7 s segments, about 10 s behind iSTB or a MAG box,
/// which play a segment or two from the end. Twelve seconds keeps about two
/// segments of buffer.
///
/// Given to the item before it loads, never by seeking once it's ready: that
/// seek threw away what AVPlayer had buffered and cost 0.7–1.8 s on every
/// channel start, measured on the owner's portal. Set up front, it starts as
/// fast as leaving it alone. The recommendation isn't known that early, so
/// this is one number rather than a share of it.
enum LiveEdgeOffset {
    static let seconds: TimeInterval = 12

    /// Nil when the stream isn't live, or starts somewhere of its own.
    static func initial(isLive: Bool, startPosition: TimeInterval?) -> TimeInterval? {
        guard isLive, (startPosition ?? 0) <= 0 else { return nil }
        return seconds
    }
}

// MARK: - Timeline

/// What the scrub bar draws and what a drag on it means (mockup 06).
///
/// Live with a guide: the bar spans the programme (19:30 – 22:30), a lighter
/// fill runs to now (the live edge) and the amber fill to the playhead
/// (now − offset). VOD: position over duration.
public struct PlaybackTimeline: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case live(start: Date, end: Date)
        /// Live with no guide bounds: nothing to scrub, the bar is hidden.
        case liveWithoutGuide
        case onDemand(duration: TimeInterval)
        /// VOD whose duration isn't known yet.
        case unknown
    }

    /// Where a drag on the bar sends the player.
    public enum SeekTarget: Sendable, Equatable {
        /// Seconds from the start of a movie or episode.
        case position(TimeInterval)
        /// Seconds behind live (0 is live).
        case behindLive(TimeInterval)
    }

    public var kind: Kind
    /// The amber fill, 0…1.
    public var position: Double
    /// The lighter fill up to the live edge, 0…1; nil for VOD.
    public var liveEdge: Double?
    /// "19:30" or "12:04".
    public var leadingLabel: String
    /// "22:30" or "1:45:00".
    public var trailingLabel: String
    /// The playhead's own time for VoiceOver ("19:45", "12:04").
    public var positionLabel: String
    public var now: Date

    public var showsBar: Bool {
        switch kind {
        case .live, .onDemand: true
        case .liveWithoutGuide, .unknown: false
        }
    }

    public static func make(
        isLive: Bool,
        programmeStart: Date?,
        programmeEnd: Date?,
        now: Date,
        liveOffset: TimeInterval,
        currentTime: TimeInterval,
        duration: TimeInterval?
    ) -> PlaybackTimeline {
        if isLive {
            guard let start = programmeStart, let end = programmeEnd, end > start else {
                return PlaybackTimeline(kind: .liveWithoutGuide, position: 1, liveEdge: 1, leadingLabel: "", trailingLabel: "", positionLabel: "", now: now)
            }
            let span = end.timeIntervalSince(start)
            let edge = clamp(now.timeIntervalSince(start) / span)
            let playhead = now.addingTimeInterval(-liveOffset)
            let position = min(clamp(playhead.timeIntervalSince(start) / span), edge)
            return PlaybackTimeline(
                kind: .live(start: start, end: end),
                position: position,
                liveEdge: edge,
                leadingLabel: HearthFormat.clock(start),
                trailingLabel: HearthFormat.clock(end),
                positionLabel: HearthFormat.clock(playhead),
                now: now
            )
        }
        guard let duration, duration > 0 else {
            return PlaybackTimeline(kind: .unknown, position: 0, liveEdge: nil, leadingLabel: HearthFormat.timecode(currentTime), trailingLabel: "", positionLabel: HearthFormat.timecode(currentTime), now: now)
        }
        return PlaybackTimeline(
            kind: .onDemand(duration: duration),
            position: clamp(currentTime / duration),
            liveEdge: nil,
            leadingLabel: HearthFormat.timecode(currentTime),
            trailingLabel: HearthFormat.timecode(duration),
            positionLabel: HearthFormat.timecode(currentTime),
            now: now
        )
    }

    /// Maps a fraction of the bar to a seek. Live positions past now clamp to
    /// live; nil when the bar can't be scrubbed.
    public func seekTarget(forFraction fraction: Double) -> SeekTarget? {
        let fraction = Self.clamp(fraction)
        switch kind {
        case .live(let start, let end):
            let target = start.addingTimeInterval(end.timeIntervalSince(start) * fraction)
            return .behindLive(max(0, now.timeIntervalSince(target)))
        case .onDemand(let duration):
            return .position(duration * fraction)
        case .liveWithoutGuide, .unknown:
            return nil
        }
    }

    /// What a point on the bar stands for, shown above the finger while it
    /// drags: "23:41" into a movie, "20:15" in a live programme (never past now).
    public func label(forFraction fraction: Double) -> String {
        let fraction = Self.clamp(fraction)
        switch kind {
        case .live(let start, let end):
            let target = start.addingTimeInterval(end.timeIntervalSince(start) * fraction)
            return HearthFormat.clock(min(target, now))
        case .onDemand(let duration):
            return HearthFormat.timecode(duration * fraction)
        case .liveWithoutGuide, .unknown:
            return positionLabel
        }
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

// MARK: - Seeking a movie or episode

/// Where a skip or a scrub sent a movie or episode, held until the engine's
/// own clock gets there. Without it the scrub bar's knob snapped back to the
/// old time for a moment after every seek (the engine still reported it), and
/// quick skips each started from that old time, so five presses of +10 came
/// to less than 50 seconds.
public struct PendingSeek: Sendable, Equatable {
    /// Seconds from the start, where the picture is headed.
    public var target: TimeInterval
    /// Where the picture was when the run of skips began, for "+1:30".
    public var origin: TimeInterval
    /// When the target last changed.
    public var since: Date

    /// The engine counts as there once its clock is this close.
    public static let arrivalTolerance: TimeInterval = 2
    /// Waits no longer than this for the engine (a seek it dropped, a stream
    /// that can't seek), then believes the engine again.
    public static let patience: TimeInterval = 10

    public init(target: TimeInterval, origin: TimeInterval, since: Date) {
        self.target = target
        self.origin = origin
        self.since = since
    }

    /// How far the run of skips has moved, "+1:30" or "−0:20".
    public var offset: TimeInterval { target - origin }

    /// True once the engine has got there, or waiting has gone on too long.
    /// `sent` is false while the seek is still being gathered (a run of
    /// presses not yet handed to the engine): the engine can't have arrived.
    public func isSettled(engineTime: TimeInterval, sent: Bool, now: Date) -> Bool {
        guard sent else { return false }
        if abs(engineTime - target) <= Self.arrivalTolerance { return true }
        return now.timeIntervalSince(since) >= Self.patience
    }
}

/// The remote's left and right on the TV's picture (and anything else that
/// presses repeatedly): presses in a row go further each time, so a 43-minute
/// episode or a two-hour film can be crossed with a run of presses rather
/// than one press per 10 seconds. The run starts over after a pause or a
/// change of direction.
public struct SkipRun: Sendable, Equatable {
    /// Presses closer together than this continue the run.
    public static let window: TimeInterval = 1.5

    public private(set) var forward = true
    public private(set) var presses = 0
    private var lastPress: Date?

    public init() {}

    /// Seconds to move for one more press, signed by direction.
    public mutating func step(forward: Bool, at now: Date) -> TimeInterval {
        if let lastPress, self.forward == forward, now.timeIntervalSince(lastPress) <= Self.window, now >= lastPress {
            presses += 1
        } else {
            presses = 1
            self.forward = forward
        }
        lastPress = now
        let seconds = Self.seconds(forPress: presses)
        return forward ? seconds : -seconds
    }

    /// 10 s for the first three presses, then 30 s, 1, 2 and 5 minutes,
    /// three presses each.
    public static func seconds(forPress press: Int) -> TimeInterval {
        switch press {
        case ...3: 10
        case 4...6: 30
        case 7...9: 60
        case 10...12: 120
        default: 300
        }
    }
}

/// A drag on the scrub bar. It starts where the finger lands (a tap jumps
/// there) and then follows the finger's movement rather than its position,
/// slower the further the finger moves up or down away from the bar, so a
/// minute can be found in a two-hour film on a phone's narrow bar: one point
/// of a 340-point bar is 21 seconds of it.
public struct ScrubDrag: Sendable, Equatable {
    public enum Speed: Sendable, Equatable {
        case full, half, quarter, fine

        public var factor: Double {
            switch self {
            case .full: 1
            case .half: 0.5
            case .quarter: 0.25
            case .fine: 0.1
            }
        }

        /// Said above the knob while slower than full.
        public var label: String? {
            switch self {
            case .full: nil
            case .half: String(localized: "Half-speed scrubbing")
            case .quarter: String(localized: "Quarter-speed scrubbing")
            case .fine: String(localized: "Fine scrubbing")
            }
        }

        /// Points away from the bar before each slower speed.
        public static func forDistance(_ distance: Double) -> Speed {
            switch abs(distance) {
            case ..<60: .full
            case ..<120: .half
            case ..<180: .quarter
            default: .fine
            }
        }
    }

    /// Where the knob is, 0…1.
    public private(set) var fraction: Double
    public private(set) var speed: Speed = .full
    private let width: Double
    private let startY: Double
    private let upperBound: Double
    private var lastX: Double

    /// `upperBound` is the live edge on a live bar: nothing lies past now.
    public init(startX: Double, startY: Double, width: Double, upperBound: Double = 1) {
        self.width = max(width, 1)
        self.startY = startY
        self.upperBound = PlaybackTimeline.clamp(upperBound)
        lastX = startX
        fraction = min(PlaybackTimeline.clamp(startX / max(width, 1)), PlaybackTimeline.clamp(upperBound))
    }

    public mutating func move(toX x: Double, y: Double) {
        speed = Speed.forDistance(y - startY)
        let moved = (x - lastX) / width * speed.factor
        fraction = min(max(fraction + moved, 0), upperBound)
        lastX = x
    }
}

// MARK: - Formatting

/// The player's own wording, beyond Core's `HearthFormat`.
public enum PlayerFormat {
    /// "−4:12": the offset badge, with a true minus sign as in the mockup.
    public static func behindLive(_ offset: TimeInterval) -> String {
        "\u{2212}" + HearthFormat.timecode(offset)
    }

    /// "Paused live · catch-up from 19:30" / "Behind live".
    public static func liveCaption(isPaused: Bool, catchUpFrom start: Date?) -> String {
        let lead = isPaused ? String(localized: "Paused live") : String(localized: "Behind live")
        guard let start else { return lead }
        return lead + " · " + String(localized: "catch-up from \(HearthFormat.clock(start))")
    }

    /// "101 Cityline News" for a channel, the title for anything else.
    public static func itemLabel(_ item: PlayerItem) -> String {
        let name = item.channelName ?? item.title
        guard let number = item.channelNumber else { return name }
        return "\(number) \(name)"
    }
}

// MARK: - Messages

/// Turns errors into the message the player shows (PLY-4) without leaking a
/// stream address: provider links carry tokens and, on Stalker, the MAC
/// (PRIV-2), and `PlayerEvent.failed` may be written somewhere.
public enum PlayerMessage {
    public static let genericFailure = String(localized: "This stream couldn't be played.")
    public static let vlcMissing = String(localized: "This stream needs the VLC engine, which isn't in this build.")
    /// AVPlayer (or VLCKit) sat loading past its start timeout.
    public static let didNotStart = String(localized: "The stream didn't start.")
    /// A live channel's stream ended, which live streams don't do on purpose.
    public static let liveStopped = String(localized: "The channel stopped sending.")
    /// VLCKit's own failure states, which carry no detail.
    public static let vlcCouldNotOpen = String(localized: "VLC couldn't open this stream.")
    public static let stoppedBeforeStart = String(localized: "The stream stopped before it started.")

    /// The engines' own wording, which says less than a provider's message.
    public static func isGeneric(_ message: String) -> Bool {
        [genericFailure, didNotStart, liveStopped, vlcCouldNotOpen, stoppedBeforeStart].contains(message)
    }

    /// What the player shows after its retry failed too (PLY-4): the
    /// provider's own words if either attempt got some ("HTTP 403: Forbidden"
    /// from AVPlayer beats VLC's wordless failure on the retry), and the
    /// missing-engine note when the stream needed VLCKit and this build has none.
    public static func final(first: String?, last: String, vlcMissing needsVLC: Bool) -> String {
        if needsVLC { return vlcMissing }
        if isGeneric(last), let first, !isGeneric(first) { return first }
        return last
    }

    public static func describe(_ error: any Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return scrub(text)
    }

    /// Replaces every URL in `text` with "the stream address" and trims it.
    public static func scrub(_ text: String) -> String {
        let pattern = #"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'<>]+"#
        let scrubbed = text.replacingOccurrences(of: pattern, with: String(localized: "the stream address"), options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return scrubbed.isEmpty ? genericFailure : scrubbed
    }
}

// MARK: - Seeking behind live

/// How to reach a point some seconds behind live (PLY-2, PLY-5): seek on the
/// link already open when it holds that moment, otherwise open the channel's
/// archive from it, otherwise it can't be done.
public enum LiveSeekPlan: Sendable, Equatable {
    /// Seek the open stream to this position (seconds from its start).
    case seek(TimeInterval)
    /// Back to live; the caller decides between a seek and a fresh link.
    case live
    /// Open the archive from `start`, `duration` seconds long.
    case archive(start: Date, duration: TimeInterval)
    case unavailable

    /// Closer to live than this counts as live: the edge itself wobbles by a
    /// segment or two.
    public static let liveTolerance: TimeInterval = 3

    public static func plan(
        behindLive target: TimeInterval,
        anchor: LiveClock.Anchor,
        currentTime: TimeInterval,
        duration: TimeInterval?,
        edgeSlack: TimeInterval?,
        now: Date,
        hasArchive: Bool,
        programmeEnd: Date?
    ) -> LiveSeekPlan {
        guard target > liveTolerance else { return .live }
        switch anchor {
        case .live:
            // An HLS window: the live edge sits `edgeSlack` before its end.
            if let duration, duration > 0 {
                let position = duration - (edgeSlack ?? 0) - target
                if position >= 0 { return .seek(position) }
            }
        case .archive(let start):
            let position = now.timeIntervalSince(start) - target
            if position >= 0, duration.map({ position <= $0 }) ?? true { return .seek(position) }
        }
        guard hasArchive else { return .unavailable }
        let start = now.addingTimeInterval(-target)
        // Through the programme's end; a catch-up link asked to run past now
        // plays on to the live point, so a minute's floor is plenty.
        let end = max(programmeEnd ?? now, now)
        return .archive(start: start, duration: max(60, end.timeIntervalSince(start)))
    }
}

// MARK: - The TV's Menu

/// What Menu does in the TV's player, so it always does something and never
/// more than one thing.
public enum TVPlayerBack: Hashable, Sendable {
    /// Back to the picture, the player still open.
    case leaveControls
    /// A multi-view tile shown full screen: back to the tiles, still playing.
    case returnToMultiView
    case close

    /// The controls come first, unless they are all there is: a failure's
    /// panel, or VoiceOver, where they never leave and Menu would do nothing.
    public static func onMenu(controlsActive: Bool, hasFailed: Bool, voiceOverEnabled: Bool, returnsToMultiView: Bool) -> TVPlayerBack {
        if controlsActive, !hasFailed, !voiceOverEnabled { return .leaveControls }
        return returnsToMultiView ? .returnToMultiView : .close
    }
}

// MARK: - Engine plan

/// Which engine each attempt uses (PLY-1, PLY-4): the chooser's pick when it
/// is in this build (AVPlayer otherwise), then one retry with a fresh link —
/// on VLCKit when AVPlayer failed or didn't start, on the same engine when
/// VLCKit failed or isn't available.
public enum EnginePlan {
    public static func first(preferred: EngineKind, available: Set<EngineKind>) -> EngineKind? {
        if available.contains(preferred) { return preferred }
        return available.contains(.avPlayer) ? .avPlayer : available.first
    }

    public static func retry(after failed: EngineKind?, preferred: EngineKind, available: Set<EngineKind>) -> EngineKind? {
        guard let failed else { return first(preferred: preferred, available: available) }
        switch failed {
        case .avPlayer: return available.contains(.vlc) ? .vlc : .avPlayer
        case .vlc: return available.contains(.vlc) ? .vlc : first(preferred: preferred, available: available)
        }
    }
}

// MARK: - Languages

/// Matches track languages to a profile's preferred ones (PLY-6). Streams
/// say "en", "eng", "en-GB" or nothing; profiles store a code or a name.
public enum LanguageMatch {
    /// The two-letter code for any of "en", "eng", "en-GB", "English".
    public static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        let lowered = value.lowercased()
        if let code = englishNames[lowered] { return code }
        let base = String(lowered.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(lowered))
        if let alpha2 = Locale.LanguageCode(base).identifier(.alpha2) { return alpha2 }
        return base
    }

    public static func matches(_ trackLanguage: String?, preferred: String?) -> Bool {
        guard let track = normalized(trackLanguage), let wanted = normalized(preferred) else { return false }
        return track == wanted
    }

    /// The first track in `preferred`'s language, matched on its language tag
    /// or, when the stream has none, its name ("English", "Deutsch (AC3)").
    public static func bestTrack(in tracks: [MediaTrack], preferred: String?) -> MediaTrack? {
        guard let wanted = normalized(preferred) else { return nil }
        if let tagged = tracks.first(where: { normalized($0.language) == wanted }) { return tagged }
        return tracks.first { track in
            track.language == nil && track.name
                .split(whereSeparator: { !$0.isLetter })
                .contains { normalized(String($0)) == wanted && $0.count > 2 }
        }
    }

    /// Track names that are language names rather than codes, as some
    /// providers label them.
    private static let englishNames: [String: String] = [
        "english": "en", "french": "fr", "francais": "fr", "français": "fr",
        "german": "de", "deutsch": "de", "spanish": "es", "español": "es",
        "italian": "it", "italiano": "it", "portuguese": "pt", "português": "pt",
        "dutch": "nl", "nederlands": "nl", "arabic": "ar", "hindi": "hi",
        "urdu": "ur", "turkish": "tr", "türkçe": "tr", "polish": "pl", "polski": "pl",
        "russian": "ru", "greek": "el", "swedish": "sv", "norwegian": "no",
        "danish": "da", "finnish": "fi", "japanese": "ja", "chinese": "zh",
        "korean": "ko", "punjabi": "pa", "gujarati": "gu", "tamil": "ta", "bengali": "bn",
    ]
}
