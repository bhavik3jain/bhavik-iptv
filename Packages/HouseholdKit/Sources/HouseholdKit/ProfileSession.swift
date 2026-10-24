import Foundation
import Observation

/// Which profile is watching on this device (PRF-2, PRF-8, PRF-9). The choice
/// is remembered in this device's UserDefaults only, never synced.
///
/// PUBLIC API IS A CONTRACT. Add to it; don't change or remove.
@MainActor
@Observable
public final class ProfileSession {
    public init(store: HouseholdStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    public let store: HouseholdStore
    let defaults: UserDefaults

    /// Nil while "Who's watching?" is showing.
    public private(set) var currentProfile: ProfileRecord?

    /// A profile this device always opens (PRF-2), or nil.
    public var alwaysOpenProfileID: UUID?

    /// True when the gate should show: more than one profile, none chosen,
    /// and no always-open profile.
    public var needsProfileSelection: Bool { currentProfile == nil }

    /// Picks the profile at launch: the always-open one, else the only one,
    /// else none (show the gate). Never the last-used one when there are
    /// several — the gate asks, as Netflix does.
    public func restore() {}

    /// Switches to a profile. The caller has already checked its PIN
    /// (`store.verifyPIN`). Leaving a Guest clears what it touched (PRF-5).
    public func select(_ profile: ProfileRecord) {
        currentProfile = profile
    }

    /// Back to "Who's watching?". Leaving a Kids profile needs an adult's PIN,
    /// checked by the caller (PRF-4).
    public func signOut() {
        currentProfile = nil
    }

    /// Re-reads the current profile from the store after an edit or a sync.
    public func refresh() {}

    public var isKids: Bool { currentProfile?.kind == .kids }
    public var isGuest: Bool { currentProfile?.kind == .guest }

    /// Kids profiles can't open settings or Household (PRF-4).
    public var canOpenSettings: Bool { !isKids }

    /// Whether this device's member may manage sources and profiles (SRC-8).
    public var canManageHousehold: Bool { store.household.currentRole.canManage && !isKids && !isGuest }
}
