import CatalogKit
import Core
import Foundation

// What a programme offers and how it is described (LIV-3, LIV-4), and the
// play requests Live TV sends (LIV-5). Values only; the card and rows draw
// them.

/// Catch-up rules as the guide applies them between catalog reads.
enum CatchupRules {
    /// Whether an aired or on-air programme can be played from its start.
    /// The catalog marks `hasArchive` when it reads a programme, but a
    /// cached programme that started since then hasn't been re-read, so the
    /// channel's archive window is checked here too.
    static func isPlayable(_ programme: CatalogProgramme, on channel: CatalogChannel, now: Date) -> Bool {
        guard channel.hasArchive, programme.start <= now else { return false }
        if programme.hasArchive { return true }
        let days = max(channel.archiveDays, 1)
        return programme.start >= now.addingTimeInterval(-TimeInterval(days) * 86_400)
    }
}

/// A button the programme card can show.
enum ProgrammeAction: Hashable, Sendable {
    /// The channel, live now.
    case watchLive
    /// The programme on now, from its start (an archive channel).
    case fromTheStart
    /// An aired programme from the archive.
    case playFromStart

    var title: String {
        switch self {
        case .watchLive: String(localized: "Watch live")
        case .fromTheStart: String(localized: "From the start")
        case .playFromStart: String(localized: "Play from the start")
        }
    }

    var systemImage: String {
        switch self {
        case .watchLive: "play.fill"
        case .fromTheStart, .playFromStart: "arrow.counterclockwise"
        }
    }

    /// Plays the programme from its start, through the archive.
    var isCatchup: Bool { self != .watchLive }
}

/// The card's two buttons for a programme: an amber primary and a dark
/// secondary, either of which may be absent.
struct ProgrammeActions: Hashable, Sendable {
    var primary: ProgrammeAction?
    var secondary: ProgrammeAction?

    /// - On now: Watch live, and From the start when the channel keeps an
    ///   archive (the mockup's card, LIV-3, LIV-4).
    /// - Aired and in the archive: Play from the start (LIV-4).
    /// - Aired and gone, or upcoming: details only — the card says why
    ///   there's nothing to play.
    /// - No guide: Watch live.
    static func make(phase: ProgrammePhase?, channelHasArchive: Bool, isPlayable: Bool) -> ProgrammeActions {
        switch phase {
        case .onAir:
            ProgrammeActions(primary: .watchLive, secondary: channelHasArchive && isPlayable ? .fromTheStart : nil)
        case .aired:
            ProgrammeActions(primary: isPlayable ? .playFromStart : nil, secondary: nil)
        case .upcoming:
            ProgrammeActions(primary: nil, secondary: nil)
        case nil:
            ProgrammeActions(primary: .watchLive, secondary: nil)
        }
    }

    var isEmpty: Bool { primary == nil && secondary == nil }
}

/// The lines under a programme's title.
enum ProgrammeText {
    /// "20:00–21:00", with the day in front when it isn't today: "Tue
    /// 20:00–21:00", "Yesterday 20:00–21:00".
    static func timeRange(start: Date, end: Date, now: Date, calendar: Calendar = .current) -> String {
        let range = HearthFormat.compactTimeRange(start, end)
        let day = GuideDay.containing(start, now: now, calendar: calendar)
        return day.isToday ? range : "\(day.title) \(range)"
    }

    /// The card's second line: "101 Cityline News · 20:00–21:00 · 18 min
    /// left"; "· Starts in 49 min" for one coming up within a few hours;
    /// "· Aired" for one that has ended.
    static func cardSubtitle(channelNumber: Int?, channelName: String, start: Date?, end: Date?, now: Date, calendar: Calendar = .current) -> String {
        var parts = [ChannelText.numberedName(number: channelNumber, name: channelName)]
        guard let start, let end else { return parts.joined(separator: " · ") }
        parts.append(timeRange(start: start, end: end, now: now, calendar: calendar))
        switch ProgrammePhase.of(start: start, end: end, now: now) {
        case .onAir:
            parts.append(HearthFormat.remaining(end.timeIntervalSince(now)))
        case .upcoming where start.timeIntervalSince(now) < 6 * 3600:
            parts.append(String(localized: "Starts in \(HearthFormat.duration(start.timeIntervalSince(now)))"))
        case .upcoming, .aired:
            break
        }
        return parts.joined(separator: " · ")
    }

    /// What VoiceOver says for a guide cell: "Evening Bulletin, 20:00 to
    /// 21:00, on now, 18 min left, can be played from the start".
    static func spokenCell(title: String, start: Date, end: Date, now: Date, isPlayable: Bool) -> String {
        var parts = [title, timeRange(start: start, end: end, now: now)]
        switch ProgrammePhase.of(start: start, end: end, now: now) {
        case .onAir:
            parts.append(String(localized: "On now"))
            parts.append(HearthFormat.remaining(end.timeIntervalSince(now)))
        case .aired:
            parts.append(String(localized: "Aired"))
        case .upcoming:
            break
        }
        if isPlayable { parts.append(String(localized: "Can be played from the start")) }
        return parts.joined(separator: ", ")
    }
}

/// The play requests Live TV makes; the app's playback coordinator carries
/// them out.
enum LiveIntents {
    /// A channel live, with the chip's channels as the up/down queue
    /// (LIV-5).
    static func live(_ channel: CatalogChannel, programme: CatalogProgramme?, queue: [String]) -> PlayIntent {
        PlayIntent(
            itemKey: channel.key.rawValue,
            kind: .live,
            title: programme?.title ?? channel.name,
            subtitle: ChannelText.numberedName(number: channel.number, name: channel.name),
            artworkURL: channel.logoURL,
            queue: queue
        )
    }

    /// A programme from its start through the archive (LIV-4): the one on
    /// now ("From the start") or an aired one.
    static func catchup(_ channel: CatalogChannel, programme: CatalogProgramme, now: Date, queue: [String]) -> PlayIntent {
        PlayIntent(
            itemKey: channel.key.rawValue,
            kind: .catchup,
            title: programme.title,
            subtitle: ChannelText.numberedName(number: channel.number, name: channel.name) + " · "
                + ProgrammeText.timeRange(start: programme.start, end: programme.end, now: now),
            artworkURL: channel.logoURL,
            catchupStart: programme.start,
            catchupEnd: programme.end,
            queue: queue
        )
    }

    static func intent(for action: ProgrammeAction, channel: CatalogChannel, programme: CatalogProgramme?, now: Date, queue: [String]) -> PlayIntent {
        if action.isCatchup, let programme {
            return catchup(channel, programme: programme, now: now, queue: queue)
        }
        return live(channel, programme: programme.flatMap { $0.isOn(at: now) ? $0 : nil }, queue: queue)
    }
}
