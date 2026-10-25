import Foundation

// The household's decisions as plain values: which duplicate survives a fold,
// where a moved favorite lands, what counts as watched, who the members are.
// `HouseholdStore` applies them to Core Data; the tests pin them without it.

/// Progress rules (VOD-3, HOME-1, SER-2).
public enum ProgressRules {
    /// A movie or episode is watched once 95% of it has played (VOD-3).
    public static let watchedFraction = 0.95

    public static func isWatched(position: TimeInterval, duration: TimeInterval) -> Bool {
        duration > 0 && position / duration >= watchedFraction
    }

    /// Started and not finished: what Continue watching lists.
    static func isUnfinished(_ row: ProgressRecord) -> Bool {
        !row.watched && row.position > 0
    }

    /// Unfinished movies and episodes, most recent first, one per series (the
    /// latest episode touched), at most `limit`. Catch-up rows are live TV
    /// and never "continue".
    static func continueWatching(_ rows: [ProgressRecord], limit: Int) -> [ProgressRecord] {
        var seenSeries = Set<String>()
        var result: [ProgressRecord] = []
        for row in rows.sorted(by: newestFirst) where row.kind != .catchup {
            // The newest row of a series decides: an older unfinished episode
            // behind a newer finished one is not where the person is.
            if let series = row.seriesKey {
                guard seenSeries.insert(series).inserted else { continue }
            }
            guard isUnfinished(row) else { continue }
            result.append(row)
            if result.count == limit { break }
        }
        return result
    }

    /// Each series' most recently touched episode row, most recent first.
    static func seriesInProgress(_ rows: [ProgressRecord], limit: Int) -> [ProgressRecord] {
        var seen = Set<String>()
        var result: [ProgressRecord] = []
        for row in rows.sorted(by: newestFirst) {
            guard let series = row.seriesKey, seen.insert(series).inserted else { continue }
            result.append(row)
            if result.count == limit { break }
        }
        return result
    }

    /// Most recent first; equal times by id, so the order never flickers.
    static func newestFirst(_ lhs: ProgressRecord, _ rhs: ProgressRecord) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// Which row survives when iCloud brings duplicates (technical spec, Sync and
/// sharing rules). Nothing in CloudKit is unique, so two devices can each
/// write "the same" favorite, progress row or household before seeing the
/// other's. Every rule picks the same survivor on every device — ties are
/// broken by the row's synced `id`, never by a local object id — so two
/// devices folding at once delete the same rows rather than each other's
/// keepers (Multitrack's FinanceFold lesson).
enum FoldRules {
    struct Row: Sendable, Hashable {
        var date: Date
        var id: String
        /// Households only: this one is the root of a share, which must
        /// never be folded away (deleting it ends the share).
        var isShared = false
    }

    /// Favorites: the earliest `addedAt` wins, keeping its hand-set place.
    static func favoriteKeeper(_ rows: [Row]) -> Int? {
        keeper(rows) { lhs, rhs in
            sameInstant(lhs.date, rhs.date) ? lhs.id < rhs.id : lhs.date < rhs.date
        }
    }

    /// Progress: the later `updatedAt` wins, whole row.
    static func progressKeeper(_ rows: [Row]) -> Int? {
        keeper(rows) { lhs, rhs in
            sameInstant(lhs.date, rhs.date) ? lhs.id < rhs.id : lhs.date > rhs.date
        }
    }

    /// Households made by two devices before either synced: a shared one
    /// first, then the oldest.
    static func householdKeeper(_ rows: [Row]) -> Int? {
        keeper(rows) { lhs, rhs in
            if lhs.isShared != rhs.isShared { return lhs.isShared }
            return sameInstant(lhs.date, rhs.date) ? lhs.id < rhs.id : lhs.date < rhs.date
        }
    }

    /// The index of the row `first` orders first.
    private static func keeper(_ rows: [Row], first: (Row, Row) -> Bool) -> Int? {
        rows.indices.min { first(rows[$0], rows[$1]) }
    }

    /// CloudKit keeps dates to the millisecond, so a row and its synced copy
    /// can differ by less than that; compared exactly, two devices ordered
    /// such a pair differently.
    static func sameInstant(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 0.001
    }
}

/// Hand-set order kept in a Double (FAV-1), so moving one favorite rewrites
/// one row — each synced write wakes every household device.
enum FractionalOrder {
    /// `items` in the order SwiftUI's `move(fromOffsets:toOffset:)` leaves
    /// them (reimplemented: HouseholdKit doesn't import SwiftUI).
    static func moved<T>(_ items: [T], fromOffsets: IndexSet, toOffset: Int) -> [T] {
        let valid = fromOffsets.filter { $0 < items.count }
        let moving = valid.map { items[$0] }
        var rest = items.enumerated().filter { !valid.contains($0.offset) }.map(\.element)
        let insertAt = toOffset - valid.filter { $0 < toOffset }.count
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        return rest
    }

    /// The sort orders to write after a move, keyed by the item's index in
    /// `orders` (which is sorted ascending). Only the moved items get new
    /// values, spaced between their new neighbours; when the gap is too
    /// small to split (after very many moves into one spot) every item is
    /// renumbered 0, 1, 2… instead, and only the ones that change are written.
    static func writes(orders: [Double], fromOffsets: IndexSet, toOffset: Int) -> [Int: Double] {
        let indices = Array(orders.indices)
        let newOrder = moved(indices, fromOffsets: fromOffsets, toOffset: toOffset)
        guard newOrder != indices else { return [:] }
        let movedSet = Set(fromOffsets.filter { $0 < orders.count })
        guard let firstMoved = newOrder.firstIndex(where: movedSet.contains) else { return [:] }
        let count = movedSet.count
        let lower = firstMoved > 0 ? orders[newOrder[firstMoved - 1]] : nil
        let upperPosition = firstMoved + count
        let upper = upperPosition < newOrder.count ? orders[newOrder[upperPosition]] : nil

        var values: [Double] = []
        switch (lower, upper) {
        case let (lower?, upper?):
            let step = (upper - lower) / Double(count + 1)
            values = (1...count).map { lower + step * Double($0) }
        case let (lower?, nil):
            values = (1...count).map { lower + Double($0) }
        case let (nil, upper?):
            values = (1...count).map { upper - Double(count + 1 - $0) }
        case (nil, nil):
            values = (0..<count).map(Double.init)
        }

        // Distinct from each other and from both neighbours, or renumber.
        let bounds = [lower].compactMap { $0 } + values + [upper].compactMap { $0 }
        let distinct = zip(bounds, bounds.dropFirst()).allSatisfy { $0 < $1 && $1 - $0 > 1e-9 }
        guard distinct else {
            var renumbered: [Int: Double] = [:]
            for (position, index) in newOrder.enumerated() where orders[index] != Double(position) {
                renumbered[index] = Double(position)
            }
            return renumbered
        }
        var result: [Int: Double] = [:]
        for (offset, value) in values.enumerated() {
            result[newOrder[firstMoved + offset]] = value
        }
        return result
    }
}

/// What HouseholdKit reads from a CatalogKit item key without importing
/// CatalogKit (features join the kits, the kits never join each other). The
/// key's shape is CatalogKit's contract:
/// `<source UUID>/<kind>/<escaped id>`, and for an episode
/// `<source UUID>/episode/<escaped series id>/<season>/<number>`.
enum ItemKeyHint {
    private static func parts(_ key: String) -> [Substring] {
        key.split(separator: "/", omittingEmptySubsequences: false)
    }

    /// The source an item comes from: favorites and progress of a removed
    /// source are hidden, not deleted (SRC-9).
    static func sourceID(of key: String) -> UUID? {
        parts(key).first.flatMap { UUID(uuidString: String($0)) }
    }

    static func kind(of key: String) -> String? {
        let parts = parts(key)
        return parts.count > 1 ? String(parts[1]) : nil
    }

    /// For an episode key: its series' key, season and number.
    static func episode(of key: String) -> (seriesKey: String, season: Int, episode: Int)? {
        let parts = parts(key)
        guard parts.count == 5, parts[1] == "episode",
              let season = Int(parts[3]), let number = Int(parts[4]) else { return nil }
        return ("\(parts[0])/series/\(parts[2])", season, number)
    }

    static func progressKind(of key: String) -> ProgressKind {
        switch kind(of: key) {
        case "episode": .episode
        case "channel", "programme", "catchup": .catchup
        default: .movie
        }
    }
}

/// A share participant reduced to what the Household screen shows.
struct ShareParticipantInfo: Sendable, Hashable {
    var id: String
    var displayName: String
    var isOwner: Bool
    var isCurrentUser: Bool
    /// Removed from the share (left or taken off by the owner).
    var isRemoved: Bool = false
}

/// Members from the share's participants plus the owner-written MemberRole
/// rows (HH-2, SRC-8). Roles are the app's, not iCloud's: every participant
/// has read-write access, because each saves their own favorites and progress.
enum MemberList {
    /// The id of the only member before the household is shared.
    static let ownerID = "owner"

    static func make(participants: [ShareParticipantInfo], roles: [String: MemberRole], ownerFallbackName: String) -> [MemberRecord] {
        let present = participants.filter { !$0.isRemoved }
        guard !present.isEmpty else {
            return [MemberRecord(id: ownerID, displayName: ownerFallbackName, role: .owner, isCurrentUser: true)]
        }
        return present
            .map { participant in
                MemberRecord(
                    id: participant.id,
                    displayName: participant.displayName,
                    role: participant.isOwner ? .owner : (roles[participant.id].flatMap { $0 == .owner ? nil : $0 } ?? .watch),
                    isCurrentUser: participant.isCurrentUser
                )
            }
            .sorted { lhs, rhs in
                if (lhs.role == .owner) != (rhs.role == .owner) { return lhs.role == .owner }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    /// This device's member's role. The owner while the household is this
    /// person's own (in the private store); a participant gets the role the
    /// owner wrote for them, and "can watch" until one arrives — controls
    /// appear a moment late rather than showing logins to a watcher.
    static func currentRole(isParticipant: Bool, currentParticipantID: String?, roles: [String: MemberRole]) -> MemberRole {
        guard isParticipant else { return .owner }
        guard let id = currentParticipantID, let role = roles[id], role != .owner else { return .watch }
        return role
    }

    /// When two devices of the owner set a role before syncing, the less
    /// privileged one stands until the owner sets it again: the same pick on
    /// every device, and never more access than was meant.
    static func foldedRole(_ roles: [MemberRole]) -> MemberRole {
        if roles.contains(.watch) { return .watch }
        if roles.contains(.manage) { return .manage }
        return roles.first ?? .watch
    }
}

/// Which profile a device opens at launch (PRF-2, PRF-9).
enum ProfileRestore {
    /// The always-open profile, else the only one, else nil (the gate asks).
    /// Never the last-used one when there are several, as Netflix does.
    static func pick(alwaysOpen: UUID?, profiles: [ProfileRecord]) -> ProfileRecord? {
        if let alwaysOpen, let profile = profiles.first(where: { $0.id == alwaysOpen }) {
            return profile
        }
        return profiles.count == 1 ? profiles[0] : nil
    }
}

/// Streams in use on one source (HH-6).
enum StreamRules {
    static func usage(
        sourceID: UUID,
        limit: Int?,
        playbacks: [PlaybackRecord],
        excluding: UUID?,
        ownPlaybackIDs: Set<UUID>,
        now: Date
    ) -> StreamUsage {
        let inUse = playbacks
            .filter { $0.sourceID == sourceID && $0.id != excluding && !$0.isStale(at: now) }
            .sorted { lhs, rhs in
                // Other devices first: they're who the warning names.
                let lhsOwn = ownPlaybackIDs.contains(lhs.id), rhsOwn = ownPlaybackIDs.contains(rhs.id)
                if lhsOwn != rhsOwn { return !lhsOwn }
                return lhs.startedAt < rhs.startedAt
            }
        return StreamUsage(sourceID: sourceID, limit: limit, inUse: inUse)
    }
}

/// Sets of keys stored as JSON arrays in one string attribute: CloudKit has
/// no set type, and a transformable attribute would need a value transformer
/// registered before the store loads.
enum JSONList {
    static func decode(_ text: String) -> Set<String> {
        guard let data = text.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(array)
    }

    /// Sorted, so the same set always writes the same string and an unchanged
    /// set is never a synced write.
    static func encode(_ set: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(set.sorted()),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func decodeUUIDs(_ text: String) -> Set<UUID> {
        Set(decode(text).compactMap(UUID.init(uuidString:)))
    }

    static func encode(_ ids: Set<UUID>) -> String {
        encode(Set(ids.map(\.uuidString)))
    }
}
