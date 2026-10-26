import CatalogKit
import Core
import Foundation
import HouseholdKit
import PlayerKit
import SourceKit

// The app shell's decisions, as small value types with no SwiftUI and no
// services, so each can be tested on its own when tests resume: how a
// household source becomes a SourceKit configuration, what the current
// profile may see, what a new household is called, which keys a refresh
// orphaned, whether a source is at its stream limit, and which item comes
// next in the player.

// MARK: - Sources

/// HouseholdKit never imports SourceKit (it stores the kind as a string), so
/// the app maps each household source to the configuration CatalogKit reads.
enum SourceMapping {
    /// The household's sources as SourceKit configurations, in the
    /// household's order. A source of a kind this build doesn't know (written
    /// by a newer build on another device) is left out rather than guessed.
    static func configurations(from records: [SourceRecord]) -> [SourceConfiguration] {
        records.filter { !$0.isRemoved }.compactMap(configuration(from:))
    }

    static func configuration(from record: SourceRecord) -> SourceConfiguration? {
        guard let kind = SourceKind(rawValue: record.kindRaw) else { return nil }
        let login = record.credentials
        return SourceConfiguration(
            id: record.id,
            name: record.name,
            kind: kind,
            serverURL: record.serverURL,
            macAddress: login.macAddress,
            username: login.username,
            password: login.password,
            playlistURL: login.playlistURL,
            guideURL: login.guideURL,
            serialNumber: login.serialNumber,
            deviceID: login.deviceID,
            deviceID2: login.deviceID2,
            signature: login.signature,
            model: login.model,
            timeZone: login.timeZone
        )
    }
}

// MARK: - What the profile sees

/// The catalog filter for the current profile and household (PRF-4, PRF-6,
/// LIV-8, PAR-1, SRCH-3).
enum CatalogFilterBuilder {
    /// - A Kids profile sees only its allowed categories, and never adult ones.
    /// - Every profile's hidden categories and chosen sources apply.
    /// - Adult categories hide everywhere when the household says so.
    /// - With no profile chosen (the gate is up) the default filter applies,
    ///   which hides adult categories.
    static func filter(profile: ProfileRecord?, household: HouseholdInfo) -> CatalogFilter {
        guard let profile else {
            return CatalogFilter(hidesAdult: true, adultCategoryIDs: household.adultCategoryKeys)
        }
        return CatalogFilter(
            visibleSourceIDs: profile.visibleSourceIDs.isEmpty ? nil : profile.visibleSourceIDs,
            allowedCategoryIDs: profile.isKids ? profile.allowedCategoryKeys : nil,
            hiddenCategoryIDs: profile.hiddenCategoryKeys,
            hidesAdult: household.hidesAdultEverywhere || profile.isKids,
            adultCategoryIDs: household.adultCategoryKeys
        )
    }
}

// MARK: - A new household's names

/// What the first household and its first profile are called (HH-1):
/// "<surname> Household" and the given name, from the device owner's name
/// where the platform tells us one, else neutral defaults. iOS stopped
/// sharing the owner's name (the device is just "iPhone"), so on iOS this
/// is usually the fallback; the Mac knows the account's full name.
enum HouseholdNaming {
    struct Names: Equatable {
        var household: String
        var profile: String
    }

    /// Account names that are not a person's.
    private static let notAPerson: Set<String> = ["mobile", "root", "admin", "administrator", "user", "guest", "owner"]

    static func names(fullName: String?) -> Names {
        let fallback = Names(
            household: String(localized: "My Household", comment: "The name of a new household when the owner's name is unknown"),
            profile: String(localized: "Me", comment: "The first profile's name when the owner's name is unknown")
        )
        guard let raw = fullName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              !notAPerson.contains(raw.lowercased()) else { return fallback }
        let components = PersonNameComponentsFormatter().personNameComponents(from: raw)
        let given = components?.givenName?.trimmingCharacters(in: .whitespaces)
        let family = components?.familyName?.trimmingCharacters(in: .whitespaces)
        let profile = (given?.isEmpty == false ? given : nil) ?? raw
        guard let family, !family.isEmpty else {
            return Names(household: fallback.household, profile: profile)
        }
        return Names(
            household: String(localized: "\(family) Household", comment: "A new household's name: the owner's surname, then Household"),
            profile: profile
        )
    }
}

// MARK: - Keys a refresh renamed (FAV-2)

/// The favorite and progress keys to check after a refresh: those of the
/// refreshed sources that point at a channel, movie or show. Episode keys
/// are left out (episodes load lazily, so "not in the catalog" means nothing
/// for them), as are catch-up keys, which carry a programme start after the
/// channel key and are never in the catalog by design.
enum KeyRewriteCandidates {
    static func keys(_ rawKeys: some Sequence<String>, refreshedSources: Set<UUID>) -> [ItemKey] {
        var seen: Set<String> = []
        var result: [ItemKey] = []
        for raw in rawKeys where !raw.contains("@") && seen.insert(raw).inserted {
            let key = ItemKey(rawValue: raw)
            guard let source = key.sourceID, refreshedSources.contains(source) else { continue }
            switch key.kind {
            case .channel?, .movie?, .series?: result.append(key)
            case .episode?, nil: continue
            }
        }
        return result
    }

    /// Sources whose catalog finished a refresh since `previous`.
    static func refreshedSources(previous: [UUID: Date], current: [UUID: Date]) -> Set<UUID> {
        Set(current.compactMap { id, date in
            guard let before = previous[id] else { return previous.isEmpty ? nil : id }
            return date > before ? id : nil
        })
    }
}

// MARK: - Stream limits (HH-6)

/// Whether a play would go over a source's stream limit.
enum StreamLimitRule {
    enum Verdict: Equatable {
        case allowed
        /// At or over the limit. `outsideHousehold` is how many streams the
        /// provider counts beyond the household's own who's-watching rows
        /// (Xtream reports its count; someone outside the household, or a
        /// device whose row hasn't synced yet).
        case atLimit(limit: Int, outsideHousehold: Int)
    }

    /// The limit as the source states it: the owner's setting for Stalker and
    /// M3U, the provider's for Xtream. Zero and nil both mean unlimited.
    static func effectiveLimit(kind: SourceKind?, ownerSetting: Int, providerMax: Int?) -> Int? {
        let value = kind == .xtream ? (providerMax ?? 0) : ownerSetting
        return value > 0 ? value : nil
    }

    /// - Parameters:
    ///   - householdInUse: The household's streams on the source, not
    ///     counting the stream this play would replace.
    ///   - providerActive: The provider's own count (Xtream `active_cons`).
    ///   - ownStreamsOnSource: Streams of this device's player the provider
    ///     still counts and the play will stop (0 or 1).
    static func evaluate(limit: Int?, householdInUse: Int, providerActive: Int?, ownStreamsOnSource: Int) -> Verdict {
        guard let limit, limit > 0 else { return .allowed }
        let providerOthers = providerActive.map { max($0 - ownStreamsOnSource, 0) } ?? 0
        let used = max(householdInUse, providerOthers)
        guard used >= limit else { return .allowed }
        return .atLimit(limit: limit, outsideHousehold: max(providerOthers - householdInUse, 0))
    }
}

/// Picks the same channel on another source for "Use another source"
/// (HH-6) and the player's last-resort "Try another source" (PLY-4): the
/// channels whose normalised name matches, on other sources, in the
/// household's source order.
enum AlternativeChannels {
    static func candidates(for channel: CatalogChannel, among matches: [CatalogChannel], sourceOrder: [UUID]) -> [CatalogChannel] {
        let name = SearchKey.normalize(channel.name)
        guard !name.isEmpty else { return [] }
        let rank = Dictionary(sourceOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var seenSources: Set<UUID> = []
        return matches
            .filter { $0.sourceID != channel.sourceID && SearchKey.normalize($0.name) == name }
            .sorted { (rank[$0.sourceID] ?? .max, $0.sourceName) < (rank[$1.sourceID] ?? .max, $1.sourceName) }
            .filter { seenSources.insert($0.sourceID).inserted }
    }
}

// MARK: - The player's queue

/// Channel up and down, and next episode: where a key sits in the queue a
/// play carried, and which key is `offset` away. The queue may or may not
/// include the item that was played; when it doesn't, that item comes first.
struct PlaybackQueue: Equatable {
    private(set) var keys: [String]

    init(current: String, queue: [String]) {
        var seen: Set<String> = []
        let unique = queue.filter { seen.insert($0).inserted }
        keys = unique.contains(current) ? unique : [current] + unique
    }

    /// The key `offset` places from `key`, or nil past either end (channel
    /// up and down stop at the ends rather than wrapping, as the pills show).
    func key(from key: String, offset: Int) -> String? {
        guard let index = keys.firstIndex(of: key) else { return nil }
        let target = index + offset
        return keys.indices.contains(target) ? keys[target] : nil
    }
}

/// The episodes after one, in season and number order, for up next when a
/// play brought no queue (SER-2).
enum EpisodeOrder {
    static func following(_ key: ItemKey, in episodes: [CatalogEpisode]) -> [ItemKey] {
        let ordered = episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        guard let index = ordered.firstIndex(where: { $0.key == key }) else { return [] }
        return ordered[(index + 1)...].map(\.key)
    }
}

/// Where a movie or episode starts: the play's own position, else the
/// profile's saved one unless it was finished or barely begun.
enum ResumePoint {
    static func position(requested: TimeInterval?, saved: ProgressRecord?) -> TimeInterval? {
        if let requested { return requested > 0 ? requested : nil }
        guard let saved, !saved.watched, saved.position > 10, saved.remaining > 30 else { return nil }
        return saved.position
    }
}

/// SourceKit's link as PlayerKit's descriptor: the two format enums share
/// their cases (and raw values) so neither kit imports the other.
enum StreamMapping {
    static func descriptor(from link: StreamLink, startPosition: TimeInterval? = nil) -> StreamDescriptor {
        StreamDescriptor(
            url: link.url,
            headers: link.headers,
            format: StreamFormat(rawValue: link.formatHint.rawValue) ?? .unknown,
            isLive: link.isLive,
            startPosition: startPosition
        )
    }
}

// MARK: - Text

enum PlaybackText {
    /// "102 Fieldhouse Sports · 19:30–22:30", the player's subtitle for a channel.
    static func liveSubtitle(channel: CatalogChannel, programme: CatalogProgramme?) -> String {
        let name = ChannelText.numberedName(number: channel.number, name: channel.name)
        guard let programme else { return name }
        return "\(name) · \(HearthFormat.timeRange(programme.start, programme.end))"
    }

    /// "S2 · E5 — The Lighthouse Keeper".
    static func episodeSubtitle(season: Int, number: Int, title: String) -> String {
        let code = String(localized: "S\(season) · E\(number)", comment: "Season and episode, as in S2 · E5")
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? code : "\(code) — \(trimmed)"
    }
}
