import CatalogKit
import Foundation

// Which chips Live TV offers and which channels each one lists, in which
// order (LIV-1, FAV-1). Plain values: the screen asks these, then the
// catalog.

/// A chip in Live TV's category row.
enum LiveChip: Hashable, Sendable, Identifiable {
    /// The profile's favorite channels, in the order the profile set (FAV-1).
    case favorites
    case all
    /// A live category. Categories of the same name from different sources
    /// ("News" from two providers) share one chip, so a household with two
    /// sources sees one News, not two.
    case category(ids: [String], name: String)

    /// What the last-chip memory stores.
    var id: String {
        switch self {
        case .favorites: "favorites"
        case .all: "all"
        case .category(_, let name): "category:" + LiveChip.normalizedName(name)
        }
    }

    var title: String {
        switch self {
        case .favorites: String(localized: "Favorites")
        case .all: String(localized: "All channels")
        case .category(_, let name): name
        }
    }

    /// The chips in order: Favorites first (unless hidden, as for a Guest,
    /// who keeps none), All channels, then the live categories in the order
    /// the catalog gives them, merged by name.
    static func chips(categories: [CatalogCategory], showsFavorites: Bool) -> [LiveChip] {
        var chips: [LiveChip] = showsFavorites ? [.favorites, .all] : [.all]
        var order: [String] = []
        var merged: [String: (ids: [String], name: String)] = [:]
        for category in categories {
            let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = normalizedName(name)
            if merged[key] == nil {
                order.append(key)
                merged[key] = ([category.id], name)
            } else {
                merged[key]?.ids.append(category.id)
            }
        }
        chips += order.compactMap { key in merged[key].map { LiveChip.category(ids: $0.ids, name: $0.name) } }
        return chips
    }

    /// The chip to show: the remembered one if it is still offered;
    /// otherwise Favorites when the profile has some, else All channels.
    static func resolve(rememberedID: String?, chips: [LiveChip], hasFavorites: Bool) -> LiveChip {
        if let rememberedID, let chip = chips.first(where: { $0.id == rememberedID }) {
            return chip
        }
        if hasFavorites, chips.contains(.favorites) { return .favorites }
        return .all
    }

    static func normalizedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Channel order rules.
enum ChannelOrdering {
    /// Number first, then name, as the catalog orders one category; used
    /// when a merged chip joins categories from several sources. Channels
    /// without a number go last.
    static func byNumberThenName(_ channels: [CatalogChannel]) -> [CatalogChannel] {
        channels.sorted { a, b in
            switch (a.number, b.number) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.key.rawValue < b.key.rawValue : order == .orderedAscending
            }
        }
    }

    /// Joins several categories' channels, dropping repeats.
    static func merge(_ lists: [[CatalogChannel]]) -> [CatalogChannel] {
        guard lists.count > 1 else { return lists.first ?? [] }
        var seen = Set<ItemKey>()
        return byNumberThenName(lists.flatMap { $0 }.filter { seen.insert($0.key).inserted })
    }

    /// Favorite item keys (already in the profile's hand-set order, FAV-1)
    /// as catalog keys: channels only, repeats dropped, order kept.
    static func favoriteKeys(_ itemKeys: [String]) -> [ItemKey] {
        var seen = Set<String>()
        return itemKeys
            .filter { seen.insert($0).inserted }
            .map { ItemKey(rawValue: $0) }
            .filter { $0.kind == nil || $0.kind == .channel }
    }

    /// The queue channel up and down walk in the player (LIV-5): the chip's
    /// channels as item keys, in the order on screen.
    static func queue(_ channels: [CatalogChannel]) -> [String] {
        channels.map(\.key.rawValue)
    }
}

/// The last chip per profile, stored as one small JSON object in
/// `@AppStorage` (per device, like the rest of a screen's view state).
enum ChipMemory {
    static func decode(_ stored: String) -> [String: String] {
        guard let data = stored.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    static func encode(_ map: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(map), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func remembered(in stored: String, profileID: UUID?) -> String? {
        decode(stored)[key(profileID)]
    }

    static func remembering(_ chipID: String, profileID: UUID?, in stored: String) -> String {
        var map = decode(stored)
        map[key(profileID)] = chipID
        return encode(map)
    }

    private static func key(_ profileID: UUID?) -> String {
        profileID?.uuidString ?? "none"
    }
}
