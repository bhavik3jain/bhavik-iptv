import CatalogKit
import Foundation
import HouseholdKit
import Testing
@testable import LibraryFeature

/// My List's per-device sort and the rows of Reorder My List (FAV-3).
@Suite struct MyListOrderingTests {
    /// A movie on the list: `minutesAgo` is when it was added, `order` its
    /// place in the profile's order.
    static func entry(_ id: String, name: String, order: Double, minutesAgo: Double, status: Status = .available, syncedTitle: String = "") -> MyListEntry {
        let movie = Fixture.movie(id, name: name)
        let favorite = FavoriteRecord(
            profileID: Fixture.profile,
            itemKey: movie.key.rawValue,
            kind: .movie,
            sortOrder: order,
            addedAt: Fixture.now.addingTimeInterval(-minutesAgo * 60),
            title: syncedTitle
        )
        switch status {
        case .available: return MyListEntry(favorite: favorite, status: .available(GridEntry(movie: movie, index: Int(order))))
        case .pending: return MyListEntry(favorite: favorite, status: .pending)
        case .unavailable: return MyListEntry(favorite: favorite, status: .unavailable)
        }
    }

    enum Status { case available, pending, unavailable }

    /// In the profile's order: Zodiac, Alien, the gone one, Memento.
    let entries = [
        entry("z", name: "Zodiac", order: 1, minutesAgo: 30),
        entry("a", name: "Alien", order: 2, minutesAgo: 10),
        entry("gone", name: "", order: 3, minutesAgo: 5, status: .unavailable),
        entry("m", name: "memento", order: 4, minutesAgo: 20),
    ]

    func names(_ entries: [MyListEntry]) -> [String] {
        entries.map { $0.sortName ?? "–" }
    }

    @Test func myOrderIsTheProfilesOrder() {
        #expect(MyListSort.custom.sorted(entries) == entries)
    }

    @Test func recentlyAddedIsNewestFirst() {
        #expect(names(MyListSort.recentlyAdded.sorted(entries)) == ["–", "Alien", "memento", "Zodiac"])
    }

    @Test func aToZIgnoresCaseAndPutsUnnamedRowsLast() {
        #expect(names(MyListSort.title.sorted(entries)) == ["Alien", "memento", "Zodiac", "–"])
    }

    /// An unavailable or loading title sorts by the name synced with it.
    @Test func aToZUsesTheSyncedNameOfATitleNotHere() {
        let list = entries + [Self.entry("b", name: "", order: 5, minutesAgo: 1, status: .pending, syncedTitle: "Blade Runner")]
        #expect(names(MyListSort.title.sorted(list)) == ["Alien", "Blade Runner", "memento", "Zodiac", "–"])
    }

    @Test func tiesKeepTheProfilesOrder() {
        let list = [
            Self.entry("1", name: "Heat", order: 1, minutesAgo: 10),
            Self.entry("2", name: "Heat", order: 2, minutesAgo: 10),
            Self.entry("3", name: "Heat", order: 3, minutesAgo: 10),
        ]
        #expect(MyListSort.title.sorted(list).map(\.id) == list.map(\.id))
        #expect(MyListSort.recentlyAdded.sorted(list).map(\.id) == list.map(\.id))
    }

    @Test func anUnknownStoredSortFallsBackToMyOrder() {
        #expect(MyListSort(rawValue: "byRating") == nil)
        #expect(MyListSort.allCases.first == .custom)
    }

    /// Reorder My List lists loading and unavailable titles too, by their
    /// favorite's id, so they reorder and keep their places.
    @Test func reorderRowsCoverEveryStatus() {
        let loading = Self.entry("l", name: "", order: 5, minutesAgo: 1, status: .pending, syncedTitle: "Blade Runner")
        let rows = (entries + [loading]).map(MyListOrderRow.init)
        #expect(rows.map(\.id) == (entries + [loading]).map(\.favorite.id))
        #expect(rows.map(\.state) == [.available, .available, .unavailable, .available, .loading])
        #expect(rows[0].title == "Zodiac")
        #expect(rows[0].caption == "2024")
        #expect(rows[2].title == "Unavailable")
        #expect(rows[4].title == "Blade Runner")
        #expect(rows[4].posterURL == nil)
    }
}
