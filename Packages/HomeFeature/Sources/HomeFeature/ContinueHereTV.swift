import CatalogKit
import Core
import HouseholdKit
import SwiftUI

// "Continue from <device>" on the Apple TV's Home (docs/designs/
// continue-on-tv.md): what another device of the household is playing for
// this profile right now — a channel, a multi-view, a movie or episode open
// in its player — as cards above Continue watching. "Continue here" carries
// it on through the app's `\.continueHere`, which ends the other device's
// rows so it stops and its streams are free.

/// One offer as a card: what the TV draws and what it asks the app for.
struct ContinueOfferCard: Equatable, Identifiable {
    enum Artwork: Equatable {
        case channel(name: String, number: Int?, logoURL: URL?, programme: String?, timing: ProgrammeTiming?)
        /// Multi-view: each tile's channel.
        case channels([Face])
        case poster(title: String, url: URL?, progress: Double?)
    }

    struct Face: Equatable, Identifiable {
        var id: String
        var name: String
        var logoURL: URL?
    }

    var id: String
    /// "On Bhavik's iPhone now".
    var eyebrow: String
    var title: String
    var subtitle: String?
    var artwork: Artwork
    var request: ContinueHereRequest
    /// The movie or episode it plays, so the hero doesn't repeat it.
    var videoItemKey: String?
}

/// What the cards read from the catalog and the household: closures, so the
/// mapping is tested without either.
struct ContinueOfferLookup {
    var channel: (String) -> CatalogChannel?
    var programmeNow: (CatalogChannel) -> CatalogProgramme?
    var movie: (String) -> CatalogMovie?
    var series: (String) -> CatalogSeries?
    var episode: (String) -> CatalogEpisode?
    var progress: (String) -> ProgressRecord?
}

extension ContinueOfferLookup {
    @MainActor
    static func live(catalog: CatalogService, store: HouseholdStore, profileID: UUID, at date: Date) -> ContinueOfferLookup {
        ContinueOfferLookup(
            channel: { catalog.channel(ItemKey(rawValue: $0)) },
            programmeNow: { catalog.nowAndNext(for: $0, at: date).now },
            movie: { catalog.movie(ItemKey(rawValue: $0)) },
            series: { catalog.seriesItem(ItemKey(rawValue: $0)) },
            episode: { catalog.episode(ItemKey(rawValue: $0)) },
            progress: { store.progress(profileID: profileID, itemKey: $0) }
        )
    }
}

enum ContinueOfferCards {
    /// Two devices playing for one profile at once is already rare.
    static let limit = 3

    /// A card for each offer this device can play: its channels are in this
    /// device's catalog for this profile, or the movie is, or the episode's
    /// show is (as the player needs). The rest are left out.
    static func cards(_ offers: [ContinueOffer], lookup: ContinueOfferLookup, at date: Date) -> [ContinueOfferCard] {
        Array(offers.compactMap { card($0, lookup: lookup, at: date) }.prefix(limit))
    }

    static func card(_ offer: ContinueOffer, lookup: ContinueOfferLookup, at date: Date) -> ContinueOfferCard? {
        let eyebrow = String(localized: "On \(offer.deviceName) now", bundle: .module, comment: "Over a card on the Apple TV's Home: the device playing it, as named by the household")
        switch offer.content {
        case .channel(let key):
            guard let channel = lookup.channel(key) else { return nil }
            let now = lookup.programmeNow(channel)
            return ContinueOfferCard(
                id: offer.id,
                eyebrow: eyebrow,
                title: channel.name,
                subtitle: now?.title,
                artwork: .channel(
                    name: channel.name,
                    number: channel.number,
                    logoURL: channel.logoURL,
                    programme: now?.title,
                    timing: now.map { ProgrammeTiming(start: $0.start, end: $0.end) }
                ),
                request: ContinueHereRequest(
                    content: .play(PlayIntent(itemKey: key, kind: .live, title: channel.name, subtitle: now?.title, artworkURL: channel.logoURL)),
                    endingPlaybackIDs: offer.playbackIDs,
                    deviceName: offer.deviceName
                ),
                videoItemKey: nil
            )

        case .multiView(let keys):
            let channels = keys.compactMap(lookup.channel)
            guard !channels.isEmpty else { return nil }
            return ContinueOfferCard(
                id: offer.id,
                eyebrow: eyebrow,
                title: String(localized: "Multi-view", bundle: .module),
                subtitle: ListFormatter.localizedString(byJoining: channels.map(\.name)),
                artwork: .channels(channels.map { ContinueOfferCard.Face(id: $0.key.rawValue, name: $0.name, logoURL: $0.logoURL) }),
                request: ContinueHereRequest(
                    content: .multiView(channelKeys: channels.map(\.key.rawValue)),
                    endingPlaybackIDs: offer.playbackIDs,
                    deviceName: offer.deviceName
                ),
                videoItemKey: nil
            )

        case .video(let key):
            let itemKey = ItemKey(rawValue: key)
            let progress = lookup.progress(key)
            switch itemKey.kind {
            case .movie:
                guard let movie = lookup.movie(key) else { return nil }
                let duration = (progress?.duration ?? 0) > 0 ? progress?.duration : movie.duration
                return videoCard(
                    offer, eyebrow: eyebrow, key: key, kind: .movie,
                    title: movie.name, subtitle: remaining(progress, duration: duration) ?? ContinueItem.movieSubtitle(movie),
                    posterURL: movie.posterURL, fraction: fraction(progress, duration: duration)
                )
            case .episode:
                guard let seriesKey = itemKey.seriesKey, let code = itemKey.seasonAndEpisode,
                      let series = lookup.series(seriesKey.rawValue) else { return nil }
                let episode = lookup.episode(key)
                let duration = (progress?.duration ?? 0) > 0 ? progress?.duration : episode?.duration
                let line = EpisodeLine.subtitle(season: code.season, number: code.number, title: episode?.title)
                let subtitle = [line, remaining(progress, duration: duration)].compactMap { $0 }.joined(separator: " · ")
                return videoCard(
                    offer, eyebrow: eyebrow, key: key, kind: .episode,
                    title: series.name, subtitle: subtitle,
                    posterURL: episode?.posterURL ?? series.posterURL, fraction: fraction(progress, duration: duration),
                    playSubtitle: line
                )
            case .channel, .series, nil:
                return nil
            }
        }
    }

    /// The hero shows the movie or episode a card already offers: the card
    /// says more (where it's playing, and that it'll stop there), so the hero
    /// steps aside rather than offer it twice.
    static func heroIsCovered(heroItemKey: String?, by cards: [ContinueOfferCard]) -> Bool {
        guard let heroItemKey else { return false }
        return cards.contains { $0.videoItemKey == heroItemKey }
    }

    private static func videoCard(
        _ offer: ContinueOffer, eyebrow: String, key: String, kind: PlayIntent.Kind,
        title: String, subtitle: String?, posterURL: URL?, fraction: Double?, playSubtitle: String? = nil
    ) -> ContinueOfferCard {
        ContinueOfferCard(
            id: offer.id,
            eyebrow: eyebrow,
            title: title,
            subtitle: subtitle,
            artwork: .poster(title: title, url: posterURL, progress: fraction),
            request: ContinueHereRequest(
                // No start position: the player starts from the profile's
                // progress, and the app moves on to the other device's
                // position if it arrives as that device stops.
                content: .play(PlayIntent(itemKey: key, kind: kind, title: title, subtitle: playSubtitle, artworkURL: posterURL)),
                endingPlaybackIDs: offer.playbackIDs,
                deviceName: offer.deviceName
            ),
            videoItemKey: key
        )
    }

    private static func fraction(_ progress: ProgressRecord?, duration: TimeInterval?) -> Double? {
        guard let progress, let duration, duration > 0, progress.position > 0 else { return nil }
        return min(max(progress.position / duration, 0), 1)
    }

    private static func remaining(_ progress: ProgressRecord?, duration: TimeInterval?) -> String? {
        guard let progress, let duration, duration > 0, progress.position > 0 else { return nil }
        return HearthFormat.remaining(max(duration - progress.position, 0))
    }
}

// MARK: - Cards

/// The offers, one wide card each, above Continue watching.
struct TVContinueOffers: View {
    let cards: [ContinueOfferCard]
    var focus: FocusState<HomeTVFocus?>.Binding
    let onHide: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            ForEach(cards) { card in
                TVContinueOfferCardView(card: card, focus: focus, onHide: { onHide(card.id) })
            }
        }
    }
}

private struct TVContinueOfferCardView: View {
    let card: ContinueOfferCard
    var focus: FocusState<HomeTVFocus?>.Binding
    let onHide: () -> Void

    @Environment(\.continueHere) private var continueHere

    var body: some View {
        HStack(alignment: .center, spacing: 48) {
            artwork
                .frame(width: 420)
                .clipShape(RoundedRectangle(cornerRadius: HearthTVMetrics.cardRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text(card.eyebrow)
                } icon: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                }
                .font(.hearthText(22, weight: .semibold, relativeTo: .caption))
                .textCase(.uppercase)
                .tracking(2)
                .foregroundStyle(HearthColor.accent)
                Text(card.title)
                    .font(.hearthDisplay(44, weight: .semibold, relativeTo: .title))
                    .tracking(-0.6)
                    .foregroundStyle(HearthColor.textPrimary)
                    .lineLimit(2)
                if let subtitle = card.subtitle {
                    Text(subtitle)
                        .font(.hearthTVCallout)
                        .foregroundStyle(HearthColor.textSecondary)
                        .lineLimit(2)
                }
                Button {
                    continueHere(card.request)
                } label: {
                    Label(String(localized: "Continue here", bundle: .module), systemImage: "play.fill")
                }
                .buttonStyle(.hearthTV(isProminent: true))
                .focused(focus, equals: .continueOffer(card.id))
                .contextMenu {
                    Button(role: .destructive, action: onHide) {
                        Label(String(localized: "Not now", bundle: .module), systemImage: "xmark.circle")
                    }
                }
                .accessibilityHint(Text("Plays it here and stops it on \(card.request.deviceName)", bundle: .module))
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(HearthColor.surface)
        )
        // One target: down from the profile menu at the far right still lands
        // on the button.
        .hearthFocusSection()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var artwork: some View {
        switch card.artwork {
        case .channel(let name, let number, let logoURL, let programme, let timing):
            TimelineView(.everyMinute) { context in
                TVChannelArtwork(name: name, number: number, logoURL: logoURL, programmeTitle: programme, timing: timing, now: context.date)
            }
        case .channels(let faces):
            TVMultiViewFaces(faces: faces)
        case .poster(let title, let url, let progress):
            TVPosterArtwork(title: title, url: url, progress: progress, aspectRatio: 16.0 / 9.0)
        }
    }
}

/// Multi-view's tiles as a grid of their channels' logos.
private struct TVMultiViewFaces: View {
    let faces: [ContinueOfferCard.Face]

    var body: some View {
        let columns = faces.count > 2 ? 2 : faces.count
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: max(columns, 1)), spacing: 10) {
            ForEach(faces) { face in
                VStack(spacing: 10) {
                    ChannelLogo(name: face.name, url: face.logoURL, size: faces.count > 2 ? 52 : 72)
                    Text(face.name)
                        .font(.hearthText(20, weight: .medium, relativeTo: .caption))
                        .foregroundStyle(HearthColor.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: faces.count > 2 ? 102 : 215)
                .background(HearthColor.surfaceRaised)
            }
        }
        .frame(minHeight: 225)
        .background(HearthColor.surface)
        .accessibilityHidden(true)
    }
}
