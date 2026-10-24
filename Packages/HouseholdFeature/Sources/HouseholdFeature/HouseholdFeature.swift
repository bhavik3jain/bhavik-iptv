import CatalogKit
import Core
import HouseholdKit
import SourceKit
import SwiftUI

// CONTRACT — the app shell builds against these entry views. Their names and
// initialisers stay; what they draw is the feature implementation's to replace.
// Services come from the environment: CatalogService, HouseholdStore and
// ProfileSession (injected by the app), plus Core's \.play and \.openRoute.

/// Household (mockup 05): members and roles with Invite, streams right now,
/// profiles, sources with status, and the sync switches.
public struct HouseholdView: View {
    public init() {}
    public var body: some View {
        Text("Household").foregroundStyle(HearthColor.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity).hearthScreenBackground()
    }
}

/// Add (nil) or edit a source: Stalker portal URL and MAC with advanced
/// fields, Xtream login, or M3U playlist; Test before saving (SRC-1…SRC-4).
public struct SourceEditorView: View {
    let sourceID: UUID?
    public init(sourceID: UUID?) { self.sourceID = sourceID }
    public var body: some View {
        Text("Source editor").foregroundStyle(HearthColor.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity).hearthScreenBackground()
    }
}

/// Each source's streams in use, as bars ("Provider B  2 of 2 · This Mac and
/// Anya's iPad"): the foot of the Mac sidebar (MAC-1).
public struct StreamUsageSummaryView: View {
    public init() {}
    public var body: some View {
        EmptyView()
    }
}
