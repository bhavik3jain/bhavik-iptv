import CatalogKit
import Core
import Foundation
import HouseholdKit
import Testing
@testable import HomeFeature

/// "Continue from <device>" on the TV's Home: which offers become cards and
/// what each asks the app to play.
@Suite struct ContinueOfferCardTests {
    static func channel(_ id: String, name: String) -> CatalogChannel {
        CatalogChannel(
            key: .channel(source: Fixture.source, id: id), sourceID: Fixture.source, sourceName: "Provider A",
            remoteID: id, number: 7, name: name, logoURL: URL(string: "https://example.com/\(id).png"),
            categoryID: nil, guideChannelID: id, hasArchive: false, archiveDays: 0
        )
    }

    let news = channel("news", name: "Cityline News")
    let sport = channel("sport", name: "Fieldhouse Sports")
    let programme = CatalogProgramme(
        id: "p", sourceID: Fixture.source, guideChannelID: "news",
        start: Fixture.reference.addingTimeInterval(-600), end: Fixture.reference.addingTimeInterval(1200),
        title: "Evening Bulletin", summary: nil, category: nil, hasArchive: false
    )
    let ids = [UUID(), UUID()]

    private func offer(_ content: ContinueOffer.Content) -> ContinueOffer {
        ContinueOffer(content: content, deviceName: "Bhavik's iPhone", profileID: Fixture.profile, titles: [], playbackIDs: ids, startedAt: Fixture.reference)
    }

    private func lookup(
        channels: [CatalogChannel] = [],
        movies: [CatalogMovie] = [],
        series: [CatalogSeries] = [],
        episodes: [CatalogEpisode] = [],
        progress: [ProgressRecord] = []
    ) -> ContinueOfferLookup {
        ContinueOfferLookup(
            channel: { key in channels.first { $0.key.rawValue == key } },
            programmeNow: { [programme] channel in channel.remoteID == "news" ? programme : nil },
            movie: { key in movies.first { $0.key.rawValue == key } },
            series: { key in series.first { $0.key.rawValue == key } },
            episode: { key in episodes.first { $0.key.rawValue == key } },
            progress: { key in progress.first { $0.itemKey == key } }
        )
    }

    @Test func aChannelPlaysLiveHereAndEndsTheOtherDevicesRow() throws {
        let card = try #require(ContinueOfferCards.card(offer(.channel(itemKey: news.key.rawValue)), lookup: lookup(channels: [news]), at: Fixture.reference))
        #expect(card.eyebrow == "On Bhavik's iPhone now")
        #expect(card.title == "Cityline News")
        #expect(card.subtitle == "Evening Bulletin")
        #expect(card.videoItemKey == nil)
        guard case .play(let intent) = card.request.content else { Issue.record("not a play"); return }
        #expect(intent.itemKey == news.key.rawValue)
        #expect(intent.kind == .live)
        #expect(card.request.endingPlaybackIDs == ids)
        #expect(card.request.deviceName == "Bhavik's iPhone")
    }

    @Test func whatThisDeviceCantPlayIsLeftOut() {
        let empty = lookup()
        #expect(ContinueOfferCards.card(offer(.channel(itemKey: news.key.rawValue)), lookup: empty, at: Fixture.reference) == nil)
        #expect(ContinueOfferCards.card(offer(.multiView(itemKeys: [news.key.rawValue])), lookup: empty, at: Fixture.reference) == nil)
        #expect(ContinueOfferCards.card(offer(.video(itemKey: Fixture.movie().key.rawValue)), lookup: empty, at: Fixture.reference) == nil)
        #expect(ContinueOfferCards.card(offer(.video(itemKey: Fixture.episodeKey(2, 4).rawValue)), lookup: empty, at: Fixture.reference) == nil)
    }

    @Test func multiViewKeepsTheChannelsThisDeviceHasInOrder() throws {
        let missing = Self.channel("gone", name: "Gone").key.rawValue
        let content = ContinueOffer.Content.multiView(itemKeys: [sport.key.rawValue, missing, news.key.rawValue])
        let card = try #require(ContinueOfferCards.card(offer(content), lookup: lookup(channels: [news, sport]), at: Fixture.reference))
        #expect(card.title == "Multi-view")
        #expect(card.subtitle == "Fieldhouse Sports and Cityline News")
        #expect(card.request.content == .multiView(channelKeys: [sport.key.rawValue, news.key.rawValue]))
        #expect(card.request.endingPlaybackIDs == ids, "every tile's row ends, even one this device can't show")
    }

    @Test func aMovieResumesFromTheProfilesProgress() throws {
        let movie = Fixture.movie(duration: 6000)
        let progress = Fixture.movieProgress(position: 1200, duration: 6000)
        let card = try #require(ContinueOfferCards.card(offer(.video(itemKey: movie.key.rawValue)), lookup: lookup(movies: [movie], progress: [progress]), at: Fixture.reference))
        #expect(card.title == "Harbour Lights")
        #expect(card.subtitle == HearthFormat.remaining(4800))
        #expect(card.artwork == .poster(title: "Harbour Lights", url: nil, progress: 0.2))
        #expect(card.videoItemKey == movie.key.rawValue)
        guard case .play(let intent) = card.request.content else { Issue.record("not a play"); return }
        #expect(intent.kind == .movie)
        #expect(intent.startPosition == nil, "the player reads the saved position")
    }

    @Test func anEpisodeNeedsOnlyItsShow() throws {
        let key = Fixture.episodeKey(2, 4)
        let card = try #require(ContinueOfferCards.card(offer(.video(itemKey: key.rawValue)), lookup: lookup(series: [Fixture.series()]), at: Fixture.reference))
        #expect(card.title == "The Lighthouse")
        #expect(card.subtitle == HearthFormat.episodeCode(season: 2, episode: 4))
        guard case .play(let intent) = card.request.content else { Issue.record("not a play"); return }
        #expect(intent.kind == .episode)
        #expect(intent.itemKey == key.rawValue)
    }

    @Test func theHeroStepsAsideForAVideoCardOfTheSameItem() throws {
        let movie = Fixture.movie()
        let card = try #require(ContinueOfferCards.card(offer(.video(itemKey: movie.key.rawValue)), lookup: lookup(movies: [movie]), at: Fixture.reference))
        #expect(ContinueOfferCards.heroIsCovered(heroItemKey: movie.key.rawValue, by: [card]))
        #expect(!ContinueOfferCards.heroIsCovered(heroItemKey: Fixture.movie("other").key.rawValue, by: [card]))
        #expect(!ContinueOfferCards.heroIsCovered(heroItemKey: nil, by: [card]))
    }

    @Test func atMostThreeCards() {
        let offers = (0..<5).map { index in
            ContinueOffer(content: .channel(itemKey: news.key.rawValue), deviceName: "Device \(index)", profileID: Fixture.profile, titles: [], playbackIDs: [], startedAt: Fixture.reference)
        }
        #expect(ContinueOfferCards.cards(offers, lookup: lookup(channels: [news]), at: Fixture.reference).map(\.request.deviceName) == ["Device 0", "Device 1", "Device 2"])
    }
}
