import CoreData
import Foundation
import SourceKit

// The few store operations everything else is built from. Imports never
// load managed objects for catalog rows: they insert and delete with batch
// requests and read back plain dictionaries, which is what keeps a 50,000
// movie import inside the spec's two minutes.

extension CatalogStore {
    /// Runs `body` on a fresh background context and returns its result.
    /// Every write in CatalogKit goes through here, off the main thread.
    func write<T: Sendable>(_ body: @escaping @Sendable (NSManagedObjectContext) throws -> T) async throws -> T {
        let context = newBackgroundContext()
        return try await context.perform { try body(context) }
    }
}

enum CatalogStoreError: Error, Sendable {
    /// A batch request came back unsuccessful without throwing.
    case batchFailed(String)
}

enum Batch {
    /// Rows per `NSBatchInsertRequest`: big enough that SQLite does the work,
    /// small enough that the dictionaries for one batch stay a few megabytes.
    static let chunkSize = 5_000

    static func insert(_ entity: String, _ rows: [[String: Any]], into context: NSManagedObjectContext) throws {
        guard !rows.isEmpty else { return }
        let request = NSBatchInsertRequest(entityName: entity, objects: rows)
        request.resultType = .statusOnly
        let result = try context.execute(request) as? NSBatchInsertResult
        if let succeeded = result?.result as? Bool, !succeeded {
            throw CatalogStoreError.batchFailed(entity)
        }
    }

    static func delete(_ entity: String, where predicate: NSPredicate, in context: NSManagedObjectContext) throws {
        let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
        fetch.predicate = predicate
        let request = NSBatchDeleteRequest(fetchRequest: fetch)
        request.resultType = .resultTypeStatusOnly
        try context.execute(request)
    }
}

enum Fetch {
    /// Plain dictionaries of a few properties, without managed objects.
    static func values(_ properties: [String], from entity: String, where predicate: NSPredicate, in context: NSManagedObjectContext, distinct: Bool = false) throws -> [[String: Any]] {
        let request = NSFetchRequest<NSDictionary>(entityName: entity)
        request.predicate = predicate
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = properties
        request.returnsDistinctResults = distinct
        return try context.fetch(request).compactMap { $0 as? [String: Any] }
    }

    static func strings(_ property: String, from entity: String, where predicate: NSPredicate, in context: NSManagedObjectContext, distinct: Bool = false) throws -> [String] {
        try values([property], from: entity, where: predicate, in: context, distinct: distinct).compactMap { $0[property] as? String }
    }

    static func count(_ entity: String, where predicate: NSPredicate, in context: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
        request.predicate = predicate
        return (try? context.count(for: request)) ?? 0
    }
}

/// Predicates the importer and the queries share.
enum Where {
    static func source(_ sourceID: UUID) -> NSPredicate {
        NSPredicate(format: "sourceID == %@", sourceID as NSUUID)
    }

    static func generation(_ generation: Int64, of sourceID: UUID) -> NSPredicate {
        NSPredicate(format: "sourceID == %@ AND generation == %lld", sourceID as NSUUID, generation)
    }

    static func notGeneration(_ generation: Int64, of sourceID: UUID) -> NSPredicate {
        NSPredicate(format: "sourceID == %@ AND generation != %lld", sourceID as NSUUID, generation)
    }
}

/// Reads and writes the one `SourceState` row per source.
enum SourceStateRow {
    static func fetch(_ sourceID: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: CatalogModel.Entity.sourceState)
        request.predicate = Where.source(sourceID)
        request.sortDescriptors = [NSSortDescriptor(key: "generation", ascending: false)]
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    /// Changes the source's row (creating it the first time) and saves.
    /// Each caller touches only its own fields, so a guide swap and an
    /// account read never overwrite each other's numbers.
    static func update(_ sourceID: UUID, in context: NSManagedObjectContext, _ change: (NSManagedObject) -> Void) throws {
        let row: NSManagedObject
        if let existing = try fetch(sourceID, in: context) {
            row = existing
        } else {
            guard let entity = NSEntityDescription.entity(forEntityName: CatalogModel.Entity.sourceState, in: context) else { return }
            row = NSManagedObject(entity: entity, insertInto: context)
            row.setValue(sourceID, forKey: "sourceID")
        }
        change(row)
        if context.hasChanges { try context.save() }
    }

    static func setAccount(_ account: AccountInfo, on row: NSManagedObject, readAt: Date) {
        row.setValue(try? JSONEncoder().encode(account), forKey: "accountJSON")
        row.setValue(account.expiresAt, forKey: "accountExpiry")
        row.setValue(account.maxConnections.map { Int64($0) }, forKey: "streamLimit")
        row.setValue(account.activeConnections.map { Int64($0) }, forKey: "activeStreams")
        row.setValue(account.activeConnections == nil ? nil : readAt, forKey: "activeStreamsReadAt")
    }

    static func loadAll(in context: NSManagedObjectContext) throws -> [UUID: PersistedSourceState] {
        let request = NSFetchRequest<NSManagedObject>(entityName: CatalogModel.Entity.sourceState)
        request.returnsObjectsAsFaults = false
        var states: [UUID: PersistedSourceState] = [:]
        for row in try context.fetch(request) {
            guard let sourceID = row.uuid("sourceID") else { continue }
            let state = PersistedSourceState(row: row)
            // Nothing is unique in the model; if a crash ever left two rows,
            // the one with the newer generation is the one the rows match.
            if let existing = states[sourceID], existing.generation >= state.generation { continue }
            states[sourceID] = state
        }
        return states
    }
}
