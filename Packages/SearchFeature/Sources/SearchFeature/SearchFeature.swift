import CatalogKit
import Core
import HouseholdKit
import SwiftUI

// CONTRACT — the app shell builds against these entry views. Their names and
// initialisers stay; what they draw is the feature implementation's to replace.
// Services come from the environment: CatalogService, HouseholdStore and
// ProfileSession (injected by the app), plus Core's \.play and \.openRoute.

/// One search across channels, the next 24 hours of the guide, movies and
/// shows from every source, grouped by type (SRCH-1…SRCH-3).
public struct SearchView: View {
    let initialQuery: String
    public init(initialQuery: String = "") { self.initialQuery = initialQuery }
    public var body: some View {
        Text("Search").foregroundStyle(HearthColor.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity).hearthScreenBackground()
    }
}
