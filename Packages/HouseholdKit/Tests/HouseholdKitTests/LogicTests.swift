import CoreData
import Foundation
import Testing
@testable import HouseholdKit

@Suite struct FractionalOrderTests {
    @Test func movedMatchesSwiftUIMove() {
        let items = ["a", "b", "c", "d"]
        #expect(FractionalOrder.moved(items, fromOffsets: [3], toOffset: 1) == ["a", "d", "b", "c"])
        #expect(FractionalOrder.moved(items, fromOffsets: [0], toOffset: 4) == ["b", "c", "d", "a"])
        #expect(FractionalOrder.moved(items, fromOffsets: [0, 2], toOffset: 4) == ["b", "d", "a", "c"])
        #expect(FractionalOrder.moved(items, fromOffsets: [1], toOffset: 1) == items)
    }

    @Test func aMoveWritesOnlyTheMovedRow() {
        let orders: [Double] = [1, 2, 3, 4]
        #expect(FractionalOrder.writes(orders: orders, fromOffsets: [3], toOffset: 1) == [3: 1.5])
        #expect(FractionalOrder.writes(orders: orders, fromOffsets: [0], toOffset: 4) == [0: 5])
        #expect(FractionalOrder.writes(orders: orders, fromOffsets: [3], toOffset: 0) == [3: 0])
        #expect(FractionalOrder.writes(orders: orders, fromOffsets: [1], toOffset: 1).isEmpty)
    }

    @Test func aGapTooSmallToSplitRenumbers() {
        let orders: [Double] = [1, 1 + 1e-12, 3]
        let writes = FractionalOrder.writes(orders: orders, fromOffsets: [2], toOffset: 1)
        // New order: index 0, 2, 1 → 0, 1, 2.
        #expect(writes == [0: 0, 2: 1, 1: 2])
    }
}

@Suite struct ItemKeyHintTests {
    @Test func readsSourceKindAndEpisode() {
        let source = TestKeys.sourceA
        #expect(ItemKeyHint.sourceID(of: TestKeys.movie("x")) == source)
        #expect(ItemKeyHint.sourceID(of: "not-a-uuid/movie/x") == nil)
        #expect(ItemKeyHint.kind(of: TestKeys.channel("9")) == "channel")
        let episode = ItemKeyHint.episode(of: TestKeys.episode("show%2F1", 3, 7))
        #expect(episode?.seriesKey == TestKeys.series("show%2F1"))
        #expect(episode?.season == 3)
        #expect(episode?.episode == 7)
        #expect(ItemKeyHint.episode(of: TestKeys.movie("x")) == nil)
        #expect(ItemKeyHint.progressKind(of: TestKeys.episode("s", 1, 1)) == .episode)
        #expect(ItemKeyHint.progressKind(of: TestKeys.movie("x")) == .movie)
        #expect(ItemKeyHint.progressKind(of: TestKeys.channel("x")) == .catchup)
    }
}

@Suite struct MemberListTests {
    @Test func beforeSharingTheOwnerIsTheOnlyMember() {
        let members = MemberList.make(participants: [], roles: [:], ownerFallbackName: "Bhavik")
        #expect(members == [MemberRecord(id: MemberList.ownerID, displayName: "Bhavik", role: .owner, isCurrentUser: true)])
    }

    @Test func participantsTakeTheOwnersRoleRows() {
        let participants = [
            ShareParticipantInfo(id: "p2", displayName: "Zara", isOwner: false, isCurrentUser: false),
            ShareParticipantInfo(id: "p1", displayName: "Bhavik", isOwner: true, isCurrentUser: true),
            ShareParticipantInfo(id: "p3", displayName: "Anya", isOwner: false, isCurrentUser: false),
            ShareParticipantInfo(id: "p4", displayName: "Gone", isOwner: false, isCurrentUser: false, isRemoved: true),
        ]
        let members = MemberList.make(participants: participants, roles: ["p2": .manage, "p3": .owner], ownerFallbackName: "x")
        #expect(members.map(\.id) == ["p1", "p3", "p2"])
        #expect(members.map(\.role) == [.owner, .watch, .manage], "a role row can't make someone the owner")
    }

    // SRC-8
    @Test func currentRole() {
        #expect(MemberList.currentRole(isParticipant: false, currentParticipantID: nil, roles: [:]) == .owner)
        #expect(MemberList.currentRole(isParticipant: true, currentParticipantID: "p2", roles: ["p2": .manage]) == .manage)
        // Until the owner's row arrives, a participant only watches.
        #expect(MemberList.currentRole(isParticipant: true, currentParticipantID: "p2", roles: [:]) == .watch)
        #expect(MemberList.currentRole(isParticipant: true, currentParticipantID: nil, roles: ["p2": .manage]) == .watch)
        #expect(MemberList.currentRole(isParticipant: true, currentParticipantID: "p2", roles: ["p2": .owner]) == .watch)
    }

    @Test func conflictingRoleRowsGrantTheLesser() {
        #expect(MemberList.foldedRole([.manage, .watch]) == .watch)
        #expect(MemberList.foldedRole([.manage, .manage]) == .manage)
        #expect(MemberList.foldedRole([]) == .watch)
    }

    @Test func rolesGateManaging() {
        #expect(MemberRole.owner.canManage)
        #expect(MemberRole.manage.canManage)
        #expect(!MemberRole.watch.canManage)
    }
}

@MainActor
@Suite struct RoleStoreTests {
    // SRC-8: MemberRole rows are owner-written.
    @Test func theOwnerWritesOneRoleRowPerParticipant() throws {
        let store = try makeStore()
        store.setRole(.manage, forParticipant: "p2")
        store.setRole(.watch, forParticipant: "p2")
        store.setRole(.owner, forParticipant: "p3")
        store.setRole(.manage, forParticipant: "")
        let rows = store.fetch(MemberRoleEntity.self, HouseholdModel.Entity.memberRole)
        #expect(rows.map(\.participantID) == ["p2"])
        #expect(rows.first?.role == .watch)
        #expect(store.rolesByParticipant(in: try #require(store.currentHouseholdEntity())) == ["p2": .watch])
    }

    @Test func roleRowsFallBackForUnknownValues() throws {
        let store = try makeStore()
        store.simulateImport { store in
            let household = store.currentHouseholdEntity()!
            let row = store.insert(HouseholdModel.Entity.memberRole, as: MemberRoleEntity.self, into: store.targetStore(for: household))
            row.participantID = "p9"
            row.roleRaw = "superuser"
            row.household = household
        }
        #expect(store.rolesByParticipant(in: try #require(store.currentHouseholdEntity())) == ["p9": .watch])
    }

    @Test func sharingNeedsICloud() async throws {
        let store = try makeStore()
        await #expect(throws: HouseholdShareError.iCloudUnavailable) { try await store.prepareShare() }
        await #expect(throws: HouseholdShareError.iCloudUnavailable) { try await store.leaveHousehold() }
        await store.refreshFromCloud()
    }
}

@Suite struct JSONListTests {
    @Test func roundTripsSortedAndToleratesGarbage() {
        #expect(JSONList.encode(["b", "a"]) == #"["a","b"]"#)
        #expect(JSONList.decode(#"["a","b"]"#) == ["a", "b"])
        #expect(JSONList.decode("not json").isEmpty)
        let ids: Set<UUID> = [TestKeys.sourceA, TestKeys.sourceB]
        #expect(JSONList.decodeUUIDs(JSONList.encode(ids)) == ids)
    }
}

@Suite struct ProfileRestoreTests {
    @Test func pickRules() {
        let one = ProfileRecord(name: "A")
        let locked = ProfileRecord(name: "L", hasPIN: true)
        let two = ProfileRecord(name: "B")
        #expect(ProfileRestore.pick(alwaysOpen: nil, profiles: [one]) == one)
        #expect(ProfileRestore.pick(alwaysOpen: nil, profiles: [locked]) == nil)
        #expect(ProfileRestore.pick(alwaysOpen: nil, profiles: [one, two]) == nil)
        #expect(ProfileRestore.pick(alwaysOpen: two.id, profiles: [one, two]) == two)
        #expect(ProfileRestore.pick(alwaysOpen: locked.id, profiles: [one, locked]) == locked)
        #expect(ProfileRestore.pick(alwaysOpen: UUID(), profiles: [one, two]) == nil)
        #expect(ProfileRestore.pick(alwaysOpen: nil, profiles: []) == nil)
    }
}
