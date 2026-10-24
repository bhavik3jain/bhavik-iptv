import CatalogKit
import Core
import HouseholdKit
import SwiftUI

// CONTRACT — the app shell builds against these entry views. Their names and
// initialisers stay; what they draw is the feature implementation's to replace.
// Services come from the environment: CatalogService, HouseholdStore and
// ProfileSession (injected by the app), plus Core's \.play and \.openRoute.

/// Settings: playback preferences, this device's always-open profile,
/// refresh, storage, about and acknowledgements. Its own window on the Mac
/// (⌘,, MAC-4); a sheet on the phone.
public struct SettingsView: View {
    public init() {}
    public var body: some View {
        Text("Settings").foregroundStyle(HearthColor.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity).hearthScreenBackground()
    }
}

/// Licences: VLCKit (LGPL, with the source offer), the fonts (SIL OFL 1.1).
public struct AcknowledgementsView: View {
    public init() {}
    public var body: some View {
        Text("Acknowledgements").foregroundStyle(HearthColor.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity).hearthScreenBackground()
    }
}
