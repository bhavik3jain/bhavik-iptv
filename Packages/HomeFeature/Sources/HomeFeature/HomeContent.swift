import CatalogKit
import Core
import Foundation
import HouseholdKit

/// Everything Home shows below its header, read in one pass whenever the
/// catalog or the household changes (their `revision`s) or the profile does.
struct HomeSnapshot: Equatable, Sendable {
    /// The profile's favorite channels the catalog still has (and the
    /// profile may see), in the profile's order. Every layout.
    var favoriteChannels: [CatalogChannel] = []

    // The iPhone, iPad and Mac: My List's movies and shows.
    var myListMovies: [HomePoster] = []
    var myListShows: [HomePoster] = []
    /// How many movies and shows My List holds, found in this device's
    /// catalog or not.
    var savedMovieCount = 0
    var savedShowCount = 0

    // The Apple TV only: Continue watching and Up next.
    var continueWatching: ContinueItem?
    var upNext: [UpNextItem] = []
    /// Shows the TV's Up next needs episodes for: never cached on this device
    /// (progress synced from elsewhere), or caught up on a cache that may be
    /// stale. Fetched in the background, one at a time; each landing re-reads
    /// Home.
    var seriesNeedingEpisodes: [CatalogSeries] = []

    static let empty = HomeSnapshot()

    var counts: HomeCounts {
        HomeCounts(
            channels: favoriteChannels.count,
            movies: myListMovies.count,
            shows: myListShows.count,
            savedMovies: savedMovieCount,
            savedShows: savedShowCount
        )
    }
}

/// Reads a `HomeSnapshot` from the catalog and the household store. The
/// catalog's reads are synchronous main-context fetches with limits, so a
/// pass is cheap; the network work (episodes, short guides) happens later in
/// tasks that don't hold up the screen.
@MainActor
struct HomeLoader {
    let catalog: CatalogService
    let store: HouseholdStore

    /// How many shows "Up next" lists at most; also caps the episode reads.
    static let upNextLimit = 12

    func load(profileID: UUID?, layout: HearthLayout) -> HomeSnapshot {
        var snapshot = HomeSnapshot()
        // "New in Movies" is gone (the owner's call): on a big portal it only
        // showed the first page the provider sent, not what was new. Guests
        // get no rows from the store (no favorites, no progress).
        guard let profileID else { return snapshot }

        let favoriteKeys = store.favorites(profileID: profileID, kind: .channel).map { ItemKey(rawValue: $0.itemKey) }
        snapshot.favoriteChannels = catalog.channels(keys: favoriteKeys)

        if layout == .tv {
            // The TV's Home keeps Continue watching and Up next.
            var needing = NeedingEpisodes()
            snapshot.continueWatching = ContinueWatchingPicker.pick(store.continueWatching(profileID: profileID, limit: 10)) { row in
                resolveContinue(row, needing: &needing)
            }
            snapshot.upNext = upNext(profileID: profileID, excludingSeries: snapshot.continueWatching?.seriesKey, needing: &needing)
            snapshot.seriesNeedingEpisodes = needing.series
        } else {
            // Everywhere else Home is favorites only (the owner, 2026-11-08).
            loadMyList(profileID: profileID, into: &snapshot)
        }
        return snapshot
    }

    // MARK: My List

    /// My List's shelves, in the profile's order. A movie's progress is read
    /// per poster on the shelf (a shelf at most); a show's latest episode for
    /// every show in one read.
    private func loadMyList(profileID: UUID, into snapshot: inout HomeSnapshot) {
        let movies = store.favorites(profileID: profileID, kind: .movie)
        let shows = store.favorites(profileID: profileID, kind: .series)
        snapshot.savedMovieCount = movies.count
        snapshot.savedShowCount = shows.count

        snapshot.myListMovies = HomeShelf.posters(movies) { favorite in
            catalog.movie(ItemKey(rawValue: favorite.itemKey)).map { movie in
                HomePoster.movie(movie, progress: store.progress(profileID: profileID, itemKey: favorite.itemKey))
            }
        }
        guard !shows.isEmpty else { return }
        let latest = HomeShelf.latestEpisodes(store.seriesInProgress(profileID: profileID, limit: 1_000))
        snapshot.myListShows = HomeShelf.posters(shows) { favorite in
            catalog.seriesItem(ItemKey(rawValue: favorite.itemKey)).map { series in
                HomePoster.series(series, latest: latest[series.key.rawValue])
            }
        }
    }

    // MARK: Continue watching (the TV)

    private func resolveContinue(_ row: ProgressRecord, needing: inout NeedingEpisodes) -> ContinueItem? {
        let key = ItemKey(rawValue: row.itemKey)
        switch row.kind {
        case .movie:
            return catalog.movie(key).map { ContinueItem.movie($0, progress: row) }
        case .episode:
            guard let seriesKey = row.seriesKey.map(ItemKey.init(rawValue:)) ?? key.seriesKey,
                  let series = catalog.seriesItem(seriesKey) else { return nil }
            let episodes = catalog.cachedEpisodes(seriesKey: seriesKey)
            if episodes.isEmpty { needing.add(series) }
            let episode = episodes.first { $0.key == key } ?? catalog.episode(key)
            // The row's code, its key's, or failing both the cached episode's.
            guard let code = UpNextPlanner.seasonAndNumber(of: row) ?? episode.map({ ($0.season, $0.number) }) else { return nil }
            return .episode(
                series: series,
                episode: episode,
                season: code.0,
                number: code.1,
                progress: row,
                queue: UpNextPlanner.queue(after: key, in: episodes)
            )
        case .catchup:
            // Live TV from the archive never "continues" (the store leaves
            // these out already; this keeps the switch honest).
            return nil
        }
    }

    // MARK: Up next (SER-2, the TV)

    private func upNext(profileID: UUID, excludingSeries heroSeries: String?, needing: inout NeedingEpisodes) -> [UpNextItem] {
        var items: [UpNextItem] = []
        for last in store.seriesInProgress(profileID: profileID, limit: 20) {
            // The hero already offers this show; listing it twice wastes the row.
            guard let seriesKeyRaw = last.seriesKey, seriesKeyRaw != heroSeries else { continue }
            let seriesKey = ItemKey(rawValue: seriesKeyRaw)
            guard let series = catalog.seriesItem(seriesKey) else { continue }

            let episodes = catalog.cachedEpisodes(seriesKey: seriesKey)
            guard !episodes.isEmpty else {
                needing.add(series)
                continue
            }
            let watched = Set(store.seriesProgress(profileID: profileID, seriesKey: seriesKeyRaw).filter(\.watched).map(\.itemKey))
            guard let pick = UpNextPlanner.pick(last: last, episodes: episodes, watchedKeys: watched) else {
                // Caught up on what this device has cached. The catalog
                // returns a fresh cache at once and refetches a day-old one,
                // which is how a new episode turns up as "New · S3 E3".
                if last.watched { needing.add(series) }
                continue
            }
            items.append(.make(series: series, pick: pick, last: last, episodes: episodes))
            if items.count == Self.upNextLimit { break }
        }
        return items
    }
}

/// Shows to fetch episodes for, in the order Home met them, each once.
private struct NeedingEpisodes {
    private(set) var series: [CatalogSeries] = []
    private var keys: Set<ItemKey> = []

    mutating func add(_ item: CatalogSeries) {
        if keys.insert(item.key).inserted { series.append(item) }
    }
}
