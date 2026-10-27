import Core
import HouseholdKit
import SwiftUI

// CONTRACT — the app shell builds against these entry views. Their names and
// initialisers stay; what they draw is the feature implementation's to replace.
// Services come from the environment: CatalogService, HouseholdStore and
// ProfileSession (injected by the app), plus Core's \.play and \.openRoute.

/// "Who's watching?" (mockup 01, PRF-2): the household's profiles, Add
/// profile, who is streaming now, Manage household. Choosing a profile (after
/// its PIN, PRF-3) calls `ProfileSession.select`.
public struct WhoIsWatchingView: View {
    let onManageHousehold: () -> Void
    @Environment(\.hearthLayout) private var layout

    public init(onManageHousehold: @escaping () -> Void = {}) {
        self.onManageHousehold = onManageHousehold
    }

    public var body: some View {
        if layout == .tv {
            WhoIsWatchingTVScreen(onManageHousehold: onManageHousehold)
        } else {
            WhoIsWatchingScreen(onManageHousehold: onManageHousehold)
        }
    }
}

/// The current profile's avatar, name and a chevron; a menu of the other
/// profiles, Manage household and Settings (PRF-8). Home's header on the
/// phone, the top of the Mac sidebar (`style: .sidebar`).
public struct ProfileSwitcherMenu: View {
    public enum Style: Sendable { case header, sidebar }
    let style: Style

    public init(style: Style = .header) {
        self.style = style
    }

    public var body: some View {
        ProfileSwitcher(style: style)
    }
}

/// Create (nil) or edit a profile: name, avatar colour and symbol, kind, PIN,
/// Kids categories, hidden categories and sources (PRF-1, PRF-3, PRF-4, PRF-6).
///
/// Pushed by the app (`HearthRoute.profileEditor`) it shows Save and relies
/// on the back button to discard; the profile gate presents it in a sheet of
/// its own with Cancel and Save.
public struct ProfileEditorView: View {
    let profileID: UUID?

    public init(profileID: UUID?) {
        self.profileID = profileID
    }

    public var body: some View {
        ProfileEditorScreen(profileID: profileID)
    }
}

/// A 4-digit PIN pad. `onSubmit` returns whether the PIN was right; a wrong
/// one shakes and clears.
public struct PINEntryView: View {
    let title: String
    let onSubmit: (String) -> Bool
    let onCancel: () -> Void

    public init(title: String, onSubmit: @escaping (String) -> Bool, onCancel: @escaping () -> Void) {
        self.title = title
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    public var body: some View {
        PINPad(
            title: title,
            onSubmit: { onSubmit($0) ? .accepted : .rejected },
            onCancel: onCancel
        ) {
            PINLockGlyph()
        }
        .hearthScreenBackground()
    }
}
