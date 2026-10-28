import Foundation
import Testing
@testable import PlayerKit

/// Multi-view's slots and its one-tile-has-sound rule (PLY-9).
@MainActor
@Suite("MultiViewModel")
struct MultiViewModelTests {
    let engines = FakeEngines()
    let resolver = ScriptedResolver(Streams.hls)

    private func makeModel(_ layout: MultiViewModel.Layout = .four) -> MultiViewModel {
        MultiViewModel(layout: layout, configuration: .test(), engineFactory: engines.factory())
    }

    @Test func startsWithEmptySlots() {
        let model = makeModel()
        #expect(model.tiles.map(\.id) == [0, 1, 2, 3])
        #expect(model.tiles.allSatisfy { $0.isEmpty })
        #expect(model.audibleTileID == nil)
        #expect(model.firstEmptyTileID == 0)
        #expect(makeModel(.two).tiles.count == 2)
        #expect(makeModel(.three).tiles.count == 3)
    }

    @Test func firstChannelHasTheSoundAndTheRestAreMuted() async throws {
        let model = makeModel()
        let sports = try #require(model.play(channel(102, "Fieldhouse Sports", resolver: resolver)))
        let news = try #require(model.play(channel(101, "Cityline News", resolver: resolver)))
        #expect(model.tiles[0].player === sports)
        #expect(model.tiles[1].player === news)
        #expect(model.audibleTileID == 0)
        #expect(!sports.isMuted)
        #expect(news.isMuted)
        #expect(model.audibleItemName == "Fieldhouse Sports")

        // Both tiles start their own stream.
        #expect(await eventually { engines.made.count == 2 })
        #expect(engines.made.allSatisfy { $0.loaded.count == 1 })
        model.closeAll()
    }

    @Test func tappingATileMovesTheSound() throws {
        let model = makeModel()
        let sports = try #require(model.play(channel(102, "Fieldhouse Sports", resolver: resolver)))
        let news = try #require(model.play(channel(101, "Cityline News", resolver: resolver)))
        model.giveSound(toTile: 1)
        #expect(model.audibleTileID == 1)
        #expect(sports.isMuted)
        #expect(!news.isMuted)

        model.giveSound(toTile: 3)
        #expect(model.audibleTileID == 1, "an empty slot has no sound to give")
        model.closeAll()
    }

    @Test func clearingTheAudibleTilePassesTheSoundOn() throws {
        let model = makeModel()
        let sports = try #require(model.play(channel(102, "Fieldhouse Sports", resolver: resolver)))
        let news = try #require(model.play(channel(101, "Cityline News", resolver: resolver)))
        model.clearTile(0, reason: "Provider B is at its stream limit.")
        #expect(sports.state == .idle)
        #expect(model.tiles[0].isEmpty)
        #expect(model.tiles[0].emptyReason == "Provider B is at its stream limit.")
        #expect(model.audibleTileID == 1)
        #expect(!news.isMuted)
        model.closeAll()
    }

    @Test func emptyReasonsAreForEmptySlotsOnly() throws {
        let model = makeModel()
        let reason = "Provider A and Provider B are both at their stream limits."
        model.setEmptyReason(reason, forTile: 3)
        #expect(model.tiles[3].emptyReason == reason)

        model.play(channel(106, "Little Owl Kids", resolver: resolver), inTile: 3)
        #expect(model.tiles[3].emptyReason == nil)
        model.setEmptyReason(reason, forTile: 3)
        #expect(model.tiles[3].emptyReason == nil)
        model.closeAll()
    }

    @Test func replacingATileClosesTheOldPlayer() throws {
        let model = makeModel(.two)
        let first = try #require(model.play(channel(102, "Fieldhouse Sports", resolver: resolver), inTile: 0))
        let second = try #require(model.play(channel(103, "Lantern Drama", resolver: resolver), inTile: 0))
        #expect(first !== second)
        #expect(model.tiles[0].player === second)
        #expect(model.audibleTileID == 0)
        #expect(!second.isMuted)
        model.closeAll()
    }

    @Test func noRoomMeansNoPlayer() throws {
        let model = makeModel(.two)
        model.play(channel(101, "Cityline News", resolver: resolver))
        model.play(channel(102, "Fieldhouse Sports", resolver: resolver))
        #expect(model.firstEmptyTileID == nil)
        #expect(model.play(channel(103, "Lantern Drama", resolver: resolver)) == nil)
        #expect(model.play(channel(103, "Lantern Drama", resolver: resolver), inTile: 7) == nil)
        model.closeAll()
    }

    @Test func goingDownToTwoClosesTheBottomRow() throws {
        let model = makeModel(.four)
        model.play(channel(101, "Cityline News", resolver: resolver))
        model.play(channel(102, "Fieldhouse Sports", resolver: resolver))
        let kids = try #require(model.play(channel(106, "Little Owl Kids", resolver: resolver)))
        model.giveSound(toTile: 2)

        model.setLayout(.two)
        #expect(model.layout == .two)
        #expect(model.tiles.count == 2)
        #expect(kids.state == .idle)
        #expect(model.audibleTileID == 0, "the sound moves to a tile still on screen")
        #expect(model.players.filter { !$0.isMuted }.count == 1)

        model.setLayout(.four)
        #expect(model.tiles.map(\.id) == [0, 1, 2, 3])
        #expect(model.tiles[2].isEmpty)
        model.closeAll()
    }

    @Test func tileEventsReachTheOwner() async throws {
        let model = makeModel()
        let log = EventLog()
        model.onEvent = { log.record($0) }
        model.play(channel(102, "Fieldhouse Sports", resolver: resolver))
        #expect(await eventually { engines.last?.loaded.isEmpty == false })
        engines.last?.simulate(.playing)
        #expect(log.events == [.started(itemID: "ch-102")])
        model.closeAll()
        #expect(log.events.last == .stopped(itemID: "ch-102", position: 0, duration: nil))
        #expect(model.tiles.allSatisfy { $0.isEmpty })
        #expect(model.audibleTileID == nil)
    }
}
