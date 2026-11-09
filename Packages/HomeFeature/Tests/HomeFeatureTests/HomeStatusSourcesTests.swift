import CatalogKit
import Foundation
import HouseholdKit
import Testing
@testable import HomeFeature

/// Home draws its sections only when `HomeStatus` is `.ready`, so which
/// sources count decides what a first run sees.
@Suite struct HomeStatusSourcesTests {
    let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private func record(_ id: UUID, name: String, isRemoved: Bool = false) -> SourceRecord {
        SourceRecord(id: id, name: name, kindRaw: "m3u", isRemoved: isRemoved)
    }

    @Test func noSourcesAnywhere() {
        #expect(HomeStatus.make(catalogSourceIDs: [], records: [], refreshStates: [:]) == .noSources)
    }

    /// The store's sources reach the catalog a moment after launch: no flash
    /// of "Add a source" at a household that has one.
    @Test func aSourceOnlyTheStoreHasYetCounts() {
        let status = HomeStatus.make(catalogSourceIDs: [], records: [record(a, name: "Provider A")], refreshStates: [:])
        #expect(status == .firstRefresh(sourceName: nil, progress: nil, message: nil))
    }

    @Test func aRemovedSourceDoesntCount() {
        let status = HomeStatus.make(catalogSourceIDs: [], records: [record(a, name: "Provider A", isRemoved: true)], refreshStates: [:])
        #expect(status == .noSources)
    }

    @Test func theStoreNamesTheCatalogsSources() {
        let states = [a: SourceRefreshState(sourceID: a, phase: .refreshing(progress: 0.5, message: "Channels"))]
        let status = HomeStatus.make(catalogSourceIDs: [a], records: [record(a, name: "Provider A")], refreshStates: states)
        #expect(status == .firstRefresh(sourceName: "Provider A", progress: 0.5, message: "Channels"))
    }

    @Test func aSourceInBothIsOneSource() {
        let states = [a: SourceRefreshState(sourceID: a, phase: .failed(message: "Server unreachable"))]
        let status = HomeStatus.make(catalogSourceIDs: [a], records: [record(a, name: "Provider A")], refreshStates: states)
        #expect(status == .failed(sourceID: a, sourceName: "Provider A", message: "Server unreachable"))
    }

    /// One source imported is enough: the other's failure doesn't hide Live TV.
    @Test func anImportedSourceMakesItReady() {
        let states = [
            a: SourceRefreshState(sourceID: a, channelCount: 12),
            b: SourceRefreshState(sourceID: b, phase: .failed(message: "Server unreachable")),
        ]
        let status = HomeStatus.make(catalogSourceIDs: [a], records: [record(a, name: "Provider A"), record(b, name: "Provider B")], refreshStates: states)
        #expect(status == .ready)
    }
}
