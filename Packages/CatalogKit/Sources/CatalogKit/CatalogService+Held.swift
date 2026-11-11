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
    /// title missing from it is gone. The held title's own key is known, so
    /// each search goes on page after page (`heldSearchPageLimit`) until that
    /// key turns up: on a portal of 162,000 titles a film's name matches its
    /// versions in several languages, more than a typed search's two pages.
    /// Each page goes to a provider once per catalog, as a typed search's
    /// does, so calling this again costs nothing. Returns how many titles the
    /// searches added (the held ones and anything else they found);
    /// `revision` bumps when any were.
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
                added += await searchProviders(query, showingProgress: false, pageLimit: Self.heldSearchPageLimit) {
                    self.queryContains(item.key)
                }
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
    /// down, not shown. When the catalog no longer holds it, the name it was
    /// dropped under (`RemovedItem`, kept 180 days for FAV-2), folded as
    /// search keys are ("greys anatomy english tv series"): builds before
    /// 112 dropped every title past the first pages at the daily refresh,
    /// before favorites carried names, and those favorites had nothing to be
    /// searched by on any device. Nil when the catalog knows neither.
    public func heldTitle(for key: ItemKey) -> String? {
        let titleKey: ItemKey?
        let entity: String
        switch key.kind {
        case .movie?: titleKey = key; entity = CatalogModel.Entity.movie
        case .series?: titleKey = key; entity = CatalogModel.Entity.series
        case .episode?: titleKey = key.seriesKey; entity = CatalogModel.Entity.series
        case .channel?, nil: return nil
        }
        guard let titleKey, let sourceID = titleKey.sourceID, source(sourceID) != nil else { return nil }
        let name = liveRow(entity, key: titleKey)?.string("name").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        let remembered = removedNameKey(for: titleKey) ?? ""
        return SearchKey.normalize(remembered).count >= 2 ? remembered : nil
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
/// name's title part goes first, and the whole name follows for a portal
/// that only matches that. Last comes the title part's most distinctive
/// word: a name remembered only in its folded form ("greys anatomy english
/// tv series", `heldTitle(for:)`) has no separators left and matches nothing
/// whole, and one word matches the portal's spelling however its punctuation
/// goes.
///
/// The title part is the first part that isn't a tag (`isTag`), not the
/// longest: "Iron Man - DISNEY+ | ENGLISH MOVIES" was searched as "ENGLISH
/// MOVIES", which the portal answers with nothing, so the Mac's My List read
/// "Unavailable" for every title whose name is shorter than its tags (Iron
/// Man, Inception, Oppenheimer, Suits, The Pitt; 2026-11-11). Searched by
/// their own names, each was on the portal's first or second page.
enum HeldTitleSearch {
    static let separators = [" - ", " – ", " — ", " | ", "|", " (", " [", ")", "]"]

    /// Folded words providers add to names (languages, kinds, quality),
    /// never the word to search a title by.
    static let labels: Set<String> = [
        "english", "hindi", "tamil", "telugu", "malayalam", "kannada", "punjabi", "bengali", "marathi", "gujarati",
        "urdu", "arabic", "french", "german", "spanish", "italian", "turkish", "russian", "portuguese", "dutch",
        "polish", "korean", "japanese", "chinese", "persian", "multi", "multisub", "dubbed", "dual", "audio",
        "subbed", "subs", "subtitles", "vostfr", "series", "season", "episode", "episodes", "movie", "movies",
        "film", "films", "quality", "excellent", "cinema", "version", "extended", "uncut",
        "tv", "kids", "latest", "new", "old", "collection", "classic", "classics", "eng", "subtitle",
        "hd", "fhd", "uhd", "sd", "4k", "hdr", "netflix", "disney", "prime", "video", "amazon", "paramount",
        "hbo", "max", "hulu", "apple", "peacock", "starz", "showtime", "zee5", "hotstar", "jiocinema",
    ]

    static func queries(for title: String) -> [String] {
        let full = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard SearchKey.normalize(full).count >= 2 else { return [] }
        var parts = [full]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        let core = titlePart(parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }) ?? ""
        let plain = SearchKey.normalize(core).count >= 2 ? core : full
        var queries = plain == full ? [full] : [core, full]
        if let word = distinctiveWord(in: plain), !queries.contains(where: { SearchKey.normalize($0) == SearchKey.normalize(word) }) {
            queries.append(word)
        }
        return queries
    }

    /// The part that names the title, in the name's own order: the first
    /// that isn't a tag and isn't all capitals (a prefix like "CRUNCHYROLL |"
    /// is shouted, a title rarely), else the first that isn't a tag, else the
    /// first part at all ("UP - DISNEY+ | ENGLISH MOVIES" is the film "UP").
    static func titlePart(_ parts: [String]) -> String? {
        let named = parts.filter { SearchKey.normalize($0).count >= 2 }
        let titles = named.filter { !isTag($0) }
        return titles.first { $0 != $0.uppercased() } ?? titles.first ?? named.first
    }

    /// A part made only of a provider's labels ("ENGLISH MOVIES", "DISNEY+",
    /// "TV SERIES", "Eng Subtitle"), a year or a number, or a code of up to
    /// three capitals ("EN", "UK", "HBO").
    static func isTag(_ part: String) -> Bool {
        let words = part.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return true }
        if words.count == 1, let word = words.first, word.count <= 3, word == word.uppercased(), word.contains(where: \.isLetter) { return true }
        return words.allSatisfy { word in
            let folded = SearchKey.normalize(word)
            return labels.contains(folded) || folded.allSatisfy(\.isNumber)
        }
    }

    /// The longest word of at least four letters that isn't a label or a
    /// number (a year, "1080p"); the first of equals. Nil when none is.
    static func distinctiveWord(in name: String) -> String? {
        var best: Substring?
        var bestLength = 0
        for word in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let folded = SearchKey.normalize(String(word))
            guard folded.count >= 4, folded.count > bestLength,
                  !folded.contains(where: \.isNumber), !labels.contains(folded) else { continue }
            best = word
            bestLength = folded.count
        }
        return best.map(String.init)
    }
}
