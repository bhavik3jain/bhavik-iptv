import Foundation

/// The hearts on a list of channels (FAV-1), so a channel can be favorited
/// where it was found rather than on its own page: which ones are this
/// profile's favorites, read once for the list instead of a query per row.
/// Build it in a view's `body`: that also redraws the hearts after a toggle
/// here or on another device.
@MainActor
public struct ChannelFavorites {
    private let store: HouseholdStore
    private let profileID: UUID?
    private let keys: Set<String>

    public init(store: HouseholdStore, profile: ProfileRecord?) {
        // The store's queries aren't observable themselves; its revision is.
        _ = store.revision
        self.store = store
        let keeper = profile?.isGuest == true ? nil : profile?.id
        profileID = keeper
        keys = keeper.map { Set(store.favorites(profileID: $0, kind: .channel).map(\.itemKey)) } ?? []
    }

    /// False for a Guest, who keeps no favorites (PRF-5), and before a profile
    /// is chosen: such a list shows no hearts.
    public var canChange: Bool { profileID != nil }

    public func contains(_ itemKey: String) -> Bool { keys.contains(itemKey) }

    /// Adds at the end of the profile's favorites, or removes.
    public func toggle(_ itemKey: String) {
        guard let profileID else { return }
        store.toggleFavorite(profileID: profileID, itemKey: itemKey, kind: .channel)
    }
}
