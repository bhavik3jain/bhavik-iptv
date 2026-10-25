import Foundation
import Testing
@testable import PlayerKit

/// The model's retry, fallback, event and navigation logic, against fake
/// engines: no AVPlayer, no VLCKit, no network.
@MainActor
@Suite("PlayerModel")
struct PlayerModelTests {
    let engines = FakeEngines()
    let log = EventLog()

    private func makeModel(
        _ item: PlayerItem,
        configuration: PlayerConfiguration = .test(),
        kinds: Set<EngineKind> = [.avPlayer, .vlc],
        navigator: PlayerModel.Navigator? = nil
    ) -> PlayerModel {
        let model = PlayerModel(item: item, navigator: navigator, configuration: configuration, engineFactory: engines.factory(kinds))
        model.onEvent = { [log] in log.record($0) }
        return model
    }

    // MARK: Starting (PLY-1)

    @Test func startsOnTheChosenEngineAndEmitsStartedOnce() async throws {
        let resolver = ScriptedResolver(Streams.hls)
        let model = makeModel(channel(102, "Fieldhouse Sports", resolver: resolver))

        await model.start()
        let engine = try #require(engines.last)
        #expect(engine.kind == .avPlayer)
        #expect(engine.loaded.map(\.url) == [Streams.hls.url])
        #expect(engine.playCount == 1)
        #expect(model.state == .loading)
        #expect(resolver.requests == [.standard])

        engine.simulate(.playing)
        engine.simulate(.buffering)
        engine.simulate(.playing)
        #expect(model.state == .playing)
        #expect(model.engineKind == .avPlayer)
        #expect(log.events == [.started(itemID: "ch-102")])

        await model.start()
        #expect(resolver.requests.count == 1, "start() runs once")
        model.close()
    }

    @Test func rawTransportStreamsGoStraightToVLC() async throws {
        let model = makeModel(channel(102, "Fieldhouse Sports", resolver: ScriptedResolver(Streams.liveTS)))
        await model.start()
        #expect(engines.last?.kind == .vlc)
        model.close()
    }

    @Test func movieResumesFromItsStartPosition() async throws {
        let model = makeModel(movie(resolver: ScriptedResolver(Streams.movie), startPosition: 1234))
        await model.start()
        #expect(engines.last?.loaded.first?.startPosition == 1234)
        model.close()
    }

    // MARK: Retry and fallback (PLY-4)

    @Test func avPlayerFailureIsRetriedOnceOnVLCWithAFreshLink() async throws {
        let resolver = ScriptedResolver(Streams.hls)
        let model = makeModel(channel(102, "Fieldhouse Sports", resolver: resolver))
        await model.start()
        let first = try #require(engines.last)

        first.simulate(.failed("HTTP 403: Forbidden"))
        #expect(await eventually { engines.made.count == 2 && engines.last?.loaded.isEmpty == false })
        let second = try #require(engines.last)
        #expect(second.kind == .vlc)
        #expect(first.stopCount >= 1, "the failed engine lets go of its stream")
        #expect(resolver.requests == [.standard, .standard], "the retry asks for a fresh link")
        #expect(model.state == .loading)

        second.simulate(.playing)
        #expect(model.state == .playing)
        #expect(model.engineKind == .vlc)
        #expect(log.events == [.started(itemID: "ch-102")], "a retry that works shows no failure")
        model.close()
    }

    @Test func avPlayerThatDoesNotStartInTimeIsRetriedOnVLC() async throws {
        let model = makeModel(
            channel(102, "Fieldhouse Sports", resolver: ScriptedResolver(Streams.hls)),
            configuration: .test(startTimeout: 0.05)
        )
        await model.start()
        #expect(engines.last?.kind == .avPlayer)
        #expect(await eventually { engines.last?.kind == .vlc && engines.last?.loaded.isEmpty == false })
        model.close()
    }

    @Test func pausedBeforeTheFirstFrameIsNotATimeout() async throws {
        let model = makeModel(
            channel(102, "Fieldhouse Sports", resolver: ScriptedResolver(Streams.hls)),
            configuration: .test(startTimeout: 0.05)
        )
        await model.start()
        engines.last?.simulate(.paused)
        try await Task.sleep(for: .milliseconds(150))
        #expect(engines.made.count == 1)
        model.close()
    }

    @Test func secondFailureShowsTheProvidersMessage() async throws {
        let resolver = ScriptedResolver(Streams.hls)
        let model = makeModel(channel(102, "Fieldhouse Sports", resolver: resolver))
        await model.start()
        engines.last?.simulate(.failed("HTTP 403: Forbidden"))
        #expect(await eventually { engines.last?.kind == .vlc && engines.last?.loaded.isEmpty == false })

        // VLCKit's own failure carries no detail; AVPlayer's first one did.
        engines.last?.simulate(.failed(PlayerMessage.vlcCouldNotOpen))
        #expect(model.state == .failed("HTTP 403: Forbidden"))
        #expect(log.events.last == .failed(itemID: "ch-102", message: "HTTP 403: Forbidden"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(resolver.requests.count == 2, "only one automatic retry")
        model.close()
    }

    @Test func resolverFailureIsRetriedThenShown() async throws {
        let resolver = ScriptedResolver([.failure("Your subscription has expired.")])
        let model = makeModel(channel(102, "Fieldhouse Sports", resolver: resolver))
        await model.start()
        #expect(await eventually { model.state == .failed("Your subscription has expired.") })
        #expect(resolver.requests.count == 2)
        #expect(engines.made.isEmpty)
        #expect(log.events == [.failed(itemID: "ch-102", message: "Your subscription has expired.")])
        model.close()
    }

    @Test func retryAfterTheErrorStartsAgainWithItsOwnRetry() async throws {
        let resolver = ScriptedResolver([.failure("Busy"), .failure("Busy"), .stream(Streams.hls)])
        let model = makeModel(channel(102, "Fieldhouse Sports", resolver: resolver))
        await model.start()
        #expect(await eventually { model.state.failureMessage != nil })

        await model.retry()
        #expect(resolver.requests.count == 3)
        engines.last?.simulate(.playing)
        #expect(model.state == .playing)
        #expect(log.events.last == .started(itemID: "ch-102"))
        model.close()
    }

    @Test func withoutVLCAVPlayerTriesAndTheMessageSaysWhy() async throws {
        let model = makeModel(
            channel(102, "Fieldhouse Sports", resolver: ScriptedResolver(Streams.liveTS)),
            kinds: [.avPlayer]
        )
        await model.start()
        let engine = try #require(engines.last)
        #expect(engine.kind == .avPlayer)

        engine.simulate(.failed("Cannot Open"))
        #expect(await eventually { engine.loaded.count == 2 })
        #expect(engines.made.count == 1, "the same AVPlayer engine is reused")
        engine.simulate(.failed("Cannot Open"))
        #expect(model.state == .failed(PlayerMessage.vlcMissing))
        model.close()
    }

    @Test func aStreamThatPlayedForAMinuteEarnsAnotherRetry() async throws {
        let model = makeModel(channel(102, "Fieldhouse Sports", resolver: ScriptedResolver(Streams.hls)))
        await model.start()
        let engine = try #require(engines.last)
        engine.simulate(.playing)
        model.tick(elapsed: 61)

        // Died after playing: retried on the engine that worked.
        engine.simulate(.failed("The network connection was lost."))
        #expect(await eventually { engine.loaded.count == 2 })
        engine.simulate(.playing)
        model.tick(elapsed: 61)
        engine.simulate(.failed("The network connection was lost."))
        #expect(await eventually { engine.loaded.count == 3 })

        // Died again straight away: that's the error screen.
        engine.simulate(.playing)
        engine.simulate(.failed("The network connection was lost."))
        #expect(model.state == .failed("The network connection was lost."))
        #expect(log.events.filter { if case .stopped = $0 { true } else { false } }.count == 1)
        model.close()
    }

    @Test func liveStreamEndingCountsAsAFailure() async throws {
        let model = makeModel(channel(102, "Fieldhouse Sports", resolver: ScriptedResolver(Streams.liveTS)))
        await model.start()
        let engine = try #require(engines.last)
        engine.simulate(.playing)
        engine.simulate(.ended)
        #expect(await eventually { engine.loaded.count == 2 }, "retried, not finished")
        #expect(!log.events.contains(.finished(itemID: "ch-102", duration: nil)))
        model.close()
    }

    // MARK: Events

    @Test func checkpointsComeEveryFiveMinutesOfPlayingOnly() async throws {
        let model = makeModel(movie(resolver: ScriptedResolver(Streams.movie)))
        await model.start()
        let engine = try #require(engines.last)
        engine.duration = 3600
        engine.simulate(.playing)

        for _ in 0..<299 { model.tick(elapsed: 1) }
        #expect(log.events == [.started(itemID: "movie-7")], "nothing per second")
        engine.currentTime = 300
        model.tick(elapsed: 1)
        #expect(log.events.last == .checkpoint(itemID: "movie-7", position: 300, duration: 3600))

        engine.currentTime = 420
        model.pause()
        #expect(log.events.last == .paused(itemID: "movie-7", position: 420, duration: 3600))
        model.tick(elapsed: 600)
        #expect(log.events.count == 3, "paused time doesn't count")

        model.play()
        #expect(model.state == .playing)
        #expect(log.events.count == 3, "resuming isn't a new start")

        model.close()
        #expect(log.events.last == .stopped(itemID: "movie-7", position: 420, duration: 3600))
        #expect(model.state == .idle)
    }

    @Test func checkpointNowWritesProgressForTheBackground() async throws {
        let model = makeModel(movie(resolver: ScriptedResolver(Streams.movie)))
        model.checkpointNow()
        #expect(log.events.isEmpty, "nothing before it starts")
        await model.start()
        engines.last?.currentTime = 50
        engines.last?.simulate(.playing)
        model.checkpointNow()
        #expect(log.events.last == .checkpoint(itemID: "movie-7", position: 50, duration: nil))
        model.close()
    }

    @Test func finishingEmitsFinishedAndNoStop() async throws {
        let model = makeModel(movie(resolver: ScriptedResolver(Streams.movie)))
        await model.start()
        let engine = try #require(engines.last)
        engine.duration = 5400
        engine.simulate(.playing)
        engine.simulate(.ended)
        #expect(log.events.last == .finished(itemID: "movie-7", duration: 5400))
        #expect(model.state == .ended)

        model.close()
        #expect(log.events.last == .finished(itemID: "movie-7", duration: 5400), "no stop after a finish")
    }

    @Test func replayAfterTheEndIsANewStart() async throws {
        let model = makeModel(movie(resolver: ScriptedResolver(Streams.movie)))
        await model.start()
        let engine = try #require(engines.last)
        engine.simulate(.playing)
        engine.simulate(.ended)
        model.play()
        #expect(log.events == [.started(itemID: "movie-7"), .finished(itemID: "movie-7", duration: nil), .started(itemID: "movie-7")])
        model.close()
    }

    @Test func closingCallsOnCloseOnce() async throws {
        let model = makeModel(movie(resolver: ScriptedResolver(Streams.movie)))
        var closes = 0
        model.onClose = { closes += 1 }
        await model.start()
        model.close()
        model.close()
        #expect(closes == 1)
        #expect(engines.last?.stopCount ?? 0 >= 1)
    }

    // MARK: Channels (LIV-5)

    @Test func channelUpAndPreviousChannel() async throws {
        let resolver = ScriptedResolver(Streams.hls)
        let channels = [
            channel(101, "Cityline News", resolver: resolver),
            channel(102, "Fieldhouse Sports", resolver: resolver),
            channel(103, "Lantern Drama", resolver: resolver),
        ]
        let navigator: PlayerModel.Navigator = { current, offset in
            guard let index = channels.firstIndex(where: { $0.id == current.id }) else { return nil }
            return channels.indices.contains(index + offset) ? channels[index + offset] : nil
        }
        let model = makeModel(channels[1], navigator: navigator)
        #expect(model.previousItemTitle == "101 Cityline News")
        #expect(model.nextItemTitle == "103 Lantern Drama")
        #expect(!model.canGoToLastItem)

        await model.start()
        let engine = try #require(engines.last)
        engine.currentTime = 30
        engine.simulate(.playing)

        await model.goToNextItem()
        #expect(model.item.id == "ch-103")
        #expect(Array(log.events.suffix(2)) == [
            .stopped(itemID: "ch-102", position: 30, duration: nil),
            .switched(fromItemID: "ch-102", toItemID: "ch-103"),
        ])
        #expect(engines.made.count == 1, "same engine kind is reused")
        #expect(engine.loaded.count == 2)
        #expect(model.nextItemTitle == nil)
        #expect(!model.canGoToNextItem)
        #expect(model.previousItemTitle == "102 Fieldhouse Sports")
        engine.simulate(.playing)
        #expect(log.events.last == .started(itemID: "ch-103"))

        #expect(model.lastItemTitle == "102 Fieldhouse Sports")
        await model.goToLastItem()
        #expect(model.item.id == "ch-102")
        #expect(model.lastItemTitle == "103 Lantern Drama", "previous channel flips back and forth")
        model.close()
    }

    // MARK: Live (PLY-2, PLY-5)

    @Test func liveOffsetFollowsTheWindowAndJumpToLiveSeeksToItsEnd() async throws {
        let model = makeModel(channel(102, "Fieldhouse Sports", resolver: ScriptedResolver(Streams.hls)))
        await model.start()
        let engine = try #require(engines.last)
        engine.duration = 60
        engine.currentTime = 50
        engine.simulate(.playing)
        #expect(model.liveOffset == 0)
        #expect(model.isAtLiveEdge)

        engine.currentTime = 20
        model.tick(elapsed: 1)
        #expect(model.liveOffset == 30)
        #expect(!model.isAtLiveEdge)

        await model.jumpToLive()
        #expect(engine.seeks.last == 60)
        #expect(model.liveOffset == 0)
        model.close()
    }

    @Test func skippingBackOnAWindowSeeksWithinIt() async throws {
        let model = makeModel(channel(102, "Fieldhouse Sports", resolver: ScriptedResolver(Streams.hls)))
        await model.start()
        let engine = try #require(engines.last)
        engine.duration = 60
        engine.currentTime = 50
        engine.simulate(.playing)

        model.skip(by: -10)
        #expect(await eventually { engine.seeks.last == 40 })
        model.close()
    }

    @Test func pausingWindowlessLiveCountsTheTimeBehind() async throws {
        let clock = TestClock()
        let model = makeModel(channel(102, "Fieldhouse Sports", resolver: ScriptedResolver(Streams.liveTS)), configuration: .test(clock: clock))
        await model.start()
        let engine = try #require(engines.last)
        engine.simulate(.playing)
        model.pause()
        clock.advance(by: 252)
        model.tick(elapsed: 1)
        #expect(model.liveOffset == 252)
        #expect(PlayerFormat.behindLive(model.liveOffset) == "\u{2212}4:12")
        model.close()
    }

    @Test func rewindingWindowlessLiveOpensTheArchive() async throws {
        let clock = TestClock()
        let now = clock.now
        let resolver = ScriptedResolver(Streams.liveTS)
        let end = now.addingTimeInterval(1800)
        let item = channel(102, "Fieldhouse Sports", resolver: resolver, hasArchive: true, programmeStart: now.addingTimeInterval(-1800), programmeEnd: end)
        let model = makeModel(item, configuration: .test(clock: clock))
        await model.start()
        engines.last?.simulate(.playing)

        model.skip(by: -10)
        #expect(await eventually { resolver.requests.count == 2 })
        let start = now.addingTimeInterval(-10)
        #expect(resolver.requests.last == .fromStart(start, duration: end.timeIntervalSince(start)))
        #expect(model.isPlayingArchive)
        #expect(engines.last?.loaded.last?.startPosition == nil, "an archive link starts where it was asked to")
        model.close()
    }

    @Test func playFromStartAsksForTheProgrammesArchive() async throws {
        let clock = TestClock()
        let start = clock.now.addingTimeInterval(-600)
        let end = clock.now.addingTimeInterval(3000)
        let resolver = ScriptedResolver(Streams.hls)
        let model = makeModel(channel(102, "Fieldhouse Sports", resolver: resolver, hasArchive: true, programmeStart: start, programmeEnd: end), configuration: .test(clock: clock))
        #expect(model.canPlayFromStart)
        await model.start()
        let engine = try #require(engines.last)
        engine.simulate(.playing)

        await model.playFromStart()
        #expect(resolver.requests.last == .fromStart(start, duration: 3600))
        #expect(model.isPlayingArchive)
        engine.currentTime = 100
        engine.simulate(.playing)
        model.tick(elapsed: 1)
        #expect(model.liveOffset == 500)
        #expect(!model.isAtLiveEdge)

        // Back to live from the archive takes a fresh live link.
        await model.jumpToLive()
        #expect(resolver.requests.last == .standard)
        #expect(!model.isPlayingArchive)
        model.close()
    }

    @Test func noArchiveMeansNoFromTheStart() {
        let model = makeModel(channel(102, "Fieldhouse Sports", resolver: ScriptedResolver(Streams.hls), programmeStart: Date()))
        #expect(!model.canPlayFromStart)
    }

    // MARK: Tracks, gravity, sound (PLY-6, PLY-7)

    @Test func preferredLanguagesArePickedWhenTracksLoadButNeverOverTheUser() async throws {
        let model = makeModel(movie(resolver: ScriptedResolver(Streams.movie)))
        model.setPreferredLanguages(audio: "deu", subtitle: "en")
        await model.start()
        let engine = try #require(engines.last)
        engine.simulate(.playing)
        engine.simulateTracks(
            audio: [
                MediaTrack(id: "a0", kind: .audio, name: "English", language: "en"),
                MediaTrack(id: "a1", kind: .audio, name: "Deutsch (AC3)", language: nil),
            ],
            subtitles: [MediaTrack(id: "t0", kind: .subtitle, name: "English SDH", language: "en-GB")]
        )
        #expect(model.selectedAudioTrackID == "a1")
        #expect(model.selectedSubtitleTrackID == "t0")

        model.selectAudioTrack(id: "a0")
        engine.simulateTracks(
            audio: engine.audioTracks + [MediaTrack(id: "a2", kind: .audio, name: "Commentary", language: "de")],
            subtitles: engine.subtitleTracks,
            selectedAudio: "a0"
        )
        #expect(model.selectedAudioTrackID == "a0", "the user's pick stands")
        model.close()
    }

    @Test func gravityAndMuteReachTheEngine() async throws {
        let model = makeModel(movie(resolver: ScriptedResolver(Streams.movie)))
        model.gravity = .zoom
        model.isMuted = true
        await model.start()
        let engine = try #require(engines.last)
        #expect(engine.gravity == .zoom)
        #expect(engine.isMuted)
        model.gravity = .fill
        model.isMuted = false
        #expect(engine.gravity == .fill)
        #expect(!engine.isMuted)
        model.close()
    }

    @Test func controlsToggleOnlyHideWhilePlaying() async throws {
        let model = makeModel(movie(resolver: ScriptedResolver(Streams.movie)))
        await model.start()
        model.toggleControls()
        #expect(model.controlsVisible, "stay up while loading")
        engines.last?.simulate(.playing)
        model.toggleControls()
        #expect(!model.controlsVisible)
        model.toggleControls()
        #expect(model.controlsVisible)
        model.autoHidesControls = false
        model.toggleControls()
        #expect(model.controlsVisible, "VoiceOver keeps them")
        model.close()
    }

    @Test func controlsHideAfterTheDelay() async throws {
        let configuration = PlayerConfiguration(publishesNowPlaying: false, controlsHideDelay: 0.05, tickInterval: 3600)
        let model = makeModel(movie(resolver: ScriptedResolver(Streams.movie)), configuration: configuration)
        await model.start()
        engines.last?.simulate(.playing)
        #expect(await eventually { !model.controlsVisible })
        model.close()
    }
}
