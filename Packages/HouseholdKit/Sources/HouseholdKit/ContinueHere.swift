import CoreData
import Foundation

// Continue on Apple TV (docs/designs/continue-on-tv.md): what another device
// of the household is playing for a profile, which this device can carry on
// with; and, on the device that was playing it, how it tells it was taken
// over. Built on the who's-watching rows (HH-5) alone — no new entity or
// attribute, so nothing waits on a CloudKit schema deploy.
//
// The handover: the device taking over deletes the other device's rows (its
// streams are free at once, in every device's count) and plays the same
// things, writing rows of its own for the same profile and items. The other
// device sees its rows gone while still fresh, and another device's rows for
// the same items, and stops.

/// Something another device is playing for a profile right now, which this
/// device can carry on with.
public struct ContinueOffer: Identifiable, Sendable, Hashable {
    public enum Content: Sendable, Hashable {
        /// A live channel (or a programme on it, which carries on live).
        case channel(itemKey: String)
        /// Multi-view: its channels in tile order, at most four.
        case multiView(itemKeys: [String])
        /// A movie or an episode, open in the player there (playing or
        /// paused); its position is the profile's progress row.
        case video(itemKey: String)
    }

    public var content: Content
    /// The device as its rows name it: "Bhavik's iPhone", "MacBook Pro".
    public var deviceName: String
    public var profileID: UUID
    /// What the rows say, in the content's order: "Fieldhouse Sports",
    /// "The Lighthouse · S2 E4".
    public var titles: [String]
    /// The other device's who's-watching rows, ended when this device takes
    /// over so that device stops and its streams are free.
    public var playbackIDs: [UUID]
    /// When the newest of those rows started.
    public var startedAt: Date

    public init(content: Content, deviceName: String, profileID: UUID, titles: [String], playbackIDs: [UUID], startedAt: Date) {
        self.content = content
        self.deviceName = deviceName
        self.profileID = profileID
        self.titles = titles
        self.playbackIDs = playbackIDs
        self.startedAt = startedAt
    }

    public var id: String {
        switch content {
        case .channel(let key): "\(deviceName)|channel|\(key)"
        case .multiView(let keys): "\(deviceName)|multiview|\(keys.joined(separator: ","))"
        case .video(let key): "\(deviceName)|video|\(key)"
        }
    }

    /// Every item key the offer plays.
    public var itemKeys: [String] {
        switch content {
        case .channel(let key), .video(let key): [key]
        case .multiView(let keys): keys
        }
    }
}

/// Which of the household's who's-watching rows make offers for a profile.
public enum ContinueOfferRules {
    /// Multi-view has at most four tiles.
    public static let maxTiles = 4

    /// The profile's fresh rows from other devices, one offer per device and
    /// kind, the most recently started first:
    ///
    /// - a device's one channel row is a channel; two or more are its
    ///   multi-view (one player per device, one thing at a time), in tile
    ///   order — rows sort by when they started, and multi-view writes its
    ///   tiles' start times in slot order;
    /// - a device's newest movie or episode row is a video;
    /// - this device's own rows (by id, and by this device's name, which
    ///   also covers rows it wrote before a relaunch), stale rows and running
    ///   downloads' rows (`PlaybackRowKey`) are left out.
    public static func offers(profileID: UUID, playbacks: [PlaybackRecord], ownPlaybackIDs: Set<UUID>, ownDeviceName: String, now: Date) -> [ContinueOffer] {
        let rows = playbacks.filter { row in
            row.profileID == profileID
                && !row.isStale(at: now)
                && !ownPlaybackIDs.contains(row.id)
                && row.deviceName != ownDeviceName
                && !PlaybackRowKey.isDownload(row.itemKey)
        }
        var offers: [ContinueOffer] = []
        for (device, group) in Dictionary(grouping: rows, by: \.deviceName) {
            let ordered = group.sorted(by: tileOrder)
            var seenChannels = Set<String>()
            let channels = ordered.filter { ItemKeyHint.kind(of: $0.itemKey) == "channel" && seenChannels.insert($0.itemKey).inserted }
            if channels.count == 1, let row = channels.first {
                offers.append(ContinueOffer(
                    content: .channel(itemKey: row.itemKey),
                    deviceName: device,
                    profileID: profileID,
                    titles: [row.title],
                    playbackIDs: ordered.filter { $0.itemKey == row.itemKey }.map(\.id),
                    startedAt: row.startedAt
                ))
            } else if channels.count > 1 {
                let tiles = Array(channels.prefix(maxTiles))
                let keys = tiles.map(\.itemKey)
                offers.append(ContinueOffer(
                    content: .multiView(itemKeys: keys),
                    deviceName: device,
                    profileID: profileID,
                    titles: tiles.map(\.title),
                    // Every channel row of the device: a fifth (or a
                    // duplicate) goes too, so nothing keeps playing there.
                    playbackIDs: ordered.filter { ItemKeyHint.kind(of: $0.itemKey) == "channel" }.map(\.id),
                    startedAt: tiles.map(\.startedAt).max() ?? now
                ))
            }
            let videos = ordered.filter { ["movie", "episode"].contains(ItemKeyHint.kind(of: $0.itemKey)) }
            if let newest = videos.max(by: { tileOrder($0, $1) }) {
                offers.append(ContinueOffer(
                    content: .video(itemKey: newest.itemKey),
                    deviceName: device,
                    profileID: profileID,
                    titles: [newest.title],
                    playbackIDs: videos.filter { $0.itemKey == newest.itemKey }.map(\.id),
                    startedAt: newest.startedAt
                ))
            }
        }
        return offers.sorted { lhs, rhs in
            lhs.startedAt != rhs.startedAt ? lhs.startedAt > rhs.startedAt : lhs.id < rhs.id
        }
    }

    /// When rows started, then by id, so the order never flickers.
    static func tileOrder(_ lhs: PlaybackRecord, _ rhs: PlaybackRecord) -> Bool {
        lhs.startedAt != rhs.startedAt ? lhs.startedAt < rhs.startedAt : lhs.id.uuidString < rhs.id.uuidString
    }
}

/// The item key a who's-watching row carries. A running download's row
/// (DL-2) marks its item's key, so nothing mistakes a download for something
/// playing: Continue on Apple TV never offers one.
public enum PlaybackRowKey {
    static let downloadSuffix = "#download"

    public static func download(_ itemKey: String) -> String {
        itemKey + downloadSuffix
    }

    public static func isDownload(_ rowKey: String) -> Bool {
        rowKey.hasSuffix(downloadSuffix)
    }
}

/// Another device took over what this device was playing.
public struct PlaybackTakeover: Sendable, Hashable {
    /// This device's rows it ended: stop what they were for.
    public var endedIDs: Set<UUID>
    /// The device now playing it, as its rows name it.
    public var deviceName: String

    public init(endedIDs: Set<UUID>, deviceName: String) {
        self.endedIDs = endedIDs
        self.deviceName = deviceName
    }
}

/// How a device tells that another took over what it was playing.
enum TakeoverRules {
    /// A row this device wrote less than this long ago can't have been
    /// purged as stale (15 minutes unseen, by the purging device's clock),
    /// with two minutes left for clocks that disagree. Heartbeats come every
    /// 10 minutes, so a playing device's rows are always inside it.
    static let window: TimeInterval = PlaybackRecord.staleAfter - 2 * 60

    /// `written` is one session's rows as this device last wrote them (a
    /// player's one row, a multi-view's tiles), `lastSeenAt` being its last
    /// write. Taken over when a row is gone from the store while still inside
    /// the window, and another device is now playing its item for the same
    /// profile. Every gone row of the session ends with it: the device that
    /// took over a multi-view ended all its tiles, even one it had no stream
    /// free for. A gone row with no such successor was purged while this
    /// device was away, or the other device couldn't start: a heartbeat
    /// writes it again (HH-5).
    static func takeover(written: [PlaybackRecord], present: Set<UUID>, others: [PlaybackRecord], now: Date) -> PlaybackTakeover? {
        let gone = written.filter { !present.contains($0.id) && now.timeIntervalSince($0.lastSeenAt) < window }
        guard !gone.isEmpty else { return nil }
        let successor = others
            .filter { other in
                !other.isStale(at: now) && gone.contains { $0.profileID == other.profileID && $0.itemKey == other.itemKey }
            }
            .max { $0.startedAt < $1.startedAt }
        guard let successor else { return nil }
        return PlaybackTakeover(endedIDs: Set(gone.map(\.id)), deviceName: successor.deviceName)
    }
}

// MARK: - The store's side

extension HouseholdStore {
    /// What other devices are playing for this profile now, that this device
    /// (named `deviceName`) can carry on with; the most recent first. Empty
    /// for a Guest: everyone shares that profile, so another device's Guest
    /// is somebody else.
    public func continueOffers(profileID: UUID, deviceName: String, now: Date = .now) -> [ContinueOffer] {
        guard let profile = profiles.first(where: { $0.id == profileID }), !profile.isGuest else { return [] }
        return ContinueOfferRules.offers(
            profileID: profileID,
            playbacks: activePlaybacks,
            ownPlaybackIDs: ownPlaybackIDs,
            ownDeviceName: deviceName,
            now: now
        )
    }

    /// Ends other devices' who's-watching rows, in one write, as this device
    /// takes over what they were playing: their streams are free at once,
    /// and each of those devices stops once it sees this one playing the
    /// same thing (`takeover(ofPlaybacks:)`).
    public func endPlaybacks(_ ids: some Sequence<UUID>) {
        let ids = Set(ids)
        guard !ids.isEmpty else { return }
        for id in ids { ownPlaybacks[id] = nil }
        let rows = fetch(PlaybackEntity.self, HouseholdModel.Entity.playback).filter { $0.id.map(ids.contains) ?? false }
        guard !rows.isEmpty else { return }
        rows.forEach(viewContext.delete)
        commit("end playbacks")
    }

    /// Whether another device took over this device's rows `ids` — one
    /// session's: a player's row, or a multi-view's tiles. Call it when the
    /// store changes; stop what the ended rows were for, which also stops
    /// their rows here (`stopPlayback`).
    public func takeover(ofPlaybacks ids: some Sequence<UUID>, now: Date = .now) -> PlaybackTakeover? {
        let written = ids.compactMap { ownPlaybacks[$0] }
        guard !written.isEmpty else { return nil }
        let present = Set(fetch(PlaybackEntity.self, HouseholdModel.Entity.playback).compactMap(\.id))
        let own = ownPlaybackIDs
        return TakeoverRules.takeover(
            written: written,
            present: present,
            others: activePlaybacks.filter { !own.contains($0.id) },
            now: now
        )
    }
}

#if DEBUG
extension HouseholdStore {
    /// The demo's other devices (`-SeedContinueOffers YES`): a row as another
    /// device of the household writes it, which this device doesn't count as
    /// its own. It never heartbeats, so it goes stale in 15 minutes.
    @discardableResult
    public func seedPlaybackFromAnotherDevice(profileID: UUID, sourceID: UUID, itemKey: String, title: String, deviceName: String, startedAt: Date) -> UUID {
        let id = startPlayback(profileID: profileID, sourceID: sourceID, itemKey: itemKey, title: title, deviceName: deviceName, startedAt: startedAt)
        ownPlaybacks[id] = nil
        return id
    }
}
#endif
