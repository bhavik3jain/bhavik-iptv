import Foundation
import Observation

/// Two, three or four channels at once, one of them with sound (PLY-9,
/// mockup 07; three at the owner's request).
///
/// Each tile is its own `PlayerModel` built with `PlayerConfiguration
/// .multiViewTile` — muted, and leaving Now Playing to the full-screen player
/// — and takes one of the provider's streams. Whether a tile may have a
/// stream is the owner's call (technical spec, Stream limits, rule 4); a tile
/// it can't fill stays empty with the reason the owner gives ("Provider A and
/// Provider B are both at their stream limits…").
///
/// Exactly one playing tile has sound: the first one added, until the user
/// taps another.
@MainActor
@Observable
public final class MultiViewModel {
    public enum Layout: Int, Sendable, Hashable, CaseIterable {
        case two = 2
        case three = 3
        case four = 4

        public var tileCount: Int { rawValue }
    }

    /// One slot of the grid.
    public struct Tile: Identifiable {
        /// The slot's position, 0 at the top left, reading order.
        public let id: Int
        public internal(set) var player: PlayerModel?
        /// Why the slot is empty, shown under "Add a channel".
        public internal(set) var emptyReason: String?

        public var isEmpty: Bool { player == nil }
    }

    public private(set) var layout: Layout
    public private(set) var tiles: [Tile]
    /// The tile whose sound plays; nil when no tile has a player.
    public private(set) var audibleTileID: Int?

    /// Every tile's events, for progress and who's-watching rows: each tile
    /// takes a stream, so the household's records need to know about it.
    public var onEvent: ((PlayerEvent) -> Void)?

    public let configuration: PlayerConfiguration
    @ObservationIgnored let engineFactory: PlaybackEngineFactory

    public init(
        layout: Layout = .four,
        configuration: PlayerConfiguration = .multiViewTile,
        engineFactory: PlaybackEngineFactory = .standard
    ) {
        self.layout = layout
        self.configuration = configuration
        self.engineFactory = engineFactory
        self.tiles = (0..<layout.tileCount).map { Tile(id: $0) }
    }

    /// The players on screen, in reading order.
    public var players: [PlayerModel] { tiles.compactMap(\.player) }

    public var audiblePlayer: PlayerModel? {
        audibleTileID.flatMap { tiles.indices.contains($0) ? tiles[$0].player : nil }
    }

    /// "Fieldhouse Sports", for the toolbar's "Sound from …".
    public var audibleItemName: String? {
        audiblePlayer.map { $0.item.channelName ?? $0.item.title }
    }

    public var firstEmptyTileID: Int? {
        tiles.first(where: \.isEmpty)?.id
    }

    /// Opens `item` in a tile — the given one, or the first empty one — and
    /// starts it. Replaces whatever the tile held. Nil when there's no room.
    @discardableResult
    public func play(_ item: PlayerItem, inTile id: Int? = nil, navigator: PlayerModel.Navigator? = nil) -> PlayerModel? {
        guard let index = id ?? firstEmptyTileID, tiles.indices.contains(index) else { return nil }
        tiles[index].player?.close()
        let player = PlayerModel(item: item, navigator: navigator, configuration: configuration, engineFactory: engineFactory)
        player.onEvent = { [weak self] event in self?.onEvent?(event) }
        tiles[index].player = player
        tiles[index].emptyReason = nil
        if audiblePlayer == nil || audibleTileID == index {
            audibleTileID = index
        }
        applySound()
        Task { await player.start() }
        return player
    }

    /// A tap on a tile gives it the sound and mutes the rest.
    public func giveSound(toTile id: Int) {
        guard tiles.indices.contains(id), tiles[id].player != nil else { return }
        audibleTileID = id
        applySound()
    }

    /// Closes a tile's player (its stream is freed) and leaves the slot
    /// empty, with a reason if the owner has one.
    public func clearTile(_ id: Int, reason: String? = nil) {
        guard tiles.indices.contains(id) else { return }
        tiles[id].player?.close()
        tiles[id].player = nil
        tiles[id].emptyReason = reason
        if audibleTileID == id { passSoundOn() }
        applySound()
    }

    /// The reason an empty slot can't take a channel right now; nil clears it.
    public func setEmptyReason(_ reason: String?, forTile id: Int) {
        guard tiles.indices.contains(id), tiles[id].isEmpty else { return }
        tiles[id].emptyReason = reason
    }

    /// Two, three or four tiles. Going down closes the players in the slots
    /// that go.
    public func setLayout(_ newLayout: Layout) {
        guard newLayout != layout else { return }
        if newLayout.tileCount < tiles.count {
            for tile in tiles[newLayout.tileCount...] {
                tile.player?.close()
            }
            tiles.removeLast(tiles.count - newLayout.tileCount)
        } else {
            tiles += (tiles.count..<newLayout.tileCount).map { Tile(id: $0) }
        }
        layout = newLayout
        if audiblePlayer == nil { passSoundOn() }
        applySound()
    }

    /// Closes every tile, freeing every stream (leaving multi-view).
    public func closeAll() {
        for tile in tiles {
            tile.player?.close()
        }
        tiles = (0..<layout.tileCount).map { Tile(id: $0) }
        audibleTileID = nil
    }

    private func passSoundOn() {
        audibleTileID = tiles.first(where: { !$0.isEmpty })?.id
    }

    private func applySound() {
        for tile in tiles {
            tile.player?.isMuted = tile.id != audibleTileID
        }
    }
}
