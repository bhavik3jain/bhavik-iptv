import Foundation
import HouseholdKit
import Testing
@testable import SettingsFeature

@Suite struct AppVersionTextTests {
    @Test func versionAndBuild() {
        #expect(AppVersionText.make(shortVersion: "0.1", build: "252981234") == "0.1 (252981234)")
    }

    @Test func aBuildThatRepeatsTheVersionIsSaidOnce() {
        #expect(AppVersionText.make(shortVersion: "1.0", build: "1.0") == "1.0")
        #expect(AppVersionText.make(shortVersion: " 1.0", build: "1.0 ") == "1.0")
    }

    @Test func versionOnly() {
        #expect(AppVersionText.make(shortVersion: "0.1", build: nil) == "0.1")
        #expect(AppVersionText.make(shortVersion: "0.1", build: "   ") == "0.1")
    }

    @Test func buildOnly() {
        #expect(AppVersionText.make(shortVersion: nil, build: "42") == "Build 42")
        #expect(AppVersionText.make(shortVersion: "", build: "42") == "Build 42")
    }

    @Test func neitherIsADevelopmentBuild() {
        #expect(AppVersionText.make(shortVersion: nil, build: nil) == "Development build")
        #expect(AppVersionText.make(shortVersion: " ", build: "") == "Development build")
    }

    @Test func surroundingSpacesAreTrimmed() {
        #expect(AppVersionText.make(shortVersion: " 0.2 ", build: " 7 ") == "0.2 (7)")
    }
}

@Suite struct LanguageOptionsTests {
    let english = Locale(identifier: "en_US")

    @Test func everyCodeIsOfferedOnce() {
        let options = LanguageOptions.options(preferredLanguages: [], locale: english)
        #expect(options.count == LanguageOptions.codes.count)
        #expect(Set(options.map(\.code)) == Set(LanguageOptions.codes))
        #expect(Set(LanguageOptions.codes).count == LanguageOptions.codes.count)
    }

    @Test func withNoPreferenceTheListIsSortedByName() {
        let names = LanguageOptions.options(preferredLanguages: [], locale: english).map(\.name)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(names.first == "Arabic")
    }

    @Test func theDevicesLanguagesComeFirstInItsOrder() {
        let options = LanguageOptions.options(preferredLanguages: ["de-DE", "en-GB", "fr"], locale: english)
        #expect(options.prefix(3).map(\.code) == ["de", "en", "fr"])
        let rest = options.dropFirst(3).map(\.name)
        #expect(rest == rest.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(!rest.contains("German"))
    }

    @Test func repeatedOrUnofferedPreferencesAreSkipped() {
        let options = LanguageOptions.options(preferredLanguages: ["en-US", "en-GB", "xx-YY", "es-419"], locale: english)
        #expect(options.prefix(2).map(\.code) == ["en", "es"])
        #expect(options.filter { $0.code == "en" }.count == 1)
        #expect(!options.contains { $0.code == "xx" })
    }

    @Test func aProfilesCurrentCodeIsKeptEvenWhenUnlisted() {
        let options = LanguageOptions.options(including: ["GA", nil, "", "en"], preferredLanguages: [], locale: english)
        #expect(options.count == LanguageOptions.codes.count + 1)
        #expect(options.contains { $0.code == "ga" })
        #expect(!options.contains { $0.code.isEmpty })
    }

    @Test func aKeptCodeCanAlsoBePreferred() {
        let options = LanguageOptions.options(including: ["ga"], preferredLanguages: ["ga-IE"], locale: english)
        #expect(options.first?.code == "ga")
    }

    @Test func namesAreInTheDevicesLanguageAndCapitalised() {
        #expect(LanguageOptions.name(for: "de", locale: english) == "German")
        // French writes language names in lower case; the picker capitalises them.
        #expect(LanguageOptions.name(for: "de", locale: Locale(identifier: "fr_FR")) == "Allemand")
        #expect(LanguageOptions.name(for: "en", locale: Locale(identifier: "de_DE")) == "Englisch")
    }
}

@Suite struct AlwaysOpenRuleTests {
    let me = ProfileRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Me", hasPIN: true)
    let partner = ProfileRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Partner", hasPIN: true)
    let open = ProfileRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Open", hasPIN: false)
    let kid = ProfileRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "Kid", kind: .kids)
    let guest = ProfileRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, name: "Guest", kind: .guest)

    @Test func someoneElsesLockedProfileNeedsItsPIN() {
        #expect(AlwaysOpenRule.needsPIN(for: partner, currentProfileID: me.id))
        #expect(AlwaysOpenRule.needsPIN(for: partner, currentProfileID: nil))
    }

    @Test func yourOwnOrAnUnlockedProfileNeedsNothing() {
        #expect(!AlwaysOpenRule.needsPIN(for: me, currentProfileID: me.id))
        #expect(!AlwaysOpenRule.needsPIN(for: open, currentProfileID: me.id))
        #expect(!AlwaysOpenRule.needsPIN(for: open, currentProfileID: nil))
    }

    @Test func theGuestIsNotOffered() {
        let choices = AlwaysOpenRule.choices([me, guest, kid, open], current: nil)
        #expect(choices.map(\.name) == ["Me", "Kid", "Open"])
        #expect(AlwaysOpenRule.choices([me, guest], current: me.id).map(\.name) == ["Me"])
    }

    @Test func aGuestAlreadyChosenStillShows() {
        let choices = AlwaysOpenRule.choices([me, guest, open], current: guest.id)
        #expect(choices.map(\.name) == ["Me", "Guest", "Open"])
    }
}

@Suite struct SyncAndRefreshTextTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func statusLines() {
        #expect(SyncStatusText.text(.local, now: now) == "On this device only")
        #expect(SyncStatusText.text(.syncing, now: now) == "Syncing…")
        #expect(SyncStatusText.text(.upToDate(now.addingTimeInterval(-5)), now: now) == "Up to date · just now")
        #expect(SyncStatusText.text(.failed("The network connection was lost."), now: now) == "Couldn't sync: The network connection was lost.")
        #expect(SyncStatusText.text(.noAccount, now: now) == "Not signed in to iCloud")
    }

    @Test func onlyFailuresAndMissingAccountsAreProblems() {
        #expect(SyncStatusText.isProblem(.failed("x")))
        #expect(SyncStatusText.isProblem(.noAccount))
        #expect(!SyncStatusText.isProblem(.local))
        #expect(!SyncStatusText.isProblem(.syncing))
        #expect(!SyncStatusText.isProblem(.upToDate(now)))
    }

    @Test func underAMinuteIsJustNow() {
        #expect(RefreshTimeText.relative(now, now: now) == "just now")
        #expect(RefreshTimeText.relative(now.addingTimeInterval(-59.9), now: now) == "just now")
        #expect(RefreshTimeText.relative(now.addingTimeInterval(-60), now: now) != "just now")
    }

    @Test func aFutureTimeIsJustNow() {
        // A clock that was wrong when the date was written.
        #expect(RefreshTimeText.relative(now.addingTimeInterval(180), now: now) == "just now")
        #expect(RefreshTimeText.relative(now.addingTimeInterval(86_400), now: now) == "just now")
    }

    @Test func olderTimesAreRelative() {
        let twoHours = RefreshTimeText.relative(now.addingTimeInterval(-7200), now: now)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        #expect(twoHours == formatter.localizedString(for: now.addingTimeInterval(-7200), relativeTo: now))
        #expect(twoHours != RefreshTimeText.relative(now.addingTimeInterval(-60), now: now))
    }

    @Test func sourceLineSaysWhatWasDownloaded() {
        let recent = now.addingTimeInterval(-10)
        #expect(RefreshTimeText.sourceLine(catalog: nil, guide: nil, now: now) == "Not downloaded yet")
        #expect(RefreshTimeText.sourceLine(catalog: recent, guide: nil, now: now) == "Catalog just now")
        #expect(RefreshTimeText.sourceLine(catalog: nil, guide: recent, now: now) == "Guide just now")
        #expect(RefreshTimeText.sourceLine(catalog: recent, guide: recent, now: now) == "Catalog just now · Guide just now")
    }
}

@Suite struct CacheSizeTextTests {
    @Test func nothingIsEmpty() {
        #expect(CacheSizeText.text(bytes: 0) == "Empty")
        #expect(CacheSizeText.text(bytes: -1) == "Empty")
    }

    @Test func anythingIsASize() {
        #expect(CacheSizeText.text(bytes: 1) != "Empty")
        #expect(CacheSizeText.text(bytes: 12_400_000) == ByteCountFormatter.string(fromByteCount: 12_400_000, countStyle: .file))
    }
}
