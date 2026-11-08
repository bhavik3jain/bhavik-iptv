import CatalogKit
import Foundation
import HouseholdKit
import Testing
@testable import LiveTVFeature

/// Which favorites the Favorite channels sheet lists (FAV-1).
@Suite struct FavoriteChannelRowTests {
    let profile = UUID(uuidString: "00000000-0000-0000-0000-00000000F00D")!

    func favorite(_ channel: CatalogChannel, order: Double) -> FavoriteRecord {
        FavoriteRecord(profileID: profile, itemKey: channel.key.rawValue, kind: .channel, sortOrder: order, addedAt: Fixture.now)
    }

    @Test func listsWhatTheProfileSeesAndWhatsGoneButNotWhatsHidden() {
        let news = Fixture.channel("1", name: "News")
        let adult = Fixture.channel("2", name: "Late Night")
        let gone = Fixture.channel("3", name: "Closed Down")
        let sport = Fixture.channel("4", name: "Sport")
        let favorites = [news, adult, gone, sport].enumerated().map { favorite($1, order: Double($0)) }
        // The profile's rules hide "Late Night"; the catalog no longer holds
        // "Closed Down" at all.
        let visible = [news, sport].reduce(into: [String: CatalogChannel]()) { $0[$1.key.rawValue] = $1 }
        let inCatalog: Set<String> = [news, adult, sport].map(\.key.rawValue).reduce(into: []) { $0.insert($1) }

        let rows = FavoriteChannelRow.rows(favorites: favorites, visible: visible) { inCatalog.contains($0) }
        // In the profile's order; the hidden one left off, the gone one kept
        // without a channel ("Unavailable channel") so it keeps its place.
        #expect(rows.map(\.favorite.itemKey) == [news, gone, sport].map(\.key.rawValue))
        #expect(rows.map(\.channel?.name) == ["News", nil, "Sport"])
        #expect(rows.map(\.id) == [favorites[0].id, favorites[2].id, favorites[3].id])
    }

    @Test func noFavoritesNoRows() {
        #expect(FavoriteChannelRow.rows(favorites: [], visible: [:]) { _ in true }.isEmpty)
    }
}
