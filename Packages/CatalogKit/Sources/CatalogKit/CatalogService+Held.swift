import CoreData
import Foundation
import SourceKit

// Titles the household holds that this device's catalog never stored.
//
// Each device keeps its own catalog, and a big Stalker portal is kept as each
// category's first page plus whatever that device browsed or searched. A show
// found by search and favorited on the iPhone reaches the Apple TV's My List
// through iCloud as an item key that catalog doesn't hold. A Stalker portal
// can't be asked for a title by id (by id it lists only seasons and files,
// with no name or poster; checked on the owner's portal, 2026-11-07), so the
// household row also carries the title's name, written by a device whose
// catalog held it, and the device that lacks it searches its provider by that
// name. The app passes both across: CatalogKit never reads iCloud.

/// A movie or show the household holds (a favorite, something in progress),
/// as the app hands it over from iCloud.
public struct HeldItem: Hashable, Sendable {
    /// A movie, show or episode key (an episode stands for its show).
    public var key: ItemKey
    /// The name a catalog that held it knew it by (for an episode, its
    /// show's); empty when no device has written one yet.
    public var title: String

    public init(key: ItemKey, title: String = "") {
        self.key = key
        self.title = title
    }
}

extension CatalogService {
    /// For each held movie or show the catalog doesn't hold, whose source
    /// keeps that list only in part and that has a name to go by: searches
    /// the provider by its name (`searchProviders`), so the title joins the
    /// live catalog and My List, Continue watching and its page show it with
    /// its name and artwork, and it plays. `CatalogImporter.keepUnlisted`
    /// keeps it over later refreshes. A list kept whole is left alone: a
    /// title missing from it is gone. Each query goes to a provider once per
    /// catalog, as a typed search's does, so calling this again costs
    /// nothing. Returns how many titles the searches added (the held ones
    /// and anything else they found); `revision` bumps when any were.
    @discardableResult
    public func resolveHeldItems(_ items: [HeldItem]) async -> Int {
        let wanted = heldItemsToLookUp(items)
        guard !wanted.isEmpty, openStore() != nil else { return 0 }
        let keys = Set(wanted.map(\.key))
        heldKeysLookingUp.formUnion(keys)
        defer { heldKeysLookingUp.subtract(keys) }

        var added = 0
        for item in wanted {
            for query in HeldTitleSearch.queries(for: item.title) {
                // An earlier item's search may have brought this one too.
                if queryContains(item.key) || Task.isCancelled { break }
                added += await searchProviders(query, showingProgress: false)
            }
        }
        return added
    }

    /// True while `resolveHeldItems` is searching for this title: My List
    /// and the title's page say it's on its way, not that it's gone.
    public func isLookingUp(_ key: ItemKey) -> Bool {
        heldKeysLookingUp.contains(key)
    }

    /// The name to write on a household row for a key, so another device can
    /// search for it: the movie's or show's, and for an episode its show's.
    /// Read whatever the current profile's rules hide, since it's written
    /// down, not shown. Nil when the catalog doesn't hold it.
    public func heldTitle(for key: ItemKey) -> String? {
        let row: NSManagedObject?
        switch key.kind {
        case .movie?: row = liveRow(CatalogModel.Entity.movie, key: key)
        case .series?: row = liveRow(CatalogModel.Entity.series, key: key)
        case .episode?: row = key.seriesKey.flatMap { liveRow(CatalogModel.Entity.series, key: $0) }
        case .channel?, nil: row = nil
        }
        let name = row?.string("name").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    /// The movies and shows worth searching for, once each, in order: not in
    /// the catalog, not being searched for already, with a name, and from a
    /// source that keeps that list only in part.
    func heldItemsToLookUp(_ items: [HeldItem]) -> [HeldItem] {
        var titles: [ItemKey: String] = [:]
        var order: [ItemKey] = []
        for item in items {
            let key: ItemKey
            switch item.key.kind {
            case .movie?, .series?: key = item.key
            case .episode?: guard let series = item.key.seriesKey else { continue }; key = series
            case .channel?, nil: continue
            }
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if titles[key] == nil { order.append(key) }
            if titles[key]?.isEmpty ?? true { titles[key] = title }
        }
        return order.compactMap { key in
            guard let title = titles[key], !title.isEmpty,
                  let sourceID = key.sourceID, let kind = key.kind,
                  source(sourceID) != nil, keepsInPart(sourceID, kind),
                  !heldKeysLookingUp.contains(key), !queryContains(key)
            else { return nil }
            return HeldItem(key: key, title: title)
        }
    }

    /// True when the source's movie (or show) list is kept a page per
    /// category: its categories carry browse cursors.
    func keepsInPart(_ sourceID: UUID, _ kind: ItemKind) -> Bool {
        let contentKind: ContentKind
        switch kind {
        case .movie: contentKind = .vod
        case .series: contentKind = .series
        case .channel, .episode: return false
        }
        let prefix = CategoryKey.make(source: sourceID, kind: contentKind.rawValue, remoteID: "")
        return persisted[sourceID]?.browseCursors.keys.contains { $0.hasPrefix(prefix) } ?? false
    }
}

/// What a held title is searched for by. A portal's names carry decorations
/// ("Greys Anatomy - ENGLISH | TV SERIES", "EN | Lupin (2021)") that its
/// search doesn't match: on the owner's portal the whole name found nothing
/// and "Greys Anatomy" found the show first, among ten (2026-11-07). So the
/// name's longest plain part goes first, and the whole name follows for a
/// portal that only matches that.
enum HeldTitleSearch {
    static let separators = [" - ", " – ", " — ", " | ", "|", " (", " [", ")", "]"]

    static func queries(for title: String) -> [String] {
        let full = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard SearchKey.normalize(full).count >= 2 else { return [] }
        var parts = [full]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        let core = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .max { SearchKey.normalize($0).count < SearchKey.normalize($1).count } ?? ""
        guard SearchKey.normalize(core).count >= 2, core != full else { return [full] }
        return [core, full]
    }
}
