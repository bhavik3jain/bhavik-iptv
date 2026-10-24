import CatalogKit
import Core
import HouseholdKit
import SwiftUI

// CONTRACT — the app shell builds against these entry views. Their names and
// initialisers stay; what they draw is the feature implementation's to replace.
// Services come from the environment: CatalogService, HouseholdStore and
// ProfileSession (injected by the app), plus Core's \.play and \.openRoute.

/// Home for the current profile (mockup 02, HOME-1): Continue watching,
/// favorite channels with what's on, up next in shows, new movies. The header
/// holds the profile switcher, AirPlay and search; the app passes the
/// switcher in so Home never imports ProfilesFeature.
public struct HomeView<ProfileSwitcher: View>: View {
    let profileSwitcher: ProfileSwitcher

    public init(@ViewBuilder profileSwitcher: () -> ProfileSwitcher) {
        self.profileSwitcher = profileSwitcher()
    }

    public var body: some View {
        Text("Home").foregroundStyle(HearthColor.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity).hearthScreenBackground()
    }
}
