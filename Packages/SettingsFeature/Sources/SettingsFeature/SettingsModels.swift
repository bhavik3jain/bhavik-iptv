import Foundation
import HouseholdKit

// The logic behind Settings, in value types so it can be tested without a view
// (views are untested by policy): the version line, the language choices,
// the sync and refresh wording, and when choosing an always-open profile
// needs that profile's PIN.

// MARK: - Version

/// "0.1 (252981234)" from the app's Info.plist. The build number is the
/// local yyDDDHHMM stamp the build scripts write, so a TestFlight tester can
/// say exactly which build they mean.
enum AppVersionText {
    static func make(shortVersion: String?, build: String?) -> String {
        let version = shortVersion?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let build = build?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        switch (version, build) {
        case let (version?, build?) where version != build:
            return "\(version) (\(build))"
        case let (version?, _):
            return version
        case let (nil, build?):
            return String(localized: "Build \(build)", bundle: .module)
        case (nil, nil):
            // A package preview or test host, which has no app Info.plist.
            return String(localized: "Development build", bundle: .module)
        }
    }

    /// The running app's version line.
    static func current(bundle: Bundle = .main) -> String {
        make(
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }
}

// MARK: - Languages

/// The languages a profile can prefer for audio and subtitles (PLY-6),
/// stored as two-letter ISO 639-1 codes: what PlayerKit's `LanguageMatch`
/// normalises every track tag to ("eng", "en-GB" and "English" all become
/// "en").
struct LanguageOption: Identifiable, Hashable, Sendable {
    var code: String
    var name: String
    var id: String { code }
}

enum LanguageOptions {
    /// The languages IPTV providers commonly carry, covering the track tags
    /// PlayerKit recognises by name. A profile's saved code that isn't here
    /// still shows (see `options(including:)`).
    static let codes = [
        "ar", "bn", "bg", "zh", "hr", "cs", "da", "nl", "en", "fa", "fi", "fr",
        "de", "el", "gu", "he", "hi", "hu", "id", "it", "ja", "kn", "ko", "ml",
        "mr", "ms", "no", "pa", "pl", "pt", "ro", "ru", "sr", "sk", "es", "sv",
        "ta", "te", "th", "tr", "uk", "ur", "vi",
    ]

    /// Every option, named in the device's language and sorted by that name,
    /// with the device's own preferred languages first (the likeliest picks).
    /// `including` keeps a profile's current code in the list even when it
    /// isn't one of `codes`, so a choice made elsewhere is never shown blank.
    static func options(
        including current: [String?] = [],
        preferredLanguages: [String] = Locale.preferredLanguages,
        locale: Locale = .current
    ) -> [LanguageOption] {
        var all = Set(codes)
        for code in current.compactMap({ $0?.lowercased() }) where !code.isEmpty { all.insert(code) }
        let preferred = preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier(.alpha2) }
        var seen: Set<String> = []
        let firstCodes = preferred.filter { all.contains($0) && seen.insert($0).inserted }
        let named = all.map { LanguageOption(code: $0, name: name(for: $0, locale: locale)) }
        let first = firstCodes.compactMap { code in named.first { $0.code == code } }
        let rest = named
            .filter { !seen.contains($0.code) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return first + rest
    }

    /// "English", "Deutsch" → in the device's language ("German" on an
    /// English device). Falls back to the code itself.
    static func name(for code: String, locale: Locale = .current) -> String {
        guard let name = locale.localizedString(forLanguageCode: code), !name.isEmpty else { return code }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}

// MARK: - Always open (PRF-2)

enum AlwaysOpenRule {
    /// Whether making `profile` this device's always-open profile needs its
    /// PIN first. Always-open skips the gate — PIN included — at every
    /// launch (`ProfileSession.restore`), so pointing it at someone else's
    /// locked profile would be a way round their PIN. Choosing your own
    /// profile, or one with no PIN, needs nothing.
    static func needsPIN(for profile: ProfileRecord, currentProfileID: UUID?) -> Bool {
        profile.hasPIN && profile.id != currentProfileID
    }
}

// MARK: - Sync and refresh wording

enum SyncStatusText {
    /// The status line for Settings › iCloud.
    static func text(_ status: HouseholdSyncStatus, now: Date = .now) -> String {
        switch status {
        case .local:
            String(localized: "On this device only", bundle: .module, comment: "iCloud status: not syncing")
        case .syncing:
            String(localized: "Syncing…", bundle: .module)
        case .upToDate(let date):
            String(localized: "Up to date · \(RefreshTimeText.relative(date, now: now))", bundle: .module, comment: "iCloud status: Up to date · 2 min ago")
        case .failed(let message):
            String(localized: "Couldn't sync: \(message)", bundle: .module)
        case .noAccount:
            String(localized: "Not signed in to iCloud", bundle: .module)
        }
    }

    static func isProblem(_ status: HouseholdSyncStatus) -> Bool {
        switch status {
        case .failed, .noAccount: true
        case .local, .syncing, .upToDate: false
        }
    }
}

enum RefreshTimeText {
    /// "2 hours ago", "just now"; a time in the future (a device clock that
    /// was wrong when it was written) reads as "just now" rather than "in 3
    /// minutes".
    static func relative(_ date: Date, now: Date = .now) -> String {
        if now.timeIntervalSince(date) < 60 {
            return String(localized: "just now", bundle: .module)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "Catalog 2 hours ago · Guide 40 minutes ago", or "Not downloaded yet".
    static func sourceLine(catalog: Date?, guide: Date?, now: Date = .now) -> String {
        var parts: [String] = []
        if let catalog {
            parts.append(String(localized: "Catalog \(relative(catalog, now: now))", bundle: .module, comment: "When a source's channels and films were last downloaded"))
        }
        if let guide {
            parts.append(String(localized: "Guide \(relative(guide, now: now))", bundle: .module, comment: "When a source's programme guide was last downloaded"))
        }
        if parts.isEmpty {
            return String(localized: "Not downloaded yet", bundle: .module)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Storage

enum CacheSizeText {
    /// "12.4 MB", or "Empty" for nothing at all.
    static func text(bytes: Int) -> String {
        guard bytes > 0 else { return String(localized: "Empty", bundle: .module, comment: "An image cache holding nothing") }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
