import Foundation
import Testing
@testable import HouseholdKit

@MainActor
@Suite struct ProfileSessionTests {
    // PRF-2: one profile opens by itself.
    @Test func restoreOpensTheOnlyProfile() throws {
        let store = try makeStore()
        let session = ProfileSession(store: store, defaults: makeDefaults())
        session.restore()
        #expect(session.currentProfile?.id == store.firstProfile.id)
        #expect(!session.needsProfileSelection)
    }

    @Test func restoreShowsTheGateForSeveralProfiles() throws {
        let store = try makeStore()
        store.addProfile(name: "Anya", kind: .standard, avatarColor: .teal)
        let defaults = makeDefaults()
        let session = ProfileSession(store: store, defaults: defaults)
        // Even with a last-used profile: the gate asks, as Netflix does.
        session.select(store.profiles[1])
        let relaunched = ProfileSession(store: store, defaults: defaults)
        relaunched.restore()
        #expect(relaunched.currentProfile == nil)
        #expect(relaunched.needsProfileSelection)
        #expect(relaunched.lastUsedProfileID == store.profiles[1].id)
    }

    @Test func restoreOpensTheAlwaysOpenProfile() throws {
        let store = try makeStore()
        let anya = try #require(store.addProfile(name: "Anya", kind: .standard, avatarColor: .teal))
        store.setPIN("1234", for: anya.id)
        let defaults = makeDefaults()
        ProfileSession(store: store, defaults: defaults).alwaysOpenProfileID = anya.id

        // Persisted on this device: a new session (a relaunch) reads it.
        let relaunched = ProfileSession(store: store, defaults: defaults)
        #expect(relaunched.alwaysOpenProfileID == anya.id)
        relaunched.restore()
        #expect(relaunched.currentProfile?.id == anya.id)

        relaunched.alwaysOpenProfileID = nil
        #expect(ProfileSession(store: store, defaults: defaults).alwaysOpenProfileID == nil)
    }

    @Test func aMissingAlwaysOpenProfileIsIgnored() throws {
        let store = try makeStore()
        let session = ProfileSession(store: store, defaults: makeDefaults())
        session.alwaysOpenProfileID = UUID()
        session.restore()
        #expect(session.currentProfile?.id == store.firstProfile.id)
    }

    // PRF-3: the only profile, behind a PIN, still asks.
    @Test func aLoneProfileWithAPINShowsTheGate() throws {
        let store = try makeStore()
        store.setPIN("1234", for: store.firstProfile.id)
        let session = ProfileSession(store: store, defaults: makeDefaults())
        session.restore()
        #expect(session.currentProfile == nil)
    }

    @Test func restoreWithoutAHouseholdShowsNothing() throws {
        let store = try HouseholdStore(mode: .inMemory)
        let session = ProfileSession(store: store, defaults: makeDefaults())
        session.restore()
        #expect(session.currentProfile == nil)
        // The household arriving later picks the profile by the same rules.
        store.ensureHousehold(defaultName: "Jain Household", firstProfileName: "Bhavik")
        session.refresh()
        #expect(session.currentProfile?.name == "Bhavik")
    }

    // PRF-9: remembered on this device only, never a Guest.
    @Test func selectRemembersTheLastProfileButNeverAGuest() throws {
        let store = try makeStore()
        let guest = try #require(store.addProfile(name: "Guest", kind: .guest, avatarColor: .slate))
        let defaults = makeDefaults()
        let session = ProfileSession(store: store, defaults: defaults)
        session.select(store.firstProfile)
        #expect(session.lastUsedProfileID == store.firstProfile.id)
        session.select(guest)
        #expect(session.isGuest)
        #expect(session.lastUsedProfileID == store.firstProfile.id)
    }

    // PRF-5
    @Test func leavingAGuestClearsWhatItTouched() throws {
        let store = try makeStore()
        let guest = try #require(store.addProfile(name: "Guest", kind: .guest, avatarColor: .slate))
        let session = ProfileSession(store: store, defaults: makeDefaults())
        session.select(guest)
        store.simulateImport { store in
            store.importFavorite(profileID: guest.id, itemKey: TestKeys.channel("1"), sortOrder: 1, addedAt: .now)
        }
        session.signOut()
        #expect(session.currentProfile == nil)
        #expect(store.count(HouseholdModel.Entity.favorite) == 0)

        session.select(guest)
        store.simulateImport { store in
            store.importProgress(profileID: guest.id, itemKey: TestKeys.movie("m"), position: 1, duration: 10, updatedAt: .now)
        }
        session.select(store.firstProfile)
        #expect(store.count(HouseholdModel.Entity.progress) == 0)
    }

    @Test func refreshFollowsEditsAndDeletes() throws {
        let store = try makeStore()
        let anya = try #require(store.addProfile(name: "Anya", kind: .standard, avatarColor: .teal))
        let session = ProfileSession(store: store, defaults: makeDefaults())
        session.select(anya)

        var renamed = anya
        renamed.name = "Anya J"
        renamed.kind = .kids
        store.updateProfile(renamed)
        session.refresh()
        #expect(session.currentProfile?.name == "Anya J")
        #expect(session.isKids)
        #expect(!session.canOpenSettings)
        #expect(!session.canManageHousehold)

        store.deleteProfile(id: anya.id)
        session.refresh()
        #expect(session.currentProfile == nil)
    }

    @Test func signOutKeepsTheGateUpOnRefresh() throws {
        let store = try makeStore()
        let session = ProfileSession(store: store, defaults: makeDefaults())
        session.restore()
        session.signOut()
        session.refresh()
        #expect(session.currentProfile == nil, "Switch Profile shows the gate even with one profile")
    }

    // SRC-8
    @Test func theOwnerOnAStandardProfileCanManage() throws {
        let store = try makeStore()
        let session = ProfileSession(store: store, defaults: makeDefaults())
        session.restore()
        #expect(session.canManageHousehold)
        #expect(session.canOpenSettings)
    }
}
