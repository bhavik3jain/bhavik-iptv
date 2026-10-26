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
///
/// Self-contained: it brings its own `NavigationStack` (for Acknowledgements),
/// so present it — a sheet, or the Mac's `Settings` scene — rather than
/// pushing it onto another stack. Presented as a sheet it shows Done. Its
/// ideal size suits the Mac's Settings window; a sheet ignores it. Kids
/// profiles see a locked screen (PRF-4), though the app gates entry too.
public struct SettingsView: View {
    public init() {}

    @Environment(ProfileSession.self) private var session
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            Group {
                if session.canOpenSettings {
                    SettingsForm()
                } else {
                    SettingsLockedView()
                }
            }
            .navigationTitle(Text("Settings", bundle: .module))
            .inlineNavigationTitle()
            .toolbar {
                if isPresented {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Text("Done", bundle: .module)
                        }
                    }
                }
            }
        }
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
        .frame(idealWidth: 560, idealHeight: 700)
    }
}

/// Licences: VLCKit (LGPL, with the source offer), the fonts (SIL OFL 1.1).
///
/// A plain screen with a navigation title: push it from Settings (or show it
/// anywhere inside a `NavigationStack`).
public struct AcknowledgementsView: View {
    public init() {}

    public var body: some View {
        AcknowledgementsScreen()
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
