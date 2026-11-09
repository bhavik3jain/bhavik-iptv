import CatalogKit
import Core
import DownloadKit
import Foundation
import HouseholdKit
import PlayerKit
import SourceKit
import Testing
@testable import Hearth

// Continue on Apple TV, the app's side (App/Sources/ContinueHere.swift): the
// device carrying on ends the other device's rows and plays the same thing;
// the device that was playing stops when it sees that.

@MainActor
@Suite struct ContinueHereTests {
    private struct Harness {
        let playback: PlaybackCoordinator
        let catalog: CatalogService
        let store: HouseholdStore
        let profileID: UUID
    }

    private func makeHarness() async throws -> Harness {
        let store = try makeHouseholdStore()
        let configuration = SourceConfiguration(name: "Fixture", kind: .stalker, serverURL: "http://portal.test", macAddress: "00:1A:79:00:00:01")
        let catalog = CatalogService(storeURL: nil, clientFactory: { FixtureSourceClient(configuration: $0) })
        catalog.setSources([configuration])
        await catalog.waitForBackgroundRefreshes()
        // One stream at a time, as a Stalker MAC allows.
        _ = store.addSource(SourceRecord(id: configuration.id, name: "Fixture", kindRaw: SourceKind.stalker.rawValue, maxStreams: 1))
        let session = ProfileSession(store: store, defaults: makeDefaults())
        session.restore()
        let profileID = try #require(session.currentProfile?.id)
        let playback = PlaybackCoordinator(catalog: catalog, store: store, session: session, downloads: DownloadCenter())
        return Harness(playback: playback, catalog: catalog, store: store, profileID: profileID)
    }

    private func channel(_ name: String, in catalog: CatalogService) throws -> CatalogChannel {
        try #require(catalog.findChannels(name).first)
    }

    /// Another device's row, as iCloud brings it.
    @discardableResult
    private func elsewhere(_ channel: CatalogChannel, device: String, _ harness: Harness, slot: Int = 0) -> UUID {
        harness.store.seedPlaybackFromAnotherDevice(
            profileID: harness.profileID, sourceID: channel.sourceID, itemKey: channel.key.rawValue,
            title: channel.name, deviceName: device, startedAt: Date.now.addingTimeInterval(Double(slot) * 0.01)
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out")
    }

    @Test func carryingOnAChannelEndsTheOtherDevicesRowAndPlaysItHere() async throws {
        let harness = try await makeHarness()
        let news = try channel("Cityline", in: harness.catalog)
        let row = elsewhere(news, device: "Bhavik's iPhone", harness)
        let scene = UUID()

        harness.playback.continueHere(ContinueHereRequest(
            content: .play(PlayIntent(itemKey: news.key.rawValue, kind: .live, title: news.name)),
            endingPlaybackIDs: [row],
            deviceName: "Bhavik's iPhone"
        ), sceneID: scene, layout: .tv)

        #expect(!harness.store.activePlaybacks.contains { $0.id == row }, "the iPhone's stream is free at once")
        try await waitUntil { harness.playback.current?.model.item.channelName == "Cityline News" }
        #expect(harness.playback.presentedSession(forScene: scene) != nil)
        #expect(harness.playback.limitPrompt == nil, "its stream no longer counts against the limit")
    }

    @Test func somethingThisDeviceCantPlayLeavesTheOtherDeviceAlone() async throws {
        let harness = try await makeHarness()
        let news = try channel("Cityline", in: harness.catalog)
        let row = elsewhere(news, device: "Bhavik's iPhone", harness)
        let gone = ItemKey.channel(source: UUID(), id: "gone").rawValue

        harness.playback.continueHere(ContinueHereRequest(
            content: .play(PlayIntent(itemKey: gone, kind: .live, title: "Gone TV")),
            endingPlaybackIDs: [row],
            deviceName: "Bhavik's iPhone"
        ), sceneID: UUID(), layout: .tv)

        #expect(harness.store.activePlaybacks.contains { $0.id == row })
        #expect(harness.playback.notice?.title == "Can't play this here")
        #expect(harness.playback.current == nil)
    }

    @Test func carryingOnMultiViewOpensItWithTheChannelsThisDeviceHas() async throws {
        let harness = try await makeHarness()
        let news = try channel("Cityline", in: harness.catalog)
        let sport = try channel("Fieldhouse", in: harness.catalog)
        let rows = [elsewhere(sport, device: "MacBook Pro", harness, slot: 0), elsewhere(news, device: "MacBook Pro", harness, slot: 1)]
        let missing = ItemKey.channel(source: UUID(), id: "gone").rawValue
        let scene = UUID()

        harness.playback.continueHere(ContinueHereRequest(
            content: .multiView(channelKeys: [sport.key.rawValue, missing, news.key.rawValue]),
            endingPlaybackIDs: rows,
            deviceName: "MacBook Pro"
        ), sceneID: scene, layout: .tv)

        #expect(harness.store.activePlaybacks.isEmpty)
        #expect(harness.playback.multiViewStartingChannelKeys == [sport.key.rawValue, news.key.rawValue])
        #expect(harness.playback.multiViewSceneID == scene)
    }

    @Test func thePlayerHereStopsWhenAnotherDeviceCarriesItOn() async throws {
        let harness = try await makeHarness()
        let news = try channel("Cityline", in: harness.catalog)
        let scene = UUID()
        harness.playback.play(PlayIntent(itemKey: news.key.rawValue, kind: .live, title: news.name), sceneID: scene, layout: .compact)
        try await waitUntil { harness.playback.current != nil }
        let player = try #require(harness.playback.current)
        player.model.onEvent?(.started(itemID: player.model.item.id))
        let mine = try #require(player.playbackID)

        // The TV ends this row (what arrives looks like a delete) and plays
        // the channel itself.
        harness.store.purgeStalePlaybacks(now: .now.addingTimeInterval(PlaybackRecord.staleAfter + 1))
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.playback.current != nil, "a row gone with nothing playing it elsewhere keeps playing")
        elsewhere(news, device: "Living Room", harness)

        try await waitUntil { harness.playback.current == nil }
        #expect(!harness.store.activePlaybacks.contains { $0.id == mine })
        try await waitUntil { harness.playback.notice != nil }
        #expect(harness.playback.notice?.title == "Playing on Living Room")
        #expect(harness.playback.notice?.sceneID == scene)
    }

    @Test func seedContinueOffersIsALaunchFlag() {
        #expect(LaunchOptions(arguments: ["-SeedContinueOffers", "YES"]).seedContinueOffers)
        #expect(!LaunchOptions(arguments: []).seedContinueOffers)
    }
}

/// Moving on to the other device's last position.
@Suite struct HandoffResumeTests {
    private func row(position: TimeInterval, duration: TimeInterval = 6000, watched: Bool = false, savedAgo: TimeInterval = 0) -> ProgressRecord {
        ProgressRecord(
            profileID: TestIDs.profile, itemKey: ItemKey.movie(source: TestIDs.sourceA, id: "m1").rawValue, kind: .movie,
            position: position, duration: duration, watched: watched, updatedAt: referenceDate.addingTimeInterval(-savedAgo)
        )
    }

    private let baseline = referenceDate.addingTimeInterval(-300)

    @Test func aLaterPositionAheadOfThePlayerMovesIt() {
        #expect(HandoffResume.seekTarget(row(position: 1500), since: baseline, playerPosition: 1210, duration: 6000) == 1500)
    }

    @Test func theRowThePlayerOpenedFromDoesnt() {
        #expect(HandoffResume.seekTarget(row(position: 1500, savedAgo: 300), since: baseline, playerPosition: 1210, duration: 6000) == nil)
        #expect(HandoffResume.seekTarget(row(position: 1500, savedAgo: 900), since: baseline, playerPosition: 1210, duration: 6000) == nil)
    }

    @Test func nearWhereThePlayerIsOrBehindItDoesnt() {
        // The player's own saves, and the other device a few seconds behind.
        #expect(HandoffResume.seekTarget(row(position: 1215), since: baseline, playerPosition: 1210, duration: 6000) == nil)
        #expect(HandoffResume.seekTarget(row(position: 1100), since: baseline, playerPosition: 1210, duration: 6000) == nil)
    }

    @Test func aFinishedOneDoesnt() {
        #expect(HandoffResume.seekTarget(row(position: 5990), since: baseline, playerPosition: 1210, duration: 6000) == nil)
        #expect(HandoffResume.seekTarget(row(position: 5800, watched: true), since: baseline, playerPosition: 1210, duration: 6000) == nil)
        // No length from the player yet: the row's own.
        #expect(HandoffResume.seekTarget(row(position: 5990, duration: 6000), since: baseline, playerPosition: 1210, duration: nil) == nil)
    }

    @Test func withNoEarlierRowAnyNewPositionCounts() {
        #expect(HandoffResume.seekTarget(row(position: 900), since: nil, playerPosition: 0, duration: nil) == 900)
    }
}
