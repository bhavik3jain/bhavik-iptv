import CatalogKit
import Core
import HouseholdKit
import SwiftUI

// The library's pieces on the Apple TV (HearthLayout.tv): posters that lift
// with focus, the detail page's layout and the episode cards. The screens
// keep their own data and actions and draw with these when the layout is TV.

/// A poster in a TV grid: the artwork with its badge and progress (the same
/// `PosterDecoration` as the phone), the title under it; select opens the
/// movie or show, press and hold for Play, My List and Watched.
struct TVLibraryPosterLink: View {
    let entry: GridEntry

    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.play) private var play

    /// The profile that saves progress and lists; nil for a Guest.
    private var profile: ProfileRecord? {
        session.currentProfile.flatMap { $0.isGuest ? nil : $0 }
    }

    var body: some View {
        let _ = store.revision
        let now = Date.now
        let decoration: PosterDecoration
        let movieState: MoviePlayState?
        switch entry.kind {
        case .movie:
            let progress = profile.flatMap { store.progress(profileID: $0.id, itemKey: entry.id.rawValue) }
            decoration = .movie(addedAt: entry.addedAt, progress: progress, now: now)
            movieState = MoviePlayState(progress: progress)
        case .series(let latest):
            decoration = .series(addedAt: entry.addedAt, latest: latest, now: now)
            movieState = nil
        }
        return TVCard(route: entry.route, width: HearthTVMetrics.posterWidth, title: entry.title, caption: entry.caption) {
            TVPosterArtwork(title: entry.title, url: entry.posterURL, badge: decoration.badge, progress: decoration.progress)
        }
        .contextMenu {
            if let movieState {
                Button {
                    play(PlayIntent(itemKey: entry.id.rawValue, kind: .movie, title: entry.title,
                                    subtitle: entry.caption, artworkURL: entry.posterURL,
                                    startPosition: movieState.startPosition))
                } label: {
                    Label(movieState.title, systemImage: "play.fill")
                }
            }
            if let profile {
                let isFavorite = store.isFavorite(profileID: profile.id, itemKey: entry.id.rawValue)
                Button {
                    store.toggleFavorite(profileID: profile.id, itemKey: entry.id.rawValue, kind: entry.favoriteKind)
                } label: {
                    isFavorite
                        ? Label(String(localized: "Remove from My List", bundle: .module), systemImage: "heart.slash")
                        : Label(String(localized: "Add to My List", bundle: .module), systemImage: "heart")
                }
                if let movieState {
                    let watched = movieState.action == .playAgain
                    Button {
                        store.setWatched(!watched, profileID: profile.id, itemKey: entry.id.rawValue)
                    } label: {
                        watched
                            ? Label(String(localized: "Mark as unwatched", bundle: .module), systemImage: "arrow.uturn.backward.circle")
                            : Label(String(localized: "Mark as watched", bundle: .module), systemImage: "checkmark.circle")
                    }
                }
            }
        }
    }
}

/// A movie's or show's page on the TV: the artwork dimmed behind the whole
/// screen, the poster beside the title, the facts line, the actions (the
/// first takes focus), then whatever the screen adds below — a show's seasons
/// and episodes.
struct TVDetailLayout<Actions: View, Info: View, Content: View>: View {
    let title: String
    let metaParts: [String]
    let artworkURL: URL?
    let actions: Actions
    let info: Info
    let content: Content

    init(title: String, metaParts: [String], artworkURL: URL?, @ViewBuilder actions: () -> Actions, @ViewBuilder info: () -> Info, @ViewBuilder content: () -> Content) {
        self.title = title
        self.metaParts = metaParts
        self.artworkURL = artworkURL
        self.actions = actions()
        self.info = info()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                HStack(alignment: .top, spacing: 64) {
                    TVPosterArtwork(title: title, url: artworkURL)
                        .frame(width: 380)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                    VStack(alignment: .leading, spacing: 22) {
                        Text(title)
                            .font(.hearthTVLargeTitle)
                            .tracking(-0.8)
                            .foregroundStyle(HearthColor.textPrimary)
                            .lineLimit(2)
                            .accessibilityAddTraits(.isHeader)
                        if !metaParts.isEmpty {
                            Text(MetaLine.joined(metaParts))
                                .font(.hearthTVCallout)
                                .foregroundStyle(HearthColor.textSecondary)
                        }
                        actions
                            .padding(.vertical, 12)
                            .hearthFocusSection()
                        info
                    }
                    .frame(maxWidth: 1100, alignment: .leading)
                }
                content
            }
            .padding(.top, 20)
            .padding(.bottom, 60)
            // Edge to edge, so the backdrop behind the scroll view covers the
            // screen: a movie's page has no full-width shelf to widen it, and
            // the stack's grey showed down both sides.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .background { backdrop }
        .toolbar(.hidden, for: .automatic)
    }

    private var backdrop: some View {
        ZStack {
            HearthColor.background
            if let artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                            .blur(radius: 60)
                            .opacity(0.35)
                    }
                }
            }
            LinearGradient(colors: [HearthColor.background.opacity(0.2), HearthColor.background], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A plot or summary at TV size, a few lines.
struct TVPlotText: View {
    let text: String
    var lines = 5

    var body: some View {
        Text(text)
            .font(.hearthText(27, relativeTo: .body))
            .foregroundStyle(HearthColor.textOnArtwork)
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An episode in a show's TV shelf: its still (or the show's poster colour),
/// the watched mark or resume bar, "5 · The Lighthouse Keeper" and its length.
struct TVEpisodeCard: View {
    let episode: CatalogEpisode
    let seriesName: String
    let row: ProgressRecord?
    let onPlay: (TimeInterval?) -> Void
    let onPlayFromStart: () -> Void
    let onSetWatched: ((Bool) -> Void)?

    var body: some View {
        let watched = row?.watched ?? false
        let duration = episode.duration.flatMap { $0 > 0 ? $0 : nil } ?? row.flatMap { $0.duration > 0 ? $0.duration : nil }
        let started = row.map { !$0.watched && $0.position >= MoviePlayState.minimumResume && $0.duration > 0 } ?? false
        let fraction: Double? = started ? row?.fraction : nil
        let resumeAt: TimeInterval? = started ? row?.position : (watched ? 0 : nil)
        let caption = [
            watched ? String(localized: "Watched", bundle: .module) : nil,
            started ? row.map { LibraryFormat.remaining($0.remaining) } ?? nil : duration.map(LibraryFormat.duration),
        ].compactMap { $0 }.joined(separator: " · ")

        return TVCard(
            width: HearthTVMetrics.landscapeWidth,
            title: "\(episode.number) · \(episode.title)",
            caption: caption.isEmpty ? nil : caption
        ) {
            onPlay(resumeAt)
        } artwork: {
            TVPosterArtwork(
                title: episode.title.isEmpty ? seriesName : episode.title,
                url: episode.posterURL,
                badge: watched ? String(localized: "Watched", bundle: .module) : nil,
                progress: fraction,
                aspectRatio: 16.0 / 9.0
            )
        }
        .contextMenu {
            if started || watched {
                Button(action: onPlayFromStart) {
                    Label(String(localized: "Play from the beginning", bundle: .module), systemImage: "arrow.counterclockwise")
                }
            }
            if let onSetWatched {
                Button {
                    onSetWatched(!watched)
                } label: {
                    watched
                        ? Label(String(localized: "Mark as unwatched", bundle: .module), systemImage: "arrow.uturn.backward.circle")
                        : Label(String(localized: "Mark as watched", bundle: .module), systemImage: "checkmark.circle")
                }
            }
        }
    }
}

/// My List on a TV detail page: a text button with the heart, amber text
/// while the title is on the list. Not shown to a Guest.
struct TVMyListButton: View {
    let itemKey: ItemKey
    let kind: FavoriteKind

    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session

    var body: some View {
        if let profile = session.currentProfile, !profile.isGuest {
            let _ = store.revision
            let isFavorite = store.isFavorite(profileID: profile.id, itemKey: itemKey.rawValue)
            Button {
                store.toggleFavorite(profileID: profile.id, itemKey: itemKey.rawValue, kind: kind)
            } label: {
                Label(
                    isFavorite ? String(localized: "In My List", bundle: .module) : String(localized: "My List", bundle: .module),
                    systemImage: isFavorite ? "heart.fill" : "heart"
                )
            }
            .buttonStyle(.hearthTV(isSelected: isFavorite))
            .accessibilityHint(Text(isFavorite ? "Removes it from My List" : "Keeps it in My List on every device", bundle: .module))
        }
    }
}
