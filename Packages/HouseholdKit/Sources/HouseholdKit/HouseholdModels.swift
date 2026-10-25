import Core
import Foundation

// The household as screens see it: plain values read from the synced store.
// Additive changes only — features and the app compile against these.
//
// Enums are stored in Core Data as `…Raw` strings with a fallback, so adding a
// case is never a schema change.

public enum ProfileKind: String, Sendable, Codable, CaseIterable, Hashable {
    case standard
    case kids
    /// Watches anything not hidden; nothing is saved (PRF-5, PAR-4).
    case guest
}

public enum MemberRole: String, Sendable, Codable, CaseIterable, Hashable {
    case owner
    /// Adds and edits sources and profiles, changes rules (not the owner).
    case manage
    /// Picks a profile and watches; never sees logins.
    case watch

    public var canManage: Bool { self != .watch }
}

/// What a favorite row points at. Favorite channels and My List share the
/// entity (technical spec, Household store).
public enum FavoriteKind: String, Sendable, Codable, CaseIterable, Hashable {
    case channel
    case movie
    case series
}

public enum ProgressKind: String, Sendable, Codable, CaseIterable, Hashable {
    case movie
    case episode
    case catchup
}

/// `ProgressKind` under a name nothing else exports: Foundation has a
/// `ProgressKind` too, so a file importing both can't spell the type bare
/// (`.movie` arguments are unaffected). Write this, or `HouseholdKit.ProgressKind`.
public typealias HouseholdProgressKind = ProgressKind

public struct HouseholdInfo: Sendable, Hashable {
    public var id: UUID
    /// "Jain Household".
    public var name: String
    public var createdAt: Date
    /// Category keys the household marked adult beyond the name match (PAR-1).
    public var adultCategoryKeys: Set<String>
    /// Hide adult categories on every profile (the Sync switch on Household).
    public var hidesAdultEverywhere: Bool
    /// Whether the household is shared through iCloud yet.
    public var isShared: Bool
    /// This device's member's role. The owner until a share says otherwise.
    public var currentRole: MemberRole

    public init(id: UUID, name: String, createdAt: Date, adultCategoryKeys: Set<String> = [], hidesAdultEverywhere: Bool = true, isShared: Bool = false, currentRole: MemberRole = .owner) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.adultCategoryKeys = adultCategoryKeys
        self.hidesAdultEverywhere = hidesAdultEverywhere
        self.isShared = isShared
        self.currentRole = currentRole
    }
}

public struct ProfileRecord: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: ProfileKind
    public var avatarColor: AvatarPalette
    /// An SF Symbol name in place of the initial, or nil.
    public var avatarSymbol: String?
    public var sortOrder: Int
    public var hasPIN: Bool
    /// Kids: the only categories shown (CatalogCategory ids). Empty for others.
    public var allowedCategoryKeys: Set<String>
    /// Categories this profile hides (LIV-8, PRF-6).
    public var hiddenCategoryKeys: Set<String>
    /// Sources this profile sees; empty means all (PRF-6).
    public var visibleSourceIDs: Set<UUID>
    /// Preferred audio and subtitle languages, ISO 639 codes (PLY-6).
    public var audioLanguage: String?
    public var subtitleLanguage: String?

    public init(id: UUID = UUID(), name: String, kind: ProfileKind = .standard, avatarColor: AvatarPalette = .amber, avatarSymbol: String? = nil, sortOrder: Int = 0, hasPIN: Bool = false, allowedCategoryKeys: Set<String> = [], hiddenCategoryKeys: Set<String> = [], visibleSourceIDs: Set<UUID> = [], audioLanguage: String? = nil, subtitleLanguage: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.avatarColor = avatarColor
        self.avatarSymbol = avatarSymbol
        self.sortOrder = sortOrder
        self.hasPIN = hasPIN
        self.allowedCategoryKeys = allowedCategoryKeys
        self.hiddenCategoryKeys = hiddenCategoryKeys
        self.visibleSourceIDs = visibleSourceIDs
        self.audioLanguage = audioLanguage
        self.subtitleLanguage = subtitleLanguage
    }

    public var isGuest: Bool { kind == .guest }
    public var isKids: Bool { kind == .kids }
}

/// A source's login. Stored as encrypted attributes in iCloud (Allows Cloud
/// Encryption); never logged, never in UserDefaults (PRIV-2, PRIV-3).
public struct SourceCredentials: Sendable, Hashable, Codable {
    public var macAddress: String
    public var username: String
    public var password: String
    public var playlistURL: String
    public var guideURL: String
    public var serialNumber: String
    public var deviceID: String
    public var deviceID2: String
    public var signature: String
    public var model: String
    public var timeZone: String

    public init(macAddress: String = "", username: String = "", password: String = "", playlistURL: String = "", guideURL: String = "", serialNumber: String = "", deviceID: String = "", deviceID2: String = "", signature: String = "", model: String = "", timeZone: String = "") {
        self.macAddress = macAddress
        self.username = username
        self.password = password
        self.playlistURL = playlistURL
        self.guideURL = guideURL
        self.serialNumber = serialNumber
        self.deviceID = deviceID
        self.deviceID2 = deviceID2
        self.signature = signature
        self.model = model
        self.timeZone = timeZone
    }
}

public struct SourceRecord: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    /// "stalker", "xtream" or "m3u" — SourceKit's `SourceKind.rawValue`.
    /// HouseholdKit never imports SourceKit; the app maps between them.
    public var kindRaw: String
    public var serverURL: String
    public var sortOrder: Int
    /// Removed sources keep their favorites and progress (SRC-9).
    public var isRemoved: Bool
    /// Streams allowed at once: the owner's setting for Stalker (1 per MAC by
    /// default) and M3U (0 = unlimited); Xtream reports its own.
    public var maxStreams: Int
    public var expiresAt: Date?
    public var credentials: SourceCredentials

    public init(id: UUID = UUID(), name: String, kindRaw: String, serverURL: String = "", sortOrder: Int = 0, isRemoved: Bool = false, maxStreams: Int = 1, expiresAt: Date? = nil, credentials: SourceCredentials = SourceCredentials()) {
        self.id = id
        self.name = name
        self.kindRaw = kindRaw
        self.serverURL = serverURL
        self.sortOrder = sortOrder
        self.isRemoved = isRemoved
        self.maxStreams = maxStreams
        self.expiresAt = expiresAt
        self.credentials = credentials
    }
}

public struct FavoriteRecord: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var profileID: UUID
    /// CatalogKit `ItemKey.rawValue`.
    public var itemKey: String
    public var kind: FavoriteKind
    /// Set by hand (FAV-1); a Double so a move writes one row.
    public var sortOrder: Double
    public var addedAt: Date

    public init(id: UUID = UUID(), profileID: UUID, itemKey: String, kind: FavoriteKind, sortOrder: Double, addedAt: Date = .now) {
        self.id = id
        self.profileID = profileID
        self.itemKey = itemKey
        self.kind = kind
        self.sortOrder = sortOrder
        self.addedAt = addedAt
    }
}

public struct ProgressRecord: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var profileID: UUID
    public var itemKey: String
    public var kind: ProgressKind
    /// Seconds.
    public var position: TimeInterval
    public var duration: TimeInterval
    /// Set at 95% (VOD-3).
    public var watched: Bool
    public var updatedAt: Date
    /// Episodes: the series' item key, season and number (SER-2, SER-3).
    public var seriesKey: String?
    public var season: Int?
    public var episode: Int?

    public init(id: UUID = UUID(), profileID: UUID, itemKey: String, kind: ProgressKind, position: TimeInterval, duration: TimeInterval, watched: Bool = false, updatedAt: Date = .now, seriesKey: String? = nil, season: Int? = nil, episode: Int? = nil) {
        self.id = id
        self.profileID = profileID
        self.itemKey = itemKey
        self.kind = kind
        self.position = position
        self.duration = duration
        self.watched = watched
        self.updatedAt = updatedAt
        self.seriesKey = seriesKey
        self.season = season
        self.episode = episode
    }

    public var fraction: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
    public var remaining: TimeInterval { max(duration - position, 0) }
}

/// Who's watching now (HH-5): one row per active stream.
public struct PlaybackRecord: Identifiable, Sendable, Hashable {
    public var id: UUID
    public var deviceName: String
    public var profileID: UUID
    public var sourceID: UUID
    public var itemKey: String
    public var title: String
    public var startedAt: Date
    public var lastSeenAt: Date

    public init(id: UUID = UUID(), deviceName: String, profileID: UUID, sourceID: UUID, itemKey: String, title: String, startedAt: Date = .now, lastSeenAt: Date = .now) {
        self.id = id
        self.deviceName = deviceName
        self.profileID = profileID
        self.sourceID = sourceID
        self.itemKey = itemKey
        self.title = title
        self.startedAt = startedAt
        self.lastSeenAt = lastSeenAt
    }

    /// Rows unseen for 15 minutes are ignored and may be deleted by any device.
    public static let staleAfter: TimeInterval = 15 * 60

    public func isStale(at date: Date = .now) -> Bool {
        date.timeIntervalSince(lastSeenAt) > Self.staleAfter
    }
}

public struct MemberRecord: Identifiable, Sendable, Hashable {
    /// CloudKit participant id, or "owner" before the household is shared.
    public var id: String
    public var displayName: String
    public var role: MemberRole
    public var isCurrentUser: Bool

    public init(id: String, displayName: String, role: MemberRole, isCurrentUser: Bool) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.isCurrentUser = isCurrentUser
    }
}

/// A source's streams right now, for the warning before play (HH-6) and the
/// stream bars on Household and the Mac sidebar.
public struct StreamUsage: Sendable, Hashable {
    public var sourceID: UUID
    /// Nil means unlimited.
    public var limit: Int?
    /// Active streams on this source, other devices first.
    public var inUse: [PlaybackRecord]

    public init(sourceID: UUID, limit: Int?, inUse: [PlaybackRecord]) {
        self.sourceID = sourceID
        self.limit = limit
        self.inUse = inUse
    }

    /// Free streams, or nil when unlimited.
    public var free: Int? { limit.map { max($0 - inUse.count, 0) } }
    public var isAtLimit: Bool { free == 0 }
}

/// iCloud sync as the footer and Household show it.
public enum HouseholdSyncStatus: Sendable, Hashable {
    case local
    case syncing
    case upToDate(Date)
    case failed(String)
    case noAccount
}
