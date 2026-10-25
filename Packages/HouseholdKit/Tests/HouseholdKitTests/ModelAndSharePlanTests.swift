import CloudKit
import CoreData
import Foundation
import Testing
@testable import HouseholdKit

/// CloudKit's model rules fail at container load, never at compile time —
/// so they are pinned here (Multitrack's crash-at-launch lesson).
@Suite struct HouseholdModelTests {
    let model = HouseholdModel.shared

    @Test func hasTheSevenEntities() {
        #expect(Set(model.entities.compactMap(\.name)) == ["Household", "Source", "Profile", "Favorite", "Progress", "Playback", "MemberRole"])
        #expect(HouseholdModel.recordTypes.contains("CD_Household"))
    }

    @Test func everyNonOptionalAttributeHasADefault() {
        for entity in model.entities {
            for attribute in entity.attributesByName.values where !attribute.isOptional {
                #expect(attribute.defaultValue != nil, "\(entity.name ?? "?").\(attribute.name)")
            }
        }
    }

    @Test func everyRelationshipIsOptionalWithAnInverse() {
        for entity in model.entities {
            for relationship in entity.relationshipsByName.values {
                #expect(relationship.isOptional, "\(entity.name ?? "?").\(relationship.name)")
                #expect(relationship.inverseRelationship != nil, "\(entity.name ?? "?").\(relationship.name)")
                #expect(relationship.deleteRule != .denyDeleteRule)
            }
        }
    }

    @Test func nothingIsUnique() {
        for entity in model.entities {
            #expect(entity.uniquenessConstraints.isEmpty, "\(entity.name ?? "?")")
        }
    }

    // PRIV-3
    @Test func loginsAndOnlyLoginsAreEncrypted() throws {
        let source = try #require(model.entitiesByName["Source"])
        let encrypted = Set(source.attributesByName.values.filter(\.allowsCloudEncryption).map(\.name))
        #expect(encrypted == ["macAddress", "username", "password", "playlistURL", "guideURL", "serialNumber", "deviceID", "deviceID2", "signature", "model", "timeZone"])
        for entity in model.entities where entity.name != "Source" {
            let anyEncrypted = entity.attributesByName.values.contains { $0.allowsCloudEncryption }
            #expect(!anyEncrypted, "\(entity.name ?? "?")")
        }
    }

    @Test func householdIsTheRoot() throws {
        let household = try #require(model.entitiesByName["Household"])
        #expect(Set(household.relationshipsByName.keys) == ["sources", "profiles", "memberRoles", "playbacks"])
        let allToMany = household.relationshipsByName.values.allSatisfy { $0.isToMany }
        #expect(allToMany)
        let profile = try #require(model.entitiesByName["Profile"])
        #expect(profile.relationshipsByName["favorites"]?.isToMany == true)
        #expect(profile.relationshipsByName["progress"]?.isToMany == true)
    }

    @Test func enumsAreRawStrings() {
        for entity in model.entities {
            for (name, attribute) in entity.attributesByName where name.hasSuffix("Raw") {
                #expect(attribute.attributeType == .stringAttributeType, "\(entity.name ?? "?").\(name)")
            }
        }
    }
}

/// Invite's decisions (HH-2), without iCloud.
@Suite struct HouseholdSharePlanTests {
    @Test func notSharedChecksEarlierTriesThenCreatesSavesAndPresents() {
        var plan = HouseholdSharePlan()
        #expect(plan.start() == .lookUp)
        #expect(plan.handle(.lookedUp(.notShared(isSyncing: false))) == .checkEarlierTries)
        #expect(plan.handle(.earlierTriesChecked(.none)) == .create)
        #expect(plan.handle(.created(.share(hasLink: false))) == .save)
        #expect(plan.handle(.saved(.share(hasLink: true))) == .present)
        #expect(plan.step == .ready)
    }

    @Test func anExistingShareIsPresentedWithoutCreating() {
        var plan = HouseholdSharePlan()
        _ = plan.start()
        #expect(plan.handle(.lookedUp(.shared(hasLink: true, needsSave: false))) == .present)
        var titled = HouseholdSharePlan()
        _ = titled.start()
        #expect(titled.handle(.lookedUp(.shared(hasLink: true, needsSave: true))) == .save)
    }

    @Test func aFailedLookupNeverLeadsToShare() {
        var plan = HouseholdSharePlan()
        _ = plan.start()
        let error = ShareCallError.timedOut(after: .seconds(15))
        #expect(plan.handle(.lookedUp(.failed(error))) == .fail(.lookupFailed(error)))
    }

    @Test func shareIsCalledAtMostOncePerPreparation() {
        var plan = HouseholdSharePlan(ignoresEarlierTries: true)
        _ = plan.start()
        #expect(plan.handle(.lookedUp(.notShared(isSyncing: false))) == .create)
        let error = ShareCallError(domain: "CKErrorDomain", code: 4, message: "Network")
        #expect(plan.handle(.created(.failed(error))) == .waitForUpload)
        #expect(plan.handle(.uploadFinished(timedOut: false)) == .lookUp)
        // Still nothing after the upload: fail, never a second share().
        #expect(plan.handle(.lookedUp(.notShared(isSyncing: false))) == .fail(.notCreated(error)))
    }

    @Test func earlierTriesStopForShareAnyway() {
        var plan = HouseholdSharePlan()
        _ = plan.start()
        _ = plan.handle(.lookedUp(.notShared(isSyncing: false)))
        let action = plan.handle(.earlierTriesChecked(.found(["com.apple.coredata.cloudkit.share.X"])))
        #expect(action == .fail(.earlierTriesLeftCopies(1)))
        #expect(HouseholdShareError(.earlierTriesLeftCopies(1)).offersShareAnyway)
    }

    @Test func aRunningSyncIsWaitedForOnce() {
        var plan = HouseholdSharePlan()
        _ = plan.start()
        #expect(plan.handle(.lookedUp(.notShared(isSyncing: true))) == .waitForSync)
        #expect(plan.handle(.syncSettled(timedOut: true)) == .lookUp)
        #expect(plan.handle(.lookedUp(.notShared(isSyncing: true))) == .checkEarlierTries)
        #expect(HouseholdSharePlan.isWorthWaiting(forSyncSince: .now.addingTimeInterval(-10)))
        #expect(!HouseholdSharePlan.isWorthWaiting(forSyncSince: .now.addingTimeInterval(-600)))
        #expect(!HouseholdSharePlan.isWorthWaiting(forSyncSince: nil))
    }

    @Test func aMissingLinkIsWaitedForThenReported() {
        var plan = HouseholdSharePlan()
        _ = plan.start()
        #expect(plan.handle(.lookedUp(.shared(hasLink: false, needsSave: false))) == .fetchLink)
        #expect(plan.handle(.linkFetched(.share(hasLink: false))) == .waitForUpload)
        #expect(plan.handle(.uploadFinished(timedOut: false)) == .fetchLink)
        #expect(plan.handle(.linkFetched(.share(hasLink: false))) == .waitForUpload)
        #expect(plan.handle(.uploadFinished(timedOut: true)) == .fetchLink)
        #expect(plan.handle(.linkFetched(.share(hasLink: false))) == .fail(.noLink(nil)))
    }

    @Test func shareCallLedgerJoinsARunningCall() {
        var ledger = ShareCallLedger<String>()
        #expect(ledger.begin("h") == .call)
        #expect(ledger.begin("h") == .join)
        ledger.end("h")
        #expect(ledger.begin("h") == .call)
    }

    @Test func leftoverZonesAreCoreDataShareZonesOtherThanTheCurrent() {
        let current = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone")
        let leftover = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.share.ABC")
        let other = CKRecordZone.ID(zoneName: "SomethingElse")
        #expect(LeftoverShareZones.candidates([current, leftover, other], besides: current) == [leftover])
        #expect(LeftoverShareZones.candidates([leftover], besides: leftover).isEmpty)
    }

    @Test func boundedWaitReturnsNilAfterItsLimit() async {
        let answer: Int? = await Bounded.wait(.milliseconds(50)) { (_: @escaping @Sendable (Int) -> Void) in }
        #expect(answer == nil)
        let quick: Int? = await Bounded.wait(.seconds(5)) { done in done(7) }
        #expect(quick == 7)
    }

    @Test func syncStatusFromEvents() {
        var state = CloudEventLedger.State()
        #expect(CloudEventLedger.status(state) == .syncing)
        let done = Date(timeIntervalSince1970: 100)
        state.lastSuccessAt = done
        #expect(CloudEventLedger.status(state) == .upToDate(done))
        state.lastFailure = "Network"
        state.lastFailureAt = done.addingTimeInterval(5)
        #expect(CloudEventLedger.status(state) == .failed("Network"))
    }

    @Test func ledgerRecordsImports() {
        let ledger = CloudEventLedger()
        let id = UUID()
        let start = Date(timeIntervalSince1970: 10)
        ledger.record(CloudEvent(id: id, store: "S", kind: .import, start: start, end: nil, succeeded: false))
        #expect(ledger.isSyncing(in: ["S"]))
        #expect(!ledger.hasImported(store: "S"))
        ledger.record(CloudEvent(id: id, store: "S", kind: .import, start: start, end: start.addingTimeInterval(2), succeeded: true))
        #expect(!ledger.isSyncing(in: ["S"]))
        #expect(ledger.hasImported(store: "S"))
        #expect(ledger.importEnded(after: start, in: ["S"]))
        #expect(!ledger.importEnded(after: start.addingTimeInterval(5), in: ["S"]))
    }
}
