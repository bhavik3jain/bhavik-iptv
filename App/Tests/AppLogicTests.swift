import CatalogKit
import Foundation
import HouseholdKit
import SourceKit
import Testing
@testable import Hearth

// The app shell's mapping and filtering decisions (AppLogic.swift). The
// logins below are made up for the test, never a real provider's.

@Suite struct AppSourceMappingTests {
    let login = SourceCredentials(
        macAddress: "00:1A:79:00:00:01",
        username: "test-user",
        password: "test-pass",
        playlistURL: "https://playlist.invalid/list.m3u",
        guideURL: "https://guide.invalid/xmltv.xml",
        serialNumber: "SN-TEST",
        deviceID: "DEVICE-1",
        deviceID2: "DEVICE-2",
        signature: "SIG",
        model: "MAG254",
        timeZone: "Europe/London"
    )

    @Test func carriesEveryFieldOfTheLogin() throws {
        let record = SourceRecord(id: TestIDs.sourceA, name: "Provider A", kindRaw: "stalker", serverURL: "http://portal.invalid/c/", credentials: login)
        let configuration = try #require(AppSourceMapping.configuration(from: record))
        #expect(configuration == SourceConfiguration(
            id: TestIDs.sourceA,
            name: "Provider A",
            kind: .stalker,
            serverURL: "http://portal.invalid/c/",
            macAddress: "00:1A:79:00:00:01",
            username: "test-user",
            password: "test-pass",
            playlistURL: "https://playlist.invalid/list.m3u",
            guideURL: "https://guide.invalid/xmltv.xml",
            serialNumber: "SN-TEST",
            deviceID: "DEVICE-1",
            deviceID2: "DEVICE-2",
            signature: "SIG",
            model: "MAG254",
            timeZone: "Europe/London"
        ))
    }

    @Test(arguments: [("stalker", SourceKind.stalker), ("xtream", .xtream), ("m3u", .m3u)])
    func mapsEveryKnownKind(raw: String, kind: SourceKind) {
        let record = SourceRecord(name: "Source", kindRaw: raw)
        #expect(AppSourceMapping.configuration(from: record)?.kind == kind)
    }

    /// A kind written by a newer build on another device is left out, not
    /// guessed; so is a kind in the wrong case.
    @Test(arguments: ["dvb", "", "Stalker"])
    func anUnknownKindIsLeftOut(raw: String) {
        #expect(AppSourceMapping.configuration(from: SourceRecord(name: "Future", kindRaw: raw)) == nil)
    }

    @Test func keepsTheHouseholdsOrderAndDropsRemovedAndUnknownSources() {
        let records = [
            SourceRecord(id: TestIDs.sourceC, name: "C", kindRaw: "m3u"),
            SourceRecord(name: "Removed", kindRaw: "xtream", isRemoved: true),
            SourceRecord(name: "Unknown", kindRaw: "dvb"),
            SourceRecord(id: TestIDs.sourceA, name: "A", kindRaw: "stalker"),
            SourceRecord(id: TestIDs.sourceB, name: "B", kindRaw: "xtream"),
        ]
        #expect(AppSourceMapping.configurations(from: records).map(\.id) == [TestIDs.sourceC, TestIDs.sourceA, TestIDs.sourceB])
        #expect(AppSourceMapping.configurations(from: []).isEmpty)
    }
}

@Suite struct CatalogFilterBuilderTests {
    func household(hidesAdult: Bool = true, adult: Set<String> = ["a/live/xxx"]) -> HouseholdInfo {
        HouseholdInfo(id: UUID(), name: "Test Household", createdAt: referenceDate, adultCategoryKeys: adult, hidesAdultEverywhere: hidesAdult)
    }

    /// The gate is up: the default filter, which hides adult categories even
    /// when the household doesn't.
    @Test(arguments: [true, false])
    func noProfileHidesAdultAndNothingElse(householdHides: Bool) {
        let filter = CatalogFilterBuilder.filter(profile: nil, household: household(hidesAdult: householdHides))
        #expect(filter == CatalogFilter(hidesAdult: true, adultCategoryIDs: ["a/live/xxx"]))
    }

    @Test func kidsSeeOnlyTheirAllowedCategoriesAndNeverAdult() {
        let kids = ProfileRecord(name: "Kids", kind: .kids, allowedCategoryKeys: ["a/live/kids", "a/vod/family"], hiddenCategoryKeys: ["a/live/kids-2"])
        let filter = CatalogFilterBuilder.filter(profile: kids, household: household(hidesAdult: false))
        #expect(filter.allowedCategoryIDs == ["a/live/kids", "a/vod/family"])
        #expect(filter.hiddenCategoryIDs == ["a/live/kids-2"])
        #expect(filter.hidesAdult)
        #expect(filter.adultCategoryIDs == ["a/live/xxx"])
    }

    /// An empty allow list is "nothing allowed", not "everything".
    @Test func kidsWithNoAllowedCategoriesSeeNone() {
        let kids = ProfileRecord(name: "Kids", kind: .kids)
        let filter = CatalogFilterBuilder.filter(profile: kids, household: household())
        #expect(filter.allowedCategoryIDs == [])
    }

    /// Only a Kids profile is limited to allowed categories; a standard or
    /// guest profile's stray allow list (from when it was Kids) is ignored.
    @Test(arguments: [ProfileKind.standard, .guest])
    func otherProfilesAreNotLimitedToAllowedCategories(kind: ProfileKind) {
        let profile = ProfileRecord(name: "Anya", kind: kind, allowedCategoryKeys: ["a/live/kids"], hiddenCategoryKeys: ["a/live/news"])
        let filter = CatalogFilterBuilder.filter(profile: profile, household: household())
        #expect(filter.allowedCategoryIDs == nil)
        #expect(filter.hiddenCategoryIDs == ["a/live/news"])
    }

    @Test(arguments: [true, false])
    func adultFollowsTheHouseholdForAdults(householdHides: Bool) {
        let profile = ProfileRecord(name: "Bhavik")
        let filter = CatalogFilterBuilder.filter(profile: profile, household: household(hidesAdult: householdHides))
        #expect(filter.hidesAdult == householdHides)
        #expect(filter.adultCategoryIDs == ["a/live/xxx"])
    }

    /// No chosen sources means all of them (nil), never "none".
    @Test func visibleSourcesAreNilWhenNoneAreChosen() {
        let all = CatalogFilterBuilder.filter(profile: ProfileRecord(name: "Bhavik"), household: household())
        #expect(all.visibleSourceIDs == nil)

        let some = ProfileRecord(name: "Anya", visibleSourceIDs: [TestIDs.sourceB])
        #expect(CatalogFilterBuilder.filter(profile: some, household: household()).visibleSourceIDs == [TestIDs.sourceB])
    }
}

@Suite struct HouseholdNamingTests {
    @Test func surnameMakesTheHouseholdAndGivenNameTheProfile() {
        #expect(HouseholdNaming.names(fullName: "Bhavik Jain") == .init(household: "Jain Household", profile: "Bhavik"))
        #expect(HouseholdNaming.names(fullName: "  Anya Jain\n") == .init(household: "Jain Household", profile: "Anya"))
    }

    /// One name: the person's profile, and the neutral household name.
    @Test func aSingleNameKeepsTheDefaultHousehold() {
        #expect(HouseholdNaming.names(fullName: "Cher") == .init(household: "My Household", profile: "Cher"))
    }

    @Test(arguments: [nil, "", "   ", "mobile", "root", "Admin", " ADMINISTRATOR ", "user", "Guest", "owner"] as [String?])
    func noNameOrAnAccountNameFallsBack(fullName: String?) {
        #expect(HouseholdNaming.names(fullName: fullName) == .init(household: "My Household", profile: "Me"))
    }
}

@Suite struct KeyRewriteCandidatesTests {
    let a = TestIDs.sourceA
    let b = TestIDs.sourceB

    @Test func keepsChannelMovieAndSeriesKeysOfRefreshedSources() {
        let raw = [
            ItemKey.channel(source: a, id: "101").rawValue,
            ItemKey.movie(source: a, id: "m1").rawValue,
            ItemKey.series(source: a, id: "s1").rawValue,
            ItemKey.movie(source: b, id: "m2").rawValue,
        ]
        let keys = KeyRewriteCandidates.keys(raw, refreshedSources: [a])
        #expect(keys.map(\.rawValue) == Array(raw.prefix(3)))
    }

    /// Episodes load lazily and catch-up keys are never in the catalog, so
    /// neither is a candidate; nor is a key with no source or kind.
    @Test func leavesOutEpisodesCatchupAndMalformedKeys() {
        let channel = ItemKey.channel(source: a, id: "101").rawValue
        let raw = [
            ItemKey.episode(source: a, seriesID: "s1", season: 1, number: 2).rawValue,
            channel + "@1800000000.0",
            "not-a-key",
            "\(a.uuidString)/podcast/1",
            channel,
        ]
        #expect(KeyRewriteCandidates.keys(raw, refreshedSources: [a]).map(\.rawValue) == [channel])
    }

    @Test func dedupesInFirstSeenOrder() {
        let one = ItemKey.movie(source: a, id: "1").rawValue
        let two = ItemKey.movie(source: a, id: "2").rawValue
        #expect(KeyRewriteCandidates.keys([two, one, two, one], refreshedSources: [a]).map(\.rawValue) == [two, one])
        #expect(KeyRewriteCandidates.keys([one], refreshedSources: []).isEmpty)
    }

    /// The first observation is the baseline: nothing counts as refreshed.
    @Test func theFirstObservationIsTheBaseline() {
        #expect(KeyRewriteCandidates.refreshedSources(previous: [:], current: [a: referenceDate]).isEmpty)
    }

    @Test func aLaterDateOrANewSourceIsARefresh() {
        let previous = [a: referenceDate, b: referenceDate]
        let current = [
            a: referenceDate.addingTimeInterval(60),
            b: referenceDate,
            TestIDs.sourceC: referenceDate,
        ]
        #expect(KeyRewriteCandidates.refreshedSources(previous: previous, current: current) == [a, TestIDs.sourceC])
    }

    @Test func anOlderOrMissingDateIsNot() {
        let previous = [a: referenceDate, b: referenceDate]
        let current = [a: referenceDate.addingTimeInterval(-60)]
        #expect(KeyRewriteCandidates.refreshedSources(previous: previous, current: current).isEmpty)
    }
}
