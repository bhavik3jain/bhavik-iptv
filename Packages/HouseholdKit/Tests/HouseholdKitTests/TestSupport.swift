import CoreData
import Foundation
@testable import HouseholdKit

// Every store here is `.inMemory`: no test touches iCloud.

@MainActor
func makeStore(householdName: String = "Jain Household", firstProfile: String = "Bhavik") throws -> HouseholdStore {
    let store = try HouseholdStore(mode: .inMemory)
    store.ensureHousehold(defaultName: householdName, firstProfileName: firstProfile)
    return store
}

/// A UserDefaults of its own per test, so tests never share remembered ids.
func makeDefaults() -> UserDefaults {
    let name = "HouseholdKitTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Item keys in CatalogKit's shape (`<source>/<kind>/<id>`), without
/// importing CatalogKit.
enum TestKeys {
    static func movie(_ id: String, source: UUID = sourceA) -> String { "\(source.uuidString)/movie/\(id)" }
    static func channel(_ id: String, source: UUID = sourceA) -> String { "\(source.uuidString)/channel/\(id)" }
    static func series(_ id: String, source: UUID = sourceA) -> String { "\(source.uuidString)/series/\(id)" }
    static func episode(_ series: String, _ season: Int, _ number: Int, source: UUID = sourceA) -> String {
        "\(source.uuidString)/episode/\(series)/\(season)/\(number)"
    }

    static let sourceA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let sourceB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
}

extension HouseholdStore {
    /// The first profile `ensureHousehold` made.
    var firstProfile: ProfileRecord { profiles[0] }

    /// What an iCloud import does: rows written straight into the store,
    /// bypassing the store's rules, then saved.
    func simulateImport(_ body: (HouseholdStore) -> Void) {
        body(self)
        save("simulated import")
    }

    @discardableResult
    func importFavorite(profileID: UUID, itemKey: String, kind: FavoriteKind = .channel, sortOrder: Double, addedAt: Date, id: UUID = UUID()) -> FavoriteEntity {
        let profile = profileEntity(profileID)!
        let row = insert(HouseholdModel.Entity.favorite, as: FavoriteEntity.self, into: targetStore(for: profile))
        row.id = id
        row.itemKey = itemKey
        row.kindRaw = kind.rawValue
        row.sortOrder = sortOrder
        row.addedAt = addedAt
        row.profile = profile
        return row
    }

    @discardableResult
    func importProgress(profileID: UUID, itemKey: String, kind: HouseholdKit.ProgressKind = .movie, position: Double, duration: Double, watched: Bool = false, updatedAt: Date, seriesKey: String? = nil, id: UUID = UUID()) -> ProgressEntity {
        let profile = profileEntity(profileID)!
        let row = insert(HouseholdModel.Entity.progress, as: ProgressEntity.self, into: targetStore(for: profile))
        row.id = id
        row.itemKey = itemKey
        row.kindRaw = kind.rawValue
        row.position = position
        row.duration = duration
        row.watched = watched
        row.updatedAt = updatedAt
        row.seriesKey = seriesKey
        row.profile = profile
        return row
    }

    func count(_ entityName: String) -> Int {
        (try? viewContext.count(for: NSFetchRequest<NSManagedObject>(entityName: entityName))) ?? -1
    }
}
