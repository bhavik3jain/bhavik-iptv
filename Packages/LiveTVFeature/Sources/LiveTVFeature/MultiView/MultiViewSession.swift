import CatalogKit
import Core
import Foundation
import HouseholdKit
import Observation
import PlayerKit
import SourceKit

/// The tiles of one multi-view screen and the bookkeeping that keeps the
/// household's stream counts honest (PLY-9, HH-5, HH-6).
///
/// PlayerKit's `MultiViewModel` plays the tiles; this adds what the app's
/// playback coordinator does for the full-screen player but can't do here,
/// because multi-view builds its own players: a who's-watching row per tile
/// (written at play and stop, heartbeat every 10 minutes — never per
/// second), the Stalker keep-alive while a tile plays from a portal, the
/// one-tile arrangement, and a tile taken full screen and brought back.
@MainActor
@Observable
final class MultiViewSession {
    /// What a tile is showing, beyond its player.
    struct Occupant: Hashable {
        var channel: CatalogChannel
        /// The tile's who's-watching row; nil with no profile signed in.
        var playbackID: UUID?
    }

    /// A tile shown in the full-screen player.
    struct Expanded: Identifiable {
        let tileID: Int
        let player: PlayerModel
        var id: Int { tileID }
    }

    /// Heartbeats for who's-watching rows: every 10 minutes (CLAUDE.md).
    static let heartbeatInterval: TimeInterval = 10 * 60
    /// Stalker's watchdog, as a MAG box sends it: every couple of minutes.
    static let keepAliveInterval: TimeInterval = 2 * 60

    let model = MultiViewModel(layout: .four)
    private(set) var arrangement: MultiViewArrangement = .four
    /// The tile on screen in the one-tile arrangement.
    private(set) var focusTileID = 0
    private(set) var occupants: [Int: Occupant] = [:]
    private(set) var expanded: Expanded?
    @ObservationIgnored private var lastHeartbeat = Date.now

    /// The tiles drawn now: one in the one-tile arrangement, else all.
    var visibleTiles: [MultiViewModel.Tile] {
        arrangement == .one ? model.tiles.filter { $0.id == focusTileID } : model.tiles
    }

    /// The channel whose sound plays, for "Sound from …" and the strip.
    var audibleOccupant: Occupant? {
        model.audibleTileID.flatMap { occupants[$0] }
    }

    var audibleTileID: Int? { model.audibleTileID }

    /// Channels on screen, so the picker can say "On screen".
    var channelKeysOnScreen: Set<ItemKey> {
        Set(occupants.values.map(\.channel.key))
    }

    /// This screen's own rows, which the household's count already holds.
    var ownPlaybackIDs: Set<UUID> {
        Set(occupants.values.compactMap(\.playbackID))
    }

    /// Tiles on a source, optionally leaving one out (the tile being swapped
    /// gives its stream back).
    func tileCount(onSource sourceID: UUID, excludingTile excluded: Int? = nil) -> Int {
        occupants.filter { $0.key != excluded && $0.value.channel.sourceID == sourceID }.count
    }

    func occupant(ofTile id: Int) -> Occupant? { occupants[id] }

    // MARK: Playing

    /// Opens a channel live in a tile, replacing what it held.
    func play(_ channel: CatalogChannel, programme: CatalogProgramme?, inTile id: Int, catalog: CatalogService, store: HouseholdStore, profileID: UUID?) {
        guard model.tiles.indices.contains(id) else { return }
        stopRow(ofTile: id, store: store)
        let item = LivePlayerItems.live(channel, programme: programme, catalog: catalog)
        model.play(item, inTile: id)
        let playbackID = profileID.map {
            store.startPlayback(profileID: $0, sourceID: channel.sourceID, itemKey: channel.key.rawValue, title: item.title, deviceName: DeviceName.current)
        }
        occupants[id] = Occupant(channel: channel, playbackID: playbackID)
        if arrangement == .one { focusTileID = id }
    }

    /// The slot a newly picked channel goes in: the first empty visible one.
    var firstEmptyVisibleTileID: Int? {
        visibleTiles.first(where: \.isEmpty)?.id
    }

    /// Closes a tile's player and frees its stream.
    func clear(tile id: Int, store: HouseholdStore) {
        stopRow(ofTile: id, store: store)
        model.clearTile(id)
    }

    /// Closes every tile (leaving multi-view). Every stream is freed.
    func closeAll(store: HouseholdStore) {
        collapse()
        for id in Array(occupants.keys) {
            stopRow(ofTile: id, store: store)
        }
        model.closeAll()
    }

    func giveSound(toTile id: Int) {
        model.giveSound(toTile: id)
    }

    // MARK: Arrangement

    /// One, two or four tiles. Going down keeps the tile with the sound on
    /// screen, moving it into a remaining slot if it sat in one going away.
    func setArrangement(_ new: MultiViewArrangement, store: HouseholdStore) {
        guard new != arrangement else { return }
        switch new {
        case .one:
            let keep = model.audibleTileID ?? model.tiles.first(where: { !$0.isEmpty })?.id ?? 0
            for tile in model.tiles where tile.id != keep && !tile.isEmpty {
                clear(tile: tile.id, store: store)
            }
            let target = keep < 2 ? keep : 0
            if keep != target { move(tile: keep, to: target) }
            model.setLayout(.two)
            focusTileID = target
        case .two:
            if arrangement == .four {
                // Keep the tile with the sound if it's in the bottom row.
                if let audible = model.audibleTileID, audible >= 2 {
                    let target = model.tiles.prefix(2).first(where: \.isEmpty)?.id ?? 1
                    if !model.tiles[target].isEmpty { clear(tile: target, store: store) }
                    move(tile: audible, to: target)
                }
                for id in [2, 3] where occupants[id] != nil {
                    clear(tile: id, store: store)
                }
            }
            model.setLayout(.two)
        case .four:
            model.setLayout(.four)
        }
        arrangement = new
    }

    /// Moves a tile's channel to another slot. The stream restarts in the
    /// new slot (PlayerKit's tiles are fixed positions); the who's-watching
    /// row moves with it, since it is the same channel on the same source.
    private func move(tile from: Int, to target: Int) {
        guard from != target, let player = model.tiles[from].player else { return }
        let hadSound = model.audibleTileID == from
        let item = player.item
        let occupant = occupants[from]
        occupants[from] = nil
        model.clearTile(from)
        model.play(item, inTile: target)
        occupants[target] = occupant
        if hadSound { model.giveSound(toTile: target) }
    }

    // MARK: Full screen

    /// Shows a tile in the full-screen player with its sound. The player's
    /// multi-view button comes back here with the tile still playing; its
    /// close button ends that player, so the tile reopens the channel.
    func expand(tile id: Int) {
        guard model.tiles.indices.contains(id), let player = model.tiles[id].player else { return }
        model.giveSound(toTile: id)
        player.onShowMultiView = { [weak self] in self?.collapse() }
        player.onClose = { [weak self] in self?.expandedPlayerClosed(tile: id) }
        expanded = Expanded(tileID: id, player: player)
    }

    /// Back from full screen, the tile still playing.
    func collapse() {
        expanded?.player.onClose = nil
        expanded?.player.onShowMultiView = nil
        expanded = nil
    }

    private func expandedPlayerClosed(tile id: Int) {
        guard let expanded, expanded.tileID == id else { return }
        let item = expanded.player.item
        self.expanded = nil
        guard occupants[id] != nil else { return }
        model.play(item, inTile: id)
        model.giveSound(toTile: id)
    }

    // MARK: Upkeep

    /// Heartbeats the rows when 10 minutes have passed, and keeps Stalker
    /// sessions alive. Called every couple of minutes while the screen shows.
    func upkeep(now: Date, catalog: CatalogService, store: HouseholdStore) async {
        if now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval {
            lastHeartbeat = now
            for id in ownPlaybackIDs {
                store.heartbeat(playbackID: id)
            }
        }
        let sources = Set(occupants.values.map(\.channel.sourceID))
        for sourceID in sources {
            await catalog.keepAlive(sourceID: sourceID)
        }
    }

    private func stopRow(ofTile id: Int, store: HouseholdStore) {
        if let playbackID = occupants[id]?.playbackID {
            store.stopPlayback(playbackID: playbackID)
        }
        occupants[id] = nil
    }
}

/// Player items for Live TV's own players (multi-view tiles). Each resolves
/// a fresh link through the catalog every time it is asked (Stalker links
/// expire), mapped to PlayerKit's descriptor.
enum LivePlayerItems {
    @MainActor
    static func live(_ channel: CatalogChannel, programme: CatalogProgramme?, catalog: CatalogService) -> PlayerItem {
        let key = channel.key
        let numbered = ChannelText.numberedName(number: channel.number, name: channel.name)
        return PlayerItem(
            id: key.rawValue,
            title: programme?.title ?? channel.name,
            subtitle: programme.map { numbered + " · " + HearthFormat.compactTimeRange($0.start, $0.end) } ?? numbered,
            channelNumber: channel.number,
            channelName: channel.name,
            logoURL: channel.logoURL,
            isLive: true,
            programmeStart: programme?.start,
            programmeEnd: programme?.end,
            hasArchive: channel.hasArchive,
            resolve: { request in
                try await StreamDescriptors.resolve(key, request: request, catalog: catalog)
            }
        )
    }
}

/// SourceKit's links as PlayerKit's descriptors.
enum StreamDescriptors {
    /// The two enums share their cases, so the raw value carries across.
    static func format(_ hint: StreamFormatHint) -> StreamFormat {
        StreamFormat(rawValue: hint.rawValue) ?? .unknown
    }

    static func descriptor(for link: StreamLink) -> StreamDescriptor {
        StreamDescriptor(url: link.url, headers: link.headers, format: format(link.formatHint), isLive: link.isLive)
    }

    @MainActor
    static func resolve(_ key: ItemKey, request: PlayerResolveRequest, catalog: CatalogService) async throws -> StreamDescriptor {
        let link: StreamLink
        switch request {
        case .standard:
            link = try await catalog.streamLink(for: key)
        case .fromStart(let start, let duration):
            link = try await catalog.streamLink(for: key, catchupStart: start, catchupDuration: duration)
        }
        return descriptor(for: link)
    }
}
