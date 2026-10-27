import CatalogKit
import Foundation
import SourceKit
import Testing
@testable import Hearth

// HH-6: a source's stream limit, and the same channel elsewhere.

@Suite struct StreamLimitRuleTests {
    // MARK: The limit

    /// Stalker and M3U use the owner's setting, whatever the provider says.
    @Test(arguments: [SourceKind.stalker, .m3u])
    func stalkerAndM3UUseTheOwnersSetting(kind: SourceKind) {
        #expect(StreamLimitRule.effectiveLimit(kind: kind, ownerSetting: 1, providerMax: 5) == 1)
        #expect(StreamLimitRule.effectiveLimit(kind: kind, ownerSetting: 3, providerMax: nil) == 3)
    }

    /// Zero (M3U's default) and anything below it mean unlimited.
    @Test(arguments: [SourceKind.stalker, .m3u])
    func zeroOrLessIsUnlimited(kind: SourceKind) {
        #expect(StreamLimitRule.effectiveLimit(kind: kind, ownerSetting: 0, providerMax: 2) == nil)
        #expect(StreamLimitRule.effectiveLimit(kind: kind, ownerSetting: -1, providerMax: nil) == nil)
    }

    @Test func xtreamUsesTheProvidersMaximumNotTheOwnersSetting() {
        #expect(StreamLimitRule.effectiveLimit(kind: .xtream, ownerSetting: 1, providerMax: 4) == 4)
        #expect(StreamLimitRule.effectiveLimit(kind: .xtream, ownerSetting: 3, providerMax: nil) == nil)
        #expect(StreamLimitRule.effectiveLimit(kind: .xtream, ownerSetting: 3, providerMax: 0) == nil)
    }

    /// A kind this build doesn't know still has its owner's setting.
    @Test func anUnknownKindFallsBackToTheOwnersSetting() {
        #expect(StreamLimitRule.effectiveLimit(kind: nil, ownerSetting: 2, providerMax: 9) == 2)
    }

    // MARK: The verdict

    @Test func noLimitAlwaysAllows() {
        #expect(StreamLimitRule.evaluate(limit: nil, householdInUse: 50, providerActive: 50, ownStreamsOnSource: 0) == .allowed)
        #expect(StreamLimitRule.evaluate(limit: 0, householdInUse: 50, providerActive: nil, ownStreamsOnSource: 0) == .allowed)
    }

    @Test func belowTheLimitIsAllowedAndAtItIsNot() {
        #expect(StreamLimitRule.evaluate(limit: 2, householdInUse: 1, providerActive: nil, ownStreamsOnSource: 0) == .allowed)
        #expect(StreamLimitRule.evaluate(limit: 2, householdInUse: 2, providerActive: nil, ownStreamsOnSource: 0) == .atLimit(limit: 2, outsideHousehold: 0))
        #expect(StreamLimitRule.evaluate(limit: 1, householdInUse: 3, providerActive: nil, ownStreamsOnSource: 0) == .atLimit(limit: 1, outsideHousehold: 0))
    }

    /// Xtream counts streams nobody in the household explains: someone
    /// outside it, or a row that hasn't synced yet.
    @Test func theProvidersCountBeyondTheHouseholdIsOutside() {
        #expect(StreamLimitRule.evaluate(limit: 2, householdInUse: 0, providerActive: 2, ownStreamsOnSource: 0) == .atLimit(limit: 2, outsideHousehold: 2))
        #expect(StreamLimitRule.evaluate(limit: 3, householdInUse: 1, providerActive: 3, ownStreamsOnSource: 0) == .atLimit(limit: 3, outsideHousehold: 2))
    }

    /// The household's own count wins when it is higher than the provider's
    /// (a stale provider count), and nothing is then "outside".
    @Test func theHigherOfTheTwoCountsDecides() {
        #expect(StreamLimitRule.evaluate(limit: 2, householdInUse: 2, providerActive: 1, ownStreamsOnSource: 0) == .atLimit(limit: 2, outsideHousehold: 0))
        #expect(StreamLimitRule.evaluate(limit: 3, householdInUse: 1, providerActive: 2, ownStreamsOnSource: 0) == .allowed)
    }

    /// This device's own stream is about to stop, so it isn't counted.
    @Test func ownStreamThePlayReplacesIsNotCounted() {
        #expect(StreamLimitRule.evaluate(limit: 1, householdInUse: 0, providerActive: 1, ownStreamsOnSource: 1) == .allowed)
        #expect(StreamLimitRule.evaluate(limit: 2, householdInUse: 0, providerActive: 3, ownStreamsOnSource: 1) == .atLimit(limit: 2, outsideHousehold: 2))
        // Never below zero, when the provider hasn't counted the stream yet.
        #expect(StreamLimitRule.evaluate(limit: 1, householdInUse: 0, providerActive: 0, ownStreamsOnSource: 1) == .allowed)
    }
}

@Suite struct AlternativeChannelsTests {
    let order = [TestIDs.sourceB, TestIDs.sourceA, TestIDs.sourceC]

    @Test func matchesTheNormalisedNameOnOtherSourcesInHouseholdOrder() {
        let playing = makeChannel("Fieldhouse Sports", source: TestIDs.sourceA)
        let matches = [
            playing,
            makeChannel("FIELDHOUSE  sports!", id: "c-9", source: TestIDs.sourceC, sourceName: "Provider C"),
            makeChannel("Fieldhouse Sports", id: "b-1", source: TestIDs.sourceB, sourceName: "Provider B"),
            makeChannel("Fieldhouse Sports 2", id: "b-2", source: TestIDs.sourceB, sourceName: "Provider B"),
        ]
        let candidates = AlternativeChannels.candidates(for: playing, among: matches, sourceOrder: order)
        #expect(candidates.map(\.remoteID) == ["b-1", "c-9"])
    }

    @Test func neverOffersTheSameSource() {
        let playing = makeChannel("Cityline News", source: TestIDs.sourceA)
        let sameSource = makeChannel("Cityline News", id: "other", source: TestIDs.sourceA)
        #expect(AlternativeChannels.candidates(for: playing, among: [playing, sameSource], sourceOrder: order).isEmpty)
    }

    @Test func oneCandidatePerSource() {
        let playing = makeChannel("Cityline News", source: TestIDs.sourceA)
        let matches = [
            makeChannel("Cityline News", id: "b-1", source: TestIDs.sourceB),
            makeChannel("Cityline News", id: "b-2", source: TestIDs.sourceB),
        ]
        let candidates = AlternativeChannels.candidates(for: playing, among: matches, sourceOrder: order)
        #expect(candidates.count == 1)
        #expect(candidates.first?.sourceID == TestIDs.sourceB)
    }

    /// Sources the household no longer lists come last, by name.
    @Test func sourcesOutsideTheOrderComeLastByName() {
        let unknownX = UUID()
        let unknownY = UUID()
        let playing = makeChannel("Pulse Music", source: TestIDs.sourceA)
        let matches = [
            makeChannel("Pulse Music", id: "y", source: unknownY, sourceName: "Zeta"),
            makeChannel("Pulse Music", id: "x", source: unknownX, sourceName: "Alpha"),
            makeChannel("Pulse Music", id: "c", source: TestIDs.sourceC, sourceName: "Provider C"),
        ]
        let candidates = AlternativeChannels.candidates(for: playing, among: matches, sourceOrder: order)
        #expect(candidates.map(\.remoteID) == ["c", "x", "y"])
    }

    /// A name with nothing left after normalising matches nothing.
    @Test func aNameOfOnlyPunctuationMatchesNothing() {
        let playing = makeChannel("***", source: TestIDs.sourceA)
        let other = makeChannel("***", source: TestIDs.sourceB)
        #expect(AlternativeChannels.candidates(for: playing, among: [other], sourceOrder: order).isEmpty)
    }
}
