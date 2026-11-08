import Core
import SwiftUI

// Home's friendly empty states: what a section is for and how to fill it,
// in place of the section (HomePlan decides which show).

/// A round icon, a title and a line of how-to, as a card. With a route it's a
/// link (and shows a chevron); without one it only explains.
struct HomeHintCard: View {
    let systemName: String
    let title: String
    let message: String
    var route: HearthRoute?
    var hint: String?

    var body: some View {
        if let route {
            NavigationLink(value: route) { card(showsChevron: true) }
                .buttonStyle(.hearthTile)
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text(hint ?? ""))
        } else {
            card(showsChevron: false)
                .accessibilityElement(children: .combine)
        }
    }

    private func card(showsChevron: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(HearthColor.accent)
                .frame(width: HearthMetrics.minimumHitTarget, height: HearthMetrics.minimumHitTarget)
                .background(Circle().fill(HearthColor.surfaceRaised))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.hearthHeadline)
                    .foregroundStyle(HearthColor.textPrimary)
                Text(message)
                    .font(.hearthFootnote)
                    .foregroundStyle(HearthColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HearthColor.glyphMuted)
                    .accessibilityHidden(true)
            }
        }
        .hearthCard(padding: 16)
        .contentShape(RoundedRectangle(cornerRadius: HearthMetrics.cardRadius, style: .continuous))
    }
}

/// My List is empty: a "My List" header over how to add to it. Movies and
/// Shows are tabs a feature can't open, so the card only explains.
struct MyListHintSection: View {
    let gutter: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(String(localized: "My List", bundle: .module))
            HomeHintCard(
                systemName: "heart.text.square",
                title: String(localized: "Keep movies and shows here", bundle: .module),
                message: String(localized: "Tap the heart on a poster, or Add to My List on a movie or show, and it shows up here.", bundle: .module)
            )
        }
        .padding(.horizontal, gutter)
    }
}

/// No favorites at all (a new profile): what Home is for and where to start,
/// in one card rather than two empty sections.
struct HomeWelcomeCard: View {
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        EmptyStateView(
            systemName: "heart",
            title: String(localized: "Make Home yours", bundle: .module),
            message: String(localized: "Favorite channels show here with what's on now, beside the movies and shows on your My List. Tap the heart on a channel in the guide, or on any poster, to start.", bundle: .module),
            actionTitle: String(localized: "Open the guide", bundle: .module)
        ) {
            openRoute(.liveGuide)
        }
        .hearthCard(padding: 0)
    }
}
