import CloudKit
import Core
import CoreData
import Foundation
import Observation
import os

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
/// Which household is shown: one someone else shared with this person (in the
/// shared store) when there is one, else this person's own (in the private
/// store). A member who joins keeps their own first-launch household
/// untouched underneath, and gets it back on leaving (HH-4).
///
/// Roles are the app's, not iCloud's (every participant has read-write access
/// so they can save their own favorites and progress). Screens hide controls
/// by `household.currentRole`; the store also refuses household, profile and
/// source edits from a "can watch" member, so a stale screen can't write.
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

    /// Opens both stores. Throws `HouseholdStoreError` when either can't load
    /// (the app shows it); never crashes on it.
    public init(mode: Mode) throws {
        self.mode = mode
        let built = try HouseholdContainer.make(mode: mode)
        container = built.container
        privateStoreURL = built.privateURL
        sharedStoreURL = built.sharedURL
        cloudEvents = built.events
        let placeholder = HouseholdInfo(id: UUID(), name: "Household", createdAt: .now)
        placeholderHousehold = placeholder
        household = placeholder
        if let observer = built.eventObserver { observers.tokens.append(observer) }
        startObserving()
        tidyAfterImport()
        rebuildSnapshots()
        if case .cloud(let identifier) = mode {
            syncStatus = .syncing
            checkAccount(containerIdentifier: identifier)
        }
    }

    // MARK: Plumbing

    let container: NSPersistentCloudKitContainer
    let privateStoreURL: URL
    let sharedStoreURL: URL
    let cloudEvents: CloudEventLedger
    private let observers = ObserverTokens()
    private let placeholderHousehold: HouseholdInfo
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var pendingTidy = false
    @ObservationIgnored var ensureTask: Task<Void, Never>?
    /// The names `ensureHousehold` was last given, to make a new household
    /// after leaving someone else's.
    @ObservationIgnored var ensureNames: (household: String, profile: String)?
    /// Playback rows this device wrote, so stream usage lists other devices first.
    @ObservationIgnored var ownPlaybackIDs: Set<UUID> = []
    @ObservationIgnored var shareState = ShareState()
    @ObservationIgnored var shareLookupTask: Task<Void, Never>?
    @ObservationIgnored var householdFoldTask: Task<Void, Never>?
    @ObservationIgnored var lastHouseholdFoldAttempt: Date?
    @ObservationIgnored var lastNudgeAt: Date?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var shareCalls = ShareCallLedger<NSManagedObjectID>()
    @ObservationIgnored var runningShareCalls: [NSManagedObjectID: Task<Result<CKShare, ShareCallError>, Never>] = [:]
    @ObservationIgnored private var accountStatus: CKAccountStatus?

    var viewContext: NSManagedObjectContext { container.viewContext }
    var privateStore: NSPersistentStore? { container.persistentStoreCoordinator.persistentStore(for: privateStoreURL) }
    var sharedStore: NSPersistentStore? { container.persistentStoreCoordinator.persistentStore(for: sharedStoreURL) }

    /// Imports and saves often come in bursts; one snapshot rebuild per burst.
    static let refreshDebounce: Duration = .milliseconds(300)
    /// How long a first launch waits for iCloud before making a household,
    /// so a second device doesn't make a duplicate (HH-1).
    static let firstImportWait: Duration = .seconds(15)

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
    /// False until a household exists here — on a first launch in cloud mode,
    /// while `ensureHousehold` waits for iCloud. `household` is a placeholder
    /// until then.
    public private(set) var hasHousehold = false
    /// The last save that failed, in Core Data's words, or nil. The change
    /// was rolled back.
    public private(set) var lastWriteError: String?
    /// What `prepareShare` is doing ("Creating the share in iCloud…"), for
    /// the invite sheet; nil when it isn't running.
    public internal(set) var sharePreparationStatus: String?

    private func startObserving() {
        let center = NotificationCenter.default
        // Local saves and merged imports land in the view context.
        observers.tokens.append(center.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: viewContext,
            queue: nil
        ) { [weak self] _ in
            Self.onMain { self?.scheduleRefresh(tidy: false) }
        })
        // Imports from iCloud (and saves from any context) reach the stores;
        // posted on the coordinator's queue, handed to main asynchronously.
        observers.tokens.append(center.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh(tidy: true) }
        })
        cloudEvents.setListener { [weak self] in
            Task { @MainActor in self?.updateSyncStatus() }
        }
    }

    /// Runs `body` on the main actor: at once when already there (the view
    /// context posts on main), else asynchronously.
    private nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            Task { @MainActor in body() }
        }
    }

    private func scheduleRefresh(tidy: Bool) {
        pendingTidy = pendingTidy || tidy
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshDebounce)
            guard !Task.isCancelled, let self else { return }
            self.pendingRefresh = nil
            if self.pendingTidy {
                self.pendingTidy = false
                self.tidyAfterImport()
            }
            self.rebuildSnapshots()
        }
    }

    /// After this device's own write: snapshots now, not after the debounce,
    /// so the screen that wrote sees it at once.
    private func didWrite() {
        if pendingTidy {
            pendingTidy = false
            tidyAfterImport()
        }
        rebuildSnapshots()
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    /// Rebuilds every snapshot from the store and bumps `revision`.
    func rebuildSnapshots(now: Date = .now) {
        defer { revision += 1 }
        guard let current = currentHouseholdEntity() else {
            assign(\.hasHousehold, false)
            assign(\.household, placeholderHousehold)
            assign(\.profiles, [])
            assign(\.sources, [])
            assign(\.activePlaybacks, [])
            assign(\.members, MemberList.make(participants: [], roles: [:], ownerFallbackName: "You"))
            return
        }
        let isParticipant = isInSharedStore(current)
        let roles = rolesByParticipant(in: current)
        let share = shareState.householdObjectID == current.objectID ? shareState.share : nil
        let participants = share.map(ShareParticipantInfo.list(from:)) ?? []
        let role = MemberList.currentRole(
            isParticipant: isParticipant,
            currentParticipantID: share?.currentUserParticipant?.participantID,
            roles: roles
        )
        let profileRecords = live(current.profiles).map(\.record).sorted(by: Self.profileOrder)

        assign(\.hasHousehold, true)
        assign(\.household, HouseholdInfo(
            id: current.id ?? placeholderHousehold.id,
            name: current.name,
            createdAt: current.createdAt,
            adultCategoryKeys: JSONList.decode(current.adultCategoryKeys),
            hidesAdultEverywhere: current.hidesAdultEverywhere,
            isShared: isParticipant || share != nil,
            currentRole: role
        ))
        assign(\.profiles, profileRecords)
        assign(\.sources, live(current.sources).filter { !$0.isRemoved }.map(\.record).sorted(by: Self.sourceOrder))
        assign(\.activePlaybacks, live(current.playbacks).map(\.record).filter { !$0.isStale(at: now) }.sorted { $0.startedAt < $1.startedAt })
        // Before the household is shared there is one member: whoever made
        // it, whose first profile ensureHousehold named after them.
        let ownerName = profileRecords.first { $0.kind == .standard }?.name ?? "You"
        assign(\.members, MemberList.make(participants: participants, roles: roles, ownerFallbackName: ownerName))
        scheduleShareLookup()
    }

    /// Sets a snapshot only when it changed, so views don't redraw for nothing.
    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<HouseholdStore, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    func updateSyncStatus() {
        guard case .cloud = mode else {
            assign(\.syncStatus, .local)
            return
        }
        if accountStatus == .noAccount || accountStatus == .restricted {
            assign(\.syncStatus, .noAccount)
        } else {
            assign(\.syncStatus, CloudEventLedger.status(cloudEvents.snapshot))
        }
    }

    private func checkAccount(containerIdentifier: String) {
        Task { [weak self] in
            let status = try? await CKContainer(identifier: containerIdentifier).accountStatus()
            guard let self else { return }
            self.accountStatus = status
            self.updateSyncStatus()
        }
    }

    // MARK: Household (HH-1)

    /// Creates the household on first launch ("<surname> Household") with one
    /// built-in standard profile, so favorites already belong to a profile.
    /// No-op when one exists (here or arriving from iCloud).
    ///
    /// In cloud mode it first waits (at most `firstImportWait`) for this
    /// launch's first iCloud import, as Multitrack's CloudKitImportGate does:
    /// a second device that created before its import would make a duplicate
    /// household. Duplicates that still happen (both devices offline) are
    /// folded into the oldest on the next import.
    public func ensureHousehold(defaultName: String, firstProfileName: String) {
        ensureNames = (defaultName, firstProfileName)
        guard currentHouseholdEntity() == nil, ensureTask == nil else { return }
        switch mode {
        case .inMemory:
            createHousehold(name: defaultName, firstProfileName: firstProfileName)
        case .cloud:
            ensureTask = Task { [weak self] in
                await self?.waitForFirstImport()
                guard let self else { return }
                self.ensureTask = nil
                self.tidyAfterImport()
                if self.currentHouseholdEntity() == nil {
                    self.createHousehold(name: defaultName, firstProfileName: firstProfileName)
                } else {
                    self.rebuildSnapshots()
                }
            }
        }
    }

    /// `ensureHousehold`, returning once the household exists (or the wait
    /// for iCloud has ended and one was made), for a launch that wants to
    /// restore the profile session right after.
    public func prepareHousehold(defaultName: String, firstProfileName: String) async {
        ensureHousehold(defaultName: defaultName, firstProfileName: firstProfileName)
        await ensureTask?.value
    }

    /// Returns once the private store has finished an import this launch, or
    /// the bound passed, or there's no account to import from.
    private func waitForFirstImport() async {
        guard case .cloud(let identifier) = mode, let store = privateStore else { return }
        let storeID = store.identifier
        if cloudEvents.hasImported(store: storeID) { return }
        switch try? await CKContainer(identifier: identifier).accountStatus() {
        case .noAccount?, .restricted?:
            // Nothing can arrive; waiting could only time out.
            return
        default:
            break
        }
        let arrived = await cloudEvents.wait(timeout: Self.firstImportWait) { $0.hasImported(store: storeID) }
        if !arrived {
            Logger.household.notice("No iCloud import within \(Int(Self.firstImportWait.components.seconds), privacy: .public) s; creating the household locally")
        }
    }

    private func createHousehold(name: String, firstProfileName: String) {
        guard let store = privateStore else { return }
        let household = NSEntityDescription.insertNewObject(forEntityName: HouseholdModel.Entity.household, into: viewContext) as! HouseholdEntity
        viewContext.assign(household, to: store)
        household.id = UUID()
        household.name = name
        household.createdAt = .now
        household.adultCategoryKeys = "[]"
        household.hidesAdultEverywhere = true

        let profile = insert(HouseholdModel.Entity.profile, as: ProfileEntity.self, into: store)
        profile.id = UUID()
        profile.name = firstProfileName
        profile.kindRaw = ProfileKind.standard.rawValue
        profile.avatarColorRaw = AvatarPalette.amber.rawValue
        profile.sortOrder = 0
        profile.household = household
        commit("create household")
    }

    public func renameHousehold(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canManage, !name.isEmpty, let household = currentHouseholdEntity() else { return }
        set(household, \.name, name)
        commit("rename household")
    }

    public func setAdultCategoryKeys(_ keys: Set<String>) {
        guard canManage, let household = currentHouseholdEntity() else { return }
        set(household, \.adultCategoryKeys, JSONList.encode(keys))
        commit("adult categories")
    }

    public func setHidesAdultEverywhere(_ hides: Bool) {
        guard canManage, let household = currentHouseholdEntity() else { return }
        set(household, \.hidesAdultEverywhere, hides)
        commit("hide adult")
    }

    // MARK: Profiles (PRF-1, PRF-3)

    public static let maxProfiles = 8

    /// Nil when the household already has `maxProfiles`.
    @discardableResult
    public func addProfile(name: String, kind: ProfileKind, avatarColor: AvatarPalette, avatarSymbol: String? = nil) -> ProfileRecord? {
        guard canManage, let household = currentHouseholdEntity() else { return nil }
        let existing = live(household.profiles)
        guard existing.count < Self.maxProfiles else { return nil }
        let profile = insert(HouseholdModel.Entity.profile, as: ProfileEntity.self, into: targetStore(for: household))
        let id = UUID()
        profile.id = id
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.kindRaw = kind.rawValue
        profile.avatarColorRaw = avatarColor.rawValue
        profile.avatarSymbol = avatarSymbol
        profile.sortOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        profile.household = household
        guard commit("add profile") else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Writes the editable fields: name, kind, avatar, order, category and
    /// source rules, languages. Not the PIN (`setPIN`). Turning a profile into
    /// a Guest deletes what it kept (PRF-5).
    public func updateProfile(_ profile: ProfileRecord) {
        guard canManage, let entity = profileEntity(profile.id) else { return }
        let wasGuest = entity.kind == .guest
        set(entity, \.name, profile.name.trimmingCharacters(in: .whitespacesAndNewlines))
        set(entity, \.kindRaw, profile.kind.rawValue)
        set(entity, \.avatarColorRaw, profile.avatarColor.rawValue)
        set(entity, \.avatarSymbol, profile.avatarSymbol)
        set(entity, \.sortOrder, profile.sortOrder)
        set(entity, \.allowedCategoryKeys, JSONList.encode(profile.allowedCategoryKeys))
        set(entity, \.hiddenCategoryKeys, JSONList.encode(profile.hiddenCategoryKeys))
        set(entity, \.visibleSourceIDs, JSONList.encode(profile.visibleSourceIDs))
        set(entity, \.audioLanguage, profile.audioLanguage)
        set(entity, \.subtitleLanguage, profile.subtitleLanguage)
        if profile.kind == .guest, !wasGuest { deleteKeptData(of: entity) }
        commit("update profile")
    }

    /// Deletes the profile with its favorites and progress. The last profile
    /// stays: favorites must always belong to one (HH-7).
    public func deleteProfile(id: UUID) {
        guard canManage, let household = currentHouseholdEntity(), let entity = profileEntity(id) else { return }
        guard live(household.profiles).count > 1 else { return }
        viewContext.delete(entity)
        commit("delete profile")
    }

    public func moveProfiles(fromOffsets: IndexSet, toOffset: Int) {
        guard canManage, let household = currentHouseholdEntity() else { return }
        let ordered = live(household.profiles).sorted { Self.profileOrder($0.record, $1.record) }
        for (index, profile) in FractionalOrder.moved(ordered, fromOffsets: fromOffsets, toOffset: toOffset).enumerated() {
            set(profile, \.sortOrder, index)
        }
        commit("move profiles")
    }

    /// Sets or clears (nil) a 4-digit PIN, stored as a salted hash (PAR-3).
    /// An invalid PIN changes nothing. The owner or a manager clearing one is
    /// the reset for a forgotten PIN.
    public func setPIN(_ pin: String?, for profileID: UUID) {
        guard canManage, let entity = profileEntity(profileID) else { return }
        if let pin {
            guard PINHasher.isValidPIN(pin) else { return }
            let salt = PINHasher.makeSalt()
            entity.pinSalt = salt
            entity.pinHash = PINHasher.hash(pin: pin, salt: salt)
        } else {
            set(entity, \.pinHash, "")
            set(entity, \.pinSalt, "")
        }
        commit("set PIN")
    }

    /// True when `pin` opens the profile. A profile without a PIN asks for
    /// none, so anything passes.
    public func verifyPIN(_ pin: String, for profileID: UUID) -> Bool {
        guard let entity = profileEntity(profileID) else { return false }
        guard !entity.pinHash.isEmpty else { return true }
        return PINHasher.hash(pin: pin, salt: entity.pinSalt) == entity.pinHash
    }

    // MARK: Sources (SRC-8, SRC-9)

    /// Adds the source at the end of the list (or updates it, if one with its
    /// id exists) and returns it as stored.
    @discardableResult
    public func addSource(_ source: SourceRecord) -> SourceRecord {
        guard canManage, let household = currentHouseholdEntity() else { return source }
        if sourceEntity(source.id) != nil {
            updateSource(source)
            return sourceEntity(source.id)?.record ?? source
        }
        let entity = insert(HouseholdModel.Entity.source, as: SourceEntity.self, into: targetStore(for: household))
        entity.id = source.id
        apply(source, to: entity)
        entity.isRemoved = false
        entity.sortOrder = (live(household.sources).filter { $0 !== entity }.map(\.sortOrder).max() ?? -1) + 1
        entity.household = household
        commit("add source")
        return entity.isDeleted ? source : entity.record
    }

    /// Writes name, address, order, stream limit, expiry and login. Removal
    /// goes through `removeSource` / `restoreSource`.
    public func updateSource(_ source: SourceRecord) {
        guard canManage, let entity = sourceEntity(source.id) else { return }
        apply(source, to: entity)
        set(entity, \.sortOrder, source.sortOrder)
        commit("update source")
    }

    /// Hides the source; its favorites and progress stay for when it returns.
    public func removeSource(id: UUID) {
        guard canManage, let entity = sourceEntity(id) else { return }
        set(entity, \.isRemoved, true)
        commit("remove source")
    }

    /// Removed sources, for "add it back".
    public func removedSources() -> [SourceRecord] {
        guard let household = currentHouseholdEntity() else { return [] }
        return live(household.sources).filter(\.isRemoved).map(\.record).sorted(by: Self.sourceOrder)
    }

    public func restoreSource(id: UUID) {
        guard canManage, let entity = sourceEntity(id) else { return }
        set(entity, \.isRemoved, false)
        commit("restore source")
    }

    /// Records what the provider said about expiry (Household, SRC-5). Any
    /// member's device may write it: it comes from the provider, not a person.
    public func setSourceExpiry(_ date: Date?, for sourceID: UUID) {
        guard let entity = sourceEntity(sourceID) else { return }
        set(entity, \.expiresAt, date)
        commit("source expiry")
    }

    private func apply(_ source: SourceRecord, to entity: SourceEntity) {
        set(entity, \.name, source.name)
        set(entity, \.kindRaw, source.kindRaw)
        set(entity, \.serverURL, source.serverURL)
        set(entity, \.maxStreams, source.maxStreams)
        set(entity, \.expiresAt, source.expiresAt)
        let login = source.credentials
        set(entity, \.macAddress, login.macAddress)
        set(entity, \.username, login.username)
        set(entity, \.password, login.password)
        set(entity, \.playlistURL, login.playlistURL)
        set(entity, \.guideURL, login.guideURL)
        set(entity, \.serialNumber, login.serialNumber)
        set(entity, \.deviceID, login.deviceID)
        set(entity, \.deviceID2, login.deviceID2)
        set(entity, \.signature, login.signature)
        set(entity, \.model, login.model)
        set(entity, \.timeZone, login.timeZone)
    }

    // MARK: Favorites and My List (FAV-1, FAV-3, PRF-7)

    /// Ordered by `sortOrder`. Guests always get none. Favorites of a removed
    /// source are hidden until it comes back (SRC-9); a duplicate a fold
    /// hasn't reached yet shows once.
    public func favorites(profileID: UUID, kind: FavoriteKind) -> [FavoriteRecord] {
        guard let profile = profileEntity(profileID), profile.kind != .guest else { return [] }
        let removed = removedSourceIDs()
        let rows = live(profile.favorites).filter { (FavoriteKind(rawValue: $0.kindRaw) ?? .channel) == kind }
        return Dictionary(grouping: rows, by: \.itemKey)
            .compactMap { _, group in FoldRules.favoriteKeeper(group.map(\.foldRow)).map { group[$0] } }
            .filter { favorite in ItemKeyHint.sourceID(of: favorite.itemKey).map { !removed.contains($0) } ?? true }
            .map(\.record)
            .sorted(by: Self.favoriteOrder)
    }

    public func isFavorite(profileID: UUID, itemKey: String) -> Bool {
        guard let profile = profileEntity(profileID), profile.kind != .guest else { return false }
        return live(profile.favorites).contains { $0.itemKey == itemKey }
    }

    /// Adds at the end or removes. A no-op for a Guest profile.
    public func toggleFavorite(profileID: UUID, itemKey: String, kind: FavoriteKind) {
        guard let profile = profileEntity(profileID), profile.kind != .guest else { return }
        let all = live(profile.favorites)
        let matching = all.filter { $0.itemKey == itemKey }
        if matching.isEmpty {
            let favorite = insert(HouseholdModel.Entity.favorite, as: FavoriteEntity.self, into: targetStore(for: profile))
            favorite.id = UUID()
            favorite.itemKey = itemKey
            favorite.kindRaw = kind.rawValue
            favorite.addedAt = .now
            favorite.sortOrder = (all.filter { $0.kindRaw == kind.rawValue }.map(\.sortOrder).max() ?? 0) + 1
            favorite.profile = profile
        } else {
            matching.forEach(viewContext.delete)
        }
        commit("toggle favorite")
    }

    /// Moves within one profile's list of one kind, writing only the moved
    /// rows: each gets a sort order between its new neighbours (FAV-1).
    public func moveFavorites(profileID: UUID, kind: FavoriteKind, fromOffsets: IndexSet, toOffset: Int) {
        let ordered = favorites(profileID: profileID, kind: kind)
        guard !ordered.isEmpty, let profile = profileEntity(profileID) else { return }
        let writes = FractionalOrder.writes(orders: ordered.map(\.sortOrder), fromOffsets: fromOffsets, toOffset: toOffset)
        guard !writes.isEmpty else { return }
        let rows = live(profile.favorites)
        for (index, sortOrder) in writes {
            let id = ordered[index].id
            if let row = rows.first(where: { $0.id == id }) { set(row, \.sortOrder, sortOrder) }
        }
        commit("move favorites")
    }

    /// Rewrites item keys a refresh renamed (FAV-2): one synced write each.
    /// A rename that lands on a key the profile already has folds the two.
    public func rewriteItemKeys(_ replacements: [String: String]) {
        let replacements = replacements.filter { $0.key != $0.value }
        guard !replacements.isEmpty, let household = currentHouseholdEntity() else { return }
        for profile in live(household.profiles) {
            for favorite in live(profile.favorites) {
                if let key = replacements[favorite.itemKey] { favorite.itemKey = key }
            }
            for row in live(profile.progress) {
                if let key = replacements[row.itemKey] { row.itemKey = key }
                if let series = row.seriesKey, let key = replacements[series] { row.seriesKey = key }
            }
        }
        foldFavorites(in: household)
        foldProgress(in: household)
        commit("rewrite item keys")
    }

    // MARK: Progress (VOD-3, SER-2, PRF-7)

    public func progress(profileID: UUID, itemKey: String) -> ProgressRecord? {
        guard let profile = profileEntity(profileID), profile.kind != .guest else { return nil }
        return progressRow(in: profile, itemKey: itemKey)?.record
    }

    /// Saves in place (one row per profile and item); marks watched at 95%.
    /// A no-op for a Guest. Call on pause, stop, finish, background and every
    /// 5 minutes of playback — never per second.
    public func saveProgress(profileID: UUID, itemKey: String, kind: ProgressKind, position: TimeInterval, duration: TimeInterval, seriesKey: String? = nil, season: Int? = nil, episode: Int? = nil) {
        guard let profile = profileEntity(profileID), profile.kind != .guest else { return }
        let row = progressRow(in: profile, itemKey: itemKey) ?? newProgressRow(in: profile, itemKey: itemKey)
        let position = max(position, 0), duration = max(duration, 0)
        // An episode key carries its series, season and number; callers that
        // only pass the key still get series marks (SER-1, SER-2).
        let hint = ItemKeyHint.episode(of: itemKey)
        set(row, \.kindRaw, kind.rawValue)
        set(row, \.position, position)
        set(row, \.duration, duration)
        set(row, \.watched, ProgressRules.isWatched(position: position, duration: duration))
        row.updatedAt = .now
        if let series = seriesKey ?? hint?.seriesKey { set(row, \.seriesKey, series) }
        if let season = season ?? hint?.season { set(row, \.season, NSNumber(value: season)) }
        if let episode = episode ?? hint?.episode { set(row, \.episode, NSNumber(value: episode)) }
        commit("save progress")
    }

    /// Marks an item watched or not by hand. Unwatching also forgets the
    /// position. With no row yet, watching makes one, its kind and series
    /// read from the item key. A no-op for a Guest.
    public func setWatched(_ watched: Bool, profileID: UUID, itemKey: String) {
        guard let profile = profileEntity(profileID), profile.kind != .guest else { return }
        if let row = progressRow(in: profile, itemKey: itemKey) {
            guard row.watched != watched || (!watched && row.position != 0) else { return }
            row.watched = watched
            if !watched { row.position = 0 }
            row.updatedAt = .now
        } else {
            guard watched else { return }
            let row = newProgressRow(in: profile, itemKey: itemKey)
            row.kindRaw = ItemKeyHint.progressKind(of: itemKey).rawValue
            row.watched = true
            row.updatedAt = .now
            if let hint = ItemKeyHint.episode(of: itemKey) {
                row.seriesKey = hint.seriesKey
                row.season = NSNumber(value: hint.season)
                row.episode = NSNumber(value: hint.episode)
            }
        }
        commit("set watched")
    }

    /// Unfinished movies and episodes, most recent first (HOME-1): one per
    /// series, nothing from a removed source.
    public func continueWatching(profileID: UUID, limit: Int = 20) -> [ProgressRecord] {
        ProgressRules.continueWatching(visibleProgress(profileID: profileID), limit: limit)
    }

    /// Every progress row of one profile for one series, for episode marks.
    public func seriesProgress(profileID: UUID, seriesKey: String) -> [ProgressRecord] {
        guard let profile = profileEntity(profileID), profile.kind != .guest else { return [] }
        return foldedProgress(of: profile)
            .filter { $0.seriesKey == seriesKey }
            .sorted { ($0.season ?? 0, $0.episode ?? 0, $0.itemKey) < ($1.season ?? 0, $1.episode ?? 0, $1.itemKey) }
    }

    /// For each other non-guest profile, its latest episode row in this
    /// series (SER-3): "Anya · S3 E1".
    public func householdProgress(seriesKey: String, excluding profileID: UUID) -> [(profile: ProfileRecord, progress: ProgressRecord)] {
        profiles.compactMap { profile in
            guard !profile.isGuest, profile.id != profileID, let entity = profileEntity(profile.id) else { return nil }
            let latest = foldedProgress(of: entity)
                .filter { $0.seriesKey == seriesKey }
                .min(by: ProgressRules.newestFirst)
            return latest.map { (profile, $0) }
        }
    }

    /// Series with progress for this profile, most recent first, with the last
    /// episode watched — CatalogKit then finds the next one (SER-2).
    public func seriesInProgress(profileID: UUID, limit: Int = 20) -> [ProgressRecord] {
        ProgressRules.seriesInProgress(visibleProgress(profileID: profileID), limit: limit)
    }

    /// The row saves and reads use: with duplicates not yet folded, the one a
    /// fold would keep (the later `updatedAt`).
    private func progressRow(in profile: ProfileEntity, itemKey: String) -> ProgressEntity? {
        let rows = live(profile.progress).filter { $0.itemKey == itemKey }
        return FoldRules.progressKeeper(rows.map(\.foldRow)).map { rows[$0] }
    }

    private func newProgressRow(in profile: ProfileEntity, itemKey: String) -> ProgressEntity {
        let row = insert(HouseholdModel.Entity.progress, as: ProgressEntity.self, into: targetStore(for: profile))
        row.id = UUID()
        row.itemKey = itemKey
        row.profile = profile
        return row
    }

    /// One row per item, as a fold would leave them.
    private func foldedProgress(of profile: ProfileEntity) -> [ProgressRecord] {
        Dictionary(grouping: live(profile.progress), by: \.itemKey)
            .compactMap { _, group in FoldRules.progressKeeper(group.map(\.foldRow)).map { group[$0].record } }
    }

    /// A non-guest profile's rows, minus those of removed sources (SRC-9).
    private func visibleProgress(profileID: UUID) -> [ProgressRecord] {
        guard let profile = profileEntity(profileID), profile.kind != .guest else { return [] }
        let removed = removedSourceIDs()
        return foldedProgress(of: profile).filter { row in
            ItemKeyHint.sourceID(of: row.itemKey).map { !removed.contains($0) } ?? true
        }
    }

    // MARK: Who's watching (HH-5, HH-6)

    /// Writes the row at play. Returns its id for heartbeats and stop.
    @discardableResult
    public func startPlayback(profileID: UUID, sourceID: UUID, itemKey: String, title: String, deviceName: String) -> UUID {
        let id = UUID()
        guard let household = currentHouseholdEntity() else { return id }
        let row = insert(HouseholdModel.Entity.playback, as: PlaybackEntity.self, into: targetStore(for: household))
        let now = Date.now
        row.id = id
        row.profileID = profileID
        row.sourceID = sourceID
        row.itemKey = itemKey
        row.title = title
        row.deviceName = deviceName
        row.startedAt = now
        row.lastSeenAt = now
        row.household = household
        ownPlaybackIDs.insert(id)
        commit("start playback")
        return id
    }

    /// Every 10 minutes while playing, never more often.
    public func heartbeat(playbackID: UUID) {
        guard let row = playbackEntity(playbackID) else { return }
        row.lastSeenAt = .now
        commit("heartbeat")
    }

    public func stopPlayback(playbackID: UUID) {
        ownPlaybackIDs.remove(playbackID)
        guard let household = currentHouseholdEntity() else { return }
        live(household.playbacks).filter { $0.id == playbackID }.forEach(viewContext.delete)
        commit("stop playback")
    }

    /// Deletes rows unseen for 15 minutes.
    public func purgeStalePlaybacks(now: Date = .now) {
        guard let household = currentHouseholdEntity() else { return }
        if purgeStalePlaybacks(in: household, now: now) { commit("purge playbacks") }
    }

    /// Streams in use on a source, not counting `excludingPlaybackID` (this
    /// device's own stream when switching channel).
    public func streamUsage(sourceID: UUID, limit: Int?, excludingPlaybackID: UUID? = nil) -> StreamUsage {
        StreamRules.usage(
            sourceID: sourceID,
            limit: limit,
            playbacks: activePlaybacks,
            excluding: excludingPlaybackID,
            ownPlaybackIDs: ownPlaybackIDs,
            now: .now
        )
    }

    // MARK: Guests (PRF-5, PAR-4)

    /// Deletes anything a Guest profile holds. Guests never write favorites or
    /// progress through this store; this clears rows an older build or a
    /// profile that was standard before left behind. Does nothing for a
    /// profile that isn't a Guest.
    public func clearGuestData(profileID: UUID) {
        guard let profile = profileEntity(profileID), profile.kind == .guest else { return }
        guard deleteKeptData(of: profile) else { return }
        commit("clear guest")
    }

    @discardableResult
    private func deleteKeptData(of profile: ProfileEntity) -> Bool {
        let rows: [NSManagedObject] = live(profile.favorites) + live(profile.progress)
        rows.forEach(viewContext.delete)
        return !rows.isEmpty
    }

    // MARK: Lookups

    /// The household shown: the oldest one shared with this person, else this
    /// person's own oldest. Never creates one.
    func currentHouseholdEntity() -> HouseholdEntity? {
        let all = fetch(HouseholdEntity.self, HouseholdModel.Entity.household)
        let shared = all.filter(isInSharedStore)
        let candidates = shared.isEmpty ? all : shared
        return candidates.min(by: Self.householdOrder)
    }

    func fetch<T: NSManagedObject>(_ type: T.Type, _ entityName: String, predicate: NSPredicate? = nil) -> [T] {
        let request = NSFetchRequest<T>(entityName: entityName)
        request.predicate = predicate
        do {
            return try viewContext.fetch(request).filter { !$0.isDeleted }
        } catch {
            let error = error as NSError
            Logger.household.error("Fetch \(entityName, privacy: .public) failed: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
            return []
        }
    }

    func profileEntity(_ id: UUID) -> ProfileEntity? {
        guard let household = currentHouseholdEntity() else { return nil }
        return live(household.profiles).first { $0.id == id }
    }

    func sourceEntity(_ id: UUID) -> SourceEntity? {
        guard let household = currentHouseholdEntity() else { return nil }
        return live(household.sources).first { $0.id == id }
    }

    private func playbackEntity(_ id: UUID) -> PlaybackEntity? {
        guard let household = currentHouseholdEntity() else { return nil }
        return live(household.playbacks).first { $0.id == id }
    }

    private func removedSourceIDs() -> Set<UUID> {
        guard let household = currentHouseholdEntity() else { return [] }
        return Set(live(household.sources).filter(\.isRemoved).compactMap(\.id))
    }

    func rolesByParticipant(in household: HouseholdEntity) -> [String: MemberRole] {
        Dictionary(grouping: live(household.memberRoles), by: \.participantID)
            .mapValues { MemberList.foldedRole($0.map(\.role)) }
    }

    func isInSharedStore(_ object: NSManagedObject) -> Bool {
        object.objectID.persistentStore?.url == sharedStoreURL
    }

    /// Whether this device's member may change household, profile and source
    /// settings (SRC-8).
    var canManage: Bool { household.currentRole.canManage }

    /// The store `household` (or anything in it) lives in: everything related
    /// to it must be inserted there, since Core Data can't relate objects
    /// across stores.
    func targetStore(for object: NSManagedObject) -> NSPersistentStore? {
        if let store = object.objectID.persistentStore { return store }
        if let profile = object as? ProfileEntity, let household = profile.household { return targetStore(for: household) }
        return privateStore
    }

    func insert<T: NSManagedObject>(_ entityName: String, as type: T.Type, into store: NSPersistentStore?) -> T {
        // The model maps every entity to its class, so the cast can't fail.
        let object = NSEntityDescription.insertNewObject(forEntityName: entityName, into: viewContext) as! T
        if let store { viewContext.assign(object, to: store) }
        return object
    }

    func live<T: NSManagedObject>(_ set: Set<T>?) -> [T] {
        (set ?? []).filter { !$0.isDeleted }
    }

    /// Assigns only a changed value: re-setting an equal one still marks the
    /// object updated, and every update is a synced write.
    func set<Root: NSManagedObject, Value: Equatable>(_ object: Root, _ keyPath: ReferenceWritableKeyPath<Root, Value>, _ value: Value) {
        if object[keyPath: keyPath] != value { object[keyPath: keyPath] = value }
    }

    // MARK: Saving

    /// Saves (rolling back on failure, recorded in `lastWriteError`), then
    /// rebuilds the snapshots. True when the save worked or had nothing to do.
    @discardableResult
    func commit(_ action: String) -> Bool {
        let saved = save(action)
        didWrite()
        return saved
    }

    @discardableResult
    func save(_ action: String) -> Bool {
        guard viewContext.hasChanges else { return true }
        do {
            try viewContext.save()
            if lastWriteError != nil { lastWriteError = nil }
            return true
        } catch {
            let nsError = error as NSError
            Logger.household.error("Save failed (\(action, privacy: .public)): \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
            lastWriteError = HouseholdContainer.explain(error)
            viewContext.rollback()
            return false
        }
    }

    // MARK: Ordering

    static func householdOrder(_ lhs: HouseholdEntity, _ rhs: HouseholdEntity) -> Bool {
        if !FoldRules.sameInstant(lhs.createdAt, rhs.createdAt) { return lhs.createdAt < rhs.createdAt }
        return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
    }

    static func profileOrder(_ lhs: ProfileRecord, _ rhs: ProfileRecord) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func sourceOrder(_ lhs: SourceRecord, _ rhs: SourceRecord) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func favoriteOrder(_ lhs: FavoriteRecord, _ rhs: FavoriteRecord) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

// MARK: - Snapshots from managed objects

extension SourceEntity {
    var record: SourceRecord {
        SourceRecord(
            id: id ?? UUID(),
            name: name,
            kindRaw: kindRaw,
            serverURL: serverURL,
            sortOrder: sortOrder,
            isRemoved: isRemoved,
            maxStreams: maxStreams,
            expiresAt: expiresAt,
            credentials: SourceCredentials(
                macAddress: macAddress,
                username: username,
                password: password,
                playlistURL: playlistURL,
                guideURL: guideURL,
                serialNumber: serialNumber,
                deviceID: deviceID,
                deviceID2: deviceID2,
                signature: signature,
                model: model,
                timeZone: timeZone
            )
        )
    }
}

extension ProfileEntity {
    var record: ProfileRecord {
        ProfileRecord(
            id: id ?? UUID(),
            name: name,
            kind: kind,
            avatarColor: AvatarPalette(rawValue: avatarColorRaw) ?? .amber,
            avatarSymbol: avatarSymbol,
            sortOrder: sortOrder,
            hasPIN: !pinHash.isEmpty,
            allowedCategoryKeys: JSONList.decode(allowedCategoryKeys),
            hiddenCategoryKeys: JSONList.decode(hiddenCategoryKeys),
            visibleSourceIDs: JSONList.decodeUUIDs(visibleSourceIDs),
            audioLanguage: audioLanguage,
            subtitleLanguage: subtitleLanguage
        )
    }
}

extension FavoriteEntity {
    var record: FavoriteRecord {
        FavoriteRecord(
            id: id ?? UUID(),
            profileID: profile?.id ?? UUID(),
            itemKey: itemKey,
            kind: FavoriteKind(rawValue: kindRaw) ?? .channel,
            sortOrder: sortOrder,
            addedAt: addedAt
        )
    }

    var foldRow: FoldRules.Row {
        FoldRules.Row(date: addedAt, id: id?.uuidString ?? objectID.uriRepresentation().absoluteString)
    }
}

extension ProgressEntity {
    var record: ProgressRecord {
        ProgressRecord(
            id: id ?? UUID(),
            profileID: profile?.id ?? UUID(),
            itemKey: itemKey,
            kind: ProgressKind(rawValue: kindRaw) ?? .movie,
            position: position,
            duration: duration,
            watched: watched,
            updatedAt: updatedAt,
            seriesKey: seriesKey,
            season: season?.intValue,
            episode: episode?.intValue
        )
    }

    var foldRow: FoldRules.Row {
        FoldRules.Row(date: updatedAt, id: id?.uuidString ?? objectID.uriRepresentation().absoluteString)
    }
}

extension PlaybackEntity {
    var record: PlaybackRecord {
        PlaybackRecord(
            id: id ?? UUID(),
            deviceName: deviceName,
            profileID: profileID ?? UUID(),
            sourceID: sourceID ?? UUID(),
            itemKey: itemKey,
            title: title,
            startedAt: startedAt,
            lastSeenAt: lastSeenAt
        )
    }
}
