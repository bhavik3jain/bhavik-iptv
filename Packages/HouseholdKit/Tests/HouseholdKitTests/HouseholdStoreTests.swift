import Core
import CoreData
import Foundation
import Testing
@testable import HouseholdKit

@MainActor
@Suite struct HouseholdTests {
    @Test func inMemoryStoreOpensWithoutAHousehold() throws {
        let store = try HouseholdStore(mode: .inMemory)
        #expect(!store.hasHousehold)
        #expect(store.profiles.isEmpty)
        #expect(store.syncStatus == .local)
        #expect(store.members.count == 1)
    }

    // HH-1
    @Test func ensureHouseholdCreatesOneWithAStandardProfile() throws {
        let store = try makeStore()
        #expect(store.hasHousehold)
        #expect(store.household.name == "Jain Household")
        #expect(store.household.currentRole == .owner)
        #expect(!store.household.isShared)
        #expect(store.household.hidesAdultEverywhere)
        #expect(store.profiles.map(\.name) == ["Bhavik"])
        #expect(store.profiles.first?.kind == .standard)
        #expect(store.members.map(\.role) == [.owner])
        #expect(store.members.first?.displayName == "Bhavik")
    }

    @Test func ensureHouseholdIsIdempotent() throws {
        let store = try makeStore()
        let id = store.household.id
        store.ensureHousehold(defaultName: "Other Household", firstProfileName: "Someone")
        store.ensureHousehold(defaultName: "Jain Household", firstProfileName: "Bhavik")
        #expect(store.household.id == id)
        #expect(store.household.name == "Jain Household")
        #expect(store.profiles.count == 1)
        #expect(store.count(HouseholdModel.Entity.household) == 1)
        #expect(store.count(HouseholdModel.Entity.profile) == 1)
    }

    @Test func prepareHouseholdReturnsWithTheHousehold() async throws {
        let store = try HouseholdStore(mode: .inMemory)
        await store.prepareHousehold(defaultName: "Jain Household", firstProfileName: "Bhavik")
        #expect(store.hasHousehold)
    }

    /// What an import looks like from the store's side: another context saves,
    /// the view context merges, and the snapshots follow after the debounce.
    @Test func changesFromAnotherContextRebuildSnapshots() async throws {
        let store = try makeStore()
        let revision = store.revision
        let householdID = try #require(store.currentHouseholdEntity()).objectID
        let context = store.container.newBackgroundContext()
        try await context.perform {
            let profile = NSEntityDescription.insertNewObject(forEntityName: HouseholdModel.Entity.profile, into: context)
            profile.setValue(UUID(), forKey: "id")
            profile.setValue("Anya", forKey: "name")
            profile.setValue(1, forKey: "sortOrder")
            profile.setValue(context.object(with: householdID), forKey: "household")
            try context.save()
        }
        for _ in 0..<60 where store.profiles.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.profiles.map(\.name) == ["Bhavik", "Anya"])
        #expect(store.revision > revision)
    }

    @Test func householdSettingsAreSaved() throws {
        let store = try makeStore()
        let revision = store.revision
        store.renameHousehold("  Patel Household ")
        store.setAdultCategoryKeys(["s1/cat/9", "s1/cat/4"])
        store.setHidesAdultEverywhere(false)
        #expect(store.household.name == "Patel Household")
        #expect(store.household.adultCategoryKeys == ["s1/cat/9", "s1/cat/4"])
        #expect(!store.household.hidesAdultEverywhere)
        #expect(store.revision > revision)

        store.renameHousehold("   ")
        #expect(store.household.name == "Patel Household")
    }
}

@MainActor
@Suite struct ProfileTests {
    // PRF-1
    @Test func atMostEightProfiles() throws {
        let store = try makeStore()
        for index in 1..<HouseholdStore.maxProfiles {
            #expect(store.addProfile(name: "Profile \(index)", kind: .standard, avatarColor: .teal) != nil)
        }
        #expect(store.profiles.count == 8)
        #expect(store.addProfile(name: "Ninth", kind: .kids, avatarColor: .rose) == nil)
        #expect(store.profiles.count == 8)
    }

    @Test func addedProfilesGoAtTheEnd() throws {
        let store = try makeStore()
        let kids = try #require(store.addProfile(name: "Anya", kind: .kids, avatarColor: .lavender, avatarSymbol: "star.fill"))
        let guest = try #require(store.addProfile(name: "Guest", kind: .guest, avatarColor: .slate))
        #expect(store.profiles.map(\.id) == [store.firstProfile.id, kids.id, guest.id])
        #expect(kids.avatarSymbol == "star.fill")
        #expect(kids.isKids)
        #expect(guest.isGuest)
    }

    @Test func updateProfileWritesItsRules() throws {
        let store = try makeStore()
        var profile = store.firstProfile
        profile.name = "Bhavik J"
        profile.avatarColor = .blue
        profile.hiddenCategoryKeys = ["a", "b"]
        profile.visibleSourceIDs = [TestKeys.sourceA]
        profile.audioLanguage = "hi"
        store.updateProfile(profile)
        let saved = store.firstProfile
        #expect(saved.name == "Bhavik J")
        #expect(saved.avatarColor == .blue)
        #expect(saved.hiddenCategoryKeys == ["a", "b"])
        #expect(saved.visibleSourceIDs == [TestKeys.sourceA])
        #expect(saved.audioLanguage == "hi")
        #expect(saved.subtitleLanguage == nil)
    }

    @Test func deletingAProfileDeletesItsFavoritesAndProgress() throws {
        let store = try makeStore()
        let other = try #require(store.addProfile(name: "Anya", kind: .standard, avatarColor: .teal))
        store.toggleFavorite(profileID: other.id, itemKey: TestKeys.channel("1"), kind: .channel)
        store.saveProgress(profileID: other.id, itemKey: TestKeys.movie("m"), kind: .movie, position: 60, duration: 600)
        #expect(store.count(HouseholdModel.Entity.favorite) == 1)
        #expect(store.count(HouseholdModel.Entity.progress) == 1)

        store.deleteProfile(id: other.id)
        #expect(store.profiles.map(\.id) == [store.firstProfile.id])
        #expect(store.count(HouseholdModel.Entity.favorite) == 0)
        #expect(store.count(HouseholdModel.Entity.progress) == 0)
    }

    // HH-7: favorites always belong to a profile, so the last one stays.
    @Test func theLastProfileCantBeDeleted() throws {
        let store = try makeStore()
        store.deleteProfile(id: store.firstProfile.id)
        #expect(store.profiles.count == 1)
    }

    @Test func moveProfilesReorders() throws {
        let store = try makeStore()
        let bhavik = store.firstProfile.id
        let anya = try #require(store.addProfile(name: "Anya", kind: .standard, avatarColor: .teal))
        let ravi = try #require(store.addProfile(name: "Ravi", kind: .kids, avatarColor: .coral))
        store.moveProfiles(fromOffsets: [2], toOffset: 0)
        #expect(store.profiles.map(\.id) == [ravi.id, bhavik, anya.id])
        #expect(store.profiles.map(\.sortOrder) == [0, 1, 2])
    }

    // PAR-3
    @Test func pinIsSetVerifiedAndCleared() throws {
        let store = try makeStore()
        let id = store.firstProfile.id
        #expect(!store.firstProfile.hasPIN)
        #expect(store.verifyPIN("0000", for: id), "no PIN asks for none")

        store.setPIN("4821", for: id)
        #expect(store.firstProfile.hasPIN)
        #expect(store.verifyPIN("4821", for: id))
        #expect(!store.verifyPIN("4822", for: id))

        // Stored salted, never as the PIN.
        let entity = try #require(store.profileEntity(id))
        #expect(entity.pinHash != "4821")
        #expect(!entity.pinSalt.isEmpty)
        #expect(entity.pinHash == PINHasher.hash(pin: "4821", salt: entity.pinSalt))

        store.setPIN("12", for: id)
        #expect(store.verifyPIN("4821", for: id), "an invalid PIN changes nothing")

        store.setPIN(nil, for: id)
        #expect(!store.firstProfile.hasPIN)
        #expect(store.verifyPIN("9999", for: id))
    }

    @Test func pinOfAnUnknownProfileNeverVerifies() throws {
        let store = try makeStore()
        #expect(!store.verifyPIN("1234", for: UUID()))
    }

    // PRF-5: turning a profile into a Guest drops what it kept.
    @Test func becomingAGuestDeletesKeptData() throws {
        let store = try makeStore()
        let other = try #require(store.addProfile(name: "Visitor", kind: .standard, avatarColor: .teal))
        store.toggleFavorite(profileID: other.id, itemKey: TestKeys.channel("1"), kind: .channel)
        store.saveProgress(profileID: other.id, itemKey: TestKeys.movie("m"), kind: .movie, position: 60, duration: 600)
        var guest = other
        guest.kind = .guest
        store.updateProfile(guest)
        #expect(store.count(HouseholdModel.Entity.favorite) == 0)
        #expect(store.count(HouseholdModel.Entity.progress) == 0)
    }
}

@MainActor
@Suite struct SourceTests {
    static func stalker(name: String = "Portal", id: UUID = TestKeys.sourceA) -> SourceRecord {
        SourceRecord(
            id: id,
            name: name,
            kindRaw: "stalker",
            serverURL: "http://portal.example/c/",
            maxStreams: 1,
            credentials: SourceCredentials(macAddress: "00:1A:79:00:00:01", serialNumber: "SN", deviceID: "D1")
        )
    }

    @Test func addedSourceKeepsItsLogin() throws {
        let store = try makeStore()
        let added = store.addSource(Self.stalker())
        #expect(store.sources.map(\.id) == [TestKeys.sourceA])
        #expect(added.credentials.macAddress == "00:1A:79:00:00:01")
        #expect(store.sources[0].credentials.deviceID == "D1")
        #expect(store.sources[0].sortOrder == 0)

        let second = store.addSource(Self.stalker(name: "Second", id: TestKeys.sourceB))
        #expect(second.sortOrder == 1)
        #expect(store.sources.map(\.name) == ["Portal", "Second"])
    }

    @Test func addingAnExistingSourceUpdatesIt() throws {
        let store = try makeStore()
        store.addSource(Self.stalker())
        store.addSource(Self.stalker(name: "Renamed"))
        #expect(store.sources.map(\.name) == ["Renamed"])
        #expect(store.count(HouseholdModel.Entity.source) == 1)
    }

    @Test func updateAndExpiry() throws {
        let store = try makeStore()
        var source = store.addSource(Self.stalker())
        source.maxStreams = 2
        source.credentials.password = "secret"
        store.updateSource(source)
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        store.setSourceExpiry(expiry, for: source.id)
        #expect(store.sources[0].maxStreams == 2)
        #expect(store.sources[0].credentials.password == "secret")
        #expect(store.sources[0].expiresAt == expiry)
    }

    // SRC-9
    @Test func removingASourceHidesItsFavoritesAndProgressUntilItReturns() throws {
        let store = try makeStore()
        let profile = store.firstProfile.id
        store.addSource(Self.stalker())
        store.addSource(Self.stalker(name: "Other", id: TestKeys.sourceB))
        store.toggleFavorite(profileID: profile, itemKey: TestKeys.channel("1"), kind: .channel)
        store.toggleFavorite(profileID: profile, itemKey: TestKeys.channel("9", source: TestKeys.sourceB), kind: .channel)
        store.saveProgress(profileID: profile, itemKey: TestKeys.movie("m"), kind: .movie, position: 60, duration: 600)

        store.removeSource(id: TestKeys.sourceA)
        #expect(store.sources.map(\.id) == [TestKeys.sourceB])
        #expect(store.removedSources().map(\.id) == [TestKeys.sourceA])
        #expect(store.favorites(profileID: profile, kind: .channel).map(\.itemKey) == [TestKeys.channel("9", source: TestKeys.sourceB)])
        #expect(store.continueWatching(profileID: profile).isEmpty)
        // Hidden, not deleted.
        #expect(store.count(HouseholdModel.Entity.favorite) == 2)
        #expect(store.count(HouseholdModel.Entity.progress) == 1)

        store.restoreSource(id: TestKeys.sourceA)
        #expect(Set(store.sources.map(\.id)) == [TestKeys.sourceA, TestKeys.sourceB])
        #expect(store.removedSources().isEmpty)
        #expect(store.favorites(profileID: profile, kind: .channel).count == 2)
        #expect(store.continueWatching(profileID: profile).map(\.itemKey) == [TestKeys.movie("m")])
    }
}
