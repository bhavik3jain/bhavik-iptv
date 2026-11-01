import Foundation
import Testing
@testable import CatalogKit

@Test func episodeKeysRoundTrip() {
    let source = UUID()
    let key = ItemKey.episode(source: source, seriesID: "12/3", season: 2, number: 5)
    #expect(key.sourceID == source)
    #expect(key.kind == .episode)
    #expect(key.remoteID == "12/3")
    #expect(key.seasonAndEpisode?.season == 2)
    #expect(key.seasonAndEpisode?.number == 5)
    #expect(key.seriesKey == .series(source: source, id: "12/3"))
}

// A real Apple TV refuses writes to Application Support ("The catalog couldn't
// be opened: The file couldn't be saved"), and its simulator doesn't, so this
// is only the placement; scripts/tv-remote/remote.sh check runs it on a TV.
@MainActor @Test func theCatalogIsStoredWhereThePlatformAllows() {
    let path = CatalogService.defaultStoreURL.path(percentEncoded: false)
    #if os(tvOS)
    #expect(path.contains("/Library/Caches/"))
    #else
    #expect(path.contains("/Library/Application Support/"))
    #endif
    #expect(path.hasSuffix("Catalog/Catalog.sqlite"))
}
