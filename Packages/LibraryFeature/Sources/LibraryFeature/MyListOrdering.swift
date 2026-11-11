import Foundation
import HouseholdKit

// How My List is ordered (FAV-3): the profile's own order, set by hand and
// synced through the household (`FavoriteRecord.sortOrder`), or one of two
// views of it chosen on this device. Plain values, tested without a view.

/// The order My List draws its movies and shows in, chosen per device. The
/// profile's own order follows it to every device; the other two only
/// re-sort what this device shows. The Apple TV always uses the profile's
/// order (it can't edit it, but it follows it).
enum MyListSort: String, CaseIterable, Identifiable, Sendable {
    /// The profile's own order, as set in Reorder My List.
    case custom
    /// Newest on the list first.
    case recentlyAdded
    /// By title, A to Z.
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: String(localized: "My Order", bundle: .module, comment: "My List sort: the profile's own order")
        case .recentlyAdded: String(localized: "Recently Added", bundle: .module, comment: "My List sort: newest first")
        case .title: String(localized: "A–Z", bundle: .module, comment: "My List sort: by title")
        }
    }

    /// `entries`, in the profile's order, sorted this way. Ties keep the
    /// profile's order, so a sort never shuffles two equal rows.
    func sorted(_ entries: [MyListEntry]) -> [MyListEntry] {
        switch self {
        case .custom:
            return entries
        case .recentlyAdded:
            return entries.enumerated()
                .sorted { lhs, rhs in
                    let (a, b) = (lhs.element.favorite.addedAt, rhs.element.favorite.addedAt)
                    return a != b ? a > b : lhs.offset < rhs.offset
                }
                .map(\.element)
        case .title:
            // Rows with no name to sort by (unavailable, nothing synced with
            // them) go last, in the profile's order.
            return entries.enumerated()
                .sorted { lhs, rhs in
                    let (a, b) = (lhs.element.sortName, rhs.element.sortName)
                    switch (a, b) {
                    case let (a?, b?):
                        let order = a.localizedStandardCompare(b)
                        return order != .orderedSame ? order == .orderedAscending : lhs.offset < rhs.offset
                    case (.some, nil): return true
                    case (nil, .some): return false
                    case (nil, nil): return lhs.offset < rhs.offset
                    }
                }
                .map(\.element)
        }
    }
}

extension MyListEntry {
    /// The name A–Z sorts by: the catalog's, else the one synced with the
    /// favorite; nil when there's neither.
    var sortName: String? {
        let name: String
        switch status {
        case .available(let item): name = item.title
        case .pending, .unavailable: name = favorite.title
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension MyListEntry {
    /// What an unavailable tile is called: the name synced with the favorite,
    /// so the list says which title it can't find here, not just that one is
    /// missing (the Mac's eight "Unavailable" movies, 2026-11-11).
    var unavailableTitle: String {
        sortName ?? String(localized: "Unavailable", bundle: .module)
    }
}

/// One row of Reorder My List: every title on the list that this profile may
/// see, including those still loading here and those no longer offered, so
/// the order around them is set too and they keep their places.
struct MyListOrderRow: Identifiable, Equatable {
    enum State: Equatable {
        case available
        case loading
        case unavailable
    }

    var id: UUID
    var title: String
    var caption: String?
    var posterURL: URL?
    var state: State

    init(_ entry: MyListEntry) {
        id = entry.favorite.id
        switch entry.status {
        case .available(let item):
            title = item.title
            caption = item.caption
            posterURL = item.posterURL
            state = .available
        case .pending:
            title = entry.sortName ?? String(localized: "Loading…", bundle: .module)
            caption = String(localized: "Still loading on this device", bundle: .module)
            posterURL = nil
            state = .loading
        case .unavailable:
            title = entry.sortName ?? String(localized: "Unavailable", bundle: .module)
            caption = String(localized: "No longer offered", bundle: .module)
            posterURL = nil
            state = .unavailable
        }
    }
}
