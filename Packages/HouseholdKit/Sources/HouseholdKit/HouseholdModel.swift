import CoreData
import Foundation

/// The Core Data model behind the household, built by hand rather than from a
/// `.xcdatamodeld` (as Multitrack's Finance and Points are): a package can't
/// compile a model bundle without resources, and a model in code is diffable.
///
/// | Swift class        | Entity (CloudKit record type `CD_` + name) |
/// |--------------------|--------------------------------------------|
/// | `HouseholdEntity`  | `Household` — the share root               |
/// | `SourceEntity`     | `Source`                                   |
/// | `ProfileEntity`    | `Profile`                                  |
/// | `FavoriteEntity`   | `Favorite`                                 |
/// | `ProgressEntity`   | `Progress`                                 |
/// | `PlaybackEntity`   | `Playback`                                 |
/// | `MemberRoleEntity` | `MemberRole`                               |
///
/// Entity and attribute names are CloudKit record types and fields: never
/// rename one once it is in Production — that orphans every record already
/// there. Adding one needs the schema ritual (`HouseholdStore
/// .initializeCloudKitSchema`, then Deploy Schema Changes in the Console).
///
/// CloudKit's rules, every one of which fails at container load rather than
/// at compile time when broken (Multitrack's crash-at-launch lesson):
/// - every non-optional attribute has a default;
/// - every relationship is optional and has an inverse;
/// - nothing is unique (duplicates are folded by hand, `HouseholdFold`);
/// - enums are `…Raw` strings, read back with a fallback, so a new case is
///   never a schema change.
///
/// The Source login attributes are marked `allowsCloudEncryption` (PRIV-3):
/// CloudKit encrypts them with the account's keys. That flag can't be added to
/// an attribute after its first Production deploy, which is why every login
/// field is here from the start, used or not.
enum HouseholdModel {
    enum Entity {
        static let household = "Household"
        static let source = "Source"
        static let profile = "Profile"
        static let favorite = "Favorite"
        static let progress = "Progress"
        static let playback = "Playback"
        static let memberRole = "MemberRole"
    }

    /// The Source attributes that hold a login, encrypted in iCloud.
    static let encryptedSourceAttributes = [
        "macAddress", "username", "password", "playlistURL", "guideURL",
        "serialNumber", "deviceID", "deviceID2", "signature", "model", "timeZone",
    ]

    /// One model for the whole process. Core Data warns, and `+entity`
    /// lookups get ambiguous, when two loaded models claim the same
    /// `NSManagedObject` subclass — which every test building its own
    /// in-memory store would otherwise do.
    ///
    /// `nonisolated(unsafe)` because `NSManagedObjectModel` isn't `Sendable`:
    /// it is fully built here, never mutated afterwards, and Core Data reads a
    /// model from any thread once a coordinator uses it.
    nonisolated(unsafe) static let shared: NSManagedObjectModel = make()

    /// Default for non-optional dates. Always overwritten on insert; a fixed
    /// value keeps the model the same on every build.
    static let epoch = Date(timeIntervalSince1970: 0)

    static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let household = entity(Entity.household, HouseholdEntity.self)
        let source = entity(Entity.source, SourceEntity.self)
        let profile = entity(Entity.profile, ProfileEntity.self)
        let favorite = entity(Entity.favorite, FavoriteEntity.self)
        let progress = entity(Entity.progress, ProgressEntity.self)
        let playback = entity(Entity.playback, PlaybackEntity.self)
        let memberRole = entity(Entity.memberRole, MemberRoleEntity.self)

        household.properties = [
            uuid("id"),
            string("name", default: "Household"),
            date("createdAt"),
            // JSON array of category keys (PAR-1).
            string("adultCategoryKeys", default: "[]"),
            boolean("hidesAdultEverywhere", default: true),
        ]
        source.properties = [
            uuid("id"),
            string("name", default: ""),
            string("kindRaw", default: "stalker"),
            string("serverURL", default: ""),
            integer("sortOrder", default: 0),
            boolean("isRemoved", default: false),
            integer("maxStreams", default: 1),
            optionalDate("expiresAt"),
        ] + encryptedSourceAttributes.map { string($0, default: "", encrypted: true) }
        profile.properties = [
            uuid("id"),
            string("name", default: ""),
            string("kindRaw", default: ProfileKind.standard.rawValue),
            string("avatarColorRaw", default: "amber"),
            optionalString("avatarSymbol"),
            integer("sortOrder", default: 0),
            // Both empty when the profile has no PIN (PAR-3).
            string("pinHash", default: ""),
            string("pinSalt", default: ""),
            string("allowedCategoryKeys", default: "[]"),
            string("hiddenCategoryKeys", default: "[]"),
            // JSON array of source UUID strings; empty means all (PRF-6).
            string("visibleSourceIDs", default: "[]"),
            optionalString("audioLanguage"),
            optionalString("subtitleLanguage"),
        ]
        favorite.properties = [
            uuid("id"),
            string("itemKey", default: ""),
            string("kindRaw", default: FavoriteKind.channel.rawValue),
            // A Double so a move writes one row (FAV-1).
            double("sortOrder", default: 0),
            date("addedAt"),
        ]
        progress.properties = [
            uuid("id"),
            string("itemKey", default: ""),
            string("kindRaw", default: ProgressKind.movie.rawValue),
            double("position", default: 0),
            double("duration", default: 0),
            boolean("watched", default: false),
            date("updatedAt"),
            optionalString("seriesKey"),
            optionalInteger("season"),
            optionalInteger("episode"),
        ]
        playback.properties = [
            uuid("id"),
            string("deviceName", default: ""),
            uuid("profileID"),
            uuid("sourceID"),
            string("itemKey", default: ""),
            string("title", default: ""),
            date("startedAt"),
            date("lastSeenAt"),
        ]
        memberRole.properties = [
            string("participantID", default: ""),
            string("roleRaw", default: MemberRole.watch.rawValue),
        ]

        // Children go with their household or profile; the to-one side only
        // nullifies. Both sides carry the inverse, or the container won't load.
        let (sources, sourceHousehold) = toManyPair("sources", inverse: "household", from: household, to: source)
        let (profiles, profileHousehold) = toManyPair("profiles", inverse: "household", from: household, to: profile)
        let (roles, roleHousehold) = toManyPair("memberRoles", inverse: "household", from: household, to: memberRole)
        let (playbacks, playbackHousehold) = toManyPair("playbacks", inverse: "household", from: household, to: playback)
        let (favorites, favoriteProfile) = toManyPair("favorites", inverse: "profile", from: profile, to: favorite)
        let (progressRows, progressProfile) = toManyPair("progress", inverse: "profile", from: profile, to: progress)

        household.properties += [sources, profiles, roles, playbacks]
        source.properties += [sourceHousehold]
        profile.properties += [profileHousehold, favorites, progressRows]
        favorite.properties += [favoriteProfile]
        progress.properties += [progressProfile]
        playback.properties += [playbackHousehold]
        memberRole.properties += [roleHousehold]

        model.entities = [household, source, profile, favorite, progress, playback, memberRole]
        return model
    }

    /// The record types CloudKit gets, as the Console lists them.
    static var recordTypes: [String] {
        shared.entities.compactMap(\.name).map { "CD_\($0)" }.sorted()
    }

    // MARK: - Builders

    private static func entity(_ name: String, _ type: NSManagedObject.Type) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = NSStringFromClass(type)
        return entity
    }

    private static func string(_ name: String, default value: String, encrypted: Bool = false) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .stringAttributeType
        attribute.isOptional = false
        attribute.defaultValue = value
        attribute.allowsCloudEncryption = encrypted
        return attribute
    }

    private static func optionalString(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .stringAttributeType
        attribute.isOptional = true
        return attribute
    }

    /// Optional: CloudKit allows it, and a UUID default would be one shared
    /// value. Every insert sets it.
    private static func uuid(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .UUIDAttributeType
        attribute.isOptional = true
        return attribute
    }

    private static func date(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .dateAttributeType
        attribute.isOptional = false
        attribute.defaultValue = epoch
        return attribute
    }

    private static func optionalDate(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .dateAttributeType
        attribute.isOptional = true
        return attribute
    }

    private static func integer(_ name: String, default value: Int) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .integer64AttributeType
        attribute.isOptional = false
        attribute.defaultValue = value
        return attribute
    }

    private static func optionalInteger(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .integer64AttributeType
        attribute.isOptional = true
        return attribute
    }

    private static func double(_ name: String, default value: Double) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .doubleAttributeType
        attribute.isOptional = false
        attribute.defaultValue = value
        return attribute
    }

    private static func boolean(_ name: String, default value: Bool) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .booleanAttributeType
        attribute.isOptional = false
        attribute.defaultValue = value
        return attribute
    }

    private static func toManyPair(
        _ name: String,
        inverse inverseName: String,
        from: NSEntityDescription,
        to: NSEntityDescription
    ) -> (toMany: NSRelationshipDescription, toOne: NSRelationshipDescription) {
        let toMany = NSRelationshipDescription()
        toMany.name = name
        toMany.destinationEntity = to
        toMany.minCount = 0
        toMany.maxCount = 0 // 0 means to-many to Core Data.
        toMany.deleteRule = .cascadeDeleteRule
        toMany.isOptional = true

        let toOne = NSRelationshipDescription()
        toOne.name = inverseName
        toOne.destinationEntity = from
        toOne.minCount = 0
        toOne.maxCount = 1
        toOne.deleteRule = .nullifyDeleteRule
        toOne.isOptional = true

        toMany.inverseRelationship = toOne
        toOne.inverseRelationship = toMany
        return (toMany, toOne)
    }
}

// MARK: - Managed objects
//
// Internal: screens only ever see the value snapshots in HouseholdModels.swift.
// Used on the view context (main queue) only.

@objc(HearthHouseholdEntity)
final class HouseholdEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var name: String
    @NSManaged var createdAt: Date
    @NSManaged var adultCategoryKeys: String
    @NSManaged var hidesAdultEverywhere: Bool
    @NSManaged var sources: Set<SourceEntity>?
    @NSManaged var profiles: Set<ProfileEntity>?
    @NSManaged var memberRoles: Set<MemberRoleEntity>?
    @NSManaged var playbacks: Set<PlaybackEntity>?
}

@objc(HearthSourceEntity)
final class SourceEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var name: String
    @NSManaged var kindRaw: String
    @NSManaged var serverURL: String
    @NSManaged var sortOrder: Int
    @NSManaged var isRemoved: Bool
    @NSManaged var maxStreams: Int
    @NSManaged var expiresAt: Date?
    @NSManaged var macAddress: String
    @NSManaged var username: String
    @NSManaged var password: String
    @NSManaged var playlistURL: String
    @NSManaged var guideURL: String
    @NSManaged var serialNumber: String
    @NSManaged var deviceID: String
    @NSManaged var deviceID2: String
    @NSManaged var signature: String
    @NSManaged var model: String
    @NSManaged var timeZone: String
    @NSManaged var household: HouseholdEntity?
}

@objc(HearthProfileEntity)
final class ProfileEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var name: String
    @NSManaged var kindRaw: String
    @NSManaged var avatarColorRaw: String
    @NSManaged var avatarSymbol: String?
    @NSManaged var sortOrder: Int
    @NSManaged var pinHash: String
    @NSManaged var pinSalt: String
    @NSManaged var allowedCategoryKeys: String
    @NSManaged var hiddenCategoryKeys: String
    @NSManaged var visibleSourceIDs: String
    @NSManaged var audioLanguage: String?
    @NSManaged var subtitleLanguage: String?
    @NSManaged var household: HouseholdEntity?
    @NSManaged var favorites: Set<FavoriteEntity>?
    @NSManaged var progress: Set<ProgressEntity>?

    var kind: ProfileKind { ProfileKind(rawValue: kindRaw) ?? .standard }
}

@objc(HearthFavoriteEntity)
final class FavoriteEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var itemKey: String
    @NSManaged var kindRaw: String
    @NSManaged var sortOrder: Double
    @NSManaged var addedAt: Date
    @NSManaged var profile: ProfileEntity?
}

@objc(HearthProgressEntity)
final class ProgressEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var itemKey: String
    @NSManaged var kindRaw: String
    @NSManaged var position: Double
    @NSManaged var duration: Double
    @NSManaged var watched: Bool
    @NSManaged var updatedAt: Date
    @NSManaged var seriesKey: String?
    /// NSNumber because an optional scalar has no Objective-C form.
    @NSManaged var season: NSNumber?
    @NSManaged var episode: NSNumber?
    @NSManaged var profile: ProfileEntity?
}

@objc(HearthPlaybackEntity)
final class PlaybackEntity: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var deviceName: String
    @NSManaged var profileID: UUID?
    @NSManaged var sourceID: UUID?
    @NSManaged var itemKey: String
    @NSManaged var title: String
    @NSManaged var startedAt: Date
    @NSManaged var lastSeenAt: Date
    @NSManaged var household: HouseholdEntity?
}

@objc(HearthMemberRoleEntity)
final class MemberRoleEntity: NSManagedObject {
    @NSManaged var participantID: String
    @NSManaged var roleRaw: String
    @NSManaged var household: HouseholdEntity?

    var role: MemberRole { MemberRole(rawValue: roleRaw) ?? .watch }
}
