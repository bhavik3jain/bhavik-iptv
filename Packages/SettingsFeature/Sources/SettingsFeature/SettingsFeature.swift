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
/// (⌘,, MAC-4); a sheet on the phone; a sidebar section on the iPad.
///
/// A screen like every other route: host it inside a `NavigationStack` (it
/// pushes Acknowledgements onto that stack and sets its own title). It does
/// not bring a stack of its own — the app shell already wraps every host in
/// one (the phone's settings sheet, the iPad's sidebar tab, the Mac's
/// Settings window), and a stack nested in another breaks both. Nor does it
/// add Done: the sheet that presents it owns that button (the shell's route
/// sheet puts Done on every sheet), and a second one would sit beside it.
/// Kids profiles see a locked screen (PRF-4), though the app gates entry too.
public struct SettingsView: View {
    public init() {}

    @Environment(ProfileSession.self) private var session
    @Environment(\.hearthLayout) private var layout

    public var body: some View {
        Group {
            if session.canOpenSettings {
                SettingsForm()
            } else {
                SettingsLockedView()
            }
        }
        .navigationTitle(Text("Settings", bundle: .module))
        .inlineNavigationTitle()
        // A tab on the TV: the tab bar already names it.
        .toolbar(layout == .tv ? .hidden : .automatic, for: .automatic)
        .tint(HearthColor.accent)
        // The Mac's Settings window is its own scene, outside the main
        // window's root where the app sets the layout; derive it here too so
        // Acknowledgements lays out for a window, not a phone. Inside a sheet
        // this reads the sheet's own size class, which is what it should use.
        .hearthLayoutFromSizeClass()
        // Hearth is dark only. The Mac's Settings window is its own scene and
        // doesn't inherit the main window's scheme, so ask for it here too;
        // otherwise its pickers and toggles would draw in light mode.
        .preferredColorScheme(.dark)
        // The Mac's Settings window sizes itself from this; a sheet or a
        // sidebar section proposes its own size and ignores it.
        .frame(idealWidth: 560, idealHeight: 700)
    }
}

/// Licences: VLCKit (LGPL, with the source offer), the fonts (SIL OFL 1.1).
///
/// A plain screen with a navigation title: push it from Settings (or show it
/// anywhere inside a `NavigationStack`).
public struct AcknowledgementsView: View {
    @Environment(\.hearthLayout) private var layout

    public init() {}

    public var body: some View {
        AcknowledgementsScreen()
            .hearthTVScaledText(layout == .tv)
    }
}

/// What a Kids profile sees if it reaches Settings anyway (PRF-4).
private struct SettingsLockedView: View {
    var body: some View {
        ScrollView {
            EmptyStateView(
                systemName: "lock.fill",
                title: String(localized: "Settings are locked", bundle: .module),
                message: String(localized: "Kids profiles can't change settings. Switch to a grown-up's profile to open them.", bundle: .module)
            )
            .padding(.top, 60)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .hearthScreenBackground()
    }
}
