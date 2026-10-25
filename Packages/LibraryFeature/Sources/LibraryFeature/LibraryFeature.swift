import CatalogKit
import Core
import HouseholdKit
import SwiftUI

// CONTRACT — the app shell builds against these entry views. Their names and
// initialisers stay; what they draw is the feature implementation's to replace.
// Services come from the environment: CatalogService, HouseholdStore and
// ProfileSession (injected by the app), plus Core's \.play and \.openRoute.
//
// Each view expects to sit inside the app's NavigationStack (or a split
// view's detail stack) that maps `HearthRoute` with
// `.navigationDestination(for:)`: posters push `.movie` and `.series`, and
// the empty states push `.sourceEditor`. None of them opens a stack of its own.

/// Movies by category as a poster grid, sorted by date added, name or year (VOD-1).
public struct MoviesView: View {
    public init() {}
    public var body: some View {
        CatalogGridScreen(shelf: .movies)
    }
}

/// Shows by category (SER-1).
public struct ShowsView: View {
    public init() {}
    public var body: some View {
        CatalogGridScreen(shelf: .shows)
    }
}

/// The profile's My List: movies and shows (FAV-3).
public struct MyListView: View {
    public init() {}
    public var body: some View {
        MyListScreen()
    }
}

/// Downloads on this device (DL-1, Phase 4): an honest empty state for now.
public struct DownloadsView: View {
    public init() {}
    public var body: some View {
        DownloadsScreen()
    }
}

/// A movie: poster, year, plot, rating, cast, length; Play or Resume, My List (VOD-2, VOD-3).
public struct MovieDetailView: View {
    let itemKey: String
    public init(itemKey: String) { self.itemKey = itemKey }
    public var body: some View {
        MovieDetailScreen(itemKey: ItemKey(rawValue: itemKey))
    }
}

/// A show (mockup 04): seasons and episodes with watched marks and progress,
/// Resume, My List, and where others in the household are (SER-1, SER-3).
public struct ShowDetailView: View {
    let itemKey: String
    public init(itemKey: String) { self.itemKey = itemKey }
    public var body: some View {
        ShowDetailScreen(itemKey: ItemKey(rawValue: itemKey))
    }
}
