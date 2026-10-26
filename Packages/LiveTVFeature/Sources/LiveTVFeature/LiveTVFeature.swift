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
    public init() {}

    public var body: some View {
        LiveTVScreen()
    }
}

/// One channel: now, next and the rest of its guide, with favorite and play.
public struct ChannelDetailView: View {
    let itemKey: String

    public init(itemKey: String) {
        self.itemKey = itemKey
    }

    public var body: some View {
        ChannelDetailScreen(itemKey: ItemKey(rawValue: itemKey))
    }
}

/// Two or four live tiles, one with sound; a tile the stream limits rule out
/// says why (PLY-9, MAC-5; mockup 07). Shown from Live TV's toolbar.
///
/// On its own it draws its "Live TV  Guide | Multi-view" title bar, and
/// Guide dismisses it; inside Live TV's sidebar layout the toolbar has that
/// control, and Guide switches back in place.
public struct MultiViewScreen: View {
    let showsModePicker: Bool
    let onShowGuide: (() -> Void)?

    public init() {
        self.init(showsModePicker: true, onShowGuide: nil)
    }

    init(showsModePicker: Bool, onShowGuide: (() -> Void)?) {
        self.showsModePicker = showsModePicker
        self.onShowGuide = onShowGuide
    }

    public var body: some View {
        MultiViewContent(showsModePicker: showsModePicker, onShowGuide: onShowGuide)
    }
}
