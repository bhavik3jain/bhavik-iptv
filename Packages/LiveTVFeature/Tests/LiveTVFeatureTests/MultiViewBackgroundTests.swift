import CatalogKit
import Foundation
import HouseholdKit
import Testing
@testable import LiveTVFeature

/// Multi-view kept running off screen, and the way back to it.
@MainActor
@Suite struct MultiViewBackgroundTests {
    let catalog = CatalogService(storeURL: nil)
    let store: HouseholdStore

    init() throws {
        store = try HouseholdStore(mode: .inMemory)
        store.ensureHousehold(defaultName: "Home", firstProfileName: "Mum")
    }

    private func playing(_ names: String...) -> MultiViewSession {
        let session = MultiViewSession()
        for (tile, name) in names.enumerated() {
            session.play(Fixture.channel("ch\(tile)", name: name), programme: nil, inTile: tile, catalog: catalog, store: store, profileID: store.profiles.first?.id)
        }
        return session
    }

    @Test func aScreenWithNothingPlayingLeavesNothingBehind() {
        let background = MultiViewBackground()
        background.keep(MultiViewSession(), catalog: catalog, store: store)
        #expect(!background.isRunning)
        #expect(background.title == nil)
    }

    @Test func keptTilesAreStillPlayingAndTheNextScreenTakesThem() throws {
        let background = MultiViewBackground()
        let session = playing("Cityline News", "Fieldhouse Sports")
        background.keep(session, catalog: catalog, store: store)
        #expect(background.isRunning)
        #expect(background.title == "Cityline News + 1 more")
        #expect(session.model.players.count == 2)
        #expect(store.activePlaybacks.count == 2, "Each tile keeps its who's-watching row")

        let taken = try #require(background.take())
        #expect(taken === session)
        #expect(!background.isRunning)
        #expect(taken.model.players.count == 2)
        #expect(background.take() == nil)
    }

    @Test func stoppingClosesEveryTileAndItsRow() {
        let background = MultiViewBackground()
        let session = playing("Cityline News", "Fieldhouse Sports")
        background.keep(session, catalog: catalog, store: store)
        background.stop(store: store)
        #expect(!background.isRunning)
        #expect(session.model.players.isEmpty)
        #expect(store.activePlaybacks.isEmpty)
    }

    // A screen opening stops whatever else runs in the background, even with
    // no tiles of its own to take back.
    @Test func openingTellsTheOwner() {
        let background = MultiViewBackground()
        var opened = 0
        background.onOpening = { opened += 1 }
        _ = background.take()
        #expect(opened == 1)
    }

    @Test func aTileTakenFullScreenComesBackBeforeItIsKept() {
        let background = MultiViewBackground()
        let session = playing("Cityline News")
        session.expand(tile: 0)
        #expect(session.expanded != nil)
        background.keep(session, catalog: catalog, store: store)
        #expect(session.expanded == nil)
    }

    @Test func theButtonNamesTheChannelWithTheSound() {
        #expect(MultiViewBackgroundText.title(audibleChannel: "Fieldhouse Sports", channels: ["Cityline News", "Fieldhouse Sports", "Salt Road"]) == "Fieldhouse Sports + 2 more")
        #expect(MultiViewBackgroundText.title(audibleChannel: nil, channels: ["Cityline News"]) == "Cityline News")
        #expect(MultiViewBackgroundText.title(audibleChannel: nil, channels: []) == nil)
    }
}
