import CatalogKit
import Core
import Foundation
import HouseholdKit

// Home's decisions as plain values: which episode is "up next", what the
// hero says, which state the screen is in, how many posters fit. Kept out of
// the views so they can be tested without a store or a screen (none are
// written yet: the owner asked for the app first, tests later).

// MARK: - Episode text

/// How Home writes an episode: "S2 · E5 — The Lighthouse Keeper" under the
/// hero, "S3 E3" or "New · S3 E3" on a poster badge.
enum EpisodeLine {
    /// The hero's subtitle. Providers often title episodes "Episode 5" or
    /// "S02E05", which says nothing the code doesn't, so those are dropped.
    static func subtitle(season: Int, number: Int, title: String?) -> String {
        let code = HearthFormat.episodeCode(season: season, episode: number)
        guard let title = meaningfulTitle(title, number: number) else { return code }
        return String(localized: "\(code) — \(title)", bundle: .module, comment: "Hero subtitle: episode code, then the episode's title")
    }

    /// The poster badge from mockup 02: "S1 E7", or "New · S3 E3" when
    /// episodes arrived since the profile last watched (SER-2).
    static func badge(season: Int, number: Int, isNew: Bool) -> String {
        let code = String(localized: "S\(season) E\(number)", bundle: .module, comment: "Compact episode code on a poster badge: season and episode")
        guard isNew else { return code }
        return String(localized: "New · \(code)", bundle: .module, comment: "Poster badge for a show with new episodes since it was last watched")
    }

    /// The line under an Up next poster: the episode's own title, or
    /// "Episode 3" when the provider's title is only a number.
    static func caption(number: Int, title: String?) -> String {
        meaningfulTitle(title, number: number)
            ?? String(localized: "Episode \(number)", bundle: .module, comment: "An episode with no title of its own")
    }

    /// The title, unless it's empty or just restates the number ("5",
    /// "Episode 5", "Ep. 5", "E05", "S02E05", "S2 E5").
    static func meaningfulTitle(_ title: String?, number: Int) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let compact = title.lowercased().filter { !$0.isWhitespace && $0 != "." && $0 != "-" && $0 != "_" }
        // Strip a leading season ("s2", "s02") before the episode part.
        var rest = Substring(compact)
        if rest.hasPrefix("s"), let firstNonDigit = rest.dropFirst().firstIndex(where: { !$0.isNumber }), firstNonDigit > rest.index(after: rest.startIndex) {
            rest = rest[firstNonDigit...]
        }
        for prefix in ["episode", "ep", "e", ""] where rest.hasPrefix(prefix) {
            let digits = rest.dropFirst(prefix.count)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber), Int(digits) == number { return nil }
        }
        return title
    }
}

// MARK: - Continue watching (HOME-1)

/// The Continue watching hero: one unfinished movie or episode, resolved
/// through the catalog so the profile's filter applies (a Kids profile never
/// sees an adult film it once started on another profile's device).
struct ContinueItem: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case movie
        case episode(season: Int, number: Int)
    }

    var itemKey: String
    var kind: Kind
    /// The movie's or the show's name.
    var title: String
    var subtitle: String?
    /// Behind the hero's text: an episode still when the provider sends one.
    var backdropURL: URL?
    /// The movie's or show's poster, beside the hero in the sidebar layout.
    var posterURL: URL?
    var position: TimeInterval
    var duration: TimeInterval
    /// For an episode: its show, so Up next can leave that show out.
    var seriesKey: String?
    /// For an episode: the episodes that follow it, for the player's up next.
    var queue: [String]

    var id: String { itemKey }

    var progress: Double? { duration > 0 ? min(max(position / duration, 0), 1) : nil }

    var remainingText: String? {
        duration > 0 ? HearthFormat.remaining(max(duration - position, 0)) : nil
    }

    /// Tapping the card (not Resume) opens the movie or the show.
    var route: HearthRoute {
        if let seriesKey { return .series(itemKey: seriesKey) }
        return .movie(itemKey: itemKey)
    }

    var playIntent: PlayIntent {
        switch kind {
        case .movie:
            PlayIntent(itemKey: itemKey, kind: .movie, title: title, subtitle: subtitle, artworkURL: posterURL, startPosition: position)
        case .episode:
            PlayIntent(itemKey: itemKey, kind: .episode, title: title, subtitle: subtitle, artworkURL: backdropURL ?? posterURL, startPosition: position, queue: queue)
        }
    }

    static func movie(_ movie: CatalogMovie, progress: ProgressRecord) -> ContinueItem {
        ContinueItem(
            itemKey: progress.itemKey,
            kind: .movie,
            title: movie.name,
            subtitle: movieSubtitle(movie),
            backdropURL: nil,
            posterURL: movie.posterURL,
            position: progress.position,
            duration: progress.duration > 0 ? progress.duration : (movie.duration ?? 0),
            seriesKey: nil,
            queue: []
        )
    }

    /// `episode` is nil when this device hasn't cached the show's episodes
    /// yet (progress synced from another device): the hero still shows the
    /// show and the code from the progress row, and Home fetches the
    /// episodes in the background.
    static func episode(series: CatalogSeries, episode: CatalogEpisode?, season: Int, number: Int, progress: ProgressRecord, queue: [String]) -> ContinueItem {
        ContinueItem(
            itemKey: progress.itemKey,
            kind: .episode(season: season, number: number),
            title: series.name,
            subtitle: EpisodeLine.subtitle(season: season, number: number, title: episode?.title),
            backdropURL: episode?.posterURL.flatMap { $0 == series.posterURL ? nil : $0 },
            posterURL: series.posterURL,
            position: progress.position,
            duration: progress.duration > 0 ? progress.duration : (episode?.duration ?? 0),
            seriesKey: series.key.rawValue,
            queue: queue
        )
    }

    /// "2019 · Drama" — the year and first genre, whichever the provider sent.
    static func movieSubtitle(_ movie: CatalogMovie) -> String? {
        let genre = movie.genre?
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0 == "|" })
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let parts = [movie.year.map { String($0) }, genre].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Picks the hero: the most recent unfinished row that still resolves in the
/// catalog. Rows whose item left the catalog, or that the profile's filter
/// hides, are skipped rather than shown as a dead card.
enum ContinueWatchingPicker {
    static func pick(_ rows: [ProgressRecord], resolve: (ProgressRecord) -> ContinueItem?) -> ContinueItem? {
        for row in rows where !row.watched && row.position > 0 {
            if let item = resolve(row) { return item }
        }
        return nil
    }
}

// MARK: - Up next (SER-2)

/// The next episode of a show in progress, per profile (SER-2).
///
/// From the profile's most recently touched episode of the show:
/// - not finished → that episode, to resume (or start again, if its
///   position was cleared by hand);
/// - finished → the first episode after it, in season and episode order,
///   that this profile hasn't watched. Season 0 (specials) sorts first, so a
///   special is never "next" after a regular episode, but a special's next is
///   the following special or S1 E1.
/// - finished and nothing after → the show is caught up and leaves the row.
enum UpNextPlanner {
    enum Pick: Equatable, Sendable {
        case resume(CatalogEpisode, position: TimeInterval)
        case next(CatalogEpisode)

        var episode: CatalogEpisode {
            switch self {
            case .resume(let episode, _), .next(let episode): episode
            }
        }
    }

    static func pick(last: ProgressRecord, episodes: [CatalogEpisode], watchedKeys: Set<String>) -> Pick? {
        let ordered = ordered(episodes)
        guard let position = seasonAndNumber(of: last) else { return nil }

        if !last.watched {
            guard let episode = ordered.first(where: { $0.key.rawValue == last.itemKey || ($0.season, $0.number) == position }) else { return nil }
            return .resume(episode, position: last.position)
        }
        return ordered
            .first { ($0.season, $0.number) > position && !watchedKeys.contains($0.key.rawValue) }
            .map(Pick.next)
    }

    /// Season, then episode number; ties by key so the order never flickers.
    static func ordered(_ episodes: [CatalogEpisode]) -> [CatalogEpisode] {
        episodes.sorted { ($0.season, $0.number, $0.key.rawValue) < ($1.season, $1.number, $1.key.rawValue) }
    }

    /// The episodes after `episode`, for the player's up next queue.
    static func queue(after episode: ItemKey, in episodes: [CatalogEpisode], limit: Int = 50) -> [String] {
        let ordered = ordered(episodes)
        guard let index = ordered.firstIndex(where: { $0.key == episode }) else { return [] }
        return ordered[(index + 1)...].prefix(limit).map(\.key.rawValue)
    }

    /// "New": the profile had finished where it was, and the provider
    /// changed the show since (Xtream's `last_modified`, which moves when
    /// episodes are added). Without that date nothing is ever marked new.
    static func isNew(last: ProgressRecord, seriesChangedAt: Date?) -> Bool {
        guard last.watched, let seriesChangedAt else { return false }
        return seriesChangedAt > last.updatedAt
    }

    /// From the row, or failing that from its episode key.
    static func seasonAndNumber(of row: ProgressRecord) -> (Int, Int)? {
        if let season = row.season, let episode = row.episode { return (season, episode) }
        return ItemKey(rawValue: row.itemKey).seasonAndEpisode.map { ($0.season, $0.number) }
    }
}

/// One poster in "Up next in your shows".
struct UpNextItem: Equatable, Identifiable, Sendable {
    var seriesKey: String
    var seriesName: String
    var posterURL: URL?
    var episodeKey: String
    var season: Int
    var number: Int
    var episodeTitle: String?
    var isNew: Bool
    /// Where to resume, for an unfinished episode.
    var resumePosition: TimeInterval?
    var progress: Double?
    var queue: [String]

    var id: String { seriesKey }

    var badge: String { EpisodeLine.badge(season: season, number: number, isNew: isNew) }
    var caption: String { EpisodeLine.caption(number: number, title: episodeTitle) }

    var playIntent: PlayIntent {
        PlayIntent(
            itemKey: episodeKey,
            kind: .episode,
            title: seriesName,
            subtitle: EpisodeLine.subtitle(season: season, number: number, title: episodeTitle),
            artworkURL: posterURL,
            startPosition: resumePosition,
            queue: queue
        )
    }

    static func make(series: CatalogSeries, pick: UpNextPlanner.Pick, last: ProgressRecord, episodes: [CatalogEpisode]) -> UpNextItem {
        let episode = pick.episode
        var item = UpNextItem(
            seriesKey: series.key.rawValue,
            seriesName: series.name,
            posterURL: series.posterURL,
            episodeKey: episode.key.rawValue,
            season: episode.season,
            number: episode.number,
            episodeTitle: episode.title,
            isNew: false,
            resumePosition: nil,
            progress: nil,
            queue: UpNextPlanner.queue(after: episode.key, in: episodes)
        )
        switch pick {
        case .resume(_, let position):
            if position > 0 {
                item.resumePosition = position
                item.progress = last.duration > 0 ? min(max(position / last.duration, 0), 1) : nil
            }
        case .next:
            item.isNew = UpNextPlanner.isNew(last: last, seriesChangedAt: series.addedAt)
        }
        return item
    }
}

// MARK: - Screen state

/// Which Home to draw: the real one, or what stands in before there is
/// anything to show.
enum HomeStatus: Equatable, Sendable {
    /// The household has no sources yet.
    case noSources
    /// A first import is running (or queued) and nothing has landed yet.
    case firstRefresh(sourceName: String?, progress: Double?, message: String?)
    /// Every source failed its first import.
    case failed(sourceID: UUID, sourceName: String?, message: String)
    case ready

    /// - Parameters:
    ///   - sourceIDs: the household's live sources.
    ///   - names: their display names.
    static func make(sourceIDs: [UUID], names: [UUID: String], refreshStates: [UUID: SourceRefreshState]) -> HomeStatus {
        guard !sourceIDs.isEmpty else { return .noSources }
        let states = sourceIDs.map { refreshStates[$0] ?? SourceRefreshState(sourceID: $0) }

        // Anything imported means there is a Home to show, even while a
        // second source's first import runs.
        if states.contains(where: hasCatalog) { return .ready }

        for state in states {
            if case .refreshing(let progress, let message) = state.phase {
                return .firstRefresh(sourceName: names[state.sourceID], progress: progress, message: message.isEmpty ? nil : message)
            }
        }
        let failures = states.compactMap { state -> (UUID, String)? in
            if case .failed(let message) = state.phase { return (state.sourceID, message) }
            return nil
        }
        if failures.count == states.count, let first = failures.first {
            return .failed(sourceID: first.0, sourceName: names[first.0], message: first.1)
        }
        // Idle with no catalog: waiting its turn in the import queue.
        return .firstRefresh(sourceName: nil, progress: nil, message: nil)
    }

    static func hasCatalog(_ state: SourceRefreshState) -> Bool {
        state.catalogRefreshedAt != nil || state.channelCount > 0 || state.movieCount > 0 || state.seriesCount > 0
    }
}

/// The chip beside "Favorite channels": favorites follow the profile to
/// every device through iCloud, and the chip says whether that's working.
enum SyncChipContent {
    static func make(_ status: HouseholdSyncStatus) -> (title: String, systemImage: String)? {
        switch status {
        case .upToDate:
            (String(localized: "Synced", bundle: .module, comment: "Chip: favorites are synced through iCloud"), "cloud")
        case .syncing:
            (String(localized: "Syncing", bundle: .module, comment: "Chip: favorites are syncing through iCloud"), "arrow.triangle.2.circlepath.icloud")
        case .failed:
            (String(localized: "Not synced", bundle: .module, comment: "Chip: iCloud sync failed"), "exclamationmark.icloud")
        case .local, .noAccount:
            // Nothing to say on a device that isn't syncing; Household explains.
            nil
        }
    }
}

/// The header's text where the profile switcher would be (the Mac keeps the
/// switcher in its sidebar). The window's toolbar already says "Home", so the
/// header greets the profile instead of repeating it.
enum HomeGreeting {
    static func text(name: String?, at date: Date, calendar: Calendar = .current) -> String {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return String(localized: "Home", bundle: .module)
        }
        switch calendar.component(.hour, from: date) {
        case 5..<12:
            return String(localized: "Good morning, \(name)", bundle: .module)
        case 12..<17:
            return String(localized: "Good afternoon, \(name)", bundle: .module)
        default:
            return String(localized: "Good evening, \(name)", bundle: .module)
        }
    }
}

// MARK: - Layout maths

/// Widths for the two layouts. `.sidebar` covers a 466-pt iPhone Duo inner
/// display up to a full-screen Mac, so the numbers scale with the width Home
/// actually gets rather than the device.
enum HomeLayoutMetrics {
    /// Past this the screen stops growing and centres: rows of posters wider
    /// than this read as a wall.
    static let readableWidth: CGFloat = 1120

    static func gutter(layout: HearthLayout, width: CGFloat) -> CGFloat {
        layout == .sidebar && width >= 640 ? 32 : HearthMetrics.screenPadding
    }

    /// The sidebar hero puts the poster beside the text once there's room for
    /// both a readable title and the art.
    static func heroShowsSidePoster(layout: HearthLayout, contentWidth: CGFloat) -> Bool {
        layout == .sidebar && contentWidth >= 520
    }
}

/// How many poster columns fit, for the sidebar's wrapping grids.
enum PosterGridFit {
    static func columns(width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard width > 0, minimum > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
    }

    /// At most `rows` full rows, so a 20-movie list doesn't become a page.
    static func visibleCount(total: Int, columns: Int, rows: Int) -> Int {
        min(total, max(columns, 1) * max(rows, 1))
    }
}

/// Fixed-width cards (favorite channels) wrapped into rows. Past `maxRows`
/// the last slot is kept for a "more in the guide" card, so the grid never
/// grows a third row.
enum CardGrid {
    static func rows<Item>(_ items: [Item], columns: Int, maxRows: Int) -> (rows: [[Item]], hiddenCount: Int) {
        let columns = max(columns, 1)
        let capacity = columns * max(maxRows, 1)
        let shown = items.count > capacity ? capacity - 1 : items.count
        let visible = Array(items.prefix(shown))
        let rows = stride(from: 0, to: visible.count, by: columns).map { start in
            Array(visible[start..<min(start + columns, visible.count)])
        }
        return (rows, items.count - shown)
    }

    /// The sidebar wraps favorites once three cards fit side by side; with
    /// fewer (iPhone Duo open) a sideways row wastes less of the width.
    static func wrapsFavorites(layout: HearthLayout, columns: Int) -> Bool {
        layout == .sidebar && columns >= 3
    }
}
