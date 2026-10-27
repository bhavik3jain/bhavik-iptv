import Core
import SwiftUI

/// Downloads (DL-1) arrive in Phase 4. Until then the tab says so plainly
/// rather than showing a list that can never fill.
struct DownloadsScreen: View {
    @Environment(\.hearthLayout) private var layout

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LibraryTitleRow(title: String(localized: "Downloads", bundle: .module)) { EmptyView() }
                    .padding(.horizontal, libraryGutter(layout))
                    .padding(.top, 4)
                EmptyStateView(
                    systemName: "arrow.down.circle",
                    title: String(localized: "Downloads arrive in a later version", bundle: .module),
                    message: String(localized: "You'll be able to save movies and episodes to watch offline, when the provider sends them as files rather than live streams. They'll stay on this device only.", bundle: .module)
                )
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
            }
            .frame(maxWidth: libraryMaxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollRevealedTitle(String(localized: "Downloads", bundle: .module))
        .hearthScreenBackground()
    }
}
