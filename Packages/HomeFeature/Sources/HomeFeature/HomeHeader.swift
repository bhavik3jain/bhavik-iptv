import Core
import PlayerKit
import SwiftUI

/// Home's top (mockup 02): the profile switcher the app passes in, then
/// AirPlay and Search as round buttons; under that row, the time of day and
/// what the profile has saved ("6 favorite channels · 3 movies on My List").
/// The two buttons share PlayerKit's raised circle so they read as a pair.
struct HomeHeader<ProfileSwitcher: View>: View {
    let profileSwitcher: ProfileSwitcher
    /// Nil shows the switcher. Otherwise the switcher lives elsewhere (the
    /// Mac's sidebar) and this greeting stands in its place.
    let greeting: String?
    /// "Good evening", under a switcher that already shows the name.
    var salutation: String?
    /// `HomeSummary`'s line; nil with nothing saved.
    var summary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row
            if salutation != nil || summary != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let salutation {
                        Text(salutation)
                            .font(.hearthDisplay(24, weight: .semibold, relativeTo: .title2))
                            .tracking(HearthMetrics.titleTracking)
                            .foregroundStyle(HearthColor.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if let summary {
                        Text(summary)
                            .font(.hearthFootnote)
                            .foregroundStyle(HearthColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            if let greeting {
                Text(greeting)
                    .font(.hearthLargeTitle)
                    .foregroundStyle(HearthColor.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
            } else {
                profileSwitcher
            }
            Spacer(minLength: 8)
            AirPlayRouteButton()
            NavigationLink(value: HearthRoute.search(query: "")) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(HearthColor.textPrimary)
                    .frame(width: HearthMetrics.minimumHitTarget, height: HearthMetrics.minimumHitTarget)
                    .background(Circle().fill(HearthColor.surfaceRaised))
                    .contentShape(Circle())
            }
            .buttonStyle(.hearthTile)
            .accessibilityLabel(Text("Search", bundle: .module))
        }
        .frame(minHeight: HearthMetrics.minimumHitTarget)
    }
}
