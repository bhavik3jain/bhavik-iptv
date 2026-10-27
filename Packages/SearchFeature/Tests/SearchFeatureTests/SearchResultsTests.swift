import CatalogKit
import Core
import Foundation
import Testing
@testable import SearchFeature

/// Builders for search hits, every date relative to one fixed `now`.
enum Hits {
    static let source = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func channel(_ name: String, number: Int?) -> CatalogChannel {
        CatalogChannel(
            key: .channel(source: source, id: name), sourceID: source, sourceName: "Provider A", remoteID: name,
            number: number, name: name, logoURL: nil, categoryID: nil, guideChannelID: name, hasArchive: true, archiveDays: 7
        )
    }

    /// A programme `start` to `end` minutes from `now`.
    static func programme(_ title: String, from start: Double, to end: Double, archive: Bool = false, channel: String = "c") -> CatalogProgramme {
        let startDate = now.addingTimeInterval(start * 60)
        return CatalogProgramme(
            id: "\(channel)-\(title)-\(start)", sourceID: source, guideChannelID: channel,
            start: startDate, end: now.addingTimeInterval(end * 60), title: title, summary: nil, category: nil, hasArchive: archive
        )
    }

    static func hit(_ title: String, on channel: CatalogChannel, from start: Double, to end: Double, archive: Bool = false) -> SearchResults.ProgrammeHit {
        .init(programme: programme(title, from: start, to: end, archive: archive, channel: channel.name), channel: channel)
    }

    static func movie(_ name: String) -> CatalogMovie {
        CatalogMovie(
            key: .movie(source: source, id: name), sourceID: source, sourceName: "Provider A", remoteID: name, name: name,
            categoryID: nil, posterURL: nil, year: nil, plot: nil, rating: nil, duration: nil, addedAt: nil, genre: nil, cast: nil
        )
    }

    static func series(_ name: String) -> CatalogSeries {
        CatalogSeries(
            key: .series(source: source, id: name), sourceID: source, sourceName: "Provider A", remoteID: name, name: name,
            categoryID: nil, posterURL: nil, plot: nil, year: nil, rating: nil, addedAt: nil, genre: nil
        )
    }
}

@Suite struct SearchResultGroupsTests {
    let news = Hits.channel("Cityline News", number: 101)
    let sport = Hits.channel("Arena Sport", number: 7)
    let film = Hits.channel("Film Four", number: nil)
    let alpha = Hits.channel("Alpha", number: nil)

    @Test func sectionsAreInDisplayOrder() {
        #expect(SearchSection.allCases == [.channels, .onTV, .movies, .shows])
    }

    @Test func onlySectionsWithResultsShow() {
        let results = SearchResults(channels: [news], movies: [], series: [Hits.series("Harbour")])
        let groups = SearchResultGroups(results, now: Hits.now)
        #expect(groups.sections == [.channels, .shows])
        #expect(!groups.isEmpty)
        #expect(groups.count(of: .channels) == 1)
        #expect(groups.count(of: .onTV) == 0)
        #expect(groups.count(of: .shows) == 1)
    }

    @Test func noResultsIsEmpty() {
        let groups = SearchResultGroups(SearchResults(), now: Hits.now)
        #expect(groups.isEmpty)
        #expect(groups.sections.isEmpty)
    }

    @Test func theCatalogsOwnOrderIsKeptForChannelsMoviesAndShows() {
        let results = SearchResults(
            channels: [news, sport],
            movies: [Hits.movie("Zulu"), Hits.movie("Alpha")],
            series: [Hits.series("Mystery"), Hits.series("Bones")]
        )
        let groups = SearchResultGroups(results, now: Hits.now)
        #expect(groups.channels.map(\.name) == ["Cityline News", "Arena Sport"])
        #expect(groups.movies.map(\.name) == ["Zulu", "Alpha"])
        #expect(groups.series.map(\.name) == ["Mystery", "Bones"])
    }

    @Test func aGroupAtTheCatalogsLimitIsCapped() {
        let fifty = (0..<SearchResultLimits.perGroup).map { Hits.movie("m\($0)") }
        let capped = SearchResultGroups(SearchResults(movies: fifty), now: Hits.now)
        #expect(capped.isCapped(.movies))
        #expect(!capped.isCapped(.channels))
        let under = SearchResultGroups(SearchResults(movies: Array(fifty.dropLast())), now: Hits.now)
        #expect(!under.isCapped(.movies))
    }

    @Test func onNowComesFirstByChannelNumber() {
        let hits = [
            Hits.hit("Later", on: sport, from: 30, to: 90),
            Hits.hit("Bulletin", on: news, from: -10, to: 20),
            Hits.hit("Match", on: sport, from: -30, to: 60),
        ]
        let ordered = SearchResultGroups.ordered(hits, now: Hits.now).map(\.programme.title)
        #expect(ordered == ["Match", "Bulletin", "Later"])
    }

    @Test func channelsWithoutANumberSortLastThenByName() {
        let hits = [
            Hits.hit("F", on: film, from: -5, to: 5),
            Hits.hit("A", on: alpha, from: -5, to: 5),
            Hits.hit("N", on: news, from: -5, to: 5),
        ]
        #expect(SearchResultGroups.ordered(hits, now: Hits.now).map(\.programme.title) == ["N", "A", "F"])
    }

    @Test func comingUpIsByStartTimeThenChannel() {
        let hits = [
            Hits.hit("Late", on: sport, from: 120, to: 180),
            Hits.hit("Soon B", on: news, from: 30, to: 60),
            Hits.hit("Soon A", on: sport, from: 30, to: 60),
        ]
        #expect(SearchResultGroups.ordered(hits, now: Hits.now).map(\.programme.title) == ["Soon A", "Soon B", "Late"])
    }

    @Test func endedProgrammesDropOutUnlessTheArchiveHasThem() {
        let hits = [
            Hits.hit("Gone", on: news, from: -60, to: -30),
            Hits.hit("Archived", on: news, from: -60, to: -30, archive: true),
            Hits.hit("Next", on: news, from: 10, to: 40),
        ]
        // Aired-with-archive programmes sort with the rest by start time, so
        // they come before what's still to come.
        #expect(SearchResultGroups.ordered(hits, now: Hits.now).map(\.programme.title) == ["Archived", "Next"])
    }

    @Test func theNowBoundaryIncludesTheStartAndExcludesTheEnd() {
        let hits = [
            Hits.hit("Starting", on: sport, from: 0, to: 30),
            Hits.hit("Ending", on: news, from: -30, to: 0),
        ]
        let ordered = SearchResultGroups.ordered(hits, now: Hits.now)
        #expect(ordered.map(\.programme.title) == ["Starting"])
    }

    @Test func theGroupsInitialiserOrdersTheGuideHits() {
        let results = SearchResults(programmes: [
            Hits.hit("Later", on: news, from: 30, to: 60),
            Hits.hit("Now", on: news, from: -5, to: 5),
        ])
        #expect(SearchResultGroups(results, now: Hits.now).programmes.map(\.programme.title) == ["Now", "Later"])
    }
}

@Suite struct SearchResultLimitsTests {
    @Test func collapsedCountsPerLayout() {
        #expect(SearchResultLimits.collapsedCount(for: .channels, layout: .compact) == 5)
        #expect(SearchResultLimits.collapsedCount(for: .onTV, layout: .compact) == 5)
        #expect(SearchResultLimits.collapsedCount(for: .channels, layout: .sidebar) == 8)
        #expect(SearchResultLimits.collapsedCount(for: .onTV, layout: .sidebar) == 8)
        #expect(SearchResultLimits.collapsedCount(for: .movies, layout: .sidebar) == 12)
        #expect(SearchResultLimits.collapsedCount(for: .shows, layout: .sidebar) == 12)
        #expect(SearchResultLimits.collapsedCount(for: .movies, layout: .compact) == .max)
        #expect(SearchResultLimits.collapsedCount(for: .shows, layout: .compact) == .max)
    }

    @Test func shortGroupsShowEverything() {
        #expect(SearchResultLimits.visibleCount(total: 0, section: .channels, layout: .compact, expanded: false) == 0)
        #expect(SearchResultLimits.visibleCount(total: 3, section: .channels, layout: .compact, expanded: false) == 3)
        #expect(SearchResultLimits.visibleCount(total: 5, section: .channels, layout: .compact, expanded: false) == 5)
    }

    @Test func oneStragglerIsNeverHidden() {
        #expect(SearchResultLimits.visibleCount(total: 6, section: .channels, layout: .compact, expanded: false) == 6)
        #expect(SearchResultLimits.visibleCount(total: 9, section: .onTV, layout: .sidebar, expanded: false) == 9)
    }

    @Test func longGroupsCollapseToTheLimit() {
        #expect(SearchResultLimits.visibleCount(total: 7, section: .channels, layout: .compact, expanded: false) == 5)
        #expect(SearchResultLimits.visibleCount(total: 50, section: .movies, layout: .sidebar, expanded: false) == 12)
    }

    @Test func expandedShowsEverything() {
        #expect(SearchResultLimits.visibleCount(total: 50, section: .channels, layout: .compact, expanded: true) == 50)
    }

    @Test func phonePosterRowsScrollSoTheyShowEverything() {
        #expect(SearchResultLimits.visibleCount(total: 50, section: .movies, layout: .compact, expanded: false) == 50)
    }
}

@Suite struct ProgrammeHitActionTests {
    @Test func onAirPlaysLive() {
        #expect(ProgrammeHitAction.resolve(Hits.programme("p", from: -10, to: 10), now: Hits.now) == .watchLive)
        #expect(ProgrammeHitAction.resolve(Hits.programme("p", from: 0, to: 10), now: Hits.now) == .watchLive)
        #expect(ProgrammeHitAction.resolve(Hits.programme("p", from: -10, to: 10, archive: true), now: Hits.now) == .watchLive)
    }

    @Test func airedWithAnArchivePlaysCatchUp() {
        #expect(ProgrammeHitAction.resolve(Hits.programme("p", from: -60, to: -30, archive: true), now: Hits.now) == .watchCatchUp)
        #expect(ProgrammeHitAction.resolve(Hits.programme("p", from: -60, to: 0, archive: true), now: Hits.now) == .watchCatchUp)
    }

    @Test func everythingElseOpensTheChannel() {
        #expect(ProgrammeHitAction.resolve(Hits.programme("p", from: -60, to: -30), now: Hits.now) == .openChannel)
        #expect(ProgrammeHitAction.resolve(Hits.programme("p", from: 30, to: 60), now: Hits.now) == .openChannel)
        #expect(ProgrammeHitAction.resolve(Hits.programme("p", from: 30, to: 60, archive: true), now: Hits.now) == .openChannel)
    }
}

@Suite struct SearchTimeTextTests {
    let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func daysAreCountedInTheCalendar() {
        let now = date(26, 12)
        #expect(SearchTimeText.day(date(26, 0), now: now, calendar: utc) == "Today")
        #expect(SearchTimeText.day(date(26, 23, 59), now: now, calendar: utc) == "Today")
        #expect(SearchTimeText.day(date(27, 0), now: now, calendar: utc) == "Tomorrow")
        #expect(SearchTimeText.day(date(25, 23), now: now, calendar: utc) == "Yesterday")
    }

    @Test func justAfterMidnightIsTomorrow() {
        #expect(SearchTimeText.day(date(27, 0, 15), now: date(26, 23, 30), calendar: utc) == "Tomorrow")
    }

    @Test func furtherAwayIsAWeekday() {
        let later = date(28, 12)
        let text = SearchTimeText.day(later, now: date(26, 12), calendar: utc)
        #expect(text == later.formatted(.dateTime.weekday(.abbreviated)))
        #expect(!["Today", "Tomorrow", "Yesterday"].contains(text))
    }

    @Test func onAirSaysUntilWhen() {
        let programme = Hits.programme("p", from: -10, to: 20)
        #expect(SearchTimeText.when(programme, now: Hits.now, calendar: utc) == "Now · until \(HearthFormat.clock(programme.end))")
    }

    @Test func upcomingSaysTheDayAndTime() {
        let now = date(26, 23, 30)
        let programme = CatalogProgramme(id: "p", sourceID: Hits.source, guideChannelID: "c", start: date(27, 6), end: date(27, 7), title: "Breakfast", summary: nil, category: nil, hasArchive: false)
        #expect(SearchTimeText.when(programme, now: now, calendar: utc) == "Tomorrow \(HearthFormat.clock(programme.start))")
    }

    @Test func airedSaysSo() {
        let now = date(26, 20)
        let programme = CatalogProgramme(id: "p", sourceID: Hits.source, guideChannelID: "c", start: date(26, 18), end: date(26, 19), title: "Early News", summary: nil, category: nil, hasArchive: true)
        #expect(SearchTimeText.when(programme, now: now, calendar: utc) == "Aired Today \(HearthFormat.clock(programme.start))")
    }

    @Test func spokenNamesTheProgrammeChannelAndTime() {
        let channel = Hits.channel("Cityline News", number: 101)
        let hit = Hits.hit("Evening Bulletin", on: channel, from: -10, to: 20)
        let spoken = SearchTimeText.spoken(hit, now: Hits.now, calendar: utc)
        #expect(spoken == "Evening Bulletin, on 101 Cityline News, Now · until \(HearthFormat.clock(hit.programme.end))")

        let unnumbered = Hits.hit("Evening Bulletin", on: Hits.channel("Cityline News", number: nil), from: -10, to: 20)
        #expect(SearchTimeText.spoken(unnumbered, now: Hits.now, calendar: utc).hasPrefix("Evening Bulletin, on Cityline News, "))
    }
}

@Suite struct SearchLabelTests {
    @Test func posterDetailJoinsWhatItHas() {
        #expect(PosterDetail.text(year: 2019, sourceName: "Provider B") == "2019 · Provider B")
        #expect(PosterDetail.text(year: 2019, sourceName: nil) == "2019")
        #expect(PosterDetail.text(year: 2019, sourceName: "") == "2019")
        #expect(PosterDetail.text(year: nil, sourceName: "Provider B") == "Provider B")
        #expect(PosterDetail.text(year: nil, sourceName: "") == nil)
        #expect(PosterDetail.text(year: nil, sourceName: nil) == nil)
    }

    @Test func sectionTitles() {
        #expect(SearchSection.allCases.map(\.title) == ["Channels", "On TV", "Movies", "Shows"])
    }

    @Test func spokenCountsUseThePluralRules() {
        #expect(SearchSection.channels.spokenCount(3) == "3 channels")
        #expect(SearchSection.channels.spokenCount(1) == "1 channel")
        #expect(SearchSection.onTV.spokenCount(1) == "1 programme")
        #expect(SearchSection.movies.spokenCount(2) == "2 movies")
        #expect(SearchSection.shows.spokenCount(1) == "1 show")
    }
}
