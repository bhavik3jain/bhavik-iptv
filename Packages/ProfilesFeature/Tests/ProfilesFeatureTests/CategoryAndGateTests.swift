import CatalogKit
import Core
import CoreGraphics
import Foundation
import Testing
@testable import ProfilesFeature

@Suite struct CategoryGroupingTests {
    let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    let gone = UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!
    var sources: [(id: UUID, name: String)] { [(a, "Provider A"), (b, "Provider B")] }

    private func category(_ name: String, source: UUID, order: Int = 0, adult: Bool = false) -> CatalogCategory {
        CatalogCategory(
            id: CategoryKey.make(source: source, kind: "live", remoteID: name), sourceID: source, remoteID: name,
            kind: .live, name: name, sortOrder: order, isAdult: adult
        )
    }

    @Test func groupsFollowTheHouseholdsSourceOrder() {
        let categories = [category("News", source: b), category("Sport", source: a)]
        let groups = CategoryGrouping.groups(categories, sources: sources, query: "", excludingAdult: false)
        #expect(groups.map(\.sourceName) == ["Provider A", "Provider B"])
        #expect(groups.map(\.id) == [a, b])
    }

    @Test func sourcesWithNothingToShowAreLeftOut() {
        let groups = CategoryGrouping.groups([category("News", source: b)], sources: sources, query: "", excludingAdult: false)
        #expect(groups.map(\.id) == [b])
        #expect(CategoryGrouping.groups([], sources: sources, query: "", excludingAdult: false).isEmpty)
    }

    @Test func categoriesSortByTheProvidersOrderThenName() {
        let categories = [
            category("Kids 10", source: a, order: 1),
            category("Kids 2", source: a, order: 1),
            category("Sport", source: a, order: 0),
            category("Films", source: a, order: 2),
        ]
        let names = CategoryGrouping.groups(categories, sources: sources, query: "", excludingAdult: false)[0].categories.map(\.name)
        #expect(names == ["Sport", "Kids 2", "Kids 10", "Films"])
    }

    @Test func theQueryIgnoresCaseAndAccents() {
        let categories = [category("Café Culture", source: a), category("CAFE RACERS", source: b), category("News", source: a)]
        let groups = CategoryGrouping.groups(categories, sources: sources, query: "cafe", excludingAdult: false)
        #expect(groups.flatMap(\.categories).map(\.name) == ["Café Culture", "CAFE RACERS"])
        #expect(CategoryGrouping.groups(categories, sources: sources, query: "weather", excludingAdult: false).isEmpty)
        #expect(CategoryGrouping.groups(categories, sources: sources, query: "  ", excludingAdult: false).flatMap(\.categories).count == 3)
    }

    @Test func theKidsListLeavesAdultCategoriesOut() {
        let marked = category("Late Night", source: a)
        let categories = [category("Cartoons", source: a), category("XXX", source: a, adult: true), marked]
        let kids = CategoryGrouping.groups(categories, sources: sources, query: "", adultKeys: [marked.id], excludingAdult: true)
        #expect(kids.flatMap(\.categories).map(\.name) == ["Cartoons"])
        let hidden = CategoryGrouping.groups(categories, sources: sources, query: "", adultKeys: [marked.id], excludingAdult: false)
        #expect(hidden.flatMap(\.categories).count == 3)
    }

    @Test func adultByNameOrByTheHouseholdsList() {
        let named = category("Adult 18+", source: a, adult: true)
        let plain = category("Late Night", source: a)
        #expect(CategoryGrouping.isAdult(named, adultKeys: []))
        #expect(!CategoryGrouping.isAdult(plain, adultKeys: []))
        #expect(CategoryGrouping.isAdult(plain, adultKeys: [plain.id]))
    }

    @Test func aSourceTheHouseholdNoLongerListsStillShowsLast() {
        let categories = [category("Old Favourites", source: gone), category("News", source: a)]
        let groups = CategoryGrouping.groups(categories, sources: sources, query: "", excludingAdult: false)
        #expect(groups.map(\.id) == [a, gone])
        #expect(groups.last?.sourceName == "Other source")
    }
}

@Suite struct GateTileMetricsTests {
    @Test func aPhoneGetsTheMockupsAvatars() {
        let metrics = GateTileMetrics(container: CGSize(width: 393, height: 852), isSidebar: false)
        #expect(metrics.avatarSize == 96)
        #expect(metrics.gap == 28)
        #expect(!metrics.isShort)
    }

    @Test func aShortScreenTightens() {
        let metrics = GateTileMetrics(container: CGSize(width: 393, height: 700), isSidebar: false)
        #expect(metrics.isShort)
        #expect(metrics.avatarSize == 84)
        #expect(metrics.gap == 18)
        #expect(GateTileMetrics(container: CGSize(width: 393, height: 720), isSidebar: false).isShort == false)
    }

    @Test func aNarrowPhoneStillFitsThreeAcross() {
        // 320 wide: 272 of content, (272 - 2 × 18) / 3 = 78.7 → 78.
        let metrics = GateTileMetrics(container: CGSize(width: 320, height: 852), isSidebar: false)
        #expect(metrics.avatarSize == 78)
    }

    @Test func avatarsNeverShrinkBelowTheMinimum() {
        let metrics = GateTileMetrics(container: CGSize(width: 200, height: 852), isSidebar: false)
        #expect(metrics.avatarSize == GateTileMetrics.minimumAvatar)
        #expect(GateTileMetrics(container: .zero, isSidebar: true).avatarSize == GateTileMetrics.minimumAvatar)
    }

    @Test func theSidebarGrowsAvatarsWithTheHeight() {
        #expect(GateTileMetrics(container: CGSize(width: 1200, height: 900), isSidebar: true).avatarSize == 112)
        #expect(GateTileMetrics(container: CGSize(width: 1200, height: 819), isSidebar: true).avatarSize == 100)
        #expect(GateTileMetrics(container: CGSize(width: 1200, height: 820), isSidebar: true).avatarSize == 112)
    }

    @Test func iPhoneDuoOpenIsAShortSidebar() {
        let metrics = GateTileMetrics(container: CGSize(width: 466, height: 678), isSidebar: true)
        #expect(metrics.isShort)
        #expect(metrics.avatarSize == 84)
        #expect(metrics.gap == 18)
    }

    @Test func theSidebarColumnCapsTheWidth() {
        // A very wide but narrow-column sidebar uses the 640-pt column, not
        // the window: the same avatars at 700 and 3000 wide.
        let narrow = GateTileMetrics(container: CGSize(width: 700, height: 900), isSidebar: true)
        let wide = GateTileMetrics(container: CGSize(width: 3000, height: 900), isSidebar: true)
        #expect(narrow == wide)
    }
}
