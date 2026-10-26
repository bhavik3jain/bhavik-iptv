import Core
import PlayerKit
import SwiftUI

/// Home's top row (mockup 02): the profile switcher the app passes in, then
/// AirPlay and Search as round buttons. The two share PlayerKit's raised
/// circle so they read as a pair.
struct HomeHeader<ProfileSwitcher: View>: View {
    let profileSwitcher: ProfileSwitcher
    /// Nil shows the switcher. Otherwise the switcher lives elsewhere (the
    /// Mac's sidebar) and this greeting stands in its place.
    let greeting: String?

    var body: some View {
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
