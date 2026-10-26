import CatalogKit
import Core
import Foundation
import HouseholdKit
import PlayerKit
import SourceKit

/// What the coordinator records for one item the player can show: where its
/// progress goes, which source's stream it uses, and how who's-watching
/// names it.
struct PlayableContext {
    var itemKey: ItemKey
    var sourceID: UUID
    /// The key progress is saved under: the item key, or for an aired
    /// programme the play intent's id (channel key + "@" + start), so each
    /// programme keeps its own row.
    var progressKey: String
    /// Nil for live: nothing to resume.
    var progressKind: HouseholdProgressKind?
    /// Who's watching: "Fieldhouse Sports", "The Lighthouse Keeper".
    var recordTitle: String
    /// For progress when the engine doesn't know the length yet.
    var durationHint: TimeInterval?
    /// The channel, for "Use another source" and "Try another source".
    var channel: CatalogChannel?
}

/// A play ready to open.
struct PreparedPlay {
    var item: PlayerItem
    var context: PlayableContext
    /// "From the start" on a programme still on air: open live, then replay
    /// the programme from its start, so Jump to live still works.
    var startsFromBeginning: Bool
}

/// Builds PlayerKit items from catalog items for one player: the first one
/// from the play intent, then channel up/down and next episode through the
/// queue the intent carried. Every item's resolver asks the catalog for a
/// fresh link, because provider links expire and Stalker's are single-use.
@MainActor
final class PlayerItemFactory {
    private let catalog: CatalogService
    private let store: HouseholdStore
    private let profileID: UUID
    private var contexts: [String: PlayableContext] = [:]
    private var queue: PlaybackQueue?
    private var navigation: PlayIntent.Kind = .live

    init(catalog: CatalogService, store: HouseholdStore, profileID: UUID) {
        self.catalog = catalog
        self.store = store
        self.profileID = profileID
    }

    func context(for itemID: String) -> PlayableContext? {
        contexts[itemID]
    }

    // MARK: The first item

    /// Nil when the item isn't in the catalog for this profile (removed,
    /// hidden by its rules, or the source is gone).
    func prepare(_ intent: PlayIntent) -> PreparedPlay? {
        let key = ItemKey(rawValue: intent.itemKey)
        navigation = intent.kind
        switch intent.kind {
        case .live:
            guard let channel = catalog.channel(key) else { return nil }
            queue = liveQueue(for: channel, intent: intent)
            return register(liveItem(channel), startsFromBeginning: false)

        case .catchup:
            guard let channel = catalog.channel(key), let start = intent.catchupStart else { return nil }
            let end = intent.catchupEnd ?? start.addingTimeInterval(3600)
            if end > .now {
                // Still on air: the live channel, replayed from the start.
                queue = liveQueue(for: channel, intent: intent)
                let programme = (start: start, end: end, title: intent.title)
                return register(liveItem(channel, programme: programme), startsFromBeginning: true)
            }
            queue = nil
            return register(catchupItem(channel, start: start, end: end, intent: intent), startsFromBeginning: false)

        case .movie:
            guard let movie = catalog.movie(key) else { return nil }
            queue = nil
            return register(movieItem(movie, intent: intent), startsFromBeginning: false)

        case .episode:
            let episode = catalog.episode(key)
            let series = key.seriesKey.flatMap(catalog.seriesItem)
            // Episodes load lazily; the series being visible is enough.
            guard key.sourceID != nil, episode != nil || series != nil else { return nil }
            queue = episodeQueue(for: key, intent: intent)
            return register(episodeItem(key, episode: episode, series: series, intent: intent), startsFromBeginning: false)
        }
    }

    private func register(_ built: (PlayerItem, PlayableContext), startsFromBeginning: Bool) -> PreparedPlay {
        contexts[built.0.id] = built.1
        return PreparedPlay(item: built.0, context: built.1, startsFromBeginning: startsFromBeginning)
    }

    // MARK: Moving through the queue (LIV-5, SER-2)

    /// PlayerKit's navigator: channel up/down for live, next and previous
    /// episode for shows; nothing for movies and aired programmes.
    func neighbour(of current: PlayerItem, offset: Int) -> PlayerItem? {
        guard let context = contexts[current.id], let queue,
              let nextRaw = queue.key(from: context.itemKey.rawValue, offset: offset) else { return nil }
        let nextKey = ItemKey(rawValue: nextRaw)
        let built: (PlayerItem, PlayableContext)
        switch navigation {
        case .live, .catchup:
            guard let channel = catalog.channel(nextKey) else { return nil }
            built = liveItem(channel)
        case .episode:
            let episode = catalog.episode(nextKey)
            let series = nextKey.seriesKey.flatMap(catalog.seriesItem)
            guard episode != nil else { return nil }
            built = episodeItem(nextKey, episode: episode, series: series, intent: nil)
        case .movie:
            return nil
        }
        contexts[built.0.id] = built.1
        return built.0
    }

    private func liveQueue(for channel: CatalogChannel, intent: PlayIntent) -> PlaybackQueue? {
        if !intent.queue.isEmpty {
            return PlaybackQueue(current: channel.key.rawValue, queue: intent.queue)
        }
        // No queue given: the channel's own category, in guide order.
        guard let categoryID = channel.categoryID else { return nil }
        let keys = catalog.channels(categoryID: categoryID).map(\.key.rawValue)
        return PlaybackQueue(current: channel.key.rawValue, queue: keys)
    }

    private func episodeQueue(for key: ItemKey, intent: PlayIntent) -> PlaybackQueue? {
        if !intent.queue.isEmpty {
            return PlaybackQueue(current: key.rawValue, queue: intent.queue)
        }
        guard let seriesKey = key.seriesKey else { return nil }
        let following = EpisodeOrder.following(key, in: catalog.cachedEpisodes(seriesKey: seriesKey))
        return PlaybackQueue(current: key.rawValue, queue: following.map(\.rawValue))
    }

    // MARK: Items

    private func liveItem(_ channel: CatalogChannel, programme programmeOverride: (start: Date, end: Date, title: String)? = nil) -> (PlayerItem, PlayableContext) {
        let now = catalog.nowAndNext(for: channel).now
        let start = programmeOverride?.start ?? now?.start
        let end = programmeOverride?.end ?? now?.end
        let title = programmeOverride?.title ?? now?.title ?? channel.name
        let catalog = catalog
        let key = channel.key
        let item = PlayerItem(
            id: key.rawValue,
            title: title,
            subtitle: PlaybackText.liveSubtitle(channel: channel, programme: now),
            channelNumber: channel.number,
            channelName: channel.name,
            logoURL: channel.logoURL,
            isLive: true,
            programmeStart: start,
            programmeEnd: end,
            hasArchive: channel.hasArchive,
            resolve: { request in
                let link: StreamLink
                switch request {
                case .standard:
                    link = try await catalog.streamLink(for: key)
                case .fromStart(let start, let duration):
                    link = try await catalog.streamLink(for: key, catchupStart: start, catchupDuration: duration)
                }
                return StreamMapping.descriptor(from: link)
            }
        )
        let context = PlayableContext(
            itemKey: key,
            sourceID: channel.sourceID,
            progressKey: key.rawValue,
            progressKind: nil,
            recordTitle: channel.name,
            durationHint: nil,
            channel: channel
        )
        return (item, context)
    }

    /// An aired programme from the archive (LIV-4): played like a recording,
    /// with its own progress row.
    private func catchupItem(_ channel: CatalogChannel, start: Date, end: Date, intent: PlayIntent) -> (PlayerItem, PlayableContext) {
        let catalog = catalog
        let key = channel.key
        let duration = max(60, end.timeIntervalSince(start))
        let saved = store.progress(profileID: profileID, itemKey: intent.id)
        let item = PlayerItem(
            id: intent.id,
            title: intent.title,
            subtitle: intent.subtitle ?? "\(ChannelText.numberedName(number: channel.number, name: channel.name)) · \(HearthFormat.timeRange(start, end))",
            channelNumber: channel.number,
            channelName: channel.name,
            logoURL: channel.logoURL,
            artworkURL: intent.artworkURL,
            isLive: false,
            hasArchive: channel.hasArchive,
            startPosition: ResumePoint.position(requested: intent.startPosition, saved: saved),
            resolve: { _ in
                let link = try await catalog.streamLink(for: key, catchupStart: start, catchupDuration: duration)
                return StreamMapping.descriptor(from: link)
            }
        )
        let context = PlayableContext(
            itemKey: key,
            sourceID: channel.sourceID,
            progressKey: intent.id,
            progressKind: .catchup,
            recordTitle: intent.title,
            durationHint: duration,
            channel: channel
        )
        return (item, context)
    }

    private func movieItem(_ movie: CatalogMovie, intent: PlayIntent) -> (PlayerItem, PlayableContext) {
        let catalog = catalog
        let key = movie.key
        let saved = store.progress(profileID: profileID, itemKey: key.rawValue)
        let details = [movie.year.map(String.init), movie.genre].compactMap { $0 }.joined(separator: " · ")
        let item = PlayerItem(
            id: key.rawValue,
            title: intent.title.isEmpty ? movie.name : intent.title,
            subtitle: intent.subtitle ?? (details.isEmpty ? nil : details),
            artworkURL: intent.artworkURL ?? movie.posterURL,
            isLive: false,
            startPosition: ResumePoint.position(requested: intent.startPosition, saved: saved),
            resolve: { _ in
                StreamMapping.descriptor(from: try await catalog.streamLink(for: key))
            }
        )
        let context = PlayableContext(
            itemKey: key,
            sourceID: movie.sourceID,
            progressKey: key.rawValue,
            progressKind: .movie,
            recordTitle: movie.name,
            durationHint: movie.duration,
            channel: nil
        )
        return (item, context)
    }

    private func episodeItem(_ key: ItemKey, episode: CatalogEpisode?, series: CatalogSeries?, intent: PlayIntent?) -> (PlayerItem, PlayableContext) {
        let catalog = catalog
        let saved = store.progress(profileID: profileID, itemKey: key.rawValue)
        let code = key.seasonAndEpisode
        let episodeLine = code.map { PlaybackText.episodeSubtitle(season: $0.season, number: $0.number, title: episode?.title ?? "") }
        let title = intent?.title ?? series?.name ?? episode?.title ?? ""
        let item = PlayerItem(
            id: key.rawValue,
            title: title,
            subtitle: intent?.subtitle ?? episodeLine,
            artworkURL: intent?.artworkURL ?? episode?.posterURL ?? series?.posterURL,
            isLive: false,
            startPosition: ResumePoint.position(requested: intent?.startPosition, saved: saved),
            resolve: { _ in
                StreamMapping.descriptor(from: try await catalog.streamLink(for: key))
            }
        )
        let recordTitle = [series?.name, code.map { HearthFormat.episodeCode(season: $0.season, episode: $0.number) }]
            .compactMap { $0 }
            .joined(separator: " · ")
        let context = PlayableContext(
            itemKey: key,
            sourceID: key.sourceID ?? episode?.sourceID ?? UUID(),
            progressKey: key.rawValue,
            progressKind: .episode,
            recordTitle: recordTitle.isEmpty ? title : recordTitle,
            durationHint: episode?.duration,
            channel: nil
        )
        return (item, context)
    }
}
