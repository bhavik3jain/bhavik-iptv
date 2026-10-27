import CatalogKit
import Core
import HouseholdKit
import SwiftUI

/// Home on the Apple TV (mockup 02 at ten feet, HOME-1): the greeting and
/// profile switcher, the Continue watching hero with Resume in focus first,
/// then shelves the remote walks down — favorite channels (select plays,
/// long-press for the channel's page or to unfavorite), up next in your
/// shows, new in Movies. Reads the same `HomeSnapshot` as the phone.
struct HomeTVContent<ProfileSwitcher: View>: View {
    let snapshot: HomeSnapshot
    let status: HomeStatus
    let hasLoaded: Bool
    let profileSwitcher: ProfileSwitcher

    @Environment(CatalogService.self) private var catalog
    @Environment(ProfileSession.self) private var session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HearthTVMetrics.shelfSpacing) {
                header
                content
            }
            .padding(.bottom, 60)
        }
        .scrollClipDisabled()
        .hearthScreenBackground()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 32) {
            Text(HomeGreeting.text(name: session.currentProfile?.name, at: .now))
                .font(.hearthTVTitle)
                .tracking(-0.6)
                .foregroundStyle(HearthColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            profileSwitcher
        }
        .hearthFocusSection()
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .noSources:
            TVNoticeCard(
                systemName: "antenna.radiowaves.left.and.right",
                title: String(localized: "Add a source to start watching", bundle: .module),
                message: String(localized: "Add a Stalker portal, an Xtream login or an M3U playlist from Hearth on your iPhone, iPad or Mac — signed in to the same iCloud household. It appears here on its own.", bundle: .module)
            )
        case .firstRefresh(let sourceName, let progress, let message):
            TVFirstRefresh(sourceName: sourceName, progress: progress, message: message)
        case .failed(let sourceID, let sourceName, let message):
            VStack(alignment: .leading, spacing: 32) {
                TVNoticeCard(
                    systemName: "exclamationmark.triangle",
                    title: sourceName.map { String(localized: "Couldn't load \($0)", bundle: .module) }
                        ?? String(localized: "Couldn't load your source", bundle: .module),
                    message: message
                )
                Button(String(localized: "Try again", bundle: .module)) {
                    Task { await catalog.refresh(sourceID: sourceID, force: true) }
                }
                .buttonStyle(.hearthTV(isProminent: true))
            }
        case .ready:
            if hasLoaded { sections }
        }
    }

    @ViewBuilder
    private var sections: some View {
        let profileID = session.isGuest ? nil : session.currentProfile?.id

        if let item = snapshot.continueWatching {
            TVContinueHero(item: item, profileID: profileID)
        }

        TVFavoriteChannelsShelf(channels: snapshot.favoriteChannels, catalogRevision: catalog.revision, profileID: profileID, isGuest: session.isGuest)

        if !snapshot.upNext.isEmpty {
            TVShelf(String(localized: "Up next in your shows", bundle: .module)) {
                ForEach(snapshot.upNext) { item in
                    TVUpNextCard(item: item, profileID: profileID)
                }
            }
        }

        if !snapshot.newMovies.isEmpty {
            TVShelf(String(localized: "New in Movies", bundle: .module)) {
                ForEach(snapshot.newMovies) { movie in
                    TVNewMovieCard(movie: movie, isOnMyList: snapshot.myListKeys.contains(movie.key.rawValue), profileID: profileID)
                }
            }
        }
    }
}

// MARK: - Continue watching

/// The hero: the backdrop full width, the title and episode over it, Resume
/// and the way to the movie or show as the two buttons the remote starts on.
private struct TVContinueHero: View {
    let item: ContinueItem
    let profileID: UUID?

    @Environment(HouseholdStore.self) private var store
    @Environment(\.play) private var play
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            LinearGradient(
                colors: [HearthColor.background.opacity(0.95), HearthColor.background.opacity(0.55), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            VStack(alignment: .leading, spacing: 18) {
                Text("CONTINUE WATCHING", bundle: .module)
                    .font(.hearthText(22, weight: .semibold, relativeTo: .caption))
                    .tracking(2)
                    .foregroundStyle(HearthColor.accent)
                Text(item.title)
                    .font(.hearthDisplay(56, weight: .semibold, relativeTo: .largeTitle))
                    .tracking(-0.8)
                    .foregroundStyle(HearthColor.textPrimary)
                    .lineLimit(2)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.hearthTVBody)
                        .foregroundStyle(HearthColor.textOnArtwork)
                        .lineLimit(1)
                }
                if let progress = item.progress {
                    HStack(spacing: 20) {
                        HearthProgressBar(value: progress, height: 8, track: .overlay)
                            .frame(width: 420)
                        if let remaining = item.remainingText {
                            Text(remaining)
                                .font(.hearthTVCaption)
                                .foregroundStyle(HearthColor.textOnArtwork)
                        }
                    }
                }
                HStack(spacing: 28) {
                    Button {
                        play(item.playIntent)
                    } label: {
                        Label(String(localized: "Resume", bundle: .module), systemImage: "play.fill")
                    }
                    .buttonStyle(.hearthTV(isProminent: true))
                    .contextMenu { menu }
                    Button {
                        openRoute(item.route)
                    } label: {
                        Text(detailsTitle)
                    }
                    .buttonStyle(.hearthTV)
                }
                .padding(.top, 10)
                .hearthFocusSection()
            }
            .padding(56)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 500, maxHeight: 500)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [HearthColor.hero, HearthColor.heroShade], startPoint: .topTrailing, endPoint: .bottomLeading)
            if let url = item.backdropURL ?? item.posterURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var menu: some View {
        if let profileID {
            Button {
                store.setWatched(true, profileID: profileID, itemKey: item.itemKey)
            } label: {
                Label(String(localized: "Mark as watched", bundle: .module), systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
                store.setWatched(false, profileID: profileID, itemKey: item.itemKey)
            } label: {
                Label(String(localized: "Remove from Continue watching", bundle: .module), systemImage: "xmark.circle")
            }
        }
    }

    private var detailsTitle: String {
        item.seriesKey == nil
            ? String(localized: "Movie details", bundle: .module)
            : String(localized: "Go to show", bundle: .module)
    }
}

// MARK: - Favorite channels

/// The profile's favorite channels as now-playing cards; select plays with
/// the favorites as the channel up/down list.
private struct TVFavoriteChannelsShelf: View {
    let channels: [CatalogChannel]
    let catalogRevision: Int
    let profileID: UUID?
    let isGuest: Bool

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(\.play) private var play
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        if channels.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                Text("Favorite channels", bundle: .module)
                    .font(.hearthTVSectionTitle)
                    .foregroundStyle(HearthColor.textPrimary)
                TVNoticeCard(
                    systemName: "heart",
                    title: isGuest
                        ? String(localized: "Guests don't keep favorites", bundle: .module)
                        : String(localized: "Pin your favorite channels", bundle: .module),
                    message: isGuest
                        ? String(localized: "Open the Live TV guide to find something on now.", bundle: .module)
                        : String(localized: "In the Live TV guide, press and hold a channel and choose Favorite. Favorites follow this profile to every device.", bundle: .module)
                )
            }
        } else {
            TimelineView(.everyMinute) { context in
                let _ = catalogRevision
                let queue = channels.map(\.key.rawValue)
                TVShelf(String(localized: "Favorite channels", bundle: .module)) {
                    ForEach(channels.prefix(FavoriteChannelsSection.rowLimit)) { channel in
                        card(channel, queue: queue, at: context.date)
                    }
                } accessory: {
                    NavigationLink(value: HearthRoute.liveGuide) {
                        Text("Guide", bundle: .module)
                    }
                    .buttonStyle(.hearthTV)
                }
            }
        }
    }

    private func card(_ channel: CatalogChannel, queue: [String], at date: Date) -> some View {
        let now = catalog.nowAndNext(for: channel, at: date).now
        return TVCard(width: HearthTVMetrics.landscapeWidth) {
            play(PlayIntent(
                itemKey: channel.key.rawValue,
                kind: .live,
                title: channel.name,
                subtitle: now?.title,
                artworkURL: channel.logoURL,
                queue: queue
            ))
        } artwork: {
            TVChannelArtwork(
                name: channel.name,
                number: channel.number,
                logoURL: channel.logoURL,
                programmeTitle: now?.title,
                timing: now.map { ProgrammeTiming(start: $0.start, end: $0.end) },
                now: date
            )
        }
        .contextMenu {
            Button {
                openRoute(.channel(itemKey: channel.key.rawValue))
            } label: {
                Label(String(localized: "Open channel", bundle: .module), systemImage: "tv")
            }
            if let profileID {
                Button(role: .destructive) {
                    store.toggleFavorite(profileID: profileID, itemKey: channel.key.rawValue, kind: .channel)
                } label: {
                    Label(String(localized: "Unfavorite", bundle: .module), systemImage: "heart.slash")
                }
            }
        }
    }
}

// MARK: - Posters

/// Up next: the show's poster with the episode badge and progress; select
/// plays that episode, long-press opens the show or marks it watched.
private struct TVUpNextCard: View {
    let item: UpNextItem
    let profileID: UUID?

    @Environment(HouseholdStore.self) private var store
    @Environment(\.play) private var play
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        TVCard(width: HearthTVMetrics.posterWidth, title: item.seriesName, caption: item.caption) {
            play(item.playIntent)
        } artwork: {
            TVPosterArtwork(title: item.seriesName, url: item.posterURL, badge: item.badge, progress: item.progress)
        }
        .contextMenu {
            Button {
                openRoute(.series(itemKey: item.seriesKey))
            } label: {
                Label(String(localized: "Go to show", bundle: .module), systemImage: "info.circle")
            }
            if let profileID {
                Button {
                    store.setWatched(true, profileID: profileID, itemKey: item.episodeKey)
                } label: {
                    Label(String(localized: "Mark \(item.badge) as watched", bundle: .module), systemImage: "checkmark.circle")
                }
            }
        }
    }
}

/// A new movie: select opens its page, long-press plays or changes My List.
private struct TVNewMovieCard: View {
    let movie: CatalogMovie
    let isOnMyList: Bool
    let profileID: UUID?

    @Environment(HouseholdStore.self) private var store
    @Environment(\.play) private var play

    var body: some View {
        TVCard(
            route: .movie(itemKey: movie.key.rawValue),
            width: HearthTVMetrics.posterWidth,
            title: movie.name,
            caption: movie.year.map { String($0) }
        ) {
            TVPosterArtwork(title: movie.name, url: movie.posterURL)
        }
        .contextMenu {
            Button {
                play(PlayIntent(
                    itemKey: movie.key.rawValue,
                    kind: .movie,
                    title: movie.name,
                    subtitle: ContinueItem.movieSubtitle(movie),
                    artworkURL: movie.posterURL
                ))
            } label: {
                Label(String(localized: "Play", bundle: .module), systemImage: "play.fill")
            }
            if let profileID {
                Button {
                    store.toggleFavorite(profileID: profileID, itemKey: movie.key.rawValue, kind: .movie)
                } label: {
                    if isOnMyList {
                        Label(String(localized: "Remove from My List", bundle: .module), systemImage: "minus.circle")
                    } else {
                        Label(String(localized: "Add to My List", bundle: .module), systemImage: "plus.circle")
                    }
                }
            }
        }
    }
}

// MARK: - States

/// A source's first import, at TV size.
private struct TVFirstRefresh: View {
    let sourceName: String?
    let progress: Double?
    let message: String?

    var body: some View {
        VStack(spacing: 28) {
            HearthLogoMark(size: 72)
                .accessibilityHidden(true)
            Text(sourceName.map { String(localized: "Getting \($0) ready", bundle: .module) } ?? String(localized: "Getting your sources ready", bundle: .module))
                .font(.hearthTVTitle)
                .foregroundStyle(HearthColor.textPrimary)
                .multilineTextAlignment(.center)
            Text(message ?? String(localized: "Channels, movies and shows appear here as soon as they're imported. A large portal can take a few minutes.", bundle: .module))
                .font(.hearthTVCallout)
                .foregroundStyle(HearthColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            Group {
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                        .frame(width: 600)
                } else {
                    ProgressView()
                }
            }
            .tint(HearthColor.accent)
        }
        .frame(maxWidth: .infinity, minHeight: 600)
    }
}
