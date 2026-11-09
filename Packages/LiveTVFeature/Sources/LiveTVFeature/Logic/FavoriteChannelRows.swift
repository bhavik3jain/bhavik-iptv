import CatalogKit
import Foundation
import HouseholdKit

/// A row of the Favorite channels sheet (FAV-1): one of the profile's
/// favorite channels, with its channel when the profile can see it.
///
/// A favorite the catalog no longer holds (gone from the provider, a source
/// still importing) stays, as "Unavailable channel", so the order around it
/// can be set and it keeps its place. A channel the profile's rules hide is
/// left off, as on My List, so a Kids profile doesn't learn of it; it keeps
/// its place too, since moves go by the ids shown
/// (`HouseholdStore.moveFavorites(…shownIDs:…)`), never by offsets.
struct FavoriteChannelRow: Identifiable, Equatable {
    var favorite: FavoriteRecord
    /// Nil when the catalog doesn't hold the channel.
    var channel: CatalogChannel?
    var id: UUID { favorite.id }

    /// The rows for `favorites`, in their order.
    ///
    /// - Parameters:
    ///   - visible: The channels the profile can see, by item key.
    ///   - inCatalog: Whether the catalog holds a key at all, whatever the
    ///     profile's rules; asked only of favorites not in `visible`.
    static func rows(favorites: [FavoriteRecord], visible: [String: CatalogChannel], inCatalog: (String) -> Bool) -> [FavoriteChannelRow] {
        favorites.compactMap { favorite in
            if let channel = visible[favorite.itemKey] { return FavoriteChannelRow(favorite: favorite, channel: channel) }
            return inCatalog(favorite.itemKey) ? nil : FavoriteChannelRow(favorite: favorite, channel: nil)
        }
    }
}
