import Core
import HouseholdKit
import SwiftUI

/// The Continue watching hero (HOME-1, mockup 02). Resume plays from the
/// saved point; anywhere else on the card opens the movie or the show.
///
/// In the sidebar layout, with room to spare, the poster stands beside the
/// card instead of being stretched behind it: a portrait poster blown up to a
/// wide card is mostly blur.
struct ContinueWatchingHero: View {
    let item: ContinueItem
    let showsSidePoster: Bool
    /// The profile whose progress the menu may change; nil for a Guest.
    let profileID: UUID?

    @Environment(HouseholdStore.self) private var store
    @Environment(\.play) private var play
    @Environment(\.openRoute) private var openRoute
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// HeroCard's own minimum height, so the side poster matches it.
    @ScaledMetric(relativeTo: .title) private var heroHeight: CGFloat = 212

    var body: some View {
        if showsSidePoster, !dynamicTypeSize.isAccessibilitySize, let posterURL = item.posterURL {
            HStack(alignment: .center, spacing: HearthMetrics.itemSpacing) {
                card(backdropURL: item.backdropURL)
                Button {
                    openRoute(item.route)
                } label: {
                    ArtworkView(url: posterURL, title: item.title)
                        .frame(width: heroHeight * 2 / 3, height: heroHeight)
                        .clipShape(RoundedRectangle(cornerRadius: HearthMetrics.heroRadius, style: .continuous))
                }
                .buttonStyle(.hearthTile)
                .accessibilityLabel(Text(item.title))
                .accessibilityHint(Text(detailsTitle))
            }
        } else {
            card(backdropURL: item.backdropURL ?? item.posterURL)
        }
    }

    private func card(backdropURL: URL?) -> some View {
        HeroCard(
            title: item.title,
            subtitle: item.subtitle,
            progress: item.progress,
            remainingText: item.remainingText,
            artworkURL: backdropURL
        ) {
            play(item.playIntent)
        }
        // The Resume button inside keeps its own tap; this takes the rest.
        .contentShape(RoundedRectangle(cornerRadius: HearthMetrics.heroRadius, style: .continuous))
        .onTapGesture { openRoute(item.route) }
        .contextMenu { menu }
        // VoiceOver can't reach a tap gesture or actions on HeroCard's
        // container, so the card is one element: it reads like the card,
        // activating it resumes (the card's own button), and "Go to show"
        // is an action — the same two things a sighted tap can do.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Resumes playing", bundle: .module))
        .accessibilityAction { play(item.playIntent) }
        .accessibilityAction(named: Text(detailsTitle)) { openRoute(item.route) }
    }

    /// "Continue watching, Salt & Signal, S2 · E5 — The Lighthouse Keeper,
    /// 31 min left".
    private var accessibilityLabel: String {
        [String(localized: "Continue watching", bundle: .module), item.title, item.subtitle, item.remainingText]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    @ViewBuilder
    private var menu: some View {
        Button {
            play(item.playIntent)
        } label: {
            Label(String(localized: "Resume", bundle: .module), systemImage: "play.fill")
        }
        Button {
            openRoute(item.route)
        } label: {
            Label(detailsTitle, systemImage: "info.circle")
        }
        if let profileID {
            Divider()
            Button {
                store.setWatched(true, profileID: profileID, itemKey: item.itemKey)
            } label: {
                Label(String(localized: "Mark as watched", bundle: .module), systemImage: "checkmark.circle")
            }
            // Unwatching forgets the position, which is what takes an item
            // off Continue watching.
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
