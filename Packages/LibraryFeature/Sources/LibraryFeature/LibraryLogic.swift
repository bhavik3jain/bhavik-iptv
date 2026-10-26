import CatalogKit
import Foundation
import HouseholdKit

// The decisions behind the library screens, kept in plain value types so they
// can be tested without a view (views are untested by policy): what a poster's
// badge says, which episode "Resume" plays, how seasons are ordered, where
// someone else is in a show relative to you, and how a meta line reads.

// MARK: - Episode codes

/// "S2 E5" as the show screen writes it (mockup 04), and "Season 2, episode 5"
/// for VoiceOver, which would otherwise spell "S2" letter by letter.
enum EpisodeCode {
    static func short(season: Int, episode: Int) -> String {
        String(localized: "S\(season) E\(episode)", comment: "Season and episode, e.g. S2 E5")
    }

    static func spoken(season: Int, episode: Int) -> String {
        String(localized: "Season \(season), episode \(episode)", comment: "VoiceOver for S2 E5")
    }
}

// MARK: - Seasons

/// The seasons of a show in the order the picker shows them, and each one's
/// episodes in order (SER-1).
///
/// Season 0 is where providers put specials; it goes last, after the real
/// seasons, so the picker opens on "Season 1" and the next-episode walk never
/// lands on a special between two seasons.
struct SeasonGrouping: Equatable {
    struct Season: Equatable, Identifiable {
        var number: Int
        var episodes: [CatalogEpisode]
        var id: Int { number }

        var title: String {
            number == 0
                ? String(localized: "Specials", comment: "The season providers number 0")
                : String(localized: "Season \(number)", comment: "Season picker segment")
        }
    }

    var seasons: [Season]

    init(_ episodes: [CatalogEpisode]) {
        let bySeason = Dictionary(grouping: episodes, by: \.season)
        seasons = bySeason.keys
            .sorted(by: Self.seasonOrder)
            .map { number in
                Season(number: number, episodes: bySeason[number, default: []].sorted { ($0.number, $0.title) < ($1.number, $1.title) })
            }
    }

    /// Specials (0) after every numbered season.
    static func seasonOrder(_ a: Int, _ b: Int) -> Bool {
        switch (a == 0, b == 0) {
        case (true, false): false
        case (false, true): true
        default: a < b
        }
    }

    /// Every episode in watching order: season by season, specials last.
    var orderedEpisodes: [CatalogEpisode] { seasons.flatMap(\.episodes) }

    var seasonNumbers: [Int] { seasons.map(\.number) }

    /// The count the meta line writes ("3 seasons"): specials are not a season.
    var numberedSeasonCount: Int { seasons.filter { $0.number != 0 }.count }

    func season(_ number: Int) -> Season? { seasons.first { $0.number == number } }

    /// The episodes after this one, for the player's up next (PlayIntent's
    /// queue). Capped so a 900-episode soap doesn't ride along in every play.
    func keys(following episode: ItemKey, limit: Int = 50) -> [ItemKey] {
        let ordered = orderedEpisodes
        guard let index = ordered.firstIndex(where: { $0.key == episode }) else { return [] }
        return ordered[(index + 1)...].prefix(limit).map(\.key)
    }
}

// MARK: - What "Play" does on a show (SER-2)

/// Which episode a show's main button plays, and how it is labelled:
/// "Resume S2 E5", "Play S2 E6", "Play S1 E1" or "Play again" (SER-2).
///
/// The profile's most recently touched episode decides, as Continue watching
/// does: unfinished, it is where the person is (resumed when there is a
/// resume point, from the top when it was barely started or just marked
/// unwatched); finished, the next unwatched episode after it plays; with
/// nothing after it, the first unwatched one anywhere; with every episode
/// watched, the show starts again.
struct ShowPlayTarget: Equatable {
    enum Action: Equatable {
        /// Resume at a position, in seconds.
        case resume(TimeInterval)
        /// Start an episode the profile hasn't watched (from the top).
        case play
        /// Every episode is watched: start the first again.
        case playAgain
    }

    var episode: CatalogEpisode
    var action: Action

    var startPosition: TimeInterval? {
        switch action {
        case .resume(let position): position
        case .play, .playAgain: 0
        }
    }

    var title: String {
        let code = EpisodeCode.short(season: episode.season, episode: episode.number)
        switch action {
        case .resume: return String(localized: "Resume \(code)", comment: "Show's main button, e.g. Resume S2 E5")
        case .play: return String(localized: "Play \(code)", comment: "Show's main button, e.g. Play S1 E1")
        case .playAgain: return String(localized: "Play again", comment: "Show's main button once every episode is watched")
        }
    }

    var spokenTitle: String {
        let code = EpisodeCode.spoken(season: episode.season, episode: episode.number)
        switch action {
        case .resume: return String(localized: "Resume \(code)")
        case .play: return String(localized: "Play \(code)")
        case .playAgain: return String(localized: "Play again from \(code)")
        }
    }

    /// - Parameters:
    ///   - episodes: The show's episodes in watching order
    ///     (`SeasonGrouping.orderedEpisodes`).
    ///   - progress: The profile's rows for this show, keyed by item key.
    static func choose(episodes: [CatalogEpisode], progress: [String: ProgressRecord]) -> ShowPlayTarget? {
        guard let first = episodes.first else { return nil }
        let isWatched = { (episode: CatalogEpisode) in progress[episode.key.rawValue]?.watched ?? false }

        let latest = episodes.enumerated()
            .compactMap { index, episode in progress[episode.key.rawValue].map { (index, episode, $0) } }
            .max { $0.2.updatedAt < $1.2.updatedAt }

        guard let (index, episode, row) = latest else {
            return ShowPlayTarget(episode: first, action: .play)
        }
        if !row.watched {
            return target(for: episode, progress: progress)
        }
        if let next = episodes[(index + 1)...].first(where: { !isWatched($0) })
            ?? episodes.first(where: { !isWatched($0) }) {
            return target(for: next, progress: progress)
        }
        return ShowPlayTarget(episode: first, action: .playAgain)
    }

    /// An unwatched episode: resumed if it was properly started, else from
    /// the top (a few seconds in is a false start, as for movies).
    private static func target(for episode: CatalogEpisode, progress: [String: ProgressRecord]) -> ShowPlayTarget {
        if let row = progress[episode.key.rawValue], !row.watched, row.position >= MoviePlayState.minimumResume {
            return ShowPlayTarget(episode: episode, action: .resume(row.position))
        }
        return ShowPlayTarget(episode: episode, action: .play)
    }
}

// MARK: - What "Play" does on a movie (VOD-3)

/// A movie's main button: "Play", "Resume 41:12", or "Play again" once 95% of
/// it has played (VOD-3).
struct MoviePlayState: Equatable {
    enum Action: Equatable {
        case play
        case resume(TimeInterval)
        case playAgain
    }

    var action: Action
    /// 0…1 for the bar under the button; nil when not started.
    var fraction: Double?
    /// "1 h 11 min left".
    var remaining: TimeInterval?

    init(progress: ProgressRecord?) {
        guard let progress else {
            action = .play
            fraction = nil
            remaining = nil
            return
        }
        if progress.watched || ProgressRules.isWatched(position: progress.position, duration: progress.duration) {
            action = .playAgain
            fraction = nil
            remaining = nil
        } else if progress.position >= Self.minimumResume {
            action = .resume(progress.position)
            fraction = progress.duration > 0 ? progress.fraction : nil
            remaining = progress.duration > 0 ? progress.remaining : nil
        } else {
            action = .play
            fraction = nil
            remaining = nil
        }
    }

    /// Under ten seconds in is a false start, not a place to resume from.
    static let minimumResume: TimeInterval = 10

    var title: String {
        switch action {
        case .play: String(localized: "Play", comment: "Movie's main button")
        case .resume(let position):
            String(localized: "Resume \(LibraryFormat.timecode(position))", comment: "Movie's main button, e.g. Resume 41:12")
        case .playAgain: String(localized: "Play again", comment: "Movie's main button once watched")
        }
    }

    var spokenTitle: String {
        switch action {
        case .resume(let position):
            String(localized: "Resume from \(LibraryFormat.spokenDuration(position))", comment: "VoiceOver, e.g. Resume from 41 minutes, 12 seconds")
        default: title
        }
    }

    /// Where the player starts: the resume point, or explicitly 0 so the
    /// coordinator doesn't resume a finished movie by itself.
    var startPosition: TimeInterval {
        if case .resume(let position) = action { return position }
        return 0
    }

    var isResumable: Bool {
        if case .resume = action { return true }
        return false
    }
}

// MARK: - Where the household is in a show (SER-3)

/// One line of the "In this household" card: "Anya · S3 E1  ahead of you".
/// Built from `HouseholdStore.householdProgress`, which never returns a
/// Guest's rows (SER-3).
struct HouseholdShowLine: Equatable, Identifiable {
    enum Relation: Equatable {
        case ahead
        case behind
        case sameEpisode
    }

    var id: UUID
    var name: String
    var season: Int
    var episode: Int
    /// The trailing text: "31 min left", "ahead of you", "watched".
    var trailing: String
    var isCurrentProfile: Bool

    var episodeCode: String { EpisodeCode.short(season: season, episode: episode) }

    /// Where `other` is relative to `mine`, by season then episode, specials
    /// (season 0) counted after every season as the picker orders them.
    static func relation(of other: (season: Int, episode: Int), to mine: (season: Int, episode: Int)) -> Relation {
        if other.season == mine.season && other.episode == mine.episode { return .sameEpisode }
        if other.season == mine.season { return other.episode > mine.episode ? .ahead : .behind }
        return SeasonGrouping.seasonOrder(mine.season, other.season) ? .ahead : .behind
    }

    /// The current profile's line: time left in the episode, or "watched".
    static func mine(id: UUID, progress: ProgressRecord) -> HouseholdShowLine? {
        guard let season = progress.season, let episode = progress.episode else { return nil }
        let trailing: String
        if progress.watched {
            trailing = String(localized: "watched", comment: "In this household: your latest episode is finished")
        } else if progress.duration > 0, progress.remaining >= 60 {
            trailing = LibraryFormat.remaining(progress.remaining)
        } else {
            trailing = String(localized: "started", comment: "In this household: an episode begun with no known length")
        }
        return HouseholdShowLine(id: id, name: String(localized: "You", comment: "In this household: the current profile"),
                                 season: season, episode: episode, trailing: trailing, isCurrentProfile: true)
    }

    /// Another profile's line, compared with where the current one is.
    /// Without a position of your own (or as a Guest) it says how far they
    /// are into their episode instead.
    static func other(id: UUID, name: String, progress: ProgressRecord, mine: ProgressRecord?) -> HouseholdShowLine? {
        guard let season = progress.season, let episode = progress.episode else { return nil }
        let trailing: String
        if let mine, let mySeason = mine.season, let myEpisode = mine.episode {
            switch relation(of: (season, episode), to: (mySeason, myEpisode)) {
            case .ahead: trailing = String(localized: "ahead of you", comment: "In this household: another profile is further into the show")
            case .behind: trailing = String(localized: "behind you", comment: "In this household: another profile is earlier in the show")
            case .sameEpisode: trailing = String(localized: "same episode", comment: "In this household: another profile is on your episode")
            }
        } else if progress.watched {
            trailing = String(localized: "watched", comment: "In this household: their latest episode is finished")
        } else if progress.duration > 0, progress.remaining >= 60 {
            trailing = LibraryFormat.remaining(progress.remaining)
        } else {
            trailing = String(localized: "started")
        }
        return HouseholdShowLine(id: id, name: name, season: season, episode: episode, trailing: trailing, isCurrentProfile: false)
    }

    /// "Anya, season 3, episode 1, ahead of you".
    var spokenText: String {
        "\(name), \(EpisodeCode.spoken(season: season, episode: episode)), \(trailing)"
    }
}

// MARK: - Meta lines

/// "2024 · Drama · 1 h 52 min · from Provider B" under a title (VOD-2), and
/// "2024 · Drama · 3 seasons · from Provider B" on a show (mockup 04).
enum MetaLine {
    static func movie(_ movie: CatalogMovie) -> [String] {
        parts(year: movie.year, genre: movie.genre, middle: movie.duration.flatMap { $0 > 0 ? LibraryFormat.duration($0) : nil },
              rating: movie.rating, sourceName: movie.sourceName)
    }

    static func series(_ series: CatalogSeries, seasonCount: Int?) -> [String] {
        let seasons = seasonCount.flatMap { count -> String? in
            guard count > 0 else { return nil }
            return count == 1
                ? String(localized: "1 season", comment: "Show meta line")
                : String(localized: "\(count) seasons", comment: "Show meta line, e.g. 3 seasons")
        }
        return parts(year: series.year, genre: series.genre, middle: seasons, rating: series.rating, sourceName: series.sourceName)
    }

    static func joined(_ parts: [String]) -> String { parts.joined(separator: " · ") }

    /// The same pieces with commas, since some voices read "·" as "dot".
    static func spoken(_ parts: [String]) -> String { parts.joined(separator: ", ") }

    static func parts(year: Int?, genre: String?, middle: String?, rating: Double?, sourceName: String) -> [String] {
        var parts: [String] = []
        if let year, year > 0 { parts.append(String(year)) }
        if let genre = primaryGenre(genre) { parts.append(genre) }
        if let middle { parts.append(middle) }
        if let rating = ratingText(rating) { parts.append(rating) }
        let source = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty {
            parts.append(String(localized: "from \(source)", comment: "Which source an item comes from, e.g. from Provider B (SRC-7)"))
        }
        return parts
    }

    /// The first of "Drama, Thriller / Crime": the meta line has room for
    /// one; the detail section lists them all.
    static func primaryGenre(_ genre: String?) -> String? {
        allGenres(genre).first
    }

    /// Providers separate genres with commas, slashes, pipes or semicolons.
    static func allGenres(_ genre: String?) -> [String] {
        guard let genre else { return [] }
        return genre
            .split(whereSeparator: { ",/|;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// "★ 7.4"; nothing for a missing or zero rating (Stalker sends "0"
    /// for unrated).
    static func ratingText(_ rating: Double?) -> String? {
        guard let rating, rating > 0 else { return nil }
        return "★ " + rating.formatted(.number.precision(.fractionLength(rating >= 10 ? 0 : 1)))
    }

    /// Cast as a provider sends it ("A, B, C"), trimmed and capped so a
    /// 40-name credit list doesn't swamp the screen.
    static func castNames(_ cast: String?, limit: Int = 12) -> [String] {
        guard let cast else { return [] }
        return cast
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Poster badges

/// What a poster in a grid says in its corner and draws along its foot.
struct PosterDecoration: Equatable {
    var badge: String?
    var progress: Double?

    /// A title the provider added in the last week, for the "New" badge.
    static let newWindow: TimeInterval = 7 * 86_400

    static func isNew(addedAt: Date?, now: Date) -> Bool {
        guard let addedAt else { return false }
        let age = now.timeIntervalSince(addedAt)
        // A date in the future is a provider clock problem, not news.
        return age >= 0 && age < newWindow
    }

    /// A movie: a resume bar while started, "Watched" once finished, else
    /// "New" for a recent addition.
    static func movie(addedAt: Date?, progress: ProgressRecord?, now: Date) -> PosterDecoration {
        if let progress {
            if progress.watched {
                return PosterDecoration(badge: String(localized: "Watched", comment: "Poster badge on a finished movie"), progress: nil)
            }
            if progress.position >= MoviePlayState.minimumResume, progress.duration > 0 {
                return PosterDecoration(badge: nil, progress: progress.fraction)
            }
        }
        return PosterDecoration(badge: isNew(addedAt: addedAt, now: now) ? String(localized: "New", comment: "Poster badge on a recent addition") : nil,
                                progress: nil)
    }

    /// A show: the profile's latest episode ("S2 E5", with its resume bar
    /// while unfinished), "New · S2 E5" when the show is also a recent
    /// addition, or "New" alone.
    static func series(addedAt: Date?, latest: ProgressRecord?, now: Date) -> PosterDecoration {
        let isNew = isNew(addedAt: addedAt, now: now)
        guard let latest, let season = latest.season, let episode = latest.episode else {
            return PosterDecoration(badge: isNew ? String(localized: "New") : nil, progress: nil)
        }
        let code = EpisodeCode.short(season: season, episode: episode)
        let badge = isNew ? String(localized: "New · \(code)", comment: "Poster badge, e.g. New · S3 E3") : code
        let progress = (!latest.watched && latest.position > 0 && latest.duration > 0) ? latest.fraction : nil
        return PosterDecoration(badge: badge, progress: progress)
    }
}

// MARK: - Category chips

/// The chips above a grid: "All" and then each category, with the source's
/// name added where two sources both have a category of that name ("Action ·
/// Provider B"), so the chips stay tellable apart.
struct CategoryChips: Equatable {
    struct Chip: Equatable, Identifiable {
        /// Nil for "All".
        var categoryID: String?
        var title: String
        var id: String { categoryID ?? "" }
    }

    var chips: [Chip]

    init(categories: [CatalogCategory], sourceNames: [UUID: String]) {
        let nameCounts = Dictionary(grouping: categories, by: { SearchKey.normalize($0.name) }).mapValues { Set($0.map(\.sourceID)).count }
        let ordered = categories.sorted { a, b in
            if a.sourceID != b.sourceID {
                return (sourceNames[a.sourceID] ?? "", a.sourceID.uuidString) < (sourceNames[b.sourceID] ?? "", b.sourceID.uuidString)
            }
            return (a.sortOrder, a.name) < (b.sortOrder, b.name)
        }
        chips = [Chip(categoryID: nil, title: String(localized: "All", comment: "Category chip for everything"))]
            + ordered.map { category in
                let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let shared = (nameCounts[SearchKey.normalize(category.name)] ?? 0) > 1
                let title = shared ? "\(name) · \(sourceNames[category.sourceID] ?? "")" : name
                return Chip(categoryID: category.id, title: title)
            }
    }

    /// The selection to use: the stored one if it still exists, else "All".
    func validSelection(_ categoryID: String?) -> String? {
        guard let categoryID, chips.contains(where: { $0.categoryID == categoryID }) else { return nil }
        return categoryID
    }
}

// MARK: - Grid paging

/// How many items a grid asks the catalog for. Grids start with a page and
/// grow a page at a time as the last tiles scroll into view, so a 40 000-title
/// Stalker catalog never loads at once (catalog queries take a limit).
struct GridPaging: Equatable {
    static let pageSize = 90

    var limit = GridPaging.pageSize

    /// More may exist when the last query filled its limit.
    func hasMore(loaded: Int) -> Bool { loaded >= limit }

    mutating func grow() { limit += Self.pageSize }

    mutating func reset() { limit = Self.pageSize }

    /// Whether the tile at `index` is close enough to the end to ask for
    /// the next page: a row or two ahead, so scrolling rarely waits.
    func shouldGrow(appearingIndex index: Int, loaded: Int) -> Bool {
        hasMore(loaded: loaded) && index >= loaded - 18
    }
}

// MARK: - Empty and loading states

/// What a movies or shows grid shows when it has nothing to list (VOD-1,
/// SER-1), from the household's sources and their refresh states.
enum ShelfState: Equatable {
    case content
    /// The household has no sources yet.
    case noSources
    /// A source is importing; `message` is its progress line.
    case importing(message: String, progress: Double?)
    /// The import failed and nothing is stored.
    case failed(message: String, sourceID: UUID)
    /// The sources are imported and offer none of this kind.
    case noneOffered
    /// The sources have some, but this profile's rules hide them all.
    case hiddenByProfile
    /// The selected category is empty.
    case categoryEmpty

    /// - Parameters:
    ///   - offeredCount: How many of this kind the sources hold, from their
    ///     refresh states (unfiltered).
    static func resolve(hasItems: Bool, categorySelected: Bool, sourceCount: Int,
                        states: [SourceRefreshState], offeredCount: Int) -> ShelfState {
        if hasItems { return .content }
        if sourceCount == 0 { return .noSources }
        if categorySelected { return .categoryEmpty }
        for state in states {
            if case .refreshing(let progress, let message) = state.phase {
                return .importing(message: message, progress: progress)
            }
        }
        if offeredCount > 0 { return .hiddenByProfile }
        for state in states {
            if case .failed(let message) = state.phase {
                return .failed(message: message, sourceID: state.sourceID)
            }
        }
        // Sources added but never imported on this device yet (the import
        // is queued): still loading, not "none".
        if states.contains(where: { $0.catalogRefreshedAt == nil }) {
            return .importing(message: String(localized: "Waiting to load your sources…"), progress: nil)
        }
        return .noneOffered
    }
}

// MARK: - Formatting

/// Times as the library writes them. Core's `HearthFormat` builds its strings
/// by interpolation; these go through `String(localized:)` where words are
/// involved so the app's catalog can translate them.
enum LibraryFormat {
    /// "41:12", "1:02:03".
    static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// "1 h 52 min", "48 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes < 60 { return String(localized: "\(minutes) min", comment: "A length under an hour, e.g. 48 min") }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0
            ? String(localized: "\(hours) h", comment: "A whole number of hours, e.g. 2 h")
            : String(localized: "\(hours) h \(rest) min", comment: "A length over an hour, e.g. 1 h 52 min")
    }

    /// "31 min left".
    static func remaining(_ seconds: TimeInterval) -> String {
        String(localized: "\(duration(seconds)) left", comment: "Time left in a movie or episode, e.g. 31 min left")
    }

    /// "41 minutes, 12 seconds", where "41:12" would be read as a clock time.
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds).rounded())
        let units: Set<Duration.UnitsFormatStyle.Unit> = whole >= 3600 ? [.hours, .minutes] : [.minutes, .seconds]
        return Duration.seconds(whole).formatted(.units(allowed: units, width: .wide))
    }
}

extension CatalogSort {
    /// The sort menu's wording (VOD-1).
    var title: String {
        switch self {
        case .dateAdded: String(localized: "Date added", comment: "Sort option")
        case .name: String(localized: "Name", comment: "Sort option")
        case .year: String(localized: "Year", comment: "Sort option")
        }
    }
}
