import CoreData
import Foundation

/// The catalog's SQLite store: a plain `NSPersistentContainer`, never
/// CloudKit (the catalog stays on the device and is safe to delete).
///
/// Reads go through `viewContext` on the main queue; imports through
/// short-lived background contexts using batch requests, which skip contexts
/// entirely, so after one lands the service resets `viewContext` rather than
/// merging. Nothing outside CatalogKit sees a managed object.
final class CatalogStore: Sendable {
    let container: NSPersistentContainer
    let isInMemory: Bool

    private init(container: NSPersistentContainer, isInMemory: Bool) {
        self.container = container
        self.isInMemory = isInMemory
    }

    var viewContext: NSManagedObjectContext { container.viewContext }

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.undoManager = nil
        return context
    }

    /// Where an in-memory store lives. `NSInMemoryStoreType` can't run
    /// `NSBatchInsertRequest` or `NSBatchDeleteRequest`, which the whole
    /// import depends on; SQLite at `/dev/null` can, and each container gets
    /// its own empty database.
    static let inMemoryURL = URL(fileURLWithPath: "/dev/null")

    /// Opens the store at `url` (nil: in memory). A store that won't open
    /// (corrupt file, a model change lightweight migration can't map) is
    /// deleted and created again: everything in it can be fetched from the
    /// providers. Throws only when even a fresh store fails.
    static func open(at url: URL?) throws -> CatalogStore {
        let model = CatalogModel.make()
        guard let url else {
            return CatalogStore(container: try load(model: model, url: inMemoryURL), isInMemory: true)
        }
        prepareDirectory(for: url)
        do {
            return CatalogStore(container: try load(model: model, url: url), isInMemory: false)
        } catch {
            destroy(at: url, model: model)
            return CatalogStore(container: try load(model: model, url: url), isInMemory: false)
        }
    }

    private static func load(model: NSManagedObjectModel, url: URL) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "Catalog", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]

        // `shouldAddStoreAsynchronously = false` makes the completion run
        // before `loadPersistentStores` returns.
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }

        let viewContext = container.viewContext
        viewContext.undoManager = nil
        viewContext.automaticallyMergesChangesFromParent = true
        viewContext.name = "CatalogKit.view"
        return container
    }

    private static func prepareDirectory(for url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Everything here can be fetched again; keep it out of backups.
        var directoryURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directoryURL.setResourceValues(values)
    }

    private static func destroy(at url: URL, model: NSManagedObjectModel) {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try? coordinator.destroyPersistentStore(at: url, type: .sqlite)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
