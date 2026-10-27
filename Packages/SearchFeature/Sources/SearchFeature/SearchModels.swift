import CatalogKit
import Core
import Foundation

// The logic behind Search, in value types so it can be tested without a view
// (views are untested by policy): the recent-search list, how results are
// grouped and ordered, what tapping a guide hit does, and the time text.

// MARK: - Recent searches

/// The searches a profile ran on this device, newest first.
///
/// Kept in this device's UserDefaults (through `@AppStorage`), never in iCloud
/// and never sent anywhere (SRCH-2). One list per profile, so a Kids profile
/// on the family iPad doesn't see what a parent searched for; a Guest's
/// searches aren't kept at all (PRF-5).
struct RecentSearches: Hashable, Sendable {
    /// How many are kept; the oldest fall off.
    static let limit = 10

    private(set) var items: [String]

    init(_ items: [String] = []) {
        var list = RecentSearches(unchecked: [])
        // Oldest first, so the newest end up on top with duplicates folded.
        for item in items.reversed() { list = list.adding(item) }
        self = list
    }

    private init(unchecked items: [String]) {
        self.items = items
    }

    /// Reads the list back from its `@AppStorage` string. Anything that
    /// doesn't decode (an older format, a hand-edited default) is an empty
    /// list rather than an error.
    init(storage: String) {
        guard let data = storage.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            self.init()
            return
        }
        self.init(decoded)
    }

    /// The list as one JSON array string, for `@AppStorage`.
    var storage: String {
        guard let data = try? JSONEncoder().encode(items) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    var isEmpty: Bool { items.isEmpty }

    /// The query on top. Blank queries are ignored; one that reads the same
    /// once normalised ("Café " and "cafe") replaces the older entry instead
    /// of appearing twice, keeping the newest spelling.
    func adding(_ query: String) -> RecentSearches {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = SearchKey.normalize(trimmed)
        guard !key.isEmpty else { return self }
        let rest = items.filter { SearchKey.normalize($0) != key }
        return RecentSearches(unchecked: Array(([trimmed] + rest).prefix(Self.limit)))
    }

    /// The list without `query` (matched normalised, as `adding` does).
    func removing(_ query: String) -> RecentSearches {
        let key = SearchKey.normalize(query)
        return RecentSearches(unchecked: items.filter { SearchKey.normalize($0) != key })
    }

    /// The UserDefaults key for a profile's list. A profile id only — never a
    /// name — as `ProfileSession` keeps its own keys.
    static func storageKey(profileID: UUID?) -> String {
        "Hearth.Search.recent.\(profileID?.uuidString ?? "none")"
    }
}

// MARK: - Grouping and ordering

/// A group of results, in the order the screen shows them (SRCH-2: grouped by
/// type). Channels first: a channel name or number is the commonest search in
/// a TV app, and tapping one plays at once.
enum SearchSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case channels
    case onTV
    case movies
    case shows

    var id: String { rawValue }
}

/// One search's results, grouped and ordered for the screen.
///
/// The catalog has already matched, filtered for the profile (SRCH-3) and
/// ranked prefix matches first; this decides the order of the guide hits and
/// which sections show.
struct SearchResultGroups: Hashable, Sendable {
    var channels: [CatalogChannel]
    /// On air now first (by channel number), then by start time.
    var programmes: [SearchResults.ProgrammeHit]
    var movies: [CatalogMovie]
    var series: [CatalogSeries]

    init(_ results: SearchResults, now: Date) {
        channels = results.channels
        programmes = Self.ordered(results.programmes, now: now)
        movies = results.movies
        series = results.series
    }

    /// The sections that have something, in display order.
    var sections: [SearchSection] {
        SearchSection.allCases.filter { count(of: $0) > 0 }
    }

    var isEmpty: Bool { sections.isEmpty }

    func count(of section: SearchSection) -> Int {
        switch section {
        case .channels: channels.count
        case .onTV: programmes.count
        case .movies: movies.count
        case .shows: series.count
        }
    }

    /// True when the catalog stopped at its per-group limit, so there may be
    /// more matches than the group lists. The screen then says to keep
    /// typing rather than implying "Show all" really is all.
    func isCapped(_ section: SearchSection) -> Bool {
        count(of: section) >= SearchResultLimits.perGroup
    }

    /// Guide hits as the On TV section lists them: what's on now (a tap
    /// plays it) above what's coming, each part in a predictable order.
    /// Programmes that ended while the screen sat open drop out unless the
    /// archive still has them.
    static func ordered(_ hits: [SearchResults.ProgrammeHit], now: Date) -> [SearchResults.ProgrammeHit] {
        let kept = hits.filter { $0.programme.end > now || $0.programme.hasArchive }
        let onNow = kept.filter { $0.programme.isOn(at: now) }
        let other = kept.filter { !$0.programme.isOn(at: now) }
        let byChannel: (SearchResults.ProgrammeHit, SearchResults.ProgrammeHit) -> Bool = { a, b in
            let an = a.channel.number ?? .max, bn = b.channel.number ?? .max
            if an != bn { return an < bn }
            return a.channel.name.localizedStandardCompare(b.channel.name) == .orderedAscending
        }
        let byStart: (SearchResults.ProgrammeHit, SearchResults.ProgrammeHit) -> Bool = { a, b in
            if a.programme.start != b.programme.start { return a.programme.start < b.programme.start }
            return byChannel(a, b)
        }
        return onNow.sorted(by: byChannel) + other.sorted(by: byStart)
    }
}

/// How many rows a section shows before "Show all". The phone keeps each
/// group short so all four fit in a scroll or two; the sidebar layout has the
/// room for more.
enum SearchResultLimits {
    /// How many hits per group the catalog is asked for. A big portal has
    /// thousands of channels with "HD" or "News" in the name; past fifty the
    /// person is better served by a longer query than by a longer list.
    static let perGroup = 50

    static func collapsedCount(for section: SearchSection, layout: HearthLayout) -> Int {
        switch (section, layout) {
        case (.channels, .compact), (.onTV, .compact): 5
        case (.channels, .sidebar), (.onTV, .sidebar), (.channels, .tv), (.onTV, .tv): 8
        // The phone scrolls posters sideways, so it shows them all.
        case (.movies, .compact), (.shows, .compact): .max
        case (.movies, .sidebar), (.shows, .sidebar), (.movies, .tv), (.shows, .tv): 12
        }
    }

    /// The rows to draw: all when expanded, otherwise up to the collapsed
    /// count. Never hides a single straggler behind "Show all 1 more".
    static func visibleCount(total: Int, section: SearchSection, layout: HearthLayout, expanded: Bool) -> Int {
        let limit = collapsedCount(for: section, layout: layout)
        guard !expanded, total > limit else { return total }
        return total == limit + 1 ? total : limit
    }
}

// MARK: - What a guide hit does

/// What tapping an On TV result does.
enum ProgrammeHitAction: Hashable, Sendable {
    /// On air now: play the channel live.
    case watchLive
    /// Already aired and still in the channel's archive: play it from the
    /// archive (LIV-4).
    case watchCatchUp
    /// Later today or tomorrow (or aired with no archive): open the
    /// channel's page, where its guide is.
    case openChannel

    static func resolve(_ programme: CatalogProgramme, now: Date) -> ProgrammeHitAction {
        if programme.isOn(at: now) { return .watchLive }
        if programme.end <= now, programme.hasArchive { return .watchCatchUp }
        return .openChannel
    }
}

// MARK: - Time text

/// When a guide hit airs, as its row writes it: "Now · until 21:00",
/// "Today 22:30", "Tomorrow 06:00". The search covers the next 24 hours, so
/// a weekday name only appears around midnight edge cases.
enum SearchTimeText {
    static func when(_ programme: CatalogProgramme, now: Date, calendar: Calendar = .current) -> String {
        if programme.isOn(at: now) {
            return String(localized: "Now · until \(HearthFormat.clock(programme.end))", bundle: .module, comment: "A programme on air now, and when it ends")
        }
        if programme.end <= now {
            return String(localized: "Aired \(day(programme.start, now: now, calendar: calendar)) \(HearthFormat.clock(programme.start))", bundle: .module, comment: "A programme that has aired: Aired Today 18:00")
        }
        return String(localized: "\(day(programme.start, now: now, calendar: calendar)) \(HearthFormat.clock(programme.start))", bundle: .module, comment: "When a programme starts: Today 22:30")
    }

    /// "Today", "Tomorrow", "Yesterday", or the short weekday ("Sat").
    static func day(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return String(localized: "Today", bundle: .module)
        case 1: return String(localized: "Tomorrow", bundle: .module)
        case -1: return String(localized: "Yesterday", bundle: .module)
        default: return date.formatted(.dateTime.weekday(.abbreviated))
        }
    }

    /// The whole row as one VoiceOver sentence: "Evening Bulletin, on 101
    /// Cityline News, now, until 21:00. Plays live."
    static func spoken(_ hit: SearchResults.ProgrammeHit, now: Date, calendar: Calendar = .current) -> String {
        let channel = ChannelText.numberedName(number: hit.channel.number, name: hit.channel.name)
        let when = when(hit.programme, now: now, calendar: calendar)
        return String(localized: "\(hit.programme.title), on \(channel), \(when)", bundle: .module, comment: "VoiceOver: programme, channel, when")
    }
}

// MARK: - Debounce

/// What the search task is keyed on: the text as typed and the catalog's
/// revision, so an import that lands (or a profile switch, which changes the
/// catalog's filter) re-runs the search without waiting for a keystroke.
struct SearchRequest: Hashable, Sendable {
    var query: String
    var revision: Int

    /// Long enough that typing "cityline" runs one search, not eight; short
    /// enough that results feel live (~250 ms).
    static let debounce: Duration = .milliseconds(250)

    var normalizedQuery: String { SearchKey.normalize(query) }
}
