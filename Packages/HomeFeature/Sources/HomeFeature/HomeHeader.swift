import Core
import PlayerKit
import SwiftUI

/// Home's top row (mockup 02): the profile switcher the app passes in, then
/// AirPlay and Search as round buttons. The two share PlayerKit's raised
/// circle so they read as a pair.
struct HomeHeader<ProfileSwitcher: View>: View {
    let profileSwitcher: ProfileSwitcher
    /// No switcher here (the Mac keeps it in the sidebar): say where we are.
    let showsTitle: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showsTitle {
                Text("Home", bundle: .module)
                    .font(.hearthLargeTitle)
                    .foregroundStyle(HearthColor.textPrimary)
                    .lineLimit(1)
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
