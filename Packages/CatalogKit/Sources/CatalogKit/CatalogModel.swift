import CoreData
import Foundation
import SourceKit

/// The catalog store's Core Data model, built in code rather than a
/// `.xcdatamodeld`: diffable, commented, and with no compiled model resource
/// to ship from a Swift package. Same convention as Multitrack's models.
///
/// The store is never synced, so CloudKit's model rules don't bind it, but
/// the house rules are kept anyway (non-optional attributes have defaults,
/// enums are `…Raw` strings, nothing is unique) so a model change can never
/// fail at load for a reason the household store would have caught.
///
/// Every row is a plain `NSManagedObject` read through KVC: no subclasses, so
/// several stores (the tests open dozens) never fight over a class.
///
/// **Generations.** Category, Channel, Movie and Series rows carry the
/// `generation` of the import that wrote them; `SourceState.generation` names
/// the live one. An import writes a new generation beside the old, flips the
/// number when it completes, then deletes the old rows, so a failed refresh
/// leaves the last good catalog showing. Programme rows do the same with
/// `SourceState.guideGeneration`. Episodes are a per-series cache outside the
/// scheme: they are keyed by season and number, which survive refreshes.
enum CatalogModel {
    enum Entity {
        static let category = "Category"
        static let channel = "Channel"
        static let programme = "Programme"
        static let movie = "Movie"
        static let series = "Series"
        static let episode = "Episode"
        static let sourceState = "SourceState"
        /// Keys that disappeared in a refresh, with their names, so
        /// `replacementKeys(for:)` can find what replaced them (FAV-2).
        static let removedItem = "RemovedItem"

        /// The entities a catalog generation spans.
        static let generational = [category, channel, movie, series]
        /// The entities that hold an item key in `stableKey`.
        static let keyed: [(entity: String, kind: ItemKind)] = [(channel, .channel), (movie, .movie), (series, .series)]

        static func forKind(_ kind: ItemKind) -> String {
            switch kind {
            case .channel: channel
            case .movie: movie
            case .series: series
            case .episode: episode
            }
        }
    }

    static func make() -> NSManagedObjectModel {
        let category = entity(Entity.category, [
            uuid("sourceID"),
            int64("generation"),
            string("remoteID"),
            string("kindRaw", default: ContentKind.live.rawValue),
            // `CategoryKey.make(source:kind:remoteID:)`: what items' categoryID
            // and the profile rules hold.
            string("categoryKey"),
            string("name"),
            int64("sortOrder"),
            bool("isAdult"),
        ], indexes: [["sourceID", "generation", "kindRaw"], ["categoryKey"]])

        let channel = entity(Entity.channel, [
            uuid("sourceID"),
            int64("generation"),
            string("remoteID"),
            string("stableKey"),
            optionalInt64("number"),
            // The number as text, for "find channel 10…" prefix lookups (LIV-6).
            optionalString("numberText"),
            // The number, or Int64.max when there is none, so "by number then
            // name" is one sort descriptor that puts unnumbered channels last.
            int64("sortNumber", default: Int64.max),
            string("name"),
            string("searchKey"),
            optionalString("logoURL"),
            optionalString("categoryID"),
            optionalString("remoteCategoryID"),
            optionalString("guideChannelID"),
            // guideChannelID, or remoteID when the provider gives none: what
            // programmes are joined on.
            string("guideKey"),
            bool("hasArchive"),
            int64("archiveDays"),
            // Everything below is what rebuilds the SourceKit `RemoteChannel`
            // a stream link is asked for with; links themselves are never stored.
            string("command"),
            string("formatHintRaw", default: StreamFormatHint.unknown.rawValue),
            optionalString("headersJSON"),
            optionalString("catchupMode"),
            optionalString("catchupSource"),
            // The provider's own order, the last tie-break.
            int64("position"),
        ], indexes: [["sourceID", "generation"], ["stableKey"], ["searchKey"], ["guideKey"], ["sortNumber"]])

        let programme = entity(Entity.programme, [
            uuid("sourceID"),
            int64("generation"),
            string("guideChannelID"),
            date("start"),
            date("end"),
            string("title"),
            string("searchKey"),
            optionalString("summary"),
            optionalString("category"),
            bool("hasArchive"),
        ], indexes: [["sourceID", "guideChannelID", "start"], ["sourceID", "generation"], ["start"], ["end"]])

        let movie = entity(Entity.movie, [
            uuid("sourceID"),
            int64("generation"),
            string("remoteID"),
            string("stableKey"),
            string("name"),
            string("searchKey"),
            optionalString("categoryID"),
            optionalString("remoteCategoryID"),
            optionalString("posterURL"),
            optionalInt64("year"),
            optionalString("plot"),
            optionalDouble("rating"),
            optionalDouble("duration"),
            optionalString("containerExtension"),
            optionalDate("addedAt"),
            optionalString("genre"),
            optionalString("cast"),
            optionalString("director"),
            optionalString("command"),
            int64("position"),
        ], indexes: [["sourceID", "generation"], ["stableKey"], ["searchKey"], ["categoryID"], ["addedAt"]])

        let series = entity(Entity.series, [
            uuid("sourceID"),
            int64("generation"),
            string("remoteID"),
            string("stableKey"),
            string("name"),
            string("searchKey"),
            optionalString("categoryID"),
            optionalString("remoteCategoryID"),
            optionalString("posterURL"),
            optionalString("plot"),
            optionalInt64("year"),
            optionalDouble("rating"),
            optionalDate("addedAt"),
            optionalString("genre"),
            optionalString("cast"),
            optionalString("command"),
            int64("position"),
        ], indexes: [["sourceID", "generation"], ["stableKey"], ["searchKey"], ["categoryID"], ["addedAt"]])

        let episode = entity(Entity.episode, [
            uuid("sourceID"),
            // The series' provider id, as in its item key.
            string("seriesID"),
            // The provider's episode id: what the link is asked with, never
            // part of the key (some providers reissue it).
            string("remoteID"),
            string("stableKey"),
            int64("season"),
            int64("number"),
            string("title"),
            optionalString("plot"),
            optionalDouble("duration"),
            optionalString("containerExtension"),
            optionalString("posterURL"),
            optionalString("command"),
            // Stalker's `season_id` and the season's own name, from SeriesDetail.
            optionalString("seasonRemoteID"),
            optionalString("seasonName"),
            date("fetchedAt"),
        ], indexes: [["sourceID", "seriesID", "season", "number"], ["stableKey"]])

        let sourceState = entity(Entity.sourceState, [
            uuid("sourceID"),
            int64("generation"),
            int64("guideGeneration"),
            optionalDate("catalogRefreshedAt"),
            optionalDate("guideRefreshedAt"),
            // The account as last read, whole, plus the fields the technical
            // spec names so they can be read without decoding.
            optionalBinary("accountJSON"),
            optionalDate("accountExpiry"),
            optionalInt64("streamLimit"),
            optionalInt64("activeStreams"),
            optionalDate("activeStreamsReadAt"),
            int64("channelCount"),
            int64("movieCount"),
            int64("seriesCount"),
        ], indexes: [["sourceID"]])

        let removedItem = entity(Entity.removedItem, [
            uuid("sourceID"),
            string("kindRaw", default: ItemKind.channel.rawValue),
            string("stableKey"),
            // The gone item's searchKey: what its replacement must match.
            string("nameKey"),
            date("removedAt"),
        ], indexes: [["sourceID", "stableKey"], ["removedAt"]])

        let model = NSManagedObjectModel()
        model.entities = [category, channel, programme, movie, series, episode, sourceState, removedItem]
        return model
    }

    // MARK: - Builders

    private static func entity(_ name: String, _ properties: [NSAttributeDescription], indexes: [[String]]) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = properties
        let byName = Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0) })
        entity.indexes = indexes.map { names in
            let elements = names.map { NSFetchIndexElementDescription(property: byName[$0]!, collationType: .binary) }
            return NSFetchIndexDescription(name: "\(name)_\(names.joined(separator: "_"))", elements: elements)
        }
        return entity
    }

    private static func attribute(_ name: String, _ type: NSAttributeType, optional: Bool, default value: Any? = nil) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        attribute.defaultValue = value
        return attribute
    }

    private static func string(_ name: String, default value: String = "") -> NSAttributeDescription {
        attribute(name, .stringAttributeType, optional: false, default: value)
    }

    private static func optionalString(_ name: String) -> NSAttributeDescription {
        attribute(name, .stringAttributeType, optional: true)
    }

    private static func int64(_ name: String, default value: Int64 = 0) -> NSAttributeDescription {
        attribute(name, .integer64AttributeType, optional: false, default: value)
    }

    private static func optionalInt64(_ name: String) -> NSAttributeDescription {
        attribute(name, .integer64AttributeType, optional: true)
    }

    private static func optionalDouble(_ name: String) -> NSAttributeDescription {
        attribute(name, .doubleAttributeType, optional: true)
    }

    private static func bool(_ name: String) -> NSAttributeDescription {
        attribute(name, .booleanAttributeType, optional: false, default: false)
    }

    private static func date(_ name: String) -> NSAttributeDescription {
        attribute(name, .dateAttributeType, optional: false, default: Date.distantPast)
    }

    private static func optionalDate(_ name: String) -> NSAttributeDescription {
        attribute(name, .dateAttributeType, optional: true)
    }

    private static func optionalBinary(_ name: String) -> NSAttributeDescription {
        attribute(name, .binaryDataAttributeType, optional: true)
    }

    /// Optional because a UUID attribute has no sensible default; every row
    /// is written with one.
    private static func uuid(_ name: String) -> NSAttributeDescription {
        attribute(name, .UUIDAttributeType, optional: true)
    }
}
