import CloudKit
import Core
import Foundation
import Observation

/// The household shared through iCloud: a hand-built Core Data model
/// (`HouseholdModel`) in an NSPersistentCloudKitContainer with a private and a
/// shared store, `Household` as the share root. One instance for the app,
/// injected with `.environment(_:)`.
///
/// Every published property is a value snapshot refreshed when the store
/// changes (local saves and iCloud imports), so views simply read them.
/// Writes happen only when the features say so — each synced write wakes
/// every household device (technical spec, Sync and sharing rules).
///
/// PUBLIC API IS A CONTRACT: features and the app compile against these
/// signatures. Add to it; don't change or remove.
@MainActor
@Observable
public final class HouseholdStore {
    public enum Mode: Sendable {
        /// The real store, syncing with this iCloud container.
        case cloud(containerIdentifier: String)
        /// Everything in memory, no iCloud (tests, previews, `-InMemoryStores YES`).
        case inMemory
    }

    public let mode: Mode

    public init(mode: Mode) throws {
        self.mode = mode
        self.household = HouseholdInfo(id: UUID(), name: "Household", createdAt: .now)
    }

    // MARK: Snapshots

    public private(set) var household: HouseholdInfo
    /// Ordered by `sortOrder`.
    public private(set) var profiles: [ProfileRecord] = []
    /// Not removed, ordered by `sortOrder`.
    public private(set) var sources: [SourceRecord] = []
    public private(set) var members: [MemberRecord] = []
    /// Fresh rows only (stale ones filtered out).
    public private(set) var activePlaybacks: [PlaybackRecord] = []
    public private(set) var syncStatus: HouseholdSyncStatus = .local
    /// Bumped on every store change; read it in a view to re-query
    /// favorites and progress.
    public private(set) var revision: Int = 0

    // MARK: Household (HH-1)

    /// Creates the household on first launch ("<surname> Household") with one
    /// built-in standard profile, so favorites already belong to a profile.
    /// No-op when one exists (here or arriving from iCloud).
    public func ensureHousehold(defaultName: String, firstProfileName: String) {}

    public func renameHousehold(_ name: String) {}

    public func setAdultCategoryKeys(_ keys: Set<String>) {}

    public func setHidesAdultEverywhere(_ hides: Bool) {}

    // MARK: Profiles (PRF-1, PRF-3)

    public static let maxProfiles = 8

    /// Nil when the household already has `maxProfiles`.
    @discardableResult
    public func addProfile(name: String, kind: ProfileKind, avatarColor: AvatarPalette, avatarSymbol: String? = nil) -> ProfileRecord? { nil }

    public func updateProfile(_ profile: ProfileRecord) {}

    /// Deletes the profile with its favorites and progress.
    public func deleteProfile(id: UUID) {}

    public func moveProfiles(fromOffsets: IndexSet, toOffset: Int) {}

    /// Sets or clears (nil) a 4-digit PIN, stored as a salted hash (PAR-3).
    public func setPIN(_ pin: String?, for profileID: UUID) {}

    public func verifyPIN(_ pin: String, for profileID: UUID) -> Bool { false }

    // MARK: Sources (SRC-8, SRC-9)

    @discardableResult
    public func addSource(_ source: SourceRecord) -> SourceRecord { source }

    public func updateSource(_ source: SourceRecord) {}

    /// Hides the source; its favorites and progress stay for when it returns.
    public func removeSource(id: UUID) {}

    /// Removed sources, for "add it back".
    public func removedSources() -> [SourceRecord] { [] }

    public func restoreSource(id: UUID) {}

    /// Records what the provider said about expiry (Household, SRC-5).
    public func setSourceExpiry(_ date: Date?, for sourceID: UUID) {}

    // MARK: Favorites and My List (FAV-1, FAV-3, PRF-7)

    /// Ordered by `sortOrder`. Guests always get none.
    public func favorites(profileID: UUID, kind: FavoriteKind) -> [FavoriteRecord] { [] }

    public func isFavorite(profileID: UUID, itemKey: String) -> Bool { false }

    /// Adds at the end or removes. A no-op for a Guest profile.
    public func toggleFavorite(profileID: UUID, itemKey: String, kind: FavoriteKind) {}

    public func moveFavorites(profileID: UUID, kind: FavoriteKind, fromOffsets: IndexSet, toOffset: Int) {}

    /// Rewrites item keys a refresh renamed (FAV-2): one synced write each.
    public func rewriteItemKeys(_ replacements: [String: String]) {}

    // MARK: Progress (VOD-3, SER-2, PRF-7)

    public func progress(profileID: UUID, itemKey: String) -> ProgressRecord? { nil }

    /// Saves in place (one row per profile and item); marks watched at 95%.
    /// A no-op for a Guest. Call on pause, stop, finish, background and every
    /// 5 minutes of playback — never per second.
    public func saveProgress(profileID: UUID, itemKey: String, kind: ProgressKind, position: TimeInterval, duration: TimeInterval, seriesKey: String? = nil, season: Int? = nil, episode: Int? = nil) {}

    public func setWatched(_ watched: Bool, profileID: UUID, itemKey: String) {}

    /// Unfinished movies and episodes, most recent first (HOME-1).
    public func continueWatching(profileID: UUID, limit: Int = 20) -> [ProgressRecord] { [] }

    /// Every progress row of one profile for one series, for episode marks.
    public func seriesProgress(profileID: UUID, seriesKey: String) -> [ProgressRecord] { [] }

    /// For each other non-guest profile, its latest episode row in this
    /// series (SER-3): "Anya · S3 E1".
    public func householdProgress(seriesKey: String, excluding profileID: UUID) -> [(profile: ProfileRecord, progress: ProgressRecord)] { [] }

    /// Series with progress for this profile, most recent first, with the last
    /// episode watched — CatalogKit then finds the next one (SER-2).
    public func seriesInProgress(profileID: UUID, limit: Int = 20) -> [ProgressRecord] { [] }

    // MARK: Who's watching (HH-5, HH-6)

    /// Writes the row at play. Returns its id for heartbeats and stop.
    @discardableResult
    public func startPlayback(profileID: UUID, sourceID: UUID, itemKey: String, title: String, deviceName: String) -> UUID { UUID() }

    /// Every 10 minutes while playing, never more often.
    public func heartbeat(playbackID: UUID) {}

    public func stopPlayback(playbackID: UUID) {}

    /// Deletes rows unseen for 15 minutes.
    public func purgeStalePlaybacks(now: Date = .now) {}

    /// Streams in use on a source, not counting `excludingPlaybackID` (this
    /// device's own stream when switching channel).
    public func streamUsage(sourceID: UUID, limit: Int?, excludingPlaybackID: UUID? = nil) -> StreamUsage {
        StreamUsage(sourceID: sourceID, limit: limit, inUse: [])
    }

    // MARK: Sharing (HH-2…HH-4)

    /// Prepares the household's share off the main thread (never a bare
    /// `share()` on main: Multitrack's build 16 deadlocked), bounded wait.
    public func prepareShare() async throws -> (share: CKShare, container: CKContainer) {
        throw CocoaError(.featureUnsupported)
    }

    /// Accepts an invitation the system routed to the app.
    public func acceptShare(_ metadata: CKShare.Metadata) async throws {}

    /// A participant leaves by purging the share's zone, never deleting the
    /// root (which would ask iCloud to delete the owner's record).
    public func leaveHousehold() async throws {}

    /// The owner sets a member's role (MemberRole rows are owner-written).
    public func setRole(_ role: MemberRole, forParticipant participantID: String) {}

    /// Re-reads iCloud at most once a minute, waiting (bounded) for an import.
    public func refreshFromCloud() async {}
}
