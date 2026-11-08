import CoreData
import Foundation
import Testing
@testable import HouseholdKit

// Continue on Apple TV (docs/designs/continue-on-tv.md).

private let profile = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
private let otherProfile = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func row(
    _ itemKey: String,
    device: String = "Bhavik's iPhone",
    profileID: UUID = profile,
    title: String = "Title",
    startedAgo: TimeInterval = 60,
    seenAgo: TimeInterval = 30,
    id: UUID = UUID()
) -> PlaybackRecord {
    PlaybackRecord(
        id: id,
        deviceName: device,
        profileID: profileID,
        sourceID: TestKeys.sourceA,
        itemKey: itemKey,
        title: title,
        startedAt: now.addingTimeInterval(-startedAgo),
        lastSeenAt: now.addingTimeInterval(-seenAgo)
    )
}

private func offers(_ rows: [PlaybackRecord], own: Set<UUID> = [], device: String = "Living Room") -> [ContinueOffer] {
    ContinueOfferRules.offers(profileID: profile, playbacks: rows, ownPlaybackIDs: own, ownDeviceName: device, now: now)
}

@Suite struct ContinueOfferRulesTests {
    @Test func aChannelPlayingElsewhereIsOffered() {
        let news = row(TestKeys.channel("news"), title: "Cityline News")
        let result = offers([news])
        #expect(result.count == 1)
        #expect(result.first?.content == .channel(itemKey: TestKeys.channel("news")))
        #expect(result.first?.deviceName == "Bhavik's iPhone")
        #expect(result.first?.titles == ["Cityline News"])
        #expect(result.first?.playbackIDs == [news.id])
    }

    @Test func onlyThisProfilesFreshRowsFromOtherDevices() {
        let mine = row(TestKeys.channel("a"))
        let rows = [
            row(TestKeys.channel("b"), profileID: otherProfile),
            row(TestKeys.channel("c"), seenAgo: PlaybackRecord.staleAfter + 1),
            mine,
            row(TestKeys.channel("d"), device: "Living Room"),
            row(PlaybackRowKey.download(TestKeys.movie("m")), title: "Downloading Film"),
        ]
        #expect(offers(rows, own: [mine.id]).isEmpty)
    }

    @Test func twoOrMoreChannelsFromOneDeviceAreItsMultiViewInTileOrder() {
        let tiles = [
            row(TestKeys.channel("third"), device: "MacBook Pro", title: "Three", startedAgo: 98),
            row(TestKeys.channel("first"), device: "MacBook Pro", title: "One", startedAgo: 100),
            row(TestKeys.channel("second"), device: "MacBook Pro", title: "Two", startedAgo: 99),
        ]
        let result = offers(tiles)
        #expect(result.count == 1)
        #expect(result.first?.content == .multiView(itemKeys: [TestKeys.channel("first"), TestKeys.channel("second"), TestKeys.channel("third")]))
        #expect(result.first?.titles == ["One", "Two", "Three"])
        #expect(Set(result.first?.playbackIDs ?? []) == Set(tiles.map(\.id)))
    }

    @Test func multiViewKeepsFourTilesButEndsEveryChannelRow() {
        let tiles = (0..<5).map { row(TestKeys.channel("\($0)"), device: "Mac", startedAgo: Double(100 - $0)) }
        let duplicate = row(TestKeys.channel("0"), device: "Mac", startedAgo: 10)
        let result = offers(tiles + [duplicate])
        #expect(result.first?.itemKeys == (0..<4).map { TestKeys.channel("\($0)") })
        #expect(Set(result.first?.playbackIDs ?? []) == Set((tiles + [duplicate]).map(\.id)))
    }

    @Test func aMovieOrEpisodeOpenElsewhereIsAVideo() {
        let episode = row(TestKeys.episode("show", 2, 4), title: "The Lighthouse · S2 E4")
        let download = row(PlaybackRowKey.download(TestKeys.movie("film")), title: "Downloading Film", startedAgo: 5)
        let result = offers([episode, download])
        #expect(result.map(\.content) == [.video(itemKey: TestKeys.episode("show", 2, 4))])
        #expect(result.first?.playbackIDs == [episode.id])
    }

    @Test func theMostRecentlyStartedComesFirst() {
        let phone = row(TestKeys.channel("news"), device: "iPhone", startedAgo: 600)
        let mac = row(TestKeys.movie("film"), device: "Mac", startedAgo: 120)
        let result = offers([phone, mac])
        #expect(result.map(\.deviceName) == ["Mac", "iPhone"])
    }

    @Test func aDeviceWithAChannelAndAVideoMakesTwoOffers() {
        let result = offers([row(TestKeys.channel("news"), startedAgo: 50), row(TestKeys.movie("film"), startedAgo: 40)])
        #expect(result.map(\.content) == [.video(itemKey: TestKeys.movie("film")), .channel(itemKey: TestKeys.channel("news"))])
    }

    @Test func downloadRowKeysAreMarked() {
        let key = TestKeys.movie("film")
        #expect(PlaybackRowKey.isDownload(PlaybackRowKey.download(key)))
        #expect(!PlaybackRowKey.isDownload(key))
        #expect(ItemKeyHint.sourceID(of: PlaybackRowKey.download(key)) == TestKeys.sourceA, "the source still reads from the key")
    }
}

@Suite struct TakeoverRulesTests {
    private func written(_ key: String, seenAgo: TimeInterval = 60) -> PlaybackRecord {
        row(key, device: "Bhavik's iPhone", seenAgo: seenAgo)
    }

    @Test func goneWhileFreshAndPlayingElsewhereIsATakeover() {
        let mine = written(TestKeys.channel("news"))
        let tv = row(TestKeys.channel("news"), device: "Living Room", startedAgo: 5, seenAgo: 5)
        let result = TakeoverRules.takeover(written: [mine], present: [tv.id], others: [tv], now: now)
        #expect(result == PlaybackTakeover(endedIDs: [mine.id], deviceName: "Living Room"))
    }

    @Test func oneTileTakenOverEndsTheSessionsOtherGoneTiles() {
        let a = written(TestKeys.channel("a")), b = written(TestKeys.channel("b")), c = written(TestKeys.channel("c"))
        // The TV had a stream for one tile only; it ended all three rows.
        let tv = row(TestKeys.channel("a"), device: "Living Room", startedAgo: 5, seenAgo: 5)
        let result = TakeoverRules.takeover(written: [a, b, c], present: [tv.id], others: [tv], now: now)
        #expect(result?.endedIDs == [a.id, b.id, c.id])
    }

    @Test func aRowStillThereIsNoTakeover() {
        let mine = written(TestKeys.channel("news"))
        let tv = row(TestKeys.channel("news"), device: "Living Room")
        #expect(TakeoverRules.takeover(written: [mine], present: [mine.id, tv.id], others: [tv], now: now) == nil)
    }

    @Test func aRowGoneAfterTheWindowWasPurgedNotTakenOver() {
        // Offline past the 15 minutes: another device purged it as stale, and
        // a heartbeat writes it again (HH-5).
        let mine = written(TestKeys.channel("news"), seenAgo: TakeoverRules.window + 1)
        let tv = row(TestKeys.channel("news"), device: "Living Room")
        #expect(TakeoverRules.takeover(written: [mine], present: [tv.id], others: [tv], now: now) == nil)
    }

    @Test func aGoneRowWithNothingPlayingElsewhereIsNoTakeover() {
        // The other device ended the row but couldn't start: keep playing.
        let mine = written(TestKeys.channel("news"))
        let elsewhere = [
            row(TestKeys.channel("other"), device: "Living Room"),
            row(TestKeys.channel("news"), device: "Living Room", profileID: otherProfile),
            row(TestKeys.channel("news"), device: "Living Room", seenAgo: PlaybackRecord.staleAfter + 1),
        ]
        #expect(TakeoverRules.takeover(written: [mine], present: Set(elsewhere.map(\.id)), others: elsewhere, now: now) == nil)
    }
}

@MainActor
@Suite struct ContinueHereStoreTests {
    /// What an iCloud import of another device's row does.
    @discardableResult
    private func importPlayback(_ store: HouseholdStore, profileID: UUID, itemKey: String, device: String, startedAt: Date = .now) -> UUID {
        let id = UUID()
        store.simulateImport { store in
            let household = store.currentHouseholdEntity()!
            let row = store.insert(HouseholdModel.Entity.playback, as: PlaybackEntity.self, into: store.targetStore(for: household))
            row.id = id
            row.profileID = profileID
            row.sourceID = TestKeys.sourceA
            row.itemKey = itemKey
            row.title = "Imported"
            row.deviceName = device
            row.startedAt = startedAt
            row.lastSeenAt = .now
            row.household = household
        }
        store.rebuildSnapshots()
        return id
    }

    /// What an iCloud import of another device deleting this one's row does.
    private func importDeletion(_ store: HouseholdStore, of id: UUID) {
        store.simulateImport { store in
            store.fetch(PlaybackEntity.self, HouseholdModel.Entity.playback).filter { $0.id == id }.forEach(store.viewContext.delete)
        }
        store.rebuildSnapshots()
    }

    @Test func offersLeaveOutThisDevicesOwnRowsWhateverTheirName() throws {
        let store = try makeStore()
        let profileID = store.firstProfile.id
        store.startPlayback(profileID: profileID, sourceID: TestKeys.sourceA, itemKey: TestKeys.channel("own"), title: "Own", deviceName: "Renamed TV")
        let phone = importPlayback(store, profileID: profileID, itemKey: TestKeys.channel("news"), device: "iPhone")

        let result = store.continueOffers(profileID: profileID, deviceName: "Living Room")
        #expect(result.map(\.playbackIDs) == [[phone]])
    }

    @Test func aGuestGetsNoOffers() throws {
        let store = try makeStore()
        let guest = try #require(store.addProfile(name: "Guest", kind: .guest, avatarColor: .slate))
        importPlayback(store, profileID: guest.id, itemKey: TestKeys.channel("news"), device: "iPhone")
        #expect(store.continueOffers(profileID: guest.id, deviceName: "Living Room").isEmpty)
    }

    @Test func endingRowsFreesTheirStreamsInOneWrite() throws {
        let store = try makeStore()
        let profileID = store.firstProfile.id
        let a = importPlayback(store, profileID: profileID, itemKey: TestKeys.channel("a"), device: "Mac")
        let b = importPlayback(store, profileID: profileID, itemKey: TestKeys.channel("b"), device: "Mac")
        #expect(store.streamUsage(sourceID: TestKeys.sourceA, limit: 2).isAtLimit)

        store.endPlaybacks([a, b])
        #expect(store.count(HouseholdModel.Entity.playback) == 0)
        #expect(store.activePlaybacks.isEmpty)
        #expect(!store.streamUsage(sourceID: TestKeys.sourceA, limit: 2).isAtLimit)
    }

    @Test func theDeviceThatWasPlayingSeesTheTakeoverAndOnlyThen() throws {
        let phone = try makeStore()
        let profileID = phone.firstProfile.id
        let mine = phone.startPlayback(profileID: profileID, sourceID: TestKeys.sourceA, itemKey: TestKeys.channel("news"), title: "News", deviceName: "iPhone")
        #expect(phone.takeover(ofPlaybacks: [mine]) == nil)

        // The TV deletes the row first; its own row arrives a moment later.
        importDeletion(phone, of: mine)
        #expect(phone.takeover(ofPlaybacks: [mine]) == nil, "nothing plays it elsewhere yet")
        importPlayback(phone, profileID: profileID, itemKey: TestKeys.channel("news"), device: "Living Room")
        #expect(phone.takeover(ofPlaybacks: [mine]) == PlaybackTakeover(endedIDs: [mine], deviceName: "Living Room"))

        // The heartbeat doesn't write it back; stopping here forgets it.
        phone.heartbeat(playbackID: mine)
        #expect(!phone.activePlaybacks.contains { $0.id == mine })
        phone.stopPlayback(playbackID: mine)
        #expect(phone.takeover(ofPlaybacks: [mine]) == nil)
    }

    @Test func aRowPurgedWhileAwayIsNoTakeover() throws {
        let phone = try makeStore()
        let profileID = phone.firstProfile.id
        let mine = phone.startPlayback(profileID: profileID, sourceID: TestKeys.sourceA, itemKey: TestKeys.channel("news"), title: "News", deviceName: "iPhone")
        let later = Date.now.addingTimeInterval(PlaybackRecord.staleAfter + 60)
        phone.purgeStalePlaybacks(now: later)
        importPlayback(phone, profileID: profileID, itemKey: TestKeys.channel("news"), device: "Living Room")
        #expect(phone.takeover(ofPlaybacks: [mine], now: later) == nil)
    }

    @Test func multiViewTilesKeepTheStartTimesTheyAreGiven() throws {
        let store = try makeStore()
        let anchor = Date(timeIntervalSinceNow: -30)
        let id = store.startPlayback(profileID: store.firstProfile.id, sourceID: TestKeys.sourceA, itemKey: TestKeys.channel("a"), title: "A", deviceName: "Mac", startedAt: anchor.addingTimeInterval(2))
        let row = try #require(store.activePlaybacks.first { $0.id == id })
        #expect(abs(row.startedAt.timeIntervalSince(anchor) - 2) < 0.01)
        #expect(abs(row.lastSeenAt.timeIntervalSinceNow) < 5)
    }
}
