import CatalogKit
import Core
import HouseholdKit
import SwiftUI

/// Home on the iPhone, iPad and iPhone Duo: Live TV and nothing else (the
/// owner's call, 2026-11-01). The app passes the Live TV screen in, so Home
/// never imports LiveTVFeature; this puts a first run's states in front of it,
/// because a guide with no channels can't add a source, show an import's
/// progress or offer another try. Once anything has imported, it's only Live TV.
///
/// The phone's header holds the switcher while a state shows, so Household and
/// Settings stay in reach; in the sidebar layout they're in the sidebar.
public struct LiveHomeView<ProfileSwitcher: View, LiveTV: View>: View {
    let profileSwitcher: ProfileSwitcher
    let liveTV: LiveTV

    public init(@ViewBuilder profileSwitcher: () -> ProfileSwitcher, @ViewBuilder liveTV: () -> LiveTV) {
        self.profileSwitcher = profileSwitcher()
        self.liveTV = liveTV()
    }

    @Environment(CatalogService.self) private var catalog
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(\.hearthLayout) private var layout

    public var body: some View {
        let status = HomeStatus.make(catalogSourceIDs: catalog.sources.map(\.id), records: store.sources, refreshStates: catalog.refreshStates)
        if status == .ready {
            liveTV
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: HearthMetrics.sectionSpacing) {
                    if layout == .compact {
                        HomeHeader(profileSwitcher: profileSwitcher, greeting: nil)
                            .padding(.horizontal, HearthMetrics.screenPadding)
                    }
                    HomeStartState(status: status, canManageHousehold: session.canManageHousehold)
                        .padding(.horizontal, HearthMetrics.screenPadding)
                        .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length * 0.7 }
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .hearthScreenBackground()
            .navigationTitle(Text("Live TV", bundle: .module))
            .inlineNavigationTitle()
            .toolbar(layout == .compact ? .hidden : .automatic, for: .automatic)
        }
    }
}
