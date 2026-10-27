import CatalogKit
import Foundation
import HouseholdKit
@testable import Hearth

// Shared fixtures for the app shell's tests. Every store here is in memory:
// no test touches iCloud, a real provider or the Debug app's own household.

enum TestIDs {
    static let sourceA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let sourceB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let sourceC = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let profile = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
}

/// A fixed instant, so nothing depends on the clock.
let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

func makeChannel(
    _ name: String,
    id: String? = nil,
    source: UUID = TestIDs.sourceA,
    sourceName: String = "Provider A",
    number: Int? = nil,
    categoryID: String? = nil,
    logo: URL? = nil
) -> CatalogChannel {
    let remoteID = id ?? name
    return CatalogChannel(
        key: .channel(source: source, id: remoteID),
        sourceID: source,
        sourceName: sourceName,
        remoteID: remoteID,
        number: number,
        name: name,
        logoURL: logo,
        categoryID: categoryID,
        guideChannelID: nil,
        hasArchive: false,
        archiveDays: 0
    )
}

func makeEpisode(series: String = "office", source: UUID = TestIDs.sourceA, season: Int, number: Int) -> CatalogEpisode {
    CatalogEpisode(
        key: .episode(source: source, seriesID: series, season: season, number: number),
        seriesKey: .series(source: source, id: series),
        sourceID: source,
        remoteID: "\(series)-\(season)-\(number)",
        season: season,
        number: number,
        title: "Episode \(number)",
        plot: nil,
        duration: 1800,
        posterURL: nil
    )
}

func makeProgress(position: TimeInterval, duration: TimeInterval, watched: Bool = false) -> ProgressRecord {
    ProgressRecord(
        profileID: TestIDs.profile,
        itemKey: ItemKey.movie(source: TestIDs.sourceA, id: "m1").rawValue,
        kind: .movie,
        position: position,
        duration: duration,
        watched: watched,
        updatedAt: referenceDate
    )
}

/// A household of one standard profile ("Bhavik"), in memory.
@MainActor
func makeHouseholdStore() throws -> HouseholdStore {
    let store = try HouseholdStore(mode: .inMemory)
    store.ensureHousehold(defaultName: "Test Household", firstProfileName: "Bhavik")
    return store
}

/// A UserDefaults of its own per test, so sessions never share remembered ids.
func makeDefaults() -> UserDefaults {
    let name = "HearthTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}
