import CatalogKit
import Core
import Foundation
import HouseholdKit
import Testing
@testable import HomeFeature

@Suite struct HomeStatusTests {
    let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    var names: [UUID: String] { [a: "Provider A", b: "Provider B"] }

    @Test func noSourcesYet() {
        #expect(HomeStatus.make(sourceIDs: [], names: [:], refreshStates: [:]) == .noSources)
        // Stale states for sources that were removed don't count.
        #expect(HomeStatus.make(sourceIDs: [], names: names, refreshStates: [a: SourceRefreshState(sourceID: a, movieCount: 9)]) == .noSources)
    }

    @Test(arguments: [
        SourceRefreshState(sourceID: UUID(), catalogRefreshedAt: Fixture.reference),
        SourceRefreshState(sourceID: UUID(), channelCount: 1),
        SourceRefreshState(sourceID: UUID(), movieCount: 1),
        SourceRefreshState(sourceID: UUID(), seriesCount: 1),
    ])
    func anyImportedContentCountsAsACatalog(state: SourceRefreshState) {
        #expect(HomeStatus.hasCatalog(state))
    }

    @Test func anEmptyStateIsNoCatalog() {
        #expect(!HomeStatus.hasCatalog(SourceRefreshState(sourceID: a)))
        #expect(!HomeStatus.hasCatalog(SourceRefreshState(sourceID: a, phase: .refreshing(progress: 0.9, message: "Movies"), guideRefreshedAt: Fixture.reference)))
    }

    @Test func oneImportedSourceIsEnoughForHome() {
        let states: [UUID: SourceRefreshState] = [
            a: SourceRefreshState(sourceID: a, phase: .failed(message: "Server unreachable")),
            b: SourceRefreshState(sourceID: b, phase: .refreshing(progress: 0.2, message: "Channels"), channelCount: 120),
        ]
        #expect(HomeStatus.make(sourceIDs: [a, b], names: names, refreshStates: states) == .ready)
    }

    @Test func aFirstImportShowsItsProgress() {
        let states = [a: SourceRefreshState(sourceID: a, phase: .refreshing(progress: 0.4, message: "Downloading movies"))]
        #expect(HomeStatus.make(sourceIDs: [a], names: names, refreshStates: states)
                == .firstRefresh(sourceName: "Provider A", progress: 0.4, message: "Downloading movies"))
    }

    @Test func anEmptyProgressMessageIsNoMessage() {
        let states = [a: SourceRefreshState(sourceID: a, phase: .refreshing(progress: nil, message: ""))]
        #expect(HomeStatus.make(sourceIDs: [a], names: names, refreshStates: states)
                == .firstRefresh(sourceName: "Provider A", progress: nil, message: nil))
    }

    @Test func theFirstRefreshingSourceInHouseholdOrderIsShown() {
        let states: [UUID: SourceRefreshState] = [
            a: SourceRefreshState(sourceID: a, phase: .refreshing(progress: 0.1, message: "A")),
            b: SourceRefreshState(sourceID: b, phase: .refreshing(progress: 0.9, message: "B")),
        ]
        #expect(HomeStatus.make(sourceIDs: [b, a], names: names, refreshStates: states)
                == .firstRefresh(sourceName: "Provider B", progress: 0.9, message: "B"))
    }

    @Test func aRunningImportOutranksAFailedOne() {
        let states: [UUID: SourceRefreshState] = [
            a: SourceRefreshState(sourceID: a, phase: .failed(message: "Bad login")),
            b: SourceRefreshState(sourceID: b, phase: .refreshing(progress: nil, message: "Channels")),
        ]
        #expect(HomeStatus.make(sourceIDs: [a, b], names: names, refreshStates: states)
                == .firstRefresh(sourceName: "Provider B", progress: nil, message: "Channels"))
    }

    @Test func failedOnlyWhenEverySourceFailed() {
        let states: [UUID: SourceRefreshState] = [
            a: SourceRefreshState(sourceID: a, phase: .failed(message: "Bad login")),
            b: SourceRefreshState(sourceID: b, phase: .failed(message: "Timed out")),
        ]
        #expect(HomeStatus.make(sourceIDs: [a, b], names: names, refreshStates: states)
                == .failed(sourceID: a, sourceName: "Provider A", message: "Bad login"))
        #expect(HomeStatus.make(sourceIDs: [b, a], names: names, refreshStates: states)
                == .failed(sourceID: b, sourceName: "Provider B", message: "Timed out"))
    }

    @Test func oneFailureBesideAQueuedSourceIsStillWaiting() {
        let states = [a: SourceRefreshState(sourceID: a, phase: .failed(message: "Bad login"))]
        // b has no state at all: idle, waiting its turn.
        #expect(HomeStatus.make(sourceIDs: [a, b], names: names, refreshStates: states)
                == .firstRefresh(sourceName: nil, progress: nil, message: nil))
    }

    @Test func aSourceWithNoStateYetIsQueued() {
        #expect(HomeStatus.make(sourceIDs: [a], names: names, refreshStates: [:])
                == .firstRefresh(sourceName: nil, progress: nil, message: nil))
    }

    @Test func aFailedSourceWithNoNameStillFails() {
        let states = [a: SourceRefreshState(sourceID: a, phase: .failed(message: "Bad login"))]
        #expect(HomeStatus.make(sourceIDs: [a], names: [:], refreshStates: states)
                == .failed(sourceID: a, sourceName: nil, message: "Bad login"))
    }
}

@Suite struct SyncChipTests {
    @Test func saysWhetherFavoritesSync() {
        let synced = SyncChipContent.make(.upToDate(Fixture.reference))
        #expect(synced?.title == "Synced")
        #expect(synced?.systemImage == "cloud")

        let syncing = SyncChipContent.make(.syncing)
        #expect(syncing?.title == "Syncing")
        #expect(syncing?.systemImage == "arrow.triangle.2.circlepath.icloud")

        let failed = SyncChipContent.make(.failed("Quota exceeded"))
        #expect(failed?.title == "Not synced")
        #expect(failed?.systemImage == "exclamationmark.icloud")
    }

    @Test func noChipOnADeviceThatIsntSyncing() {
        #expect(SyncChipContent.make(.local) == nil)
        #expect(SyncChipContent.make(.noAccount) == nil)
    }
}

@Suite struct HomeGreetingTests {
    /// Gregorian in UTC, so the hour boundaries don't move with the machine.
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: hour, minute: minute))!
    }

    @Test(arguments: [(5, 0), (8, 30), (11, 59)])
    func morning(hour: Int, minute: Int) {
        #expect(HomeGreeting.text(name: "Anya", at: at(hour, minute), calendar: calendar) == "Good morning, Anya")
    }

    @Test(arguments: [(12, 0), (14, 15), (16, 59)])
    func afternoon(hour: Int, minute: Int) {
        #expect(HomeGreeting.text(name: "Anya", at: at(hour, minute), calendar: calendar) == "Good afternoon, Anya")
    }

    @Test(arguments: [(17, 0), (23, 59), (0, 0), (4, 59)])
    func evening(hour: Int, minute: Int) {
        #expect(HomeGreeting.text(name: "Anya", at: at(hour, minute), calendar: calendar) == "Good evening, Anya")
    }

    @Test func theHourIsReadInTheCalendarsTimeZone() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 23:00 UTC is 08:00 in Tokyo.
        #expect(HomeGreeting.text(name: "Anya", at: at(23), calendar: tokyo) == "Good morning, Anya")
    }

    @Test(arguments: [nil, "", "   "] as [String?])
    func noNameSaysHome(name: String?) {
        #expect(HomeGreeting.text(name: name, at: at(9), calendar: calendar) == "Home")
    }

    @Test func theNameIsTrimmed() {
        #expect(HomeGreeting.text(name: "  Anya ", at: at(9), calendar: calendar) == "Good morning, Anya")
    }
}
