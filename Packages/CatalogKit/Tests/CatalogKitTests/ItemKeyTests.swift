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
