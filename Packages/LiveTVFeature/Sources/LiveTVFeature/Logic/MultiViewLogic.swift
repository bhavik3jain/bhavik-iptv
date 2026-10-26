import CoreGraphics
import Foundation
import PlayerKit

// Multi-view's rules (PLY-9, MAC-5) as values: the three arrangements, how
// big the tiles can be in the space there is, each source's stream limit,
// and what an empty tile says when the limits are why it's empty.

/// One, two or four tiles. PlayerKit's `MultiViewModel` knows two and four;
/// "one" is a two-tile model showing only the tile in focus, with the other
/// tile's stream closed so it isn't held for nothing.
enum MultiViewArrangement: String, CaseIterable, Hashable, Sendable, Identifiable {
    case one
    case two
    case four

    var id: String { rawValue }

    var modelLayout: MultiViewModel.Layout {
        self == .four ? .four : .two
    }

    var title: String {
        switch self {
        case .one: String(localized: "One")
        case .two: String(localized: "Side by side")
        case .four: String(localized: "Grid of four")
        }
    }

    var systemImage: String {
        switch self {
        case .one: "rectangle"
        case .two: "rectangle.split.2x1"
        case .four: "square.grid.2x2"
        }
    }
}

/// How many columns the tiles take and how big each 16:9 tile is, so the
/// grid fills the space above the now/next strip without scrolling: two
/// tiles sit side by side when the space is wide and stack when it's tall
/// (a phone, iPhone Duo's inner display in portrait).
struct MultiViewGridGeometry: Hashable, Sendable {
    var columns: Int
    var tileSize: CGSize

    static let aspectRatio: CGFloat = 16 / 9

    static func make(tileCount: Int, available: CGSize, spacing: CGFloat) -> MultiViewGridGeometry {
        let count = max(tileCount, 1)
        let candidates = count == 1 ? [1] : (count == 2 ? [1, 2] : [1, 2, 4])
        var best = MultiViewGridGeometry(columns: 1, tileSize: .zero)
        for columns in candidates {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let widthLimit = (available.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let heightLimit = (available.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            let width = max(0, min(widthLimit, heightLimit * aspectRatio))
            if width > best.tileSize.width + 0.5 {
                best = MultiViewGridGeometry(columns: columns, tileSize: CGSize(width: width, height: width / aspectRatio))
            }
        }
        return best
    }
}

/// A source's streams right now, as multi-view counts them: other devices'
/// who's-watching rows plus this screen's own tiles.
struct SourceStreamState: Hashable, Sendable, Identifiable {
    var sourceID: UUID
    var name: String
    var inUse: Int
    /// Nil when the source has no limit.
    var limit: Int?

    var id: UUID { sourceID }

    var isFull: Bool { limit.map { inUse >= $0 } ?? false }
}

/// Each source's limit (technical spec, Stream limits).
enum SourceLimits {
    /// Xtream reports its own (`max_connections`); otherwise the owner's
    /// setting on the source: 1 per MAC by default for Stalker, 0 meaning
    /// unlimited (an M3U playlist by default).
    static func limit(kindRaw: String, maxStreams: Int, accountMaxConnections: Int?) -> Int? {
        if kindRaw == "xtream", let reported = accountMaxConnections, reported > 0 {
            return reported
        }
        return maxStreams > 0 ? maxStreams : nil
    }

    /// The owner's setting before they change it, for a source the household
    /// store hasn't synced yet: one stream per MAC for a Stalker portal,
    /// unlimited otherwise (Xtream reports its own).
    static func defaultMaxStreams(kindRaw: String) -> Int {
        kindRaw == "stalker" ? 1 : 0
    }
}

/// What an empty tile and the channel picker say about stream limits.
enum StreamLimitAdvice {
    /// The empty tile's line when one or more sources are full, as in the
    /// mockup: "Provider A and Provider B are both at their stream limits.
    /// Pick a channel from Family playlist, or swap a tile." Nil when every
    /// source has room.
    static func emptyTileReason(_ states: [SourceStreamState]) -> String? {
        let full = states.filter(\.isFull)
        guard !full.isEmpty else { return nil }
        let open = states.filter { !$0.isFull }
        let fullNames = full.map(\.name).formatted(.list(type: .and))
        let openNames = open.map(\.name).formatted(.list(type: .or))

        if open.isEmpty {
            switch full.count {
            case 1:
                return String(localized: "\(fullNames) is at its stream limit. Swap a tile to watch another of its channels.")
            case 2:
                return String(localized: "\(fullNames) are both at their stream limits. Swap a tile to watch something else.")
            default:
                return String(localized: "\(fullNames) are all at their stream limits. Swap a tile to watch something else.")
            }
        }
        switch full.count {
        case 1:
            return String(localized: "\(fullNames) is at its stream limit. Pick a channel from \(openNames), or swap a tile.")
        case 2:
            return String(localized: "\(fullNames) are both at their stream limits. Pick a channel from \(openNames), or swap a tile.")
        default:
            return String(localized: "\(fullNames) are all at their stream limits. Pick a channel from \(openNames), or swap a tile.")
        }
    }

    /// The picker's note on a channel whose source is full: "Provider B is
    /// at its limit (2 of 2)".
    static func channelNote(_ state: SourceStreamState) -> String? {
        guard state.isFull, let limit = state.limit else { return nil }
        return String(localized: "\(state.name) is at its limit (\(state.inUse) of \(limit))")
    }
}
