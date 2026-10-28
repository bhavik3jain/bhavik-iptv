import CatalogKit
import Core
import Foundation
import HouseholdKit
import Observation
import os
import PlayerKit
import SourceKit

/// One open player and what it is recording.
@MainActor
final class PlayerSession: Identifiable {
    let id = UUID()
    /// The window that asked; its root presents the player (iOS) and any
    /// prompt. Nil when a launch argument started it.
    let sceneID: UUID?
    /// The window's layout when it asked: the multi-view button is offered
    /// only in the sidebar layout.
    let layout: HearthLayout
    let profileID: UUID
    let isGuest: Bool
    let model: PlayerModel
    let items: PlayerItemFactory
    /// The who's-watching row of what's playing now (HH-5).
    var playbackID: UUID?
    var playing: PlayableContext?
    var heartbeat: Task<Void, Never>?
    var keepAlive: Task<Void, Never>?

    init(sceneID: UUID?, layout: HearthLayout, profile: ProfileRecord, model: PlayerModel, items: PlayerItemFactory) {
        self.sceneID = sceneID
        self.layout = layout
        self.profileID = profile.id
        self.isGuest = profile.isGuest
        self.model = model
        self.items = items
    }
}

/// HH-6's warning: who is using the source's streams, before a play that
/// would go over its limit.
struct StreamLimitPrompt: Identifiable {
    struct Watcher: Identifiable, Hashable {
        var id: UUID
        var profileName: String
        var palette: AvatarPalette
        var deviceName: String
        var title: String
    }

    let id = UUID()
    let sceneID: UUID?
    let layout: HearthLayout
    let intent: PlayIntent
    let sourceName: String
    let limit: Int
    let watchers: [Watcher]
    /// Streams the provider counts that no household row explains.
    let outsideHousehold: Int
    /// The same channel on a source with a stream free.
    let alternative: CatalogChannel?
    fileprivate let prepared: PreparedPlay
    fileprivate let factory: PlayerItemFactory

    var inUse: Int { watchers.count + outsideHousehold }
}

/// Something the player couldn't open before it showed (the item is gone).
struct PlaybackNotice: Identifiable {
    let id = UUID()
    let sceneID: UUID?
    let title: String
    let message: String
}

/// Carries out every `PlayIntent` (Core's `@Environment(\.play)`): finds the
/// item, checks the source's stream limit (HH-6), opens the player, and
/// writes what the household store wants at the moments it wants it —
/// who's-watching at start, every 10 minutes and at stop (HH-5); progress
/// on pause, every 5 minutes, at the end and on going to the background —
/// never per second (technical spec, Sync and sharing rules).
///
/// One player at a time: a new play closes the one before (its stream is
/// then not counted against the new one's limit). On iOS the window that
/// asked shows it full screen; on the Mac it opens in a window of its own
/// that can go full screen (⌘F in the player, ⌃⌘F from the View menu).
@MainActor
@Observable
final class PlaybackCoordinator {
    private(set) var current: PlayerSession?
    var limitPrompt: StreamLimitPrompt?
    var notice: PlaybackNotice?
    /// The window that asked for multi-view from the player.
    var multiViewSceneID: UUID?

    /// The window most recently used, for plays a launch argument starts.
    @ObservationIgnored var lastSceneID: UUID?

    private let catalog: CatalogService
    private let store: HouseholdStore
    private let session: ProfileSession
    @ObservationIgnored private let logger = Logger(subsystem: "com.bhavikjain.hearth", category: "playback")

    /// Who's-watching rows are refreshed every 10 minutes (HH-5).
    static let heartbeatInterval: Duration = .seconds(10 * 60)
    /// A Stalker session is kept alive every 5 minutes while playing.
    static let keepAliveInterval: Duration = .seconds(5 * 60)

    init(catalog: CatalogService, store: HouseholdStore, session: ProfileSession) {
        self.catalog = catalog
        self.store = store
        self.session = session
    }

    /// Whether something addressed to `target` belongs to this window: its
    /// own, or — when a launch argument started it with no window — the
    /// window used last.
    func targets(_ target: UUID?, scene sceneID: UUID) -> Bool {
        target == sceneID || (target == nil && lastSceneID == sceneID)
    }

    /// The player this window presents, if any: full screen on iOS and the
    /// TV, over the whole window on the Mac.
    func presentedSession(forScene sceneID: UUID) -> PlayerSession? {
        guard let current, targets(current.sceneID, scene: sceneID) else { return nil }
        return current
    }

    // MARK: Playing

    func play(_ intent: PlayIntent, sceneID: UUID?, layout: HearthLayout) {
        if let sceneID { lastSceneID = sceneID }
        // The gate is up: nothing plays without a profile.
        guard let profile = session.currentProfile else { return }
        Task { await begin(intent, profile: profile, sceneID: sceneID ?? lastSceneID, layout: layout, checkingLimit: true) }
    }

    private func begin(_ intent: PlayIntent, profile: ProfileRecord, sceneID: UUID?, layout: HearthLayout, checkingLimit: Bool) async {
        let factory = PlayerItemFactory(catalog: catalog, store: store, profileID: profile.id)
        guard let prepared = factory.prepare(intent) else {
            notice = PlaybackNotice(
                sceneID: sceneID,
                title: String(localized: "Can't play this"),
                message: String(localized: "\(intent.title) isn't available right now. Its source may have removed it, or it's hidden on this profile.")
            )
            return
        }
        if checkingLimit, let prompt = await limitPrompt(for: prepared, factory: factory, intent: intent, sceneID: sceneID, layout: layout) {
            limitPrompt = prompt
            return
        }
        present(prepared, factory: factory, profile: profile, sceneID: sceneID, layout: layout)
    }

    // MARK: Stream limits (HH-6)

    private struct LimitCheck {
        var verdict: StreamLimitRule.Verdict
        var usage: StreamUsage
    }

    /// The source's limit and use. Xtream reports its own (asked now, before
    /// each play); Stalker and M3U use the owner's setting, 0 meaning none.
    private func checkLimit(sourceID: UUID) async -> LimitCheck? {
        guard let record = store.sources.first(where: { $0.id == sourceID }) else { return nil }
        let kind = SourceKind(rawValue: record.kindRaw)
        var providerMax: Int?
        var providerActive: Int?
        if kind == .xtream {
            let account = await catalog.refreshAccount(sourceID: sourceID) ?? catalog.account(sourceID: sourceID)
            providerMax = account?.maxConnections
            providerActive = account?.activeConnections
        }
        let limit = StreamLimitRule.effectiveLimit(kind: kind, ownerSetting: record.maxStreams, providerMax: providerMax)
        // This device's own stream is about to stop, so it doesn't count.
        let replacing = current?.playbackID
        let usage = store.streamUsage(sourceID: sourceID, limit: limit, excludingPlaybackID: replacing)
        let ownOnSource = (replacing != nil && current?.playing?.sourceID == sourceID) ? 1 : 0
        let verdict = StreamLimitRule.evaluate(
            limit: limit,
            householdInUse: usage.inUse.count,
            providerActive: providerActive,
            ownStreamsOnSource: ownOnSource
        )
        return LimitCheck(verdict: verdict, usage: usage)
    }

    private func limitPrompt(for prepared: PreparedPlay, factory: PlayerItemFactory, intent: PlayIntent, sceneID: UUID?, layout: HearthLayout) async -> StreamLimitPrompt? {
        let sourceID = prepared.context.sourceID
        guard let check = await checkLimit(sourceID: sourceID),
              case .atLimit(let limit, let outside) = check.verdict else { return nil }
        let profiles = Dictionary(store.profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let watchers = check.usage.inUse.map { record in
            StreamLimitPrompt.Watcher(
                id: record.id,
                profileName: profiles[record.profileID]?.name ?? String(localized: "Someone"),
                palette: profiles[record.profileID]?.avatarColor ?? .slate,
                deviceName: record.deviceName,
                title: record.title
            )
        }
        return StreamLimitPrompt(
            sceneID: sceneID,
            layout: layout,
            intent: intent,
            sourceName: store.sources.first { $0.id == sourceID }?.name ?? String(localized: "This source"),
            limit: limit,
            watchers: watchers,
            outsideHousehold: outside,
            alternative: await freeAlternative(to: prepared.context.channel),
            prepared: prepared,
            factory: factory
        )
    }

    /// The same channel on another source that has a stream free: the first
    /// of up to three, in the household's source order.
    private func freeAlternative(to channel: CatalogChannel?) async -> CatalogChannel? {
        for candidate in alternatives(to: channel).prefix(3) {
            guard let check = await checkLimit(sourceID: candidate.sourceID) else { continue }
            if check.verdict == .allowed { return candidate }
        }
        return nil
    }

    private func alternatives(to channel: CatalogChannel?) -> [CatalogChannel] {
        guard let channel else { return [] }
        return AlternativeChannels.candidates(
            for: channel,
            among: catalog.findChannels(channel.name),
            sourceOrder: store.sources.map(\.id)
        )
    }

    /// The person's answer to the warning.
    enum LimitDecision {
        case watchAnyway
        case useAlternative
        case cancel
    }

    func resolveLimitPrompt(_ decision: LimitDecision) {
        guard let prompt = limitPrompt else { return }
        limitPrompt = nil
        switch decision {
        case .cancel:
            break
        case .watchAnyway:
            guard let profile = session.currentProfile else { return }
            present(prompt.prepared, factory: prompt.factory, profile: profile, sceneID: prompt.sceneID, layout: prompt.layout)
        case .useAlternative:
            guard let channel = prompt.alternative else { return }
            play(Self.liveIntent(for: channel, queue: []), sceneID: prompt.sceneID, layout: prompt.layout)
        }
    }

    static func liveIntent(for channel: CatalogChannel, queue: [String]) -> PlayIntent {
        PlayIntent(itemKey: channel.key.rawValue, kind: .live, title: channel.name, artworkURL: channel.logoURL, queue: queue)
    }

    // MARK: The player

    private func present(_ prepared: PreparedPlay, factory: PlayerItemFactory, profile: ProfileRecord, sceneID: UUID?, layout: HearthLayout) {
        closeCurrent()
        let model = PlayerModel(item: prepared.item, navigator: { [weak factory] current, offset in
            factory?.neighbour(of: current, offset: offset)
        })
        // PLY-6: the profile's audio and subtitle languages.
        model.setPreferredLanguages(audio: profile.audioLanguage, subtitle: profile.subtitleLanguage)
        let playerSession = PlayerSession(sceneID: sceneID, layout: layout, profile: profile, model: model, items: factory)
        model.onEvent = { [weak self, weak playerSession] event in
            guard let self, let playerSession else { return }
            self.handle(event, in: playerSession)
        }
        model.onClose = { [weak self, weak playerSession] in
            guard let self, let playerSession else { return }
            self.closed(playerSession)
        }
        if layout == .sidebar {
            model.onShowMultiView = { [weak self, weak playerSession] in
                guard let self else { return }
                let scene = playerSession?.sceneID ?? self.lastSceneID
                self.closeCurrent()
                self.multiViewSceneID = scene
            }
        }
        current = playerSession
        updateTryAnotherSource(playerSession, itemID: prepared.item.id)

        if prepared.startsFromBeginning {
            // Opens live, then at once the programme from its start: the
            // second open overtakes the first before it resolves.
            Task { await model.start() }
            Task { await model.playFromStart() }
        }
    }

    /// PLY-4's last step: after the retry failed too, the same channel on
    /// another source, when the household has one. Re-read on every channel
    /// change, since the channel is what decides it.
    private func updateTryAnotherSource(_ playerSession: PlayerSession, itemID: String) {
        let context = playerSession.items.context(for: itemID)
        guard let channel = context?.channel, let alternative = alternatives(to: channel).first else {
            playerSession.model.onTryAnotherSource = nil
            return
        }
        let sceneID = playerSession.sceneID
        let layout = playerSession.layout
        playerSession.model.onTryAnotherSource = { [weak self] in
            self?.play(Self.liveIntent(for: alternative, queue: []), sceneID: sceneID, layout: layout)
        }
    }

    /// Closes the player, which records its stop.
    func closeCurrent() {
        current?.model.close()
    }

    /// The app is going to the background: progress now (PLY-3 keeps the
    /// sound going; this keeps the resume point honest).
    func saveProgressNow() {
        current?.model.checkpointNow()
    }

    private func closed(_ playerSession: PlayerSession) {
        endPlayback(playerSession)
        if current === playerSession {
            current = nil
        }
    }

    // MARK: Recording

    private func handle(_ event: PlayerEvent, in playerSession: PlayerSession) {
        switch event {
        case .started(let itemID):
            guard let context = playerSession.items.context(for: itemID) else { return }
            if playerSession.playbackID != nil { endPlayback(playerSession) }
            playerSession.playing = context
            // Guests write a row too: they still use one of the streams.
            playerSession.playbackID = store.startPlayback(
                profileID: playerSession.profileID,
                sourceID: context.sourceID,
                itemKey: context.itemKey.rawValue,
                title: context.recordTitle,
                deviceName: DeviceName.current
            )
            startTimers(playerSession, sourceID: context.sourceID)

        case .paused(let itemID, let position, let duration),
             .checkpoint(let itemID, let position, let duration):
            saveProgress(playerSession, itemID: itemID, position: position, duration: duration)

        case .finished(let itemID, let duration):
            let total = duration ?? playerSession.items.context(for: itemID)?.durationHint
            if let total { saveProgress(playerSession, itemID: itemID, position: total, duration: total) }

        case .stopped(let itemID, let position, let duration):
            saveProgress(playerSession, itemID: itemID, position: position, duration: duration)
            endPlayback(playerSession)

        case .failed(_, let message):
            logger.notice("Playback failed: \(message, privacy: .private)")

        case .switched(_, let toItemID):
            // Sent before the model's item changes, so the new id comes from the event.
            updateTryAnotherSource(playerSession, itemID: toItemID)
        }
    }

    private func saveProgress(_ playerSession: PlayerSession, itemID: String, position: TimeInterval, duration: TimeInterval?) {
        guard !playerSession.isGuest,
              let context = playerSession.items.context(for: itemID),
              let kind = context.progressKind else { return }
        let total = duration ?? context.durationHint ?? 0
        guard total > 0, position.isFinite, position >= 0 else { return }
        let episode = context.itemKey.seasonAndEpisode
        store.saveProgress(
            profileID: playerSession.profileID,
            itemKey: context.progressKey,
            kind: kind,
            position: min(position, total),
            duration: total,
            seriesKey: context.itemKey.seriesKey?.rawValue,
            season: episode?.season,
            episode: episode?.number
        )
    }

    private func startTimers(_ playerSession: PlayerSession, sourceID: UUID) {
        playerSession.heartbeat?.cancel()
        playerSession.keepAlive?.cancel()
        playerSession.heartbeat = Task { [weak self, weak playerSession] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled, let self, let id = playerSession?.playbackID else { return }
                self.store.heartbeat(playbackID: id)
            }
        }
        playerSession.keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.keepAliveInterval)
                guard !Task.isCancelled, let self else { return }
                await self.catalog.keepAlive(sourceID: sourceID)
            }
        }
    }

    private func endPlayback(_ playerSession: PlayerSession) {
        playerSession.heartbeat?.cancel()
        playerSession.keepAlive?.cancel()
        playerSession.heartbeat = nil
        playerSession.keepAlive = nil
        if let id = playerSession.playbackID {
            store.stopPlayback(playbackID: id)
        }
        playerSession.playbackID = nil
        playerSession.playing = nil
    }
}
