import Core
import Foundation
import HouseholdKit
import Testing
@testable import ProfilesFeature

@Suite struct ProfileCaptionTests {
    let home = Household()

    private func progress(_ kind: HouseholdProgressKind) -> ProgressRecord {
        ProgressRecord(profileID: home.gran.id, itemKey: "x", kind: kind, position: 10, duration: 100, updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func kidsAndGuestsSayWhatTheyAre() {
        #expect(ProfileCaption.text(for: home.guest, isWatchingNow: true, latestProgress: progress(.movie), isLastUsedHere: true) == "Keeps no history")
        #expect(ProfileCaption.text(for: home.kid, isWatchingNow: true, latestProgress: progress(.movie), isLastUsedHere: true) == "Kids profile")
    }

    @Test func watchingNowComesFirst() {
        #expect(ProfileCaption.text(for: home.gran, isWatchingNow: true, latestProgress: progress(.episode), isLastUsedHere: true) == "Watching now")
    }

    @Test func thenWhatItWasLastDoing() {
        #expect(ProfileCaption.text(for: home.gran, isWatchingNow: false, latestProgress: progress(.episode), isLastUsedHere: true) == "Mid-episode")
        #expect(ProfileCaption.text(for: home.gran, isWatchingNow: false, latestProgress: progress(.movie), isLastUsedHere: false) == "Mid-movie")
        #expect(ProfileCaption.text(for: home.gran, isWatchingNow: false, latestProgress: progress(.catchup), isLastUsedHere: false) == "Mid-programme")
    }

    @Test func thenWhetherItWasLastUsedHere() {
        #expect(ProfileCaption.text(for: home.gran, isWatchingNow: false, latestProgress: nil, isLastUsedHere: true) == "Last used here")
        #expect(ProfileCaption.text(for: home.gran, isWatchingNow: false, latestProgress: nil, isLastUsedHere: false) == nil)
    }
}

@Suite struct HouseholdSummaryTests {
    @Test func sharedSaysWithHowMany() {
        #expect(HouseholdSummary.make(isShared: true, otherMembers: 0, syncsWithICloud: true).title == "Shared through iCloud")
        #expect(HouseholdSummary.make(isShared: true, otherMembers: 1, syncsWithICloud: true).title == "Shared with 1 person")
        #expect(HouseholdSummary.make(isShared: true, otherMembers: 3, syncsWithICloud: true).title == "Shared with 3 people")
        #expect(HouseholdSummary.make(isShared: true, otherMembers: 3, syncsWithICloud: true).subtitle == "Profiles, favorites and progress sync via iCloud")
    }

    @Test func sharingOutranksTheAccountState() {
        #expect(HouseholdSummary.make(isShared: true, otherMembers: 2, syncsWithICloud: false).title == "Shared with 2 people")
    }

    @Test func notSharedSaysWhereProfilesLive() {
        let local = HouseholdSummary.make(isShared: false, otherMembers: 0, syncsWithICloud: false)
        #expect(local.title == "Only on this device")
        #expect(local.subtitle == "Sign in to iCloud to sync profiles, favorites and progress")
        let mine = HouseholdSummary.make(isShared: false, otherMembers: 0, syncsWithICloud: true)
        #expect(mine.title == "Only on your devices")
        #expect(mine.subtitle == "Profiles, favorites and progress sync across your devices via iCloud")
    }
}

@Suite struct MemberPaletteTests {
    @Test func slateIsKeptForTheOverflowCircle() {
        #expect(!MemberPalette.order.contains(.slate))
        #expect(Set(MemberPalette.order).count == MemberPalette.order.count)
        #expect(MemberPalette.order.first == .amber)
    }

    @Test func coloursWrapInBothDirections() {
        let count = MemberPalette.order.count
        #expect(MemberPalette.palette(at: 0) == .amber)
        #expect(MemberPalette.palette(at: 1) == .teal)
        #expect(MemberPalette.palette(at: count) == .amber)
        #expect(MemberPalette.palette(at: count + 1) == .teal)
        #expect(MemberPalette.palette(at: -1) == MemberPalette.order.last)
    }

    @Test func ownerFirstThenThisPersonThenByName() {
        let members = [
            MemberRecord(id: "c", displayName: "Zed", role: .watch, isCurrentUser: false),
            MemberRecord(id: "d", displayName: "Member 10", role: .watch, isCurrentUser: false),
            MemberRecord(id: "me", displayName: "Yara", role: .manage, isCurrentUser: true),
            MemberRecord(id: "e", displayName: "Member 2", role: .manage, isCurrentUser: false),
            MemberRecord(id: "owner", displayName: "Xavier", role: .owner, isCurrentUser: false),
        ]
        #expect(MemberPalette.ordered(members).map(\.id) == ["owner", "me", "e", "d", "c"])
    }

    @Test func anOwnerWhoIsThisPersonIsStillFirst() {
        let members = [
            MemberRecord(id: "a", displayName: "Abe", role: .watch, isCurrentUser: false),
            MemberRecord(id: "owner", displayName: "Zoe", role: .owner, isCurrentUser: true),
        ]
        #expect(MemberPalette.ordered(members).map(\.id) == ["owner", "a"])
    }
}

@Suite struct WatchingNowRowTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let home = Household()
    let sourceA = SourceRecord(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!, name: "Provider A", kindRaw: "xtream", maxStreams: 2)
    let unlimited = SourceRecord(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!, name: "Playlist", kindRaw: "m3u", maxStreams: 0)

    private func playback(_ id: Int, profile: UUID, source: UUID, title: String = "Evening Bulletin", device: String = "Living Room iPad", startedMinutesAgo: Double, lastSeenMinutesAgo: Double = 1) -> PlaybackRecord {
        PlaybackRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            deviceName: device, profileID: profile, sourceID: source, itemKey: "k\(id)", title: title,
            startedAt: now.addingTimeInterval(-startedMinutesAgo * 60), lastSeenAt: now.addingTimeInterval(-lastSeenMinutesAgo * 60)
        )
    }

    @Test func freshRowsOldestFirst() {
        let rows = WatchingNowRow.rows(
            playbacks: [
                playback(1, profile: home.mum.id, source: sourceA.id, startedMinutesAgo: 5),
                playback(2, profile: home.dad.id, source: sourceA.id, startedMinutesAgo: 30),
            ],
            profiles: home.all, sources: [sourceA], now: now
        )
        #expect(rows.map(\.sentence) == ["Dad is watching on Living Room iPad", "Mum is watching on Living Room iPad"])
    }

    @Test func rowsUnseenForFifteenMinutesDropOut() {
        let rows = WatchingNowRow.rows(
            playbacks: [
                playback(1, profile: home.mum.id, source: sourceA.id, startedMinutesAgo: 60, lastSeenMinutesAgo: 15),
                playback(2, profile: home.dad.id, source: sourceA.id, startedMinutesAgo: 60, lastSeenMinutesAgo: 15.1),
            ],
            profiles: home.all, sources: [sourceA], now: now
        )
        #expect(rows.map(\.id) == [playback(1, profile: home.mum.id, source: sourceA.id, startedMinutesAgo: 0).id])
    }

    @Test func detailIsTheProgrammeAndSource() {
        let row = WatchingNowRow.rows(playbacks: [playback(1, profile: home.mum.id, source: sourceA.id, startedMinutesAgo: 1)], profiles: home.all, sources: [sourceA], now: now)[0]
        #expect(row.detail == "Evening Bulletin · Provider A")
        #expect(row.streams == "1/2 streams")
        #expect(row.spoken == "Mum is watching on Living Room iPad, Evening Bulletin · Provider A, 1 of 2 streams in use")
    }

    @Test func missingPiecesLeaveTheDetailShorterOrEmpty() {
        let noTitle = WatchingNowRow.rows(playbacks: [playback(1, profile: home.mum.id, source: sourceA.id, title: "", startedMinutesAgo: 1)], profiles: home.all, sources: [sourceA], now: now)[0]
        #expect(noTitle.detail == "Provider A")

        let nothing = WatchingNowRow.rows(playbacks: [playback(1, profile: home.mum.id, source: UUID(), title: "", startedMinutesAgo: 1)], profiles: home.all, sources: [sourceA], now: now)[0]
        #expect(nothing.detail == nil)
        #expect(nothing.streams == "1 stream")
        // Spoken: the sentence, no empty detail, then the stream count.
        #expect(nothing.spoken.hasPrefix("Mum is watching on Living Room iPad, 1 "))
        #expect(!nothing.spoken.contains(", ,"))
    }

    @Test func aDeletedProfileIsSomeone() {
        let row = WatchingNowRow.rows(playbacks: [playback(1, profile: UUID(), source: sourceA.id, startedMinutesAgo: 1)], profiles: home.all, sources: [sourceA], now: now)[0]
        #expect(row.sentence == "Someone is watching on Living Room iPad")
    }

    @Test func streamsCountFreshRowsOnTheSameSourceOnly() {
        let rows = WatchingNowRow.rows(
            playbacks: [
                playback(1, profile: home.mum.id, source: sourceA.id, startedMinutesAgo: 3),
                playback(2, profile: home.dad.id, source: sourceA.id, startedMinutesAgo: 2),
                playback(3, profile: home.gran.id, source: unlimited.id, startedMinutesAgo: 1),
                playback(4, profile: home.kid.id, source: sourceA.id, startedMinutesAgo: 90, lastSeenMinutesAgo: 40),
            ],
            profiles: home.all, sources: [sourceA, unlimited], now: now
        )
        #expect(rows.map(\.streams) == ["2/2 streams", "2/2 streams", "1 stream"])
    }

    @Test func streamsText() {
        #expect(WatchingNowRow.streamsText(inUse: 1, limit: 2) == "1/2 streams")
        #expect(WatchingNowRow.streamsText(inUse: 3, limit: 2) == "3/2 streams")
        #expect(WatchingNowRow.streamsText(inUse: 1, limit: nil) == "1 stream")
        #expect(WatchingNowRow.streamsText(inUse: 2, limit: nil) == "2 streams")
        #expect(WatchingNowRow.streamsText(inUse: 0, limit: nil) == "0 streams")
    }

    @Test func noPlaybacksNoRows() {
        #expect(WatchingNowRow.rows(playbacks: [], profiles: home.all, sources: [sourceA], now: now).isEmpty)
    }
}

@Suite struct ProfileEditRulesTests {
    let home = Household()

    @Test func atMostEightProfiles() {
        #expect(ProfileEditRules.canAdd(profileCount: 0))
        #expect(ProfileEditRules.canAdd(profileCount: 7))
        #expect(!ProfileEditRules.canAdd(profileCount: 8))
        #expect(!ProfileEditRules.canAdd(profileCount: 9))
    }

    @Test func theOnlyStandardProfileIsTheLastStandard() {
        let profiles = [home.gran, home.kid, home.guest]
        #expect(ProfileEditRules.isLastStandard(home.gran.id, in: profiles))
        #expect(!ProfileEditRules.isLastStandard(home.kid.id, in: profiles))
        #expect(!ProfileEditRules.isLastStandard(nil, in: profiles))
        #expect(!ProfileEditRules.isLastStandard(UUID(), in: profiles))
        #expect(!ProfileEditRules.isLastStandard(home.gran.id, in: [home.gran, home.mum]))
    }

    @Test func theLastStandardCantBeDeleted() {
        let profiles = [home.gran, home.kid]
        #expect(!ProfileEditRules.canDelete(home.gran.id, in: profiles))
        #expect(ProfileEditRules.canDelete(home.kid.id, in: profiles))
    }

    @Test func theOnlyProfileOrAnUnknownOneCantBeDeleted() {
        #expect(!ProfileEditRules.canDelete(home.kid.id, in: [home.kid]))
        #expect(!ProfileEditRules.canDelete(nil, in: home.all))
        #expect(!ProfileEditRules.canDelete(UUID(), in: home.all))
    }

    @Test func anyStandardCanGoWhenAnotherRemains() {
        #expect(ProfileEditRules.canDelete(home.mum.id, in: home.all))
    }

    @Test func theLastStandardStaysStandard() {
        #expect(ProfileEditRules.kinds(for: home.gran.id, in: [home.gran, home.kid]) == [.standard])
        #expect(ProfileEditRules.kinds(for: home.mum.id, in: home.all) == ProfileKind.allCases)
        #expect(ProfileEditRules.kinds(for: nil, in: home.all) == ProfileKind.allCases)
    }
}

@Suite struct SourceVisibilityTests {
    let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    let removed = UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!
    var all: [UUID] { [a, b, c] }

    @Test func emptyMeansEverySource() {
        #expect(SourceVisibility.isVisible(a, in: []))
        #expect(SourceVisibility.isVisible(a, in: [a]))
        #expect(!SourceVisibility.isVisible(b, in: [a]))
    }

    @Test func theLastVisibleSourceCantBeHidden() {
        #expect(SourceVisibility.canHide(a, visible: [], allSourceIDs: all))
        #expect(!SourceVisibility.canHide(a, visible: [a], allSourceIDs: all))
        #expect(SourceVisibility.canHide(a, visible: [a, b], allSourceIDs: all))
        #expect(!SourceVisibility.canHide(a, visible: [], allSourceIDs: [a]))
        // A hidden source's switch is already off; turning it "off" again is harmless.
        #expect(SourceVisibility.canHide(b, visible: [a], allSourceIDs: all))
    }

    @Test func hidingOneFromAllListsTheRest() {
        #expect(SourceVisibility.toggled(b, isOn: false, visible: [], allSourceIDs: all) == [a, c])
    }

    @Test func turningEverySourceBackOnCollapsesToAll() {
        #expect(SourceVisibility.toggled(b, isOn: true, visible: [a, c], allSourceIDs: all) == [])
    }

    @Test func hidingTheLastVisibleSourceIsRefused() {
        #expect(SourceVisibility.toggled(a, isOn: false, visible: [a], allSourceIDs: all) == [a])
    }

    @Test func removedSourcesKeepTheirSetting() {
        #expect(SourceVisibility.toggled(b, isOn: true, visible: [a, removed], allSourceIDs: all) == [a, b, removed])
        #expect(SourceVisibility.toggled(a, isOn: false, visible: [a, b, removed], allSourceIDs: all) == [b, removed])
    }

    @Test func removedSourcesDontCountAsVisible() {
        // Only `a` of the current sources is on, so it can't go, whatever
        // the set remembers about a removed source.
        #expect(!SourceVisibility.canHide(a, visible: [a, removed], allSourceIDs: all))
    }
}

@Suite struct ProfileDraftTests {
    let record = ProfileRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!, name: "Leo", kind: .kids, avatarColor: .teal,
        avatarSymbol: "star.fill", sortOrder: 3, hasPIN: true, allowedCategoryKeys: ["cartoons"], hiddenCategoryKeys: ["news"],
        visibleSourceIDs: [UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!], audioLanguage: "en", subtitleLanguage: "fr"
    )

    @Test func startsFromTheRecord() {
        let draft = ProfileDraft(record: record)
        #expect(draft.name == "Leo")
        #expect(draft.kind == .kids)
        #expect(draft.avatarColor == .teal)
        #expect(draft.avatarSymbol == "star.fill")
        #expect(draft.allowedCategoryKeys == ["cartoons"])
        #expect(draft.hiddenCategoryKeys == ["news"])
        #expect(draft.visibleSourceIDs == record.visibleSourceIDs)
        #expect(draft.audioLanguage == "en")
        #expect(draft.subtitleLanguage == "fr")
        #expect(draft.pinChange == .unchanged)
    }

    @Test func applyingRoundTripsAnUnchangedDraft() {
        #expect(ProfileDraft(record: record).applied(to: record) == record)
    }

    @Test func aNewProfileTakesTheFirstUnusedColour() {
        #expect(ProfileDraft.new(existing: []).avatarColor == .amber)
        let existing = [ProfileRecord(name: "A", avatarColor: .amber), ProfileRecord(name: "B", avatarColor: .lavender)]
        let draft = ProfileDraft.new(existing: existing)
        #expect(draft.avatarColor == .teal)
        #expect(draft.name.isEmpty)
        #expect(draft.kind == .standard)
        #expect(!draft.isValid)
    }

    @Test func withEveryColourTakenItCyclesByCount() {
        let existing = MemberPalette.order.map { ProfileRecord(name: "x", avatarColor: $0) }
        #expect(ProfileDraft.new(existing: existing).avatarColor == MemberPalette.palette(at: existing.count))
    }

    @Test func aBlankNameIsInvalid() {
        var draft = ProfileDraft(record: record)
        draft.name = "  \n "
        #expect(!draft.isValid)
        draft.name = "  Leo "
        #expect(draft.isValid)
        #expect(draft.trimmedName == "Leo")
    }

    @Test func savedNamesAreTrimmedAndCapped() {
        var draft = ProfileDraft(record: record)
        draft.name = "  Bartholomew Montgomery-Smythe  "
        let saved = draft.applied(to: record)
        #expect(saved.name == "Bartholomew Montgomery-S")
        #expect(saved.name.count == ProfileDraft.maxNameLength)
    }

    @Test func onlyKidsKeepAnAllowedList() {
        var draft = ProfileDraft(record: record)
        draft.kind = .standard
        let saved = draft.applied(to: record)
        #expect(saved.kind == .standard)
        #expect(saved.allowedCategoryKeys.isEmpty)
        #expect(saved.hiddenCategoryKeys == ["news"])
    }

    @Test func applyingLeavesWhatTheDraftDoesntOwn() {
        var draft = ProfileDraft(record: record)
        draft.name = "Leonard"
        draft.avatarColor = .rose
        draft.avatarSymbol = nil
        draft.pinChange = .remove
        let saved = draft.applied(to: record)
        #expect(saved.id == record.id)
        #expect(saved.sortOrder == 3)
        // The PIN goes through `setPIN` on Save, not through the record.
        #expect(saved.hasPIN)
        #expect(saved.name == "Leonard")
        #expect(saved.avatarColor == .rose)
        #expect(saved.avatarSymbol == nil)
    }

    @Test func willHavePINFollowsTheStagedChange() {
        var draft = ProfileDraft(record: record)
        #expect(draft.willHavePIN(hadPIN: true))
        #expect(!draft.willHavePIN(hadPIN: false))
        draft.pinChange = .set("1234")
        #expect(draft.willHavePIN(hadPIN: false))
        draft.pinChange = .remove
        #expect(!draft.willHavePIN(hadPIN: true))
    }
}

@Suite struct EditorChoicesTests {
    let english = Locale(identifier: "en_US")

    @Test func everyAvatarSymbolHasASpokenName() {
        #expect(Set(AvatarSymbols.all).count == AvatarSymbols.all.count)
        for symbol in AvatarSymbols.all {
            #expect(AvatarSymbols.spokenName(symbol) != symbol, "\(symbol) has no spoken name")
        }
        #expect(AvatarSymbols.spokenName("not.a.symbol") == "not.a.symbol")
    }

    @Test func everyColourHasASpokenName() {
        let names = AvatarPalette.allCases.map(\.spokenName)
        #expect(Set(names).count == AvatarPalette.allCases.count)
        #expect(AvatarPalette.amber.spokenName == "Amber")
    }

    @Test func languagesAreNamedAndSortedByName() {
        let options = LanguageOptions.options(locale: english)
        #expect(options.count == LanguageOptions.codes.count)
        #expect(Set(options.map(\.code)) == Set(LanguageOptions.codes))
        let names = options.map(\.name)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(options.first { $0.code == "de" }?.name == "German")
    }

    @Test func aProfilesUnlistedLanguageIsKept() {
        let options = LanguageOptions.options(keeping: ["ga", nil, "en"], locale: english)
        #expect(options.count == LanguageOptions.codes.count + 1)
        #expect(options.contains { $0.code == "ga" })
        #expect(options.filter { $0.code == "en" }.count == 1)
    }

    @Test func languageNamesFollowTheLocale() {
        #expect(LanguageOptions.name(for: "fr", locale: english) == "French")
        #expect(LanguageOptions.name(for: "de", locale: Locale(identifier: "fr_FR")) == "Allemand")
    }
}
