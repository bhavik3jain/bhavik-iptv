import CatalogKit
import Core
import HouseholdKit
import SwiftUI

/// A movie (VOD-2, VOD-3): artwork, title, "2024 · Drama · 1 h 52 min · from
/// Provider B", Play or "Resume 41:12" (watched at 95% reads "Play again"),
/// the My List heart, the plot and whatever credits the provider sends.
///
/// Download (DL-1) is Phase 4, so there is no download button yet rather than
/// one that does nothing.
struct MovieDetailScreen: View {
    let itemKey: ItemKey

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.hearthLayout) private var layout
    @Environment(\.play) private var play

    var body: some View {
        let _ = catalog.revision
        if let movie = catalog.movie(itemKey) {
            loaded(movie)
        } else {
            UnavailableItemView(itemKey: itemKey, kind: .movie)
        }
    }

    private var profileID: UUID? {
        session.currentProfile.flatMap { $0.isGuest ? nil : $0.id }
    }

    @ViewBuilder
    private func loaded(_ movie: CatalogMovie) -> some View {
        let _ = store.revision
        let progress = profileID.flatMap { store.progress(profileID: $0, itemKey: movie.key.rawValue) }
        let state = MoviePlayState(progress: progress)
        if layout == .tv {
            tvDetail(movie, state: state)
        } else {
            touchDetail(movie, state: state, progress: progress)
        }
    }

    // MARK: TV

    /// The TV's page: Play (or Resume) first in focus, From the beginning
    /// while part way, My List, Watched; the plot and credits under them.
    private func tvDetail(_ movie: CatalogMovie, state: MoviePlayState) -> some View {
        TVDetailLayout(title: movie.name, metaParts: MetaLine.movie(movie), artworkURL: movie.posterURL) {
            HStack(spacing: 24) {
                Button {
                    start(movie, at: state.startPosition)
                } label: {
                    Label(state.title, systemImage: "play.fill")
                }
                .buttonStyle(.hearthTV(isProminent: true))
                .accessibilityLabel(Text(state.spokenTitle))
                if state.isResumable {
                    Button {
                        start(movie, at: 0)
                    } label: {
                        Label(String(localized: "From the beginning", bundle: .module), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.hearthTV)
                }
                TVMyListButton(itemKey: movie.key, kind: .movie)
                if let profileID {
                    let isWatched = state.action == .playAgain
                    Button {
                        store.setWatched(!isWatched, profileID: profileID, itemKey: movie.key.rawValue)
                    } label: {
                        Label(isWatched ? String(localized: "Mark as unwatched", bundle: .module) : String(localized: "Mark as watched", bundle: .module),
                              systemImage: isWatched ? "arrow.uturn.backward.circle" : "checkmark.circle")
                    }
                    .buttonStyle(.hearthTV)
                }
            }
        } info: {
            if let fraction = state.fraction {
                HStack(spacing: 20) {
                    HearthProgressBar(value: fraction, height: 8)
                        .frame(width: 360)
                    if let remaining = state.remaining {
                        Text(LibraryFormat.remaining(remaining))
                            .font(.hearthTVCaption)
                            .foregroundStyle(HearthColor.textSecondary)
                    }
                }
            }
            if let plot = movie.plot?.trimmingCharacters(in: .whitespacesAndNewlines), !plot.isEmpty {
                TVPlotText(text: plot)
            }
            let cast = MetaLine.castNames(movie.cast)
            if !cast.isEmpty {
                Text(String(localized: "Cast", bundle: .module) + "  " + cast.joined(separator: ", "))
                    .font(.hearthTVCaption)
                    .foregroundStyle(HearthColor.textTertiary)
                    .lineLimit(2)
            }
        } content: {
            EmptyView()
        }
    }

    // MARK: Phone and sidebar

    private func touchDetail(_ movie: CatalogMovie, state: MoviePlayState, progress: ProgressRecord?) -> some View {
        DetailScaffold(title: movie.name, metaParts: MetaLine.movie(movie), artworkURL: movie.posterURL) {
            actions(movie, state: state, progress: progress)
        } aside: {
            aside(movie)
        } content: {
            EmptyView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HearthShareLink(item: shareText(movie)) {
                    Label(String(localized: "Share", bundle: .module), systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: Actions

    private func actions(_ movie: CatalogMovie, state: MoviePlayState, progress: ProgressRecord?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DetailPlayButton(title: state.title, spokenTitle: state.spokenTitle) {
                    start(movie, at: state.startPosition)
                }
                if state.isResumable {
                    SquareIconButton(systemName: "arrow.counterclockwise", label: String(localized: "Play from the beginning", bundle: .module)) {
                        start(movie, at: 0)
                    }
                }
                MyListHeartButton(itemKey: movie.key, kind: .movie)
            }
            if let fraction = state.fraction {
                HStack(spacing: 10) {
                    HearthProgressBar(value: fraction)
                        .frame(maxWidth: 180)
                    if let remaining = state.remaining {
                        Text(LibraryFormat.remaining(remaining))
                            .font(.hearthMono(12, relativeTo: .caption))
                            .foregroundStyle(HearthColor.textSecondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(state.remaining.map(LibraryFormat.remaining) ?? ""))
            }
            if profileID != nil {
                watchedToggle(movie, isWatched: state.action == .playAgain)
            }
        }
    }

    /// "Mark as unwatched" once watched (and "Mark as watched" while part
    /// way), for a profile that saves progress; Guests never see it.
    private func watchedToggle(_ movie: CatalogMovie, isWatched: Bool) -> some View {
        Button {
            guard let profileID else { return }
            store.setWatched(!isWatched, profileID: profileID, itemKey: movie.key.rawValue)
        } label: {
            Label(isWatched ? String(localized: "Mark as unwatched", bundle: .module) : String(localized: "Mark as watched", bundle: .module),
                  systemImage: isWatched ? "arrow.uturn.backward.circle" : "checkmark.circle")
                .font(.hearthText(14, weight: .medium, relativeTo: .callout))
                .foregroundStyle(HearthColor.textSecondary)
                .frame(minHeight: HearthMetrics.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func start(_ movie: CatalogMovie, at position: TimeInterval) {
        play(PlayIntent(itemKey: movie.key.rawValue, kind: .movie, title: movie.name,
                        subtitle: movie.year.map(String.init), artworkURL: movie.posterURL,
                        startPosition: position))
    }

    // MARK: Plot and credits

    @ViewBuilder
    private func aside(_ movie: CatalogMovie) -> some View {
        let plot = movie.plot?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let genres = MetaLine.allGenres(movie.genre)
        let cast = MetaLine.castNames(movie.cast)
        if !plot.isEmpty {
            ExpandableText(text: plot)
        }
        if !genres.isEmpty || !cast.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if genres.count > 1 {
                    CreditRow(label: String(localized: "Genres", bundle: .module), value: genres.formatted(.list(type: .and)))
                }
                if !cast.isEmpty {
                    CreditRow(label: String(localized: "Cast", bundle: .module), value: cast.joined(separator: ", "))
                }
            }
            .padding(.top, 4)
        }
    }

    private func shareText(_ movie: CatalogMovie) -> String {
        movie.year.map { "\(movie.name) (\($0))" } ?? movie.name
    }
}

/// A movie or show the screen can't show: hidden by this profile's rules, or
/// gone from its provider (or its source removed). A gone item still in My
/// List can be taken off it here.
struct UnavailableItemView: View {
    let itemKey: ItemKey
    let kind: FavoriteKind

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = (catalog.revision, store.revision)
        ScrollView {
            Group {
                if catalog.contains(itemKey) {
                    EmptyStateView(
                        systemName: "eye.slash",
                        title: String(localized: "Not available on this profile", bundle: .module),
                        message: String(localized: "This profile's rules hide its category.", bundle: .module)
                    )
                } else if let profile = session.currentProfile, !profile.isGuest,
                          store.isFavorite(profileID: profile.id, itemKey: itemKey.rawValue) {
                    EmptyStateView(
                        systemName: "questionmark.square.dashed",
                        title: String(localized: "No longer available", bundle: .module),
                        message: String(localized: "Its provider stopped offering it, or its source was removed from the household.", bundle: .module),
                        actionTitle: String(localized: "Remove from My List", bundle: .module),
                        action: {
                            store.toggleFavorite(profileID: profile.id, itemKey: itemKey.rawValue, kind: kind)
                            dismiss()
                        }
                    )
                } else {
                    EmptyStateView(
                        systemName: "questionmark.square.dashed",
                        title: String(localized: "No longer available", bundle: .module),
                        message: String(localized: "Its provider stopped offering it, or its source was removed from the household.", bundle: .module)
                    )
                }
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        }
        .navigationTitle(kind == .series ? String(localized: "Show", bundle: .module) : String(localized: "Movie", bundle: .module))
        .inlineNavigationTitle()
        .hearthScreenBackground()
    }
}
