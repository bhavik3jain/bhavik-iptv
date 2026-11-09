import CatalogKit
import CoreData
import Foundation
@testable import HouseholdKit
import Testing
@testable import LiveTVFeature

/// Multi-view's side of Continue on Apple TV: tiles' rows in slot order,
/// the arrangement another device's tiles open in, and tiles stopping here
/// when another device carries them on.
@MainActor
@Suite struct MultiViewHandoffTests {
    let catalog = CatalogService(storeURL: nil)
    let store: HouseholdStore

    init() throws {
        store = try HouseholdStore(mode: .inMemory)
        store.ensureHousehold(defaultName: "Home", firstProfileName: "Mum")
    }

    private var profileID: UUID { store.profiles[0].id }

    private func play(_ session: MultiViewSession, _ id: String, inTile tile: Int) {
        session.play(Fixture.channel(id), programme: nil, inTile: tile, catalog: catalog, store: store, profileID: profileID)
    }

    @Test func rowsSortInSlotOrderWhateverOrderTheTilesFilled() {
        let session = MultiViewSession()
        play(session, "third", inTile: 2)
        play(session, "first", inTile: 0)
        play(session, "second", inTile: 1)

        let offers = ContinueOfferRules.offers(profileID: profileID, playbacks: store.activePlaybacks, ownPlaybackIDs: [], ownDeviceName: "Another TV", now: .now)
        #expect(offers.first?.itemKeys == ["first", "second", "third"].map { Fixture.channel($0).key.rawValue })
        session.closeAll(store: store)
    }

    @Test func aSwappedTileKeepsItsPlace() {
        let session = MultiViewSession()
        play(session, "a", inTile: 0)
        play(session, "b", inTile: 1)
        play(session, "swapped", inTile: 0)

        let offers = ContinueOfferRules.offers(profileID: profileID, playbacks: store.activePlaybacks, ownPlaybackIDs: [], ownDeviceName: "Another TV", now: .now)
        #expect(offers.first?.itemKeys == ["swapped", "b"].map { Fixture.channel($0).key.rawValue })
        session.closeAll(store: store)
    }

    @Test func rowStartsAreTenMillisecondsASlot() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(MultiViewHandoff.rowStart(anchor: anchor, slot: 0) == anchor)
        #expect(abs(MultiViewHandoff.rowStart(anchor: anchor, slot: 3).timeIntervalSince(anchor) - 0.03) < 1e-9)
        #expect(MultiViewHandoff.rowStart(anchor: anchor, slot: 1) < MultiViewHandoff.rowStart(anchor: anchor, slot: 2))
    }

    @Test func carriedChannelsPickTheArrangement() {
        #expect(MultiViewHandoff.arrangement(forChannels: 0) == nil)
        #expect(MultiViewHandoff.arrangement(forChannels: 1) == nil)
        #expect(MultiViewHandoff.arrangement(forChannels: 2) == .two)
        #expect(MultiViewHandoff.arrangement(forChannels: 3) == .three)
        #expect(MultiViewHandoff.arrangement(forChannels: 4) == .four)
        #expect(MultiViewHandoff.arrangement(forChannels: 6) == .four)
    }

    @Test func tilesAnotherDeviceTookOverStopHere() throws {
        let session = MultiViewSession()
        play(session, "a", inTile: 0)
        play(session, "b", inTile: 1)
        #expect(session.releaseTilesTakenOver(store: store) == nil, "nothing has happened yet")

        // What iCloud brings: the TV deleted both rows and plays "a".
        let ended = session.ownPlaybackIDs
        store.simulateRemote { store in
            store.fetch(PlaybackEntity.self, HouseholdModel.Entity.playback).forEach(store.viewContext.delete)
            store.insertRemotePlayback(profileID: profileID, itemKey: Fixture.channel("a").key.rawValue, device: "Living Room")
        }

        let takeover = try #require(session.releaseTilesTakenOver(store: store))
        #expect(takeover.deviceName == "Living Room")
        #expect(takeover.endedIDs == ended)
        #expect(session.occupants.isEmpty)
        #expect(session.model.players.isEmpty)
        #expect(session.releaseTilesTakenOver(store: store) == nil, "and only once")
    }

    @Test func theBackgroundSessionEndsWhenEveryTileIsTakenOver() {
        let background = MultiViewBackground()
        let session = MultiViewSession()
        play(session, "a", inTile: 0)
        background.keep(session, catalog: catalog, store: store)

        store.simulateRemote { store in
            store.fetch(PlaybackEntity.self, HouseholdModel.Entity.playback).forEach(store.viewContext.delete)
            store.insertRemotePlayback(profileID: profileID, itemKey: Fixture.channel("a").key.rawValue, device: "Living Room")
        }
        #expect(background.releaseTilesTakenOver(store: store)?.deviceName == "Living Room")
        #expect(!background.isRunning)
    }
}

private extension HouseholdStore {
    /// Rows changed by another device, as an iCloud import lands them.
    func simulateRemote(_ body: (HouseholdStore) -> Void) {
        body(self)
        save("simulated import")
        rebuildSnapshots()
    }

    func insertRemotePlayback(profileID: UUID, itemKey: String, device: String) {
        guard let household = currentHouseholdEntity() else { return }
        let row = insert(HouseholdModel.Entity.playback, as: PlaybackEntity.self, into: targetStore(for: household))
        row.id = UUID()
        row.profileID = profileID
        row.sourceID = Fixture.sourceA
        row.itemKey = itemKey
        row.title = "Remote"
        row.deviceName = device
        row.startedAt = .now
        row.lastSeenAt = .now
        row.household = household
    }
}
