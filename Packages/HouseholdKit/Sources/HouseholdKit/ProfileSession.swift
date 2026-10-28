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
        self.alwaysOpenProfileID = Self.readID(Keys.alwaysOpen, from: defaults)
    }

    public let store: HouseholdStore
    let defaults: UserDefaults

    /// This device's UserDefaults keys. Profile ids only — never a name, a
    /// login or anything else about the household.
    enum Keys {
        static let alwaysOpen = "Hearth.ProfileSession.alwaysOpenProfileID"
        static let lastUsed = "Hearth.ProfileSession.lastUsedProfileID"
    }

    /// Nil while "Who's watching?" is showing.
    public private(set) var currentProfile: ProfileRecord?

    /// A profile this device always opens (PRF-2), or nil. Kept in this
    /// device's UserDefaults; setting it saves it.
    public var alwaysOpenProfileID: UUID? {
        didSet {
            guard alwaysOpenProfileID != oldValue else { return }
            Self.writeID(alwaysOpenProfileID, Keys.alwaysOpen, to: defaults)
        }
    }

    /// The profile last picked on this device (PRF-9), for the gate to mark.
    /// Never used to skip the gate when there are several profiles. Guests
    /// are never remembered (PRF-5).
    public var lastUsedProfileID: UUID? { Self.readID(Keys.lastUsed, from: defaults) }

    /// True after Switch Profile: `refresh` then leaves the gate up rather
    /// than picking a profile again.
    @ObservationIgnored private var choseGate = false

    /// The profile Switch Profile left, while the gate it opened is up: the
    /// TV's Menu button goes back to it (through its PIN, if it has one).
    /// Nil at launch and once a profile is chosen.
    public private(set) var previousProfileID: UUID?

    /// True when the gate should show: more than one profile, none chosen,
    /// and no always-open profile.
    public var needsProfileSelection: Bool { currentProfile == nil }

    /// Picks the profile at launch: the always-open one, else the only one,
    /// else none (show the gate). Never the last-used one when there are
    /// several — the gate asks, as Netflix does.
    ///
    /// The only profile opens by itself only without a PIN (PRF-3: the PIN
    /// is asked when switching to it, and launch is a switch). The always-open
    /// profile opens even with one: someone who knew it chose it for this
    /// device. An always-open id the household no longer has is ignored.
    public func restore() {
        choseGate = false
        previousProfileID = nil
        currentProfile = ProfileRestore.pick(alwaysOpen: alwaysOpenProfileID, profiles: store.profiles)
    }

    /// Switches to a profile. The caller has already checked its PIN
    /// (`store.verifyPIN`). Leaving a Guest clears what it touched (PRF-5).
    public func select(_ profile: ProfileRecord) {
        leaveGuest(unlessSwitchingTo: profile.id)
        choseGate = false
        previousProfileID = nil
        currentProfile = profile
        if !profile.isGuest {
            Self.writeID(profile.id, Keys.lastUsed, to: defaults)
        }
    }

    /// Back to "Who's watching?". Leaving a Kids profile needs an adult's PIN,
    /// checked by the caller (PRF-4). Leaving a Guest clears what it touched.
    public func signOut() {
        leaveGuest(unlessSwitchingTo: nil)
        choseGate = true
        previousProfileID = currentProfile?.id
        currentProfile = nil
    }

    /// Re-reads the current profile from the store after an edit or a sync:
    /// its new name, kind or PIN, or nil (the gate) when it was deleted. With
    /// no profile chosen yet — the household still arriving from iCloud at
    /// launch — it picks one by `restore`'s rules, unless the person asked for
    /// the gate.
    public func refresh() {
        let profiles = store.profiles
        if let current = currentProfile {
            guard store.hasHousehold else { return }
            currentProfile = profiles.first { $0.id == current.id }
        } else if !choseGate {
            currentProfile = ProfileRestore.pick(alwaysOpen: alwaysOpenProfileID, profiles: profiles)
        }
    }

    public var isKids: Bool { currentProfile?.kind == .kids }
    public var isGuest: Bool { currentProfile?.kind == .guest }

    /// Kids profiles can't open settings or Household (PRF-4).
    public var canOpenSettings: Bool { !isKids }

    /// Whether this device's member may manage sources and profiles (SRC-8).
    public var canManageHousehold: Bool { store.household.currentRole.canManage && !isKids && !isGuest }

    /// A Guest keeps nothing (PRF-5, PAR-4): the store never writes for one,
    /// and anything an older build or an earlier kind left goes on leaving.
    private func leaveGuest(unlessSwitchingTo nextID: UUID?) {
        guard let current = currentProfile, current.isGuest, current.id != nextID else { return }
        store.clearGuestData(profileID: current.id)
    }

    private static func readID(_ key: String, from defaults: UserDefaults) -> UUID? {
        defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    private static func writeID(_ id: UUID?, _ key: String, to defaults: UserDefaults) {
        if let id {
            defaults.set(id.uuidString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
