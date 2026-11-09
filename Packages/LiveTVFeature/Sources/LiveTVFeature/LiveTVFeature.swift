import CatalogKit
import Core
import HouseholdKit
import PlayerKit
import SwiftUI

// CONTRACT — the app shell builds against these entry views. Their names and
// initialisers stay; what they draw is the feature implementation's to replace.
// Services come from the environment: CatalogService, HouseholdStore and
// ProfileSession (injected by the app), plus Core's \.play and \.openRoute.

/// Live TV (mockup 03): category chips with Favorites first, the timeline
/// guide (LIV-2) or a channel list (LIV-1), a programme card with Watch live
/// and From the start (LIV-3, LIV-4), channel search (LIV-6). In the sidebar
/// layout the toolbar also offers Multi-view.
public struct LiveTVView: View {
    let profileSwitcher: AnyView?

    public init() {
        profileSwitcher = nil
    }

    /// Live TV as the first screen, on iOS: in the phone layout the header
    /// holds the switcher the app passes in, so this never imports
    /// ProfilesFeature, then AirPlay and a search of everything, which are
    /// otherwise out of reach there. The sidebar layouts ignore it.
    public init<ProfileSwitcher: View>(@ViewBuilder profileSwitcher: () -> ProfileSwitcher) {
        self.profileSwitcher = AnyView(profileSwitcher())
    }

    public var body: some View {
        LiveTVScreen(profileSwitcher: profileSwitcher)
    }
}

/// One channel: now, next and the rest of its guide, with favorite and play.
public struct ChannelDetailView: View {
    let itemKey: String
    @Environment(\.hearthLayout) private var layout

    public init(itemKey: String) {
        self.itemKey = itemKey
    }

    public var body: some View {
        ChannelDetailScreen(itemKey: ItemKey(rawValue: itemKey))
            // The TV shows the wide layout as it is, its type scaled up.
            .hearthTVScaledText(layout == .tv)
    }
}

/// Two or four live tiles, one with sound; a tile the stream limits rule out
/// says why (PLY-9, MAC-5; mockup 07). Shown from Live TV's toolbar.
///
/// On its own it draws its "Live TV  Guide | Multi-view" title bar, and
/// Guide dismisses it; inside Live TV's sidebar layout the toolbar has that
/// control, and Guide switches back in place.
///
/// On the Apple TV it is the remote's own screen (`TVMultiViewContent`),
/// opened full screen from the guide or the player; `startingChannelKey` is
/// the channel to bring along, and Menu calls `onClose` as it leaves.
/// `startingChannelKeys` opens it with several, in tile order: another
/// device's multi-view carried on here (Continue on Apple TV).
public struct MultiViewScreen: View {
    let showsModePicker: Bool
    let onShowGuide: (() -> Void)?
    let startingChannelKeys: [String]

    @Environment(\.hearthLayout) private var layout

    public init() {
        self.init(showsModePicker: true, onShowGuide: nil)
    }

    public init(startingChannelKey: String?, onClose: @escaping () -> Void) {
        self.init(showsModePicker: true, onShowGuide: onClose, startingChannelKey: startingChannelKey)
    }

    public init(startingChannelKeys: [String], onClose: @escaping () -> Void) {
        self.init(showsModePicker: true, onShowGuide: onClose, startingChannelKeys: startingChannelKeys)
    }

    init(showsModePicker: Bool, onShowGuide: (() -> Void)?, startingChannelKey: String? = nil) {
        self.init(showsModePicker: showsModePicker, onShowGuide: onShowGuide, startingChannelKeys: startingChannelKey.map { [$0] } ?? [])
    }

    init(showsModePicker: Bool, onShowGuide: (() -> Void)?, startingChannelKeys: [String]) {
        self.showsModePicker = showsModePicker
        self.onShowGuide = onShowGuide
        self.startingChannelKeys = startingChannelKeys
    }

    public var body: some View {
        if layout == .tv {
            TVMultiViewContent(startingChannelKeys: startingChannelKeys, onClose: onShowGuide)
        } else {
            MultiViewContent(showsModePicker: showsModePicker, onShowGuide: onShowGuide)
        }
    }
}
