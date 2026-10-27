import Foundation
import Testing
@testable import SearchFeature

@Suite struct RecentSearchesTests {
    @Test func newestGoesOnTop() {
        let list = RecentSearches().adding("news").adding("cityline")
        #expect(list.items == ["cityline", "news"])
    }

    @Test func queriesAreTrimmed() {
        #expect(RecentSearches().adding("  cityline \n").items == ["cityline"])
    }

    @Test(arguments: ["", "   ", "\n\t", "...", "'", "—"])
    func queriesWithNothingSearchableAreIgnored(query: String) {
        let list = RecentSearches(["news"])
        #expect(list.adding(query) == list)
    }

    @Test func aRepeatMovesUpWithTheNewestSpelling() {
        let list = RecentSearches().adding("Café").adding("news").adding("cafe ")
        #expect(list.items == ["cafe", "news"])
    }

    @Test func normalisedMatchesFoldPunctuationToo() {
        let list = RecentSearches().adding("Grey's Anatomy").adding("greys anatomy")
        #expect(list.items == ["greys anatomy"])
    }

    @Test func repeatingTheTopQueryChangesNothing() {
        // The screen only writes UserDefaults when the list changes.
        let list = RecentSearches().adding("news").adding("cityline")
        #expect(list.adding("cityline") == list)
    }

    @Test func onlyTheNewestTenAreKept() {
        var list = RecentSearches()
        for index in 1...12 { list = list.adding("query \(index)") }
        #expect(list.items.count == RecentSearches.limit)
        #expect(list.items.first == "query 12")
        #expect(list.items.last == "query 3")
    }

    @Test func buildingFromAListFoldsDuplicatesKeepingTheFirst() {
        // Items are newest first: "Café" is the more recent spelling.
        let list = RecentSearches(["Café", "news", "cafe", "", "  "])
        #expect(list.items == ["Café", "news"])
    }

    @Test func buildingFromALongListKeepsTheNewest() {
        let list = RecentSearches((1...15).map { "q\($0)" })
        #expect(list.items == (1...10).map { "q\($0)" })
    }

    @Test func removingMatchesNormalised() {
        let list = RecentSearches(["Café", "news"])
        #expect(list.removing("CAFE").items == ["news"])
        #expect(list.removing("weather") == list)
        #expect(RecentSearches().removing("news").isEmpty)
    }

    @Test func storageRoundTrips() {
        let list = RecentSearches(["cityline", "Grey's", "日本"])
        let restored = RecentSearches(storage: list.storage)
        #expect(restored == list)
        #expect(RecentSearches().storage == "[]")
    }

    @Test(arguments: ["", "not json", "{\"a\":1}", "[1,2]", "[\"unterminated"])
    func unreadableStorageIsAnEmptyList(storage: String) {
        #expect(RecentSearches(storage: storage).isEmpty)
    }

    @Test func storedListsAreCleanedOnTheWayIn() {
        // A hand-edited default with duplicates and blanks.
        let restored = RecentSearches(storage: #"["news", "  ", "NEWS", "sport"]"#)
        #expect(restored.items == ["news", "sport"])
    }

    @Test func eachProfileHasItsOwnKey() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
        #expect(RecentSearches.storageKey(profileID: id) == "Hearth.Search.recent.00000000-0000-0000-0000-0000000000B1")
        #expect(RecentSearches.storageKey(profileID: nil) == "Hearth.Search.recent.none")
        #expect(RecentSearches.storageKey(profileID: id) != RecentSearches.storageKey(profileID: UUID()))
    }
}

@Suite struct SearchRequestTests {
    @Test func theQueryIsComparedNormalised() {
        #expect(SearchRequest(query: "  Café NEWS ", revision: 1).normalizedQuery == "cafe news")
        #expect(SearchRequest(query: "", revision: 1).normalizedQuery.isEmpty)
    }

    @Test func aNewCatalogRevisionIsANewRequest() {
        // The task is keyed on the request: a revision bump re-runs the search.
        #expect(SearchRequest(query: "news", revision: 1) != SearchRequest(query: "news", revision: 2))
        #expect(SearchRequest(query: "news", revision: 1) == SearchRequest(query: "news", revision: 1))
    }

    @Test func theDebounceIsAQuarterSecond() {
        #expect(SearchRequest.debounce == .milliseconds(250))
    }
}
