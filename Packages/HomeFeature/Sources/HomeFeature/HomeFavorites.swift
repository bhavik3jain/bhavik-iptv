import CatalogKit
import Core
import Foundation
import HouseholdKit

// Home on the iPhone, iPad, iPhone Duo and Mac is the profile's favorites
// (the owner, 2026-11-08: "a better home page … basic details, like
// favorites", and no Continue watching or Up next on the Mac): favorite
// channels with what's on, then My List's movies and shows. What it shows and
// in which order is decided here, as plain values, so it's tested without a
// store or a screen. The Apple TV's Home is its own (HomeTV.swift).

// MARK: - Posters

/// A movie or show on one of Home's My List shelves: its poster opens the
/// title's page.
struct HomePoster: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case movie
        case series
    }

    var itemKey: String
    var kind: Kind
    var title: String
    var posterURL: URL?
    /// Under the name: the year, or for a movie part-way through, the time
    /// left.
    var caption: String?
    /// On the poster: "S2 E5" for a show the profile has watched, "Watched"
    /// for a finished movie.
    var badge: String?
    /// The bar along the poster's foot: a started movie, or a show's latest
    /// episode left unfinished.
    var progress: Double?
    /// For a movie the profile started: where Play picks up.
    var resumePosition: TimeInterval?

    var id: String { itemKey }

    var route: HearthRoute {
        switch kind {
        case .movie: .movie(itemKey: itemKey)
        case .series: .series(itemKey: itemKey)
        }
    }

    var favoriteKind: FavoriteKind {
        switch kind {
        case .movie: .movie
        case .series: .series
        }
    }

    /// A false start isn't somewhere to resume from (Library's rule too).
    static let minimumResume: TimeInterval = 10

    static func movie(_ movie: CatalogMovie, progress: ProgressRecord?) -> HomePoster {
        var poster = HomePoster(
            itemKey: movie.key.rawValue,
            kind: .movie,
            title: movie.name,
            posterURL: movie.posterURL,
            caption: movie.year.map { String($0) }
        )
        guard let progress else { return poster }
        if progress.watched {
            poster.badge = String(localized: "Watched", bundle: .module, comment: "Poster badge on a finished movie")
        } else if progress.position >= minimumResume {
            poster.resumePosition = progress.position
            let duration = progress.duration > 0 ? progress.duration : (movie.duration ?? 0)
            if duration > 0 {
                poster.progress = min(max(progress.position / duration, 0), 1)
                poster.caption = HearthFormat.remaining(max(duration - progress.position, 0))
            }
        }
        return poster
    }

    /// `latest` is the profile's most recent episode row of the show, from
    /// one read for the whole shelf (`HomeShelf.latestEpisodes`).
    static func series(_ series: CatalogSeries, latest: ProgressRecord?) -> HomePoster {
        var poster = HomePoster(
            itemKey: series.key.rawValue,
            kind: .series,
            title: series.name,
            posterURL: series.posterURL,
            caption: series.year.map { String($0) }
        )
        guard let latest, let code = UpNextPlanner.seasonAndNumber(of: latest) else { return poster }
        poster.badge = EpisodeLine.badge(season: code.0, number: code.1, isNew: false)
        if !latest.watched, latest.position > 0, latest.duration > 0 {
            poster.progress = latest.fraction
        }
        return poster
    }
}

/// A My List shelf: the profile's favorites of one kind, in the order the
/// store gives them (the profile's own order), resolved through the catalog.
enum HomeShelf {
    /// How many posters a shelf holds; "See all" opens the rest in My List.
    static let limit = 20
    /// The sidebar layout wraps a shelf into a grid this many rows high.
    static let gridRows = 2

    /// Titles this device's catalog doesn't hold (a big portal is kept a page
    /// per category) are left off: My List says what's become of them. Stops
    /// resolving once the shelf is full, so a long list costs one shelf of
    /// catalog reads.
    static func posters(_ favorites: [FavoriteRecord], limit: Int = HomeShelf.limit, resolve: (FavoriteRecord) -> HomePoster?) -> [HomePoster] {
        var posters: [HomePoster] = []
        var seen: Set<String> = []
        for favorite in favorites where posters.count < limit {
            guard !seen.contains(favorite.itemKey), let poster = resolve(favorite) else { continue }
            seen.insert(favorite.itemKey)
            posters.append(poster)
        }
        return posters
    }

    /// Each show's latest episode row, from `seriesInProgress` (newest
    /// first, so the first row of a show is its latest).
    static func latestEpisodes(_ rows: [ProgressRecord]) -> [String: ProgressRecord] {
        var latest: [String: ProgressRecord] = [:]
        for row in rows {
            guard let seriesKey = row.seriesKey, latest[seriesKey] == nil else { continue }
            latest[seriesKey] = row
        }
        return latest
    }
}

// MARK: - Sections

/// One part of Home below its header.
enum HomeSection: Hashable, Sendable {
    /// The favorite channels' now-playing cards.
    case favoriteChannels
    case myListMovies
    case myListShows
    /// No favorite channels: how to pin one (a guest: the way to the guide).
    case favoriteChannelsHint
    /// Nothing on My List: how to add to it.
    case myListHint
    /// No favorites of any kind: one card in place of both hints.
    case welcome
}

/// How much Home has to show, for which sections it draws.
struct HomeCounts: Equatable, Sendable {
    /// Favorite channels the catalog has, all of them.
    var channels = 0
    /// Posters on the My List shelves.
    var movies = 0
    var shows = 0
    /// What My List holds, whether or not this device's catalog has each
    /// title yet: a list of titles still being found isn't an empty list.
    var savedMovies = 0
    var savedShows = 0

    var isListEmpty: Bool { savedMovies + savedShows == 0 }
}

enum HomePlan {
    /// What has something comes first, channels then movies then shows;
    /// hints for what's empty follow. With nothing at all, one welcome card.
    /// A guest keeps no favorites: just the way to the guide.
    static func sections(_ counts: HomeCounts, isGuest: Bool) -> [HomeSection] {
        if isGuest { return [.favoriteChannelsHint] }
        if counts.channels == 0, counts.isListEmpty { return [.welcome] }
        var sections: [HomeSection] = []
        if counts.channels > 0 { sections.append(.favoriteChannels) }
        if counts.movies > 0 { sections.append(.myListMovies) }
        if counts.shows > 0 { sections.append(.myListShows) }
        if counts.channels == 0 { sections.append(.favoriteChannelsHint) }
        if counts.isListEmpty { sections.append(.myListHint) }
        return sections
    }
}

// MARK: - Header

/// The line under the greeting: "6 favorite channels · 3 movies and 2 shows
/// on My List". Nil with nothing saved, and for a guest.
enum HomeSummary {
    static func text(_ counts: HomeCounts, isGuest: Bool) -> String? {
        guard !isGuest else { return nil }
        var parts: [String] = []
        if counts.channels > 0 {
            parts.append(counts.channels == 1
                ? String(localized: "1 favorite channel", bundle: .module)
                : String(localized: "\(counts.channels) favorite channels", bundle: .module))
        }
        let movies: String? = switch counts.savedMovies {
        case ..<1: nil
        case 1: String(localized: "1 movie", bundle: .module)
        default: String(localized: "\(counts.savedMovies) movies", bundle: .module)
        }
        let shows: String? = switch counts.savedShows {
        case ..<1: nil
        case 1: String(localized: "1 show", bundle: .module)
        default: String(localized: "\(counts.savedShows) shows", bundle: .module)
        }
        switch (movies, shows) {
        case let (movies?, shows?):
            parts.append(String(localized: "\(movies) and \(shows) on My List", bundle: .module, comment: "Home's summary, e.g. 3 movies and 2 shows on My List"))
        case let (items?, nil), let (nil, items?):
            parts.append(String(localized: "\(items) on My List", bundle: .module, comment: "Home's summary, e.g. 3 movies on My List"))
        case (nil, nil):
            break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
