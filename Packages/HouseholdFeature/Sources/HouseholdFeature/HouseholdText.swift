import CatalogKit
import Core
import Foundation
import HouseholdKit
import SourceKit

// Every line of text the Household screens compute, in value types so the
// rules (what a watcher may see, when "Expired" beats "Updated") can be
// tested without a view. Views only lay them out.

/// A source's row on Household (SRC-5, SRC-8).
struct SourceRowText: Hashable {
    /// "MAC", "XC", "M3U": the tile at the start of the row.
    var code: String
    var title: String
    /// "Portal · 00:1A:79:••:••:41", "Xtream login · 2 streams",
    /// "M3U + XMLTV guide". A watcher's says only what kind it is.
    var subtitle: String
    /// "Active\nuntil Mar 2027", "Expired", "Updated\n2 h ago",
    /// "Updating\n40%".
    var status: String
    /// The status needs attention (expired, disabled, a failed refresh).
    var isWarning: Bool
    var isRefreshing: Bool

    init(record: SourceRecord, state: SourceRefreshState?, canSeeLogins: Bool, now: Date = .now) {
        let kind = SourceMapping.kind(of: record)
        let account = state?.account
        code = Self.code(for: kind)
        title = record.name.isEmpty ? String(localized: "Untitled source") : record.name
        subtitle = Self.subtitle(record: record, kind: kind, account: account, canSeeLogins: canSeeLogins)
        (status, isWarning, isRefreshing) = Self.status(record: record, kind: kind, state: state, now: now)
    }

    static func code(for kind: SourceKind?) -> String {
        switch kind {
        case .stalker: "MAC"
        case .xtream: "XC"
        case .m3u: "M3U"
        case nil: "?"
        }
    }

    /// "Stalker portal", "Xtream Codes", "M3U playlist": the editor's picker.
    static func kindTitle(_ kind: SourceKind) -> String {
        switch kind {
        case .stalker: String(localized: "Stalker portal")
        case .xtream: String(localized: "Xtream Codes")
        case .m3u: String(localized: "M3U playlist")
        }
    }

    static func subtitle(record: SourceRecord, kind: SourceKind?, account: AccountInfo?, canSeeLogins: Bool) -> String {
        let login = record.credentials
        switch kind {
        case .stalker:
            let portal = String(localized: "Portal", comment: "A Stalker source, before its masked MAC address")
            guard canSeeLogins, !login.macAddress.isEmpty else { return portal }
            return "\(portal) · \(MACAddress.masked(login.macAddress))"
        case .xtream:
            let base = String(localized: "Xtream login")
            guard let max = account?.maxConnections, max > 0 else { return base }
            return "\(base) · \(max == 1 ? String(localized: "1 stream") : String(localized: "\(max) streams"))"
        case .m3u:
            let isFile = login.playlistURL.lowercased().hasPrefix("file:")
            let hasGuide = !login.guideURL.trimmingCharacters(in: .whitespaces).isEmpty
            switch (isFile, hasGuide) {
            case (false, true): return String(localized: "M3U + XMLTV guide")
            case (false, false): return String(localized: "M3U playlist")
            case (true, true): return String(localized: "M3U file + XMLTV guide")
            case (true, false): return String(localized: "M3U file on one device")
            }
        case nil:
            return String(localized: "Needs a newer version of the app")
        }
    }

    static func status(record: SourceRecord, kind: SourceKind?, state: SourceRefreshState?, now: Date) -> (text: String, isWarning: Bool, isRefreshing: Bool) {
        if case .refreshing(let progress, _) = state?.phase {
            let percent = progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "…"
            return (String(localized: "Updating\n\(percent)", comment: "A source's catalog is downloading; second line is a percentage"), false, true)
        }
        let account = state?.account
        if account?.status == .disabled {
            return (String(localized: "Disabled"), true, false)
        }
        let expiry = SourceExpiry.effective(record: record, account: account)
        if account?.status == .expired || (expiry.map { $0 < now } ?? false) {
            return (String(localized: "Expired"), true, false)
        }
        if case .failed = state?.phase {
            return (String(localized: "Couldn't\nupdate", comment: "Two lines: a source's last refresh failed"), true, false)
        }
        if let expiry, kind != .m3u {
            return (String(localized: "Active\nuntil \(HouseholdFormat.monthYear(expiry))", comment: "Two lines: a source is active until a month and year"), false, false)
        }
        if let refreshed = state?.catalogRefreshedAt {
            return (String(localized: "Updated\n\(HouseholdFormat.ago(refreshed, now: now))", comment: "Two lines: when a source's catalog was last downloaded"), false, false)
        }
        return (String(localized: "Not updated\nyet"), false, false)
    }
}

/// A saved source's status at the top of its editor (SRC-5, SRC-6): one
/// line each, unlike the Household row's two-line squeeze.
struct SourceStatusText: Hashable {
    /// "Active until 12 Mar 2027", "Expired on 3 Jan 2026", "Downloading
    /// channels · 40%", "Couldn't update".
    var headline: String
    var isWarning: Bool
    /// "412 channels · 3,120 movies · 210 shows" on this device.
    var detail: String?
    /// "Catalog updated 2 h ago · guide 20 min ago".
    var updated: String?
    /// The last refresh's failure, in the provider's words.
    var failure: String?
    var isRefreshing: Bool

    init(record: SourceRecord, state: SourceRefreshState?, now: Date = .now) {
        let account = state?.account
        let expiry = SourceExpiry.effective(record: record, account: account)
        isRefreshing = false
        isWarning = false
        failure = nil

        switch state?.phase {
        case .refreshing(let progress, let message):
            isRefreshing = true
            let base = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "Updating…") : message
            headline = progress.map { "\(base) · \(Int(($0 * 100).rounded()))%" } ?? base
        case .failed(let message):
            failure = message
            headline = String(localized: "Couldn't update")
            isWarning = true
        case .idle, nil:
            headline = String(localized: "Not downloaded on this device yet")
        }

        if !isRefreshing {
            if account?.status == .disabled {
                headline = String(localized: "The provider has disabled this login")
                isWarning = true
            } else if account?.status == .expired || (expiry.map { $0 < now } ?? false) {
                headline = expiry.map { String(localized: "Expired on \(HouseholdFormat.day($0))") } ?? String(localized: "Expired")
                isWarning = true
            } else if failure == nil {
                if let expiry {
                    headline = String(localized: "Active until \(HouseholdFormat.day(expiry))")
                } else if account?.status == .active || state?.catalogRefreshedAt != nil {
                    headline = String(localized: "Active")
                }
            }
        }

        if let state, state.catalogRefreshedAt != nil {
            detail = HouseholdFormat.counts(channels: state.channelCount, movies: state.movieCount, series: state.seriesCount)
        } else {
            detail = nil
        }
        var updatedParts: [String] = []
        if let catalogDate = state?.catalogRefreshedAt {
            updatedParts.append(String(localized: "Catalog updated \(HouseholdFormat.ago(catalogDate, now: now))"))
        }
        if let guideDate = state?.guideRefreshedAt {
            updatedParts.append(String(localized: "guide \(HouseholdFormat.ago(guideDate, now: now))", comment: "After 'Catalog updated 2 h ago · ': when the guide was last downloaded"))
        }
        updated = updatedParts.isEmpty ? nil : updatedParts.joined(separator: " · ")
    }
}

/// The line under a profile's name on Household: "PIN · All sources",
/// "Kids categories only · PIN to leave", "Keeps no history or favorites".
enum ProfileSummaryText {
    static func subtitle(for profile: ProfileRecord, sourceCount: Int) -> String {
        switch profile.kind {
        case .guest:
            return String(localized: "Keeps no history or favorites")
        case .kids:
            // Leaving a Kids profile always takes an adult's PIN (PRF-4).
            return String(localized: "Kids categories only · PIN to leave")
        case .standard:
            var parts: [String] = []
            if profile.hasPIN { parts.append(String(localized: "PIN", comment: "The profile is locked with a PIN")) }
            parts.append(sources(profile.visibleSourceIDs, of: sourceCount))
            return parts.joined(separator: " · ")
        }
    }

    /// "All sources", "1 source", "2 of 3 sources" (PRF-6).
    static func sources(_ visible: Set<UUID>, of count: Int) -> String {
        if visible.isEmpty || visible.count >= count { return String(localized: "All sources") }
        if visible.count == 1 { return String(localized: "1 source") }
        return String(localized: "\(visible.count) of \(count) sources")
    }
}

/// Members and roles (HH-2, SRC-8).
enum MemberText {
    static func role(_ role: MemberRole) -> String {
        switch role {
        case .owner: String(localized: "Owner")
        case .manage: String(localized: "Can manage")
        case .watch: String(localized: "Can watch")
        }
    }

    /// What a role allows, for the owner's role menu.
    static func roleExplanation(_ role: MemberRole) -> String {
        switch role {
        case .owner: String(localized: "Everything, including members")
        case .manage: String(localized: "Adds and edits sources and profiles")
        case .watch: String(localized: "Picks a profile and watches; never sees logins")
        }
    }

    /// "Bhavik (you)": not when HouseholdKit had no profile name to give the
    /// only member and called them "You" already.
    static func showsYouSuffix(_ member: MemberRecord) -> Bool {
        member.isCurrentUser && member.displayName != "You"
    }

    /// "Shared through iCloud · 3 people", "Only on your devices".
    static func householdLine(isShared: Bool, memberCount: Int) -> String {
        guard isShared else { return String(localized: "Only on your devices") }
        let people = memberCount == 1 ? String(localized: "1 person") : String(localized: "\(memberCount) people")
        return String(localized: "Shared through iCloud · \(people)", comment: "The household card's subtitle; the argument is '3 people'")
    }

    /// The colour of a member's circle: amber for this person, as in the
    /// mockup, then a stable pick from the rest by name so a member keeps
    /// their colour as others join.
    static func palette(for member: MemberRecord) -> AvatarPalette {
        if member.isCurrentUser { return .amber }
        let others: [AvatarPalette] = [.teal, .slate, .lavender, .coral, .green, .blue, .rose]
        return others[TilePalette.index(for: member.displayName) % others.count]
    }
}

/// Who is using a source's streams (HH-5): "Anya · Living Room iPad ·
/// Lantern Drama", one line per stream.
enum StreamCaption {
    static func lines(_ playbacks: [PlaybackRecord], profiles: [ProfileRecord]) -> String? {
        guard !playbacks.isEmpty else { return nil }
        let names = Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return playbacks
            .map { playback in
                [names[playback.profileID], playback.deviceName, playback.title]
                    .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
            }
            .joined(separator: "\n")
    }

    /// "This device and Anya's iPad": the Mac sidebar's foot, one entry per
    /// device. This device first, then the others in the order they started.
    ///
    /// A device named after its person ("Anya's iPad") is shown as it is;
    /// one with a plain name ("iPad", all iOS gives an app without the
    /// device-name entitlement) gets the profile watching: "Anya on iPad".
    /// This device is recognised by name: HouseholdKit keeps which rows are
    /// its own to itself.
    static func devices(_ playbacks: [PlaybackRecord], profiles: [ProfileRecord], thisDevice: String) -> String? {
        guard !playbacks.isEmpty else { return nil }
        let profileNames = Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var entries: [String] = []
        if playbacks.contains(where: { $0.deviceName == thisDevice }) {
            entries.append(String(localized: "This device"))
        }
        for playback in playbacks.sorted(by: { $0.startedAt < $1.startedAt }) where playback.deviceName != thisDevice {
            let entry = deviceEntry(device: playback.deviceName, profile: profileNames[playback.profileID])
            if !entries.contains(entry) { entries.append(entry) }
        }
        return entries.formatted(.list(type: .and))
    }

    static func deviceEntry(device: String, profile: String?) -> String {
        let device = device.trimmingCharacters(in: .whitespaces)
        guard let profile = profile?.trimmingCharacters(in: .whitespaces), !profile.isEmpty else {
            return device.isEmpty ? String(localized: "another device") : device
        }
        if device.isEmpty { return profile }
        if device.localizedCaseInsensitiveContains(profile) { return device }
        return String(localized: "\(profile) on \(device)", comment: "Who is streaming where: 'Anya on iPad'")
    }
}

/// iCloud as the Sync section words it.
enum SyncStatusText {
    static func text(_ status: HouseholdSyncStatus, now: Date = .now) -> (text: String, isWarning: Bool) {
        switch status {
        case .local: (String(localized: "On this device only"), false)
        case .syncing: (String(localized: "Syncing…"), false)
        case .upToDate(let date): (String(localized: "Up to date · \(HouseholdFormat.ago(date, now: now))"), false)
        case .failed(let message): (message, true)
        case .noAccount: (String(localized: "Not signed in to iCloud"), true)
        }
    }
}

/// Which expiry a source shows (SRC-5): the provider's latest word on this
/// device, else what a household device last recorded.
enum SourceExpiry {
    /// An active account with no end date has none, whatever was recorded
    /// before (the provider made it unlimited). An account read that said
    /// nothing useful (status unknown) keeps the recorded date.
    static func effective(record: SourceRecord, account: AccountInfo?) -> Date? {
        guard let account else { return record.expiresAt }
        if let date = account.expiresAt { return date }
        return account.status == .active ? nil : record.expiresAt
    }

    /// What to write to the household after an account read, or nil to
    /// leave the record alone: only a real change, since every write wakes
    /// every household device.
    static func update(record: SourceRecord, account: AccountInfo?) -> Date?? {
        guard let account else { return nil }
        let latest = effective(record: record, account: account)
        switch (record.expiresAt, latest) {
        case (nil, nil): return nil
        case (let stored?, let new?) where abs(stored.timeIntervalSince(new)) < 60: return nil
        default: return .some(latest)
        }
    }
}

enum HouseholdFormat {
    /// "Mar 2027".
    static func monthYear(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).year())
    }

    /// "12 Mar 2027".
    static func day(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    /// "just now", "12 min ago", "2 h ago", "3 d ago": as short as the
    /// Sources rows' second line needs.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return String(localized: "just now")
        case ..<3600: return String(localized: "\(Int(seconds / 60)) min ago")
        case ..<86_400: return String(localized: "\(Int(seconds / 3600)) h ago")
        default: return String(localized: "\(Int(seconds / 86_400)) d ago")
        }
    }

    /// "412 channels · 3,120 movies · 210 shows", leaving out what the
    /// provider doesn't offer.
    static func counts(channels: Int?, movies: Int?, series: Int?) -> String? {
        var parts: [String] = []
        if let channels, channels > 0 { parts.append(channels == 1 ? String(localized: "1 channel") : String(localized: "\(channels) channels")) }
        if let movies, movies > 0 { parts.append(movies == 1 ? String(localized: "1 movie") : String(localized: "\(movies) movies")) }
        if let series, series > 0 { parts.append(series == 1 ? String(localized: "1 show") : String(localized: "\(series) shows")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
