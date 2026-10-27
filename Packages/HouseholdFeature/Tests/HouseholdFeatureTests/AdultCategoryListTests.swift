import CatalogKit
import Foundation
import SourceKit
import Testing
@testable import HouseholdFeature

/// `AdultCategoryList`: the adult-marking screen's list (PAR-1).
@Suite struct AdultCategoryListTests {
    let portal = UUID(uuidString: "0D0D0D0D-0000-4000-8000-0000000000A1")!
    let playlist = UUID(uuidString: "0D0D0D0D-0000-4000-8000-0000000000A2")!

    func category(_ remoteID: String, _ name: String, source: UUID) -> CatalogCategory {
        CatalogCategory(id: "\(source.uuidString)/live/\(remoteID)", sourceID: source, remoteID: remoteID, kind: .live, name: name, sortOrder: 0, isAdult: false)
    }

    var categories: [CatalogCategory] {
        [
            category("1", "News", source: portal),
            category("2", "XXX Adult", source: portal),
            category("10", "Café Movies", source: playlist),
            category("3", "Late Night", source: portal),
            category("11", "+18 Movies", source: playlist),
            category("12", "", source: playlist),
        ]
    }

    func list(marked: Set<String> = [], names: [UUID: String]? = nil, query: String = "") -> AdultCategoryList {
        AdultCategoryList(categories: categories, marked: marked, sourceNames: names ?? [portal: "Provider A", playlist: "Family List"], query: query)
    }

    @Test func groupedBySourceInTheCatalogsOrder() {
        let list = list()
        #expect(!list.isFiltered)
        #expect(list.groups.map(\.id) == [portal, playlist])
        #expect(list.groups.map(\.title) == ["Provider A", "Family List"])
        #expect(list.groups[0].rows.map(\.name) == ["News", "XXX Adult", "Late Night"])
        #expect(list.groups[1].rows.map(\.name) == ["Café Movies", "+18 Movies", "Untitled category"])
    }

    @Test func namesMatchedAndMarksApplied() {
        let lateNight = "\(portal.uuidString)/live/3"
        let list = list(marked: [lateNight, "someone-elses-key"])
        let rows = list.groups.flatMap(\.rows)
        #expect(rows.filter(\.isMatchedByName).map(\.name) == ["XXX Adult", "+18 Movies"])
        #expect(rows.filter(\.isMarked).map(\.id) == [lateNight])
    }

    @Test func aSourceWithoutANameIsStillListed() {
        let list = list(names: [portal: "Provider A"])
        #expect(list.groups.map(\.title) == ["Provider A", "Source"])
    }

    @Test func searchMatchesEveryWordFoldedAndDropsEmptyGroups() {
        // Case and accents folded; every word must appear.
        let cafe = list(query: "  CAFE ")
        #expect(cafe.isFiltered)
        #expect(cafe.groups.map(\.id) == [playlist])
        #expect(cafe.groups[0].rows.map(\.name) == ["Café Movies"])

        #expect(list(query: "movies").groups.flatMap(\.rows).map(\.name) == ["Café Movies", "+18 Movies"])
        #expect(list(query: "night late").groups.flatMap(\.rows).map(\.name) == ["Late Night"])
        #expect(list(query: "late morning").groups.isEmpty)
        #expect(list(query: "late morning").isFiltered)
        // Punctuation alone isn't a search.
        #expect(!list(query: " - ").isFiltered)
        #expect(list(query: " - ").groups.flatMap(\.rows).count == 6)
    }

    @Test func noCategoriesNoGroups() {
        let empty = AdultCategoryList(categories: [], marked: [], sourceNames: [:], query: "")
        #expect(empty.groups.isEmpty)
        #expect(!empty.isFiltered)
    }

    @Test func kindTitles() {
        #expect(AdultCategoryList.kindTitle(.live) == "Live TV")
        #expect(AdultCategoryList.kindTitle(.vod) == "Movies")
        #expect(AdultCategoryList.kindTitle(.series) == "Shows")
    }
}
