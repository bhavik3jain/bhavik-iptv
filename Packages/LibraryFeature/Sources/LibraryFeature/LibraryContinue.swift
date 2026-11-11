import CatalogKit
import Core
import Foundation
import HouseholdKit
import SwiftUI

// "Continue watching" at the top of the Movies and Shows tabs, as Netflix
// has (the owner, 2026-11-10). Every layout: Home on the iPhone, iPad and
// Mac stays the profile's favorites, and the Apple TV's Home keeps its hero.

/// One card in a Movies or Shows tab's Continue watching row.
struct ContinueCard: Identifiable, Equatable {
    /// The movie's or the show's key.
    var id: String
    var title: String
    /// "41 min left", "Resume S2 E5", "Play S2 E6".
    var caption: String?
    var posterURL: URL?
    var progress: Double?
    /// The movie's or show's page.
    var route: HearthRoute
    /// What choosing the card plays. Nil while this device hasn't the
    /// show's episodes (its progress came from another device): the card
    /// opens the show then, and the episodes are fetched.
    var playIntent: PlayIntent?
    /// The movie's or episode's key, for the menu's marks.
    var itemKey: String
    var isMovie: Bool
    /// For an episode: "S2 E5", for "Mark S2 E5 as watched".
    var episodeCode: String?
}

/// What the row lists, as plain values.
enum LibraryContinue {
    /// Cards a row shows at most.
    static let limit = 20

    /// Started, unfinished movies, most recent first (`continueWatching`'s
    /// order): past a false start (`MoviePlayState`), and only those the
    /// catalog holds, through the profile's filter, so a Kids profile never
    /// sees an adult film started elsewhere.
    static func movies(_ rows: [ProgressRecord], movie: (ItemKey) -> CatalogMovie?) -> [ContinueCard] {
        var cards: [ContinueCard] = []
        for row in rows where row.kind == .movie {
            let state = MoviePlayState(progress: row)
            guard state.isResumable, let movie = movie(ItemKey(rawValue: row.itemKey)) else { continue }
            let remaining = state.remaining.map(LibraryFormat.remaining)
            cards.append(ContinueCard(
                id: row.itemKey,
                title: movie.name,
                caption: remaining ?? state.title,
                posterURL: movie.posterURL,
                progress: state.fraction,
                route: .movie(itemKey: row.itemKey),
                playIntent: PlayIntent(itemKey: row.itemKey, kind: .movie, title: movie.name, subtitle: movie.year.map(String.init),
                                       artworkURL: movie.posterURL, startPosition: state.startPosition),
                itemKey: row.itemKey,
                isMovie: true,
                episodeCode: nil
            ))
            if cards.count == limit { break }
        }
        return cards
    }

    /// Shows in progress, most recent first (`seriesInProgress`'s order),
    /// each at the episode its own page's main button plays
    /// (`ShowPlayTarget`): the unfinished one, or the next after a finished
    /// one. A show caught up on every episode leaves the row. A show whose
    /// episodes this device hasn't cached is listed from its progress row
    /// and returned in `needingEpisodes` to fetch.
    static func shows(
        _ latest: [ProgressRecord],
        series: (ItemKey) -> CatalogSeries?,
        episodes: (ItemKey) -> [CatalogEpisode],
        progress: (String) -> [String: ProgressRecord]
    ) -> (cards: [ContinueCard], needingEpisodes: [CatalogSeries]) {
        var cards: [ContinueCard] = []
        var needing: [CatalogSeries] = []
        for row in latest {
            guard let seriesKey = row.seriesKey, let show = series(ItemKey(rawValue: seriesKey)) else { continue }
            let cached = episodes(show.key)
            guard !cached.isEmpty else {
                needing.append(show)
                if let card = uncachedCard(show, row: row) { cards.append(card) }
                if cards.count == limit { break }
                continue
            }
            let grouping = SeasonGrouping(cached)
            guard let target = ShowPlayTarget.choose(episodes: grouping.orderedEpisodes, progress: progress(seriesKey)) else { continue }
            if target.action == .playAgain { continue }
            let episode = target.episode
            let code = EpisodeCode.short(season: episode.season, episode: episode.number)
            var fraction: Double?
            if case .resume(let position) = target.action, let duration = progress(seriesKey)[episode.key.rawValue]?.duration, duration > 0 {
                fraction = min(max(position / duration, 0), 1)
            }
            let subtitle = episode.title.trimmingCharacters(in: .whitespaces).isEmpty ? code : "\(code) — \(episode.title)"
            cards.append(ContinueCard(
                id: seriesKey,
                title: show.name,
                caption: target.title,
                posterURL: show.posterURL,
                progress: fraction,
                route: .series(itemKey: seriesKey),
                playIntent: PlayIntent(itemKey: episode.key.rawValue, kind: .episode, title: show.name, subtitle: subtitle,
                                       artworkURL: episode.posterURL ?? show.posterURL, startPosition: target.startPosition,
                                       queue: grouping.keys(following: episode.key).map(\.rawValue)),
                itemKey: episode.key.rawValue,
                isMovie: false,
                episodeCode: code
            ))
            if cards.count == limit { break }
        }
        return (cards, needing)
    }

    /// A show with no cached episodes: where its row says the profile is,
    /// opening the show. A finished episode's row says nothing of what comes
    /// next until the episodes arrive.
    private static func uncachedCard(_ show: CatalogSeries, row: ProgressRecord) -> ContinueCard? {
        let code = (row.season).flatMap { season in row.episode.map { EpisodeCode.short(season: season, episode: $0) } }
        let unfinished = !row.watched && row.position >= MoviePlayState.minimumResume
        let caption: String?
        if unfinished, let code {
            caption = String(localized: "Resume \(code)", bundle: .module, comment: "Show's main button, e.g. Resume S2 E5")
        } else {
            caption = code
        }
        return ContinueCard(
            id: show.key.rawValue,
            title: show.name,
            caption: caption,
            posterURL: show.posterURL,
            progress: unfinished && row.duration > 0 ? row.fraction : nil,
            route: .series(itemKey: show.key.rawValue),
            playIntent: nil,
            itemKey: row.itemKey,
            isMovie: false,
            episodeCode: code
        )
    }
}

// MARK: - Views

/// Choosing a card plays it (or opens the show, `ContinueCard.playIntent`);
/// the menu opens the page or marks it.
private struct ContinueCardActions: ViewModifier {
    let card: ContinueCard
    @Environment(ProfileSession.self) private var session

    func body(content: Content) -> some View {
        content.contextMenu { ContinueCardMenu(card: card, profileID: session.currentProfile.flatMap { $0.isGuest ? nil : $0.id }) }
    }
}

private struct ContinueCardMenu: View {
    let card: ContinueCard
    let profileID: UUID?
    @Environment(HouseholdStore.self) private var store
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        Button {
            openRoute(card.route)
        } label: {
            card.isMovie
                ? Label(String(localized: "Movie details", bundle: .module), systemImage: "info.circle")
                : Label(String(localized: "Go to show", bundle: .module), systemImage: "info.circle")
        }
        if let profileID {
            if card.isMovie {
                Button {
                    store.setWatched(true, profileID: profileID, itemKey: card.itemKey)
                } label: {
                    Label(String(localized: "Mark as watched", bundle: .module), systemImage: "checkmark.circle")
                }
                Button(role: .destructive) {
                    // Forgets the position, which takes it off the row.
                    store.setWatched(false, profileID: profileID, itemKey: card.itemKey)
                } label: {
                    Label(String(localized: "Remove from Continue watching", bundle: .module), systemImage: "xmark.circle")
                }
            } else if let code = card.episodeCode {
                Button {
                    store.setWatched(true, profileID: profileID, itemKey: card.itemKey)
                } label: {
                    Label(String(localized: "Mark \(code) as watched", bundle: .module), systemImage: "checkmark.circle")
                }
            }
        }
    }
}

/// The phone and sidebar row: a section title and a sideways row of
/// posters with their resume bars.
struct LibraryContinueRow: View {
    let cards: [ContinueCard]
    let gutter: CGFloat

    @Environment(\.play) private var play
    @Environment(\.openRoute) private var openRoute
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 108

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(String(localized: "Continue watching", bundle: .module)) { EmptyView() }
                .padding(.horizontal, gutter)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: HearthMetrics.itemSpacing) {
                    ForEach(cards) { card in
                        Button {
                            choose(card)
                        } label: {
                            PosterCell(title: card.title, url: card.posterURL, caption: card.caption,
                                       decoration: PosterDecoration(badge: nil, progress: card.progress))
                        }
                        .buttonStyle(.hearthTile)
                        .modifier(ContinueCardActions(card: card))
                        .frame(width: tileWidth)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, gutter, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
        .padding(.vertical, 6)
    }

    private func choose(_ card: ContinueCard) {
        if let intent = card.playIntent { play(intent) } else { openRoute(card.route) }
    }
}

/// Where down from the TV's tab bar lands on Movies and Shows.
enum LibraryTVFocus: Hashable {
    case firstContinue
    case firstPoster
}

/// The Apple TV's row: poster cards that lift with focus; select plays,
/// long-press for the page and the marks.
struct TVLibraryContinueShelf: View {
    let cards: [ContinueCard]
    var focus: FocusState<LibraryTVFocus?>.Binding

    @Environment(\.play) private var play
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        TVShelf(String(localized: "Continue watching", bundle: .module)) {
            ForEach(cards) { card in
                if card.id == cards.first?.id {
                    tvCard(card)
                        .focused(focus, equals: .firstContinue)
                } else {
                    tvCard(card)
                }
            }
        }
    }

    private func tvCard(_ card: ContinueCard) -> some View {
        TVCard(width: HearthTVMetrics.posterWidth, title: card.title, caption: card.caption) {
            if let intent = card.playIntent { play(intent) } else { openRoute(card.route) }
        } artwork: {
            TVPosterArtwork(title: card.title, url: card.posterURL, progress: card.progress)
        }
        .modifier(ContinueCardActions(card: card))
    }
}
