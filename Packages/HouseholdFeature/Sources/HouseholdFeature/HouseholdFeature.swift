import CatalogKit
import Core
import HouseholdKit
import SourceKit
import SwiftUI

// CONTRACT — the app shell builds against these entry views: HouseholdView()
// (here), SourceEditorView(sourceID:) (SourceEditorView.swift) and
// StreamUsageSummaryView() (StreamUsageViews.swift). Their names and
// initialisers stay. Services come from the environment: CatalogService,
// HouseholdStore and ProfileSession (injected by the app), plus Core's
// \.openRoute. Also public, additive only: `SourceEditorSheet(sourceID:)`
// (the editor with its own navigation, for a sheet), `SourceMapping` (for the
// app's `catalog.setSources`) and `StreamLimit` (the limit the app's
// playback coordinator hands `HouseholdStore.streamUsage`, HH-6).

/// Household (mockup 05): members and roles with Invite, streams right now,
/// profiles, sources with status, and the sync switch.
///
/// One column on a phone and on iPhone Duo's inner display; two on an iPad
/// or Mac window wide enough for them, chosen by the width the screen
/// actually has rather than by device.
public struct HouseholdView: View {
    @Environment(HouseholdStore.self) private var store
    @Environment(ProfileSession.self) private var session
    @Environment(CatalogService.self) private var catalog
    @Environment(\.hearthLayout) private var layout

    @State private var width: CGFloat = 0

    public init() {}

    /// Two columns from here: each stays at least ~420 pt, the width the
    /// mockup's single column was drawn at.
    private static let twoColumnWidth: CGFloat = 880
    /// The single column never stretches wider than this on a big window.
    private static let readableWidth: CGFloat = 640
    /// Nor do the two columns, on a full-screen Mac.
    private static let twoColumnMaxWidth: CGFloat = 1180

    public var body: some View {
        Group {
            if session.canOpenSettings {
                content
            } else {
                // PRF-4: the app doesn't route a Kids profile here; this is
                // the backstop for a stale link.
                EmptyStateView(
                    systemName: "lock",
                    title: String(localized: "Ask a grown-up"),
                    message: String(localized: "Household settings aren't available on a Kids profile.")
                )
                .frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(Text("Household"))
        .largeNavigationTitle()
        .hearthScreenBackground()
        .task {
            // The members and role may have changed while away (HH-2).
            store.refreshShareStatus()
        }
        .task(id: catalog.revision) {
            recordProviderExpiry()
        }
    }

    private var content: some View {
        ScrollView {
            Group {
                if width >= Self.twoColumnWidth {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(spacing: 28) {
                            HouseholdCard()
                            StreamsRightNowSection()
                            SyncSection()
                        }
                        VStack(spacing: 28) {
                            ProfilesSection()
                            SourcesSection()
                        }
                    }
                    .frame(maxWidth: Self.twoColumnMaxWidth)
                } else {
                    VStack(spacing: 28) {
                        HouseholdCard()
                        StreamsRightNowSection()
                        ProfilesSection()
                        SourcesSection()
                        SyncSection()
                    }
                    .frame(maxWidth: Self.readableWidth)
                }
            }
            .padding(.horizontal, layout == .sidebar ? HearthMetrics.screenPadding : 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .refreshable {
            // Pull to refresh: every source again, now (SRC-6), and iCloud.
            // The spinner waits for iCloud only: a big portal's catalog
            // takes minutes, and its row shows the progress. The catalog
            // work runs on its own task, because the refresh task is
            // cancelled when this screen goes away and a cancelled refresh
            // stops the import.
            SourceRefresher.refresh(store.sources.map(\.id), in: catalog)
            await store.refreshFromCloud()
        }
    }

    /// Keeps each source's expiry in the household as the provider last said
    /// it (SRC-5), so every member's Household shows it before their own
    /// device has refreshed. Writes only a changed date: each write wakes
    /// every household device.
    private func recordProviderExpiry() {
        for source in store.sources {
            guard let change = SourceExpiry.update(record: source, account: catalog.account(sourceID: source.id)) else { continue }
            store.setSourceExpiry(change, for: source.id)
        }
    }
}
