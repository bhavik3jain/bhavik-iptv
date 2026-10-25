import Core
import Foundation
import HouseholdKit

// The decisions behind the profile screens, kept in small value types so they
// can be tested without a view (views are untested by policy): which PINs a
// switch needs, what a tile's caption says, how the household card reads, and
// the source-visibility arithmetic of the editor.

// MARK: - PINs a switch needs (PRF-3, PRF-4)

/// One PIN to type before a switch goes ahead: a profile's own PIN, or any
/// adult's.
struct PINStep: Identifiable, Hashable {
    enum Purpose: Hashable {
        /// The profile being opened has a PIN (PRF-3).
        case profile
        /// An adult must agree: leaving a Kids profile (PRF-4), or changing
        /// profiles from the shared gate.
        case adult
    }

    var purpose: Purpose
    var title: String
    var message: String?
    /// The PIN of any of these profiles passes.
    var profileIDs: [UUID]
    /// The avatar drawn over the pad: the profile being opened. Nil for an
    /// adult's PIN, which shows a lock instead.
    var avatar: ProfileRecord?

    var id: String {
        "\(purpose)-" + profileIDs.map(\.uuidString).joined(separator: ",")
    }
}

/// Which PINs stand between this device and a profile.
///
/// Adults are standard profiles: a Guest is not an adult, and neither is a
/// Kids profile, so their PINs never let anyone out of a Kids profile.
enum PINSteps {
    /// Standard profiles that have a PIN: the people who can let someone out
    /// of a Kids profile or into the profile editor.
    static func adultsWithPIN(in profiles: [ProfileRecord]) -> [ProfileRecord] {
        profiles.filter { $0.kind == .standard && $0.hasPIN }
    }

    /// What must be typed to go from `current` to `target` (nil: back to
    /// "Who's watching?").
    ///
    /// - The target's own PIN when it has one (PRF-3), unless it is the
    ///   profile already open.
    /// - Leaving a Kids profile, an adult's PIN when any adult has one
    ///   (PRF-4). An adult opening their own locked profile proves both at
    ///   once, so that is a single step; otherwise the adult's PIN comes
    ///   first, then the target's.
    static func forSwitch(from current: ProfileRecord?, to target: ProfileRecord?, profiles: [ProfileRecord]) -> [PINStep] {
        let targetIsLocked = target.map { $0.hasPIN && $0.id != current?.id } ?? false
        var steps: [PINStep] = []

        if let current, current.isKids {
            let adults = adultsWithPIN(in: profiles).filter { $0.id != current.id }
            if !adults.isEmpty {
                if let target, targetIsLocked, target.kind == .standard {
                    return [profileStep(target)]
                }
                steps.append(adultStep(adults, message: String(
                    localized: "Leaving \(current.name) needs the PIN of \(names(adults)).",
                    bundle: .module,
                    comment: "Under the PIN pad when leaving a Kids profile. The second value is a list of adult profile names joined with 'or'."
                )))
            }
        }
        if let target, targetIsLocked {
            steps.append(profileStep(target))
        }
        return steps
    }

    /// What must be typed before profiles can be added or edited from the
    /// shared "Who's watching?" screen: an adult's PIN when any adult has
    /// one. Without it anyone holding the iPad could remove a PIN or make an
    /// unrestricted profile, and PINs would protect nothing.
    static func forManaging(profiles: [ProfileRecord]) -> [PINStep] {
        let adults = adultsWithPIN(in: profiles)
        guard !adults.isEmpty else { return [] }
        return [adultStep(adults, message: String(
            localized: "Changing profiles needs the PIN of \(names(adults)).",
            bundle: .module,
            comment: "Under the PIN pad before editing profiles. The value is a list of adult profile names joined with 'or'."
        ))]
    }

    private static func profileStep(_ profile: ProfileRecord) -> PINStep {
        PINStep(
            purpose: .profile,
            title: String(localized: "Enter \(profile.name)’s PIN", bundle: .module, comment: "PIN pad title; the value is a profile name"),
            message: nil,
            profileIDs: [profile.id],
            avatar: profile
        )
    }

    private static func adultStep(_ adults: [ProfileRecord], message: String) -> PINStep {
        PINStep(
            purpose: .adult,
            title: String(localized: "Enter an adult’s PIN", bundle: .module),
            message: message,
            profileIDs: adults.map(\.id),
            avatar: nil
        )
    }

    private static func names(_ profiles: [ProfileRecord]) -> String {
        profiles.map(\.name).formatted(.list(type: .or))
    }
}

// MARK: - The PIN pad's state (PRF-3)

/// What the pad does with a complete PIN, as its owner decides.
enum PINPadOutcome: Equatable {
    /// Right: the dots stay filled while the sheet goes away.
    case accepted
    /// Wrong: shake, clear, say so, and count it towards the cooldown.
    case rejected
    /// Not a wrong PIN but not done either (the second entry of a new PIN
    /// didn't match the first): shake and clear without counting it.
    case mismatched
    /// Fine, and another PIN follows (the next step, or "enter it again"):
    /// clear without a shake.
    case next
}

/// The PIN pad's state machine: the digits typed, whether the pad is waiting
/// for an answer, wrong tries, and the cooldown that slows guessing.
///
/// Four digits are only 10 000 PINs; a short pause every five wrong tries
/// keeps a child from walking through them while still letting a person who
/// fat-fingered recover quickly.
struct PINEntryState: Equatable {
    static let length = 4
    static let triesBeforeCooldown = 5
    static let cooldown: TimeInterval = 30

    enum Phase: Equatable {
        case entering
        /// Four digits are in and the owner is deciding.
        case checking
        case accepted
    }

    private(set) var digits = ""
    private(set) var phase = Phase.entering
    private(set) var failedTries = 0
    /// Bumped on every shake: the trigger for the shake and the error haptic.
    private(set) var shakes = 0
    /// Set by a wrong PIN, cleared by the next digit.
    private(set) var showsWrongPIN = false
    private(set) var lockedUntil: Date?

    func isLocked(at date: Date) -> Bool {
        lockedUntil.map { date < $0 } ?? false
    }

    func canType(at date: Date) -> Bool {
        phase == .entering && !isLocked(at: date)
    }

    /// Whole seconds left of the cooldown, or nil when none.
    func secondsLeft(at date: Date) -> Int? {
        guard let lockedUntil, date < lockedUntil else { return nil }
        return Int(lockedUntil.timeIntervalSince(date).rounded(.up))
    }

    /// Adds a digit. Returns the PIN when this digit completed it; the pad
    /// then waits (`checking`) for `resolve`.
    mutating func append(_ digit: Character, at date: Date = .now) -> String? {
        guard canType(at: date), digit.isASCII, digit.isNumber, digits.count < Self.length else { return nil }
        digits.append(digit)
        showsWrongPIN = false
        guard digits.count == Self.length else { return nil }
        phase = .checking
        return digits
    }

    mutating func deleteLast() {
        guard phase == .entering, !digits.isEmpty else { return }
        digits.removeLast()
    }

    mutating func resolve(_ outcome: PINPadOutcome, at date: Date = .now) {
        switch outcome {
        case .accepted:
            phase = .accepted
        case .next:
            digits = ""
            phase = .entering
        case .mismatched:
            digits = ""
            phase = .entering
            shakes += 1
        case .rejected:
            digits = ""
            phase = .entering
            shakes += 1
            failedTries += 1
            showsWrongPIN = true
            if failedTries.isMultiple(of: Self.triesBeforeCooldown) {
                lockedUntil = date.addingTimeInterval(Self.cooldown)
            }
        }
    }

    /// Clears a cooldown that has run out.
    mutating func endCooldown(at date: Date = .now) {
        if let lockedUntil, date >= lockedUntil {
            self.lockedUntil = nil
            showsWrongPIN = false
        }
    }
}

/// Choosing a new PIN: type it, type it again, and start over when the two
/// differ.
struct PINSetupState: Equatable {
    enum Step: Equatable {
        case enter
        case confirm(first: String)
    }

    enum Result: Equatable {
        case confirmNext
        case mismatch
        case done(String)
    }

    private(set) var step = Step.enter
    /// The last confirmation didn't match, so the pad says so.
    private(set) var mismatched = false

    var isConfirming: Bool {
        if case .confirm = step { return true }
        return false
    }

    mutating func submit(_ pin: String) -> Result {
        switch step {
        case .enter:
            step = .confirm(first: pin)
            mismatched = false
            return .confirmNext
        case .confirm(let first):
            guard first == pin else {
                step = .enter
                mismatched = true
                return .mismatch
            }
            return .done(pin)
        }
    }
}

// MARK: - A profile tile's caption (mockup 01)

/// The grey line under a profile on "Who's watching?": what kind of profile
/// it is for Kids and Guests (that is what someone choosing needs to know),
/// otherwise what it was last doing.
enum ProfileCaption {
    static func text(for profile: ProfileRecord, isWatchingNow: Bool, latestProgress: ProgressRecord?, isLastUsedHere: Bool) -> String? {
        switch profile.kind {
        case .guest:
            return String(localized: "Keeps no history", bundle: .module, comment: "Caption under the Guest profile (PRF-5)")
        case .kids:
            return String(localized: "Kids profile", bundle: .module)
        case .standard:
            break
        }
        if isWatchingNow {
            return String(localized: "Watching now", bundle: .module, comment: "Caption under a profile streaming on some device")
        }
        if let latestProgress {
            switch latestProgress.kind {
            case .episode: return String(localized: "Mid-episode", bundle: .module)
            case .movie: return String(localized: "Mid-movie", bundle: .module)
            case .catchup: return String(localized: "Mid-programme", bundle: .module)
            }
        }
        if isLastUsedHere {
            return String(localized: "Last used here", bundle: .module, comment: "Caption under the profile last picked on this device (PRF-9)")
        }
        return nil
    }
}

// MARK: - The household card on "Who's watching?"

/// The card's title and line: shared with whom, or where the profiles live.
struct HouseholdSummary: Equatable {
    var title: String
    var subtitle: String

    /// - Parameters:
    ///   - otherMembers: Members besides this person.
    ///   - syncsWithICloud: False with no iCloud account, or with the
    ///     in-memory store (`-InMemoryStores YES`): nothing leaves the device.
    static func make(isShared: Bool, otherMembers: Int, syncsWithICloud: Bool) -> HouseholdSummary {
        if isShared {
            let title = switch otherMembers {
            case 0: String(localized: "Shared through iCloud", bundle: .module, comment: "Household card title: shared, nobody has joined yet")
            case 1: String(localized: "Shared with 1 person", bundle: .module)
            default: String(localized: "Shared with \(otherMembers) people", bundle: .module)
            }
            return HouseholdSummary(title: title, subtitle: String(localized: "Profiles, favorites and progress sync via iCloud", bundle: .module))
        }
        if !syncsWithICloud {
            return HouseholdSummary(
                title: String(localized: "Only on this device", bundle: .module),
                subtitle: String(localized: "Sign in to iCloud to sync profiles, favorites and progress", bundle: .module)
            )
        }
        return HouseholdSummary(
            title: String(localized: "Only on your devices", bundle: .module),
            subtitle: String(localized: "Profiles, favorites and progress sync across your devices via iCloud", bundle: .module)
        )
    }
}

/// Colours for member circles. Members carry no colour of their own, so they
/// take the palette in order, owner first (the mockup's amber "BJ", teal "AJ").
/// Slate is left out: the "+N" circle is slate.
enum MemberPalette {
    static let order: [AvatarPalette] = [.amber, .teal, .lavender, .coral, .green, .blue, .rose]

    static func palette(at index: Int) -> AvatarPalette {
        order[((index % order.count) + order.count) % order.count]
    }

    /// Owner first, then this person, then everyone else by name, so the
    /// colours don't shuffle between launches.
    static func ordered(_ members: [MemberRecord]) -> [MemberRecord] {
        members.sorted { a, b in
            if (a.role == .owner) != (b.role == .owner) { return a.role == .owner }
            if a.isCurrentUser != b.isCurrentUser { return a.isCurrentUser }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
    }
}

/// One "Anya is watching on Living Room iPad   1/2 streams" row (HH-5):
/// person and device in the sentence, programme and source under it, and the
/// source's streams in use against its limit.
struct WatchingNowRow: Identifiable, Hashable {
    var id: UUID
    var sentence: String
    var detail: String?
    var streams: String?
    var spoken: String

    /// Rows for the playbacks still fresh at `now`, oldest first. Rows go
    /// stale on their own after 15 minutes without a heartbeat, so the view
    /// re-runs this on a timer rather than only when the store changes.
    static func rows(playbacks: [PlaybackRecord], profiles: [ProfileRecord], sources: [SourceRecord], now: Date) -> [WatchingNowRow] {
        let fresh = playbacks.filter { !$0.isStale(at: now) }.sorted { $0.startedAt < $1.startedAt }
        return fresh.map { playback in
            let person = profiles.first { $0.id == playback.profileID }?.name
                ?? String(localized: "Someone", bundle: .module, comment: "A stream whose profile was deleted")
            let source = sources.first { $0.id == playback.sourceID }
            let sentence = String(localized: "\(person) is watching on \(playback.deviceName)", bundle: .module, comment: "Who's watching row: profile name, device name")
            let detail = [playback.title, source?.name].compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.joined(separator: " · ")
            let inUse = fresh.filter { $0.sourceID == playback.sourceID }.count
            let limit = source.flatMap { $0.maxStreams > 0 ? $0.maxStreams : nil }
            let streams = streamsText(inUse: inUse, limit: limit)
            let spoken = [sentence, detail.isEmpty ? nil : detail, spokenStreams(inUse: inUse, limit: limit)]
                .compactMap { $0 }
                .joined(separator: ", ")
            return WatchingNowRow(id: playback.id, sentence: sentence, detail: detail.isEmpty ? nil : detail, streams: streams, spoken: spoken)
        }
    }

    /// "1/2 streams", as in the mockup; "1 stream" with no limit.
    static func streamsText(inUse: Int, limit: Int?) -> String {
        if let limit {
            return String(localized: "\(inUse)/\(limit) streams", bundle: .module, comment: "Streams in use of a source's limit, as 1/2 streams")
        }
        return inUse == 1
            ? String(localized: "1 stream", bundle: .module)
            : String(localized: "\(inUse) streams", bundle: .module)
    }

    private static func spokenStreams(inUse: Int, limit: Int?) -> String {
        if let limit {
            return String(localized: "\(inUse) of \(limit) streams in use", bundle: .module)
        }
        return String(localized: "\(inUse) streams in use", bundle: .module)
    }
}

// MARK: - The editor's rules (PRF-1, PRF-4, PRF-6)

/// What may be added, deleted or changed in kind.
enum ProfileEditRules {
    /// PRF-1. Mirrors `HouseholdStore.maxProfiles`, which is main-actor
    /// isolated; the store enforces it again on write.
    static let maxProfiles = 8

    static func canAdd(profileCount: Int) -> Bool {
        profileCount < maxProfiles
    }

    /// The household's only standard profile stays standard and can't be
    /// deleted: without an adult profile nobody could let a child out of a
    /// Kids profile, and favorites must always have a profile to belong to.
    static func isLastStandard(_ id: UUID?, in profiles: [ProfileRecord]) -> Bool {
        guard let id, let profile = profiles.first(where: { $0.id == id }), profile.kind == .standard else { return false }
        return profiles.filter { $0.kind == .standard }.count == 1
    }

    static func canDelete(_ id: UUID?, in profiles: [ProfileRecord]) -> Bool {
        guard let id, profiles.contains(where: { $0.id == id }) else { return false }
        return profiles.count > 1 && !isLastStandard(id, in: profiles)
    }

    /// The kinds the editor offers: every kind, except that the last standard
    /// profile can only stay standard.
    static func kinds(for id: UUID?, in profiles: [ProfileRecord]) -> [ProfileKind] {
        isLastStandard(id, in: profiles) ? [.standard] : ProfileKind.allCases
    }
}

/// Which sources a profile sees (PRF-6). The stored set is empty for "all",
/// so a source added later shows everywhere until someone hides it.
enum SourceVisibility {
    static func isVisible(_ id: UUID, in visible: Set<UUID>) -> Bool {
        visible.isEmpty || visible.contains(id)
    }

    /// Whether this source's switch may turn off: never the last visible one,
    /// since "nothing" can't be stored (empty means everything).
    static func canHide(_ id: UUID, visible: Set<UUID>, allSourceIDs: [UUID]) -> Bool {
        let shown = allSourceIDs.filter { isVisible($0, in: visible) }
        return !(shown.count == 1 && shown.first == id)
    }

    /// The set after flipping one source. Every current source on collapses
    /// back to the empty "all"; ids of removed sources are kept, so adding a
    /// source back restores its old setting (SRC-9).
    static func toggled(_ id: UUID, isOn: Bool, visible: Set<UUID>, allSourceIDs: [UUID]) -> Set<UUID> {
        guard isOn || canHide(id, visible: visible, allSourceIDs: allSourceIDs) else { return visible }
        var set = visible.isEmpty ? Set(allSourceIDs) : visible
        if isOn { set.insert(id) } else { set.remove(id) }
        return Set(allSourceIDs).isSubset(of: set) ? [] : set
    }
}

/// The editor's working copy of a profile: edited freely, written once on
/// Save. The PIN is staged here too and goes to `setPIN` on Save, so Cancel
/// really cancels.
struct ProfileDraft: Equatable {
    static let maxNameLength = 24

    enum PINChange: Equatable {
        case unchanged
        case set(String)
        case remove
    }

    var name: String
    var kind: ProfileKind
    var avatarColor: AvatarPalette
    var avatarSymbol: String?
    var allowedCategoryKeys: Set<String>
    var hiddenCategoryKeys: Set<String>
    var visibleSourceIDs: Set<UUID>
    var audioLanguage: String?
    var subtitleLanguage: String?
    var pinChange = PINChange.unchanged

    init(record: ProfileRecord) {
        name = record.name
        kind = record.kind
        avatarColor = record.avatarColor
        avatarSymbol = record.avatarSymbol
        allowedCategoryKeys = record.allowedCategoryKeys
        hiddenCategoryKeys = record.hiddenCategoryKeys
        visibleSourceIDs = record.visibleSourceIDs
        audioLanguage = record.audioLanguage
        subtitleLanguage = record.subtitleLanguage
    }

    /// A new profile in the first colour nobody uses yet.
    static func new(existing: [ProfileRecord]) -> ProfileDraft {
        let used = Set(existing.map(\.avatarColor))
        let color = MemberPalette.order.first { !used.contains($0) } ?? MemberPalette.palette(at: existing.count)
        return ProfileDraft(record: ProfileRecord(name: "", avatarColor: color))
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool { !trimmedName.isEmpty }

    /// Whether the profile will ask for a PIN once saved.
    func willHavePIN(hadPIN: Bool) -> Bool {
        switch pinChange {
        case .unchanged: hadPIN
        case .set: true
        case .remove: false
        }
    }

    /// `record` with this draft's editable fields. Kids keep their allowed
    /// list; other kinds store none (the field means nothing for them, and a
    /// stale list would come back if the kind changed again).
    func applied(to record: ProfileRecord) -> ProfileRecord {
        var result = record
        result.name = String(trimmedName.prefix(Self.maxNameLength))
        result.kind = kind
        result.avatarColor = avatarColor
        result.avatarSymbol = avatarSymbol
        result.allowedCategoryKeys = kind == .kids ? allowedCategoryKeys : []
        result.hiddenCategoryKeys = hiddenCategoryKeys
        result.visibleSourceIDs = visibleSourceIDs
        result.audioLanguage = audioLanguage
        result.subtitleLanguage = subtitleLanguage
        return result
    }
}

// MARK: - Choices offered by the editor

/// The SF Symbols a profile can wear instead of its initial (PRF-1), with
/// the names VoiceOver reads.
enum AvatarSymbols {
    static let all: [String] = [
        "face.smiling", "star.fill", "heart.fill", "bolt.fill", "leaf.fill", "pawprint.fill",
        "gamecontroller.fill", "music.note", "moon.stars.fill", "sun.max.fill", "flame.fill", "sparkles",
        "crown.fill", "hare.fill", "tortoise.fill", "fish.fill", "bird.fill", "soccerball",
        "basketball.fill", "film.fill", "book.fill", "paintpalette.fill", "airplane", "cloud.fill",
    ]

    static func spokenName(_ symbol: String) -> String {
        switch symbol {
        case "face.smiling": String(localized: "Smiling face", bundle: .module)
        case "star.fill": String(localized: "Star", bundle: .module)
        case "heart.fill": String(localized: "Heart", bundle: .module)
        case "bolt.fill": String(localized: "Lightning bolt", bundle: .module)
        case "leaf.fill": String(localized: "Leaf", bundle: .module)
        case "pawprint.fill": String(localized: "Paw print", bundle: .module)
        case "gamecontroller.fill": String(localized: "Game controller", bundle: .module)
        case "music.note": String(localized: "Music note", bundle: .module)
        case "moon.stars.fill": String(localized: "Moon and stars", bundle: .module)
        case "sun.max.fill": String(localized: "Sun", bundle: .module)
        case "flame.fill": String(localized: "Flame", bundle: .module)
        case "sparkles": String(localized: "Sparkles", bundle: .module)
        case "crown.fill": String(localized: "Crown", bundle: .module)
        case "hare.fill": String(localized: "Hare", bundle: .module)
        case "tortoise.fill": String(localized: "Tortoise", bundle: .module)
        case "fish.fill": String(localized: "Fish", bundle: .module)
        case "bird.fill": String(localized: "Bird", bundle: .module)
        case "soccerball": String(localized: "Football", bundle: .module)
        case "basketball.fill": String(localized: "Basketball", bundle: .module)
        case "film.fill": String(localized: "Film", bundle: .module)
        case "book.fill": String(localized: "Book", bundle: .module)
        case "paintpalette.fill": String(localized: "Paint palette", bundle: .module)
        case "airplane": String(localized: "Aeroplane", bundle: .module)
        case "cloud.fill": String(localized: "Cloud", bundle: .module)
        default: symbol
        }
    }
}

extension AvatarPalette {
    /// The colour's name, for VoiceOver on the editor's swatches.
    var spokenName: String {
        switch self {
        case .amber: String(localized: "Amber", bundle: .module)
        case .teal: String(localized: "Teal", bundle: .module)
        case .lavender: String(localized: "Lavender", bundle: .module)
        case .slate: String(localized: "Slate", bundle: .module)
        case .coral: String(localized: "Coral", bundle: .module)
        case .green: String(localized: "Green", bundle: .module)
        case .blue: String(localized: "Blue", bundle: .module)
        case .rose: String(localized: "Rose", bundle: .module)
        }
    }
}

extension ProfileKind {
    var title: String {
        switch self {
        case .standard: String(localized: "Standard", bundle: .module, comment: "Profile kind")
        case .kids: String(localized: "Kids", bundle: .module, comment: "Profile kind")
        case .guest: String(localized: "Guest", bundle: .module, comment: "Profile kind")
        }
    }

    /// What the kind means, under the kind picker.
    var explanation: String {
        switch self {
        case .standard:
            String(localized: "Keeps its own favorites, My List and progress.", bundle: .module)
        case .kids:
            String(localized: "Sees only the categories you allow below, can’t open Settings or Household, and needs an adult’s PIN to leave.", bundle: .module)
        case .guest:
            String(localized: "Watches anything not hidden and keeps nothing: no favorites, progress or history. Cleared whenever someone leaves it.", bundle: .module)
        }
    }
}

/// Languages offered for audio and subtitles (PLY-6): ISO 639-1 codes the
/// player matches against a stream's tracks, named in the reader's language.
enum LanguageOptions {
    static let codes = [
        "ar", "bn", "cs", "da", "de", "el", "en", "es", "fa", "fi", "fr", "gu", "he", "hi", "hu", "id",
        "it", "ja", "ko", "ml", "mr", "ms", "nl", "no", "pa", "pl", "pt", "ro", "ru", "sv", "ta", "te",
        "th", "tr", "uk", "ur", "vi", "zh",
    ]

    struct Option: Hashable, Identifiable {
        var code: String
        var name: String
        var id: String { code }
    }

    /// Every offered language by name, plus `keeping` when a profile already
    /// has a code the list lacks (set on a newer build, say), so a picker
    /// never loses it.
    static func options(keeping extra: [String?] = [], locale: Locale = .current) -> [Option] {
        var all = Set(codes)
        for case let code? in extra { all.insert(code) }
        return all.map { Option(code: $0, name: name(for: $0, locale: locale)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func name(for code: String, locale: Locale = .current) -> String {
        locale.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }
}
