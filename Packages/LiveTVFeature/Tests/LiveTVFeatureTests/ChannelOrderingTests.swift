import CatalogKit
import Foundation
import Testing
@testable import LiveTVFeature

@Suite struct LiveChipTests {
    private let news = Fixture.category("1", name: "News")
    private let sport = Fixture.category("2", name: "Sport")
    private let kids = Fixture.category("3", name: "Kids")

    @Test func favoritesThenAllThenCategoriesInCatalogOrder() {
        let chips = LiveChip.chips(categories: [news, sport, kids], showsFavorites: true)
        #expect(chips.map(\.id) == ["favorites", "all", "category:news", "category:sport", "category:kids"])
    }

    @Test func aGuestGetsNoFavoritesChip() {
        let chips = LiveChip.chips(categories: [news], showsFavorites: false)
        #expect(chips == [.all, .category(ids: [news.id], name: "News")])
    }

    @Test func withNoCategoriesThereAreOnlyTheFixedChips() {
        #expect(LiveChip.chips(categories: [], showsFavorites: true) == [.favorites, .all])
        #expect(LiveChip.chips(categories: [], showsFavorites: false) == [.all])
    }

    @Test func sameNamedCategoriesFromSeveralSourcesShareOneChip() {
        let otherNews = Fixture.category("9", name: "news ", source: Fixture.sourceB)
        let accented = Fixture.category("10", name: "NÉWS", source: Fixture.sourceB)
        let chips = LiveChip.chips(categories: [news, sport, otherNews, accented], showsFavorites: false)
        // The first spelling names the chip; it sits where the first one was.
        #expect(chips == [
            .all,
            .category(ids: [news.id, otherNews.id, accented.id], name: "News"),
            .category(ids: [sport.id], name: "Sport"),
        ])
    }

    @Test func blankCategoryNamesGetNoChipAndNamesAreTrimmed() {
        let chips = LiveChip.chips(categories: [
            Fixture.category("1", name: ""),
            Fixture.category("2", name: "   "),
            Fixture.category("3", name: "\n"),
            Fixture.category("4", name: "  Movies  "),
        ], showsFavorites: false)
        #expect(chips == [.all, .category(ids: [Fixture.category("4", name: "").id], name: "Movies")])
    }

    @Test func titles() {
        #expect(LiveChip.favorites.title == "Favorites")
        #expect(LiveChip.all.title == "All channels")
        #expect(LiveChip.category(ids: ["x"], name: "Sport").title == "Sport")
    }

    @Test func aCategoryChipsIDIgnoresCaseAccentsAndItsCategories() {
        // What the last-chip memory stores must survive a source being added.
        let one = LiveChip.category(ids: ["a"], name: "Café")
        let two = LiveChip.category(ids: ["a", "b"], name: " CAFE ")
        #expect(one.id == two.id)
        #expect(one.id == "category:cafe")
    }

    @Test func resolveKeepsTheRememberedChipWhileItIsOffered() {
        let chips = LiveChip.chips(categories: [news, sport], showsFavorites: true)
        #expect(LiveChip.resolve(rememberedID: "category:sport", chips: chips, hasFavorites: true) == .category(ids: [sport.id], name: "Sport"))
        #expect(LiveChip.resolve(rememberedID: "all", chips: chips, hasFavorites: true) == .all)
    }

    @Test func resolveFallsBackToFavoritesWhenThereAreSome() {
        let chips = LiveChip.chips(categories: [news], showsFavorites: true)
        #expect(LiveChip.resolve(rememberedID: "category:gone", chips: chips, hasFavorites: true) == .favorites)
        #expect(LiveChip.resolve(rememberedID: nil, chips: chips, hasFavorites: true) == .favorites)
    }

    @Test func resolveFallsBackToAllWithoutFavorites() {
        let withChip = LiveChip.chips(categories: [news], showsFavorites: true)
        #expect(LiveChip.resolve(rememberedID: nil, chips: withChip, hasFavorites: false) == .all)
        // A Guest: no Favorites chip, so neither a remembered one nor
        // favorites on file can land there.
        let guest = LiveChip.chips(categories: [news], showsFavorites: false)
        #expect(LiveChip.resolve(rememberedID: "favorites", chips: guest, hasFavorites: true) == .all)
        #expect(LiveChip.resolve(rememberedID: nil, chips: guest, hasFavorites: true) == .all)
    }
}

@Suite struct ChannelOrderingTests {
    private func channel(_ id: String, _ number: Int?, _ name: String, source: UUID = Fixture.sourceA) -> CatalogChannel {
        Fixture.channel(id, number: number, name: name, source: source)
    }

    @Test func numberedChannelsComeFirstInNumberOrder() {
        let sorted = ChannelOrdering.byNumberThenName([
            channel("a", 10, "Ten"),
            channel("c", nil, "Zed"),
            channel("b", 2, "Two"),
            channel("d", nil, "Alpha"),
        ])
        #expect(sorted.map(\.name) == ["Two", "Ten", "Alpha", "Zed"])
    }

    @Test func namesCompareTheWayFinderDoes() {
        let sorted = ChannelOrdering.byNumberThenName([
            channel("a", nil, "Channel 10"),
            channel("b", nil, "channel 2"),
            channel("c", nil, "Channel 1"),
        ])
        #expect(sorted.map(\.name) == ["Channel 1", "channel 2", "Channel 10"])
    }

    @Test func aSharedNumberFallsBackToTheName() {
        let sorted = ChannelOrdering.byNumberThenName([channel("g", 5, "Beta"), channel("h", 5, "Alpha"), channel("i", 4, "Zulu")])
        #expect(sorted.map(\.name) == ["Zulu", "Alpha", "Beta"])
    }

    @Test func fullTiesAreBrokenByKeySoTheOrderNeverFlickers() {
        let x = channel("x", 7, "Same")
        let y = channel("y", 7, "Same")
        #expect(ChannelOrdering.byNumberThenName([y, x]).map(\.key) == [x.key, y.key])
        #expect(ChannelOrdering.byNumberThenName([x, y]).map(\.key) == [x.key, y.key])
    }

    @Test func mergingOneListKeepsTheCatalogsOrder() {
        let list = [channel("b", 9, "Nine"), channel("a", 1, "One")]
        #expect(ChannelOrdering.merge([list]) == list)
        #expect(ChannelOrdering.merge([]).isEmpty)
    }

    @Test func mergingSeveralListsDropsRepeatsAndSorts() {
        let one = channel("1", 1, "One")
        let two = channel("2", 2, "Two")
        let three = channel("3", 3, "Three")
        let merged = ChannelOrdering.merge([[three, one], [two, one], []])
        #expect(merged == [one, two, three])
    }

    @Test func theSameRemoteIDFromTwoSourcesIsTwoChannels() {
        let a = channel("101", 101, "News", source: Fixture.sourceA)
        let b = channel("101", 101, "News", source: Fixture.sourceB)
        let merged = ChannelOrdering.merge([[a], [b]])
        #expect(merged.count == 2)
        #expect(Set(merged.map(\.key)) == [a.key, b.key])
    }

    @Test func favoriteKeysKeepTheProfilesOrderAndOnlyChannels() {
        let first = ItemKey.channel(source: Fixture.sourceA, id: "2").rawValue
        let second = ItemKey.channel(source: Fixture.sourceB, id: "1").rawValue
        let movie = ItemKey.movie(source: Fixture.sourceA, id: "m").rawValue
        let episode = ItemKey.episode(source: Fixture.sourceA, seriesID: "s", season: 1, number: 1).rawValue
        let keys = ChannelOrdering.favoriteKeys([first, movie, second, first, episode, "unparseable"])
        // A key with no kind can't be ruled out as a channel, so it stays.
        #expect(keys.map(\.rawValue) == [first, second, "unparseable"])
        #expect(ChannelOrdering.favoriteKeys([]).isEmpty)
    }

    @Test func theQueueIsTheChannelsKeysInScreenOrder() {
        let channels = [channel("3", 3, "Three"), channel("1", 1, "One")]
        #expect(ChannelOrdering.queue(channels) == channels.map(\.key.rawValue))
        #expect(ChannelOrdering.queue([]).isEmpty)
    }
}

@Suite struct ChipMemoryTests {
    let anya = UUID(uuidString: "00000000-0000-0000-0000-00000000A0A0")!
    let dad = UUID(uuidString: "00000000-0000-0000-0000-00000000D0D0")!

    @Test func unreadableStorageRemembersNothing() {
        #expect(ChipMemory.decode("").isEmpty)
        #expect(ChipMemory.decode("not json").isEmpty)
        #expect(ChipMemory.decode("[1, 2]").isEmpty)
        #expect(ChipMemory.remembered(in: "{", profileID: anya) == nil)
    }

    @Test func rememberingStartsFromNothing() {
        let stored = ChipMemory.remembering("category:news", profileID: anya, in: "")
        #expect(ChipMemory.remembered(in: stored, profileID: anya) == "category:news")
    }

    @Test func eachProfileHasItsOwnChip() {
        var stored = ChipMemory.remembering("category:news", profileID: anya, in: "")
        stored = ChipMemory.remembering("favorites", profileID: dad, in: stored)
        stored = ChipMemory.remembering("all", profileID: nil, in: stored)
        #expect(ChipMemory.remembered(in: stored, profileID: anya) == "category:news")
        #expect(ChipMemory.remembered(in: stored, profileID: dad) == "favorites")
        #expect(ChipMemory.remembered(in: stored, profileID: nil) == "all")
    }

    @Test func rememberingAgainReplacesOnlyThatProfilesChip() {
        var stored = ChipMemory.remembering("category:news", profileID: anya, in: "")
        stored = ChipMemory.remembering("favorites", profileID: dad, in: stored)
        stored = ChipMemory.remembering("category:sport", profileID: anya, in: stored)
        #expect(ChipMemory.decode(stored) == [anya.uuidString: "category:sport", dad.uuidString: "favorites"])
    }

    @Test func encodeAndDecodeRoundTrip() {
        let map = [anya.uuidString: "all", "none": "category:kids"]
        #expect(ChipMemory.decode(ChipMemory.encode(map)) == map)
        #expect(ChipMemory.decode(ChipMemory.encode([:])).isEmpty)
    }
}
